import AVFoundation
import CoreAudio
import Speech
import Translation

/// 实时语音识别引擎。
///
/// 采集层采用 `AVAudioEngine` 的 inputNode（macOS 上最可靠的麦克风采集路径，
/// 微信等成熟应用均采用该方案），并通过 CoreAudio 将系统默认输入设备切换为
/// 用户所选的外置麦克风（AVAudioEngine 只能读取系统默认输入设备），
/// 停止/退出时自动恢复原设备。
///
/// 音频统一转换为 16kHz 单声道 Float32 后送入 `SFSpeechAudioBufferRecognitionRequest`，
/// 完全本地识别，不联网。
/// 一条翻译记录（英文原文 + 中文译文 + 发生时间）。
struct TranslationEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let source: String
    let target: String
}

/// 一节课程（用于课后回看完整翻译记录）。
struct CourseSession: Identifiable, Equatable {
    let id = UUID()
    let startDate: Date
    let endDate: Date
    let entries: [TranslationEntry]

    /// 课程时长（秒）。
    var duration: TimeInterval { endDate.timeIntervalSince(startDate) }
}

@MainActor
final class SpeechEngine: NSObject, ObservableObject {
    /// 当前已识别出的英文文本（随语音实时累积）。
    @Published private(set) var recognizedText = ""
    /// 是否正在录音识别中。
    @Published private(set) var isRecording = false
    /// 输入电平（0…1），用于 UI 的振幅反馈。
    @Published private(set) var level: Float = 0
    /// 是否已成功采集到音频数据（用于诊断"未检测到语音"）。
    @Published private(set) var audioActive = false
    /// 最近一次错误提示（已转为可操作的中文）。
    @Published private(set) var lastError: String?
    /// 已翻译出的中文文本（随完整句子逐句追加）。
    @Published private(set) var translatedText = ""
    /// 是否正在翻译中。
    @Published private(set) var isTranslating = false
    /// 系统版本不支持翻译（需 macOS 15+）。
    @Published private(set) var translationUnavailable = false
    /// 是否启用实时翻译（可在界面上开关）。
    @Published var isTranslationEnabled = true

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var forwarder: AudioForwarder?
    private var previousDefaultInputID: AudioDeviceID = 0
    private var finalText = ""

    // MARK: - 长时间运行（自动分段 / 自动恢复 / 计时）

    /// 本次录音已运行时长（秒），用于界面显示课堂进行时间。
    @Published private(set) var sessionDuration: TimeInterval = 0
    private var sessionStartDate: Date?
    private var sessionDurationTask: Task<Void, Never>?
    /// 自动分段循环任务：每 60 秒结束当前识别会话并新建一个，
    /// 防止单次 SFSpeechRecognitionTask 长时间运行累积延迟/误差。
    private var segmentLoopTask: Task<Void, Never>?
    /// 是否正在分段切换中。
    private var isSegmenting = false
    /// 分段计数（诊断日志用）。
    private var segmentCount = 0
    /// 连续自动重连失败次数（超过上限后停止，提示用户手动操作）。
    private var autoRestartFailures = 0

    // MARK: - 课程记录

    /// 全部翻译记录（带时间戳）。界面仅显示最近 1 分钟，其余保留用于课后回看。
    @Published private(set) var translationEntries: [TranslationEntry] = []
    /// 课程是否进行中。
    @Published private(set) var isCourseActive = false
    /// 课程开始时间。
    @Published private(set) var courseStartDate: Date?
    /// 课程进行时长（秒），用于界面显示。
    @Published private(set) var courseDuration: TimeInterval = 0
    /// 最近一节已结束的课程（供课后回看）。
    @Published private(set) var completedCourse: CourseSession?
    /// 课程时长计时器。
    private var courseTimerTask: Task<Void, Never>?
    /// 翻译记录最多保留条数（防止长时间运行内存膨胀）。
    private static let maxTranslationEntries = 10_000
    /// 界面仅显示最近这一时间窗内的翻译记录。
    static let visibleTranslationWindow: TimeInterval = 60

    // MARK: - 翻译状态

    /// 翻译会话（由视图层 `.translationTask` 注入；用 Any 持有以兼容 14.0 部署目标）。
    /// 使用 `.translationTask` 创建的会话 `canRequestDownloads` 为 true，
    /// 语言包缺失时系统会自动弹出下载提示。
    var translationSessionBox: Any?
    /// 翻译服务（macOS 15+ 可用，用 Any 持有以兼容 14.0 部署目标）。
    private var translationServiceBox: Any?

    /// 由视图层 `.translationTask` 注入翻译会话。
    /// 该会话 `canRequestDownloads` 为 true，语言包缺失时系统会弹出下载提示。
    func setTranslationSession(_ session: Any) {
        translationSessionBox = session
    }
    /// 已翻译句子的原文集合（去重，避免识别修正导致重复翻译）。
    private var translatedSentenceKeys: Set<String> = []
    /// 防抖任务：识别停止一段时间后才翻译，避免随每帧识别结果抖动。
    private var translationDebounceTask: Task<Void, Never>?
    /// 翻译串行链：保证翻译按顺序执行，避免并发导致译文乱序。
    private var translationChain: Task<Void, Never>?

    /// SFSpeechRecognizer 最兼容的输入格式：16kHz 单声道 Float32。
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    // MARK: - 诊断

    /// 诊断日志文件路径（便于排查权限/设备问题）。
    nonisolated private static let diagLogPath = "/tmp/realtimetranslator_diag.log"

    nonisolated private static func diag(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        if let data = line.data(using: .utf8) {
            if let handle = FileHandle(forWritingAtPath: Self.diagLogPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: Self.diagLogPath))
            }
        }
    }

    // MARK: - 控制

    /// 开始录音识别。若已在录音则先停止。
    func start(deviceID: String) {
        if isRecording {
            stop()
        }
        guard !isRecording else { return }
        Self.diag("===== start(deviceID=\(deviceID)) =====")

        // 0. 麦克风权限兜底：未授权则主动弹窗请求；已拒绝则给出指引。
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            Self.diag("麦克风权限 notDetermined，主动请求…")
            let sem = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Self.diag("请求麦克风权限结果: \(granted)")
                sem.signal()
            }
            sem.wait()
        case .denied, .restricted:
            lastError = "麦克风权限未开启：请在「系统设置 → 隐私与安全性 → 麦克风」中允许本应用后重试。"
            Self.diag("麦克风权限 denied/restricted")
            return
        default:
            Self.diag("麦克风权限已授权")
        }

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            lastError = "语音识别不可用，请到「系统设置 → 隐私与安全性 → 语音识别」确认已开启并下载英语语言包。"
            Self.diag("语音识别器不可用")
            return
        }
        guard let audioDeviceID = Self.audioDeviceID(for: deviceID) else {
            lastError = "找不到所选麦克风对应的系统音频设备，请重新选择或刷新设备列表。"
            Self.diag("audioDeviceID(for:) 匹配失败: \(deviceID)")
            return
        }
        Self.diag("所选设备 \(deviceID) → CoreAudio id=\(audioDeviceID)")

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true // 完全本地识别，无需联网

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                self?.handleRecognitionResult(result, error: error)
            }
        }

        previousDefaultInputID = Self.defaultInputDeviceID()
        Self.diag("切换前默认输入设备 id=\(previousDefaultInputID)")

        do {
            // 1. 将系统默认输入设备切换为所选麦克风（AVAudioEngine 只能读默认输入）
            let status = Self.setDefaultInputDevice(audioDeviceID)
            Self.diag("setDefaultInputDevice(\(audioDeviceID)) 返回 \(status)")
            guard status == noErr else {
                restoreInput()
                lastError = "无法切换到所选麦克风（错误码 \(status)）。"
                return
            }
            // 切换是异步生效的：给系统一点时间完成重配，避免引擎读到过渡期格式。
            Thread.sleep(forTimeInterval: 0.4)
            Self.diag("切换后默认输入设备 id=\(Self.defaultInputDeviceID())")

            // 2. 启动音频引擎，统一转换为 16kHz 单声道 Float32
            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            var hardwareFormat = inputNode.outputFormat(forBus: 0)
            // 过渡期可能拿到 0Hz / 0 声道，重试一次。
            if hardwareFormat.sampleRate <= 0 || hardwareFormat.channelCount <= 0 {
                Self.diag("首次取格式异常 (\(hardwareFormat.sampleRate)Hz/\(hardwareFormat.channelCount)ch)，重试…")
                Thread.sleep(forTimeInterval: 0.5)
                hardwareFormat = inputNode.outputFormat(forBus: 0)
            }
            Self.diag("硬件格式: \(hardwareFormat.sampleRate)Hz / \(hardwareFormat.channelCount)ch")
            guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0,
                  let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
                restoreInput()
                lastError = "无法适配麦克风音频格式（\(hardwareFormat.sampleRate)Hz）。"
                Self.diag("转换器创建失败")
                return
            }

            let forwarder = AudioForwarder(targetFormat: targetFormat)
            forwarder.request = request
            forwarder.converter = converter
            forwarder.onLevel = { [weak self] value in
                Task { @MainActor in
                    self?.level = value
                }
            }
            forwarder.onAudioActive = { [weak self] active in
                Task { @MainActor in
                    self?.audioActive = active
                }
            }
            forwarder.onError = { [weak self] message in
                Task { @MainActor in
                    self?.lastError = message
                }
            }
            self.forwarder = forwarder

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak forwarder] buffer, _ in
                forwarder?.handle(buffer)
            }

            engine.prepare()
            try engine.start()
            Self.diag("AVAudioEngine.start() 成功")

            audioEngine = engine
            recognitionRequest = request
            isRecording = true
            level = 0
            audioActive = false
            lastError = nil
            sessionStartDate = Date()
            sessionDuration = 0
            segmentCount = 0
            autoRestartFailures = 0
            startSegmentationLoop()
            startDurationTimer()
            Self.diag("长时间运行保护已启动（自动分段 60s / 自动重连 / 计时）")

            // 3. 看门狗：3 秒内没有音频回调则提示（区分"没权限/设备问题"与"说话问题"）。
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, self.isRecording, !self.audioActive else { return }
                self.lastError = "3 秒内未采集到音频：请确认「系统设置 → 隐私与安全性 → 麦克风」已允许本应用（如未出现授权弹窗，请先在系统设置中手动添加本应用），并确认输入音量不为 0。"
            }
        } catch {
            restoreInput()
            lastError = "无法启动录音：\(error.localizedDescription)"
            Self.diag("engine.start 抛出异常: \(error)")
        }
    }

    /// 停止录音并恢复系统默认输入设备，保留已识别文本。
    func stop() {
        guard isRecording else { return }
        segmentLoopTask?.cancel()
        segmentLoopTask = nil
        sessionDurationTask?.cancel()
        sessionDurationTask = nil
        sessionStartDate = nil
        isSegmenting = false
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        forwarder = nil
        restoreInput()
        isRecording = false
        level = 0
        audioActive = false
    }

    // MARK: - 长时间运行保护

    /// 统一的识别结果回调处理：更新文本、触发增量翻译、处理结束/异常。
    /// - 正常 partial：刷新 recognizedText 并触发停顿判句翻译。
    /// - isFinal：把本段文本固化进 finalText，再按当前模式（分段/结束）处理。
    /// - 非用户主动停止的错误：自动重连新分段。
    private func handleRecognitionResult(_ result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            recognizedText = finalText + result.bestTranscription.formattedString
            updateTranslationIfNeeded(for: recognizedText)
        }
        if let error {
            lastError = friendlyMessage(for: error)
            Self.diag("识别错误: \(error)")
        }
        guard result?.isFinal == true || error != nil else { return }

        if let result {
            finalText += result.bestTranscription.formattedString
            recognizedText = finalText
            updateTranslationIfNeeded(for: recognizedText)
        }
        recognitionRequest = nil
        recognitionTask = nil

        if isSegmenting {
            // 自动分段：无缝开启新分段继续识别。
            isSegmenting = false
            Self.diag("分段 #\(segmentCount) 结束，开启新分段")
            startRecognitionSegment()
        } else if error != nil, isRecording {
            // 非用户主动停止的异常：尝试自动重连。
            scheduleAutoRestart()
        }
    }

    /// 结束当前识别会话，并在其 isFinal 回调后启动新分段。
    /// 音频引擎不停止，实现无缝续识别；分段间隙丢弃的音频约几百毫秒。
    private func segmentRecognition() {
        guard isRecording, !isSegmenting else { return }
        guard let request = recognitionRequest else { return }
        isSegmenting = true
        segmentCount += 1
        Self.diag("自动分段 #\(segmentCount)：结束当前识别会话")
        // 先停止向旧请求写入（endAudio 后不能再 append），等 isFinal 回调里开新分段。
        forwarder?.request = nil
        request.endAudio()
        // 兜底：若 5 秒内未收到 isFinal（识别器卡住），强制开启新分段，避免识别静止。
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, self.isRecording, self.isSegmenting else { return }
            Self.diag("分段超时未结束，强制开启新分段")
            self.isSegmenting = false
            self.recognitionRequest = nil
            self.recognitionTask = nil
            self.startRecognitionSegment()
        }
    }

    /// 创建新的识别会话（音频引擎保持运行），用于自动分段与异常重连。
    private func startRecognitionSegment() {
        guard isRecording, let recognizer = speechRecognizer, recognizer.isAvailable else {
            Self.diag("无法开启新分段：识别器不可用")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                self?.handleRecognitionResult(result, error: error)
            }
        }
        recognitionRequest = request
        forwarder?.request = request
        Self.diag("新识别分段已开启（累计分段 #\(segmentCount)）")
    }

    /// 识别异常后的自动重连：3 秒后开新分段，连续失败 5 次则停止并提示。
    private func scheduleAutoRestart() {
        guard isRecording, !isSegmenting else { return }
        autoRestartFailures += 1
        guard autoRestartFailures <= 5 else {
            lastError = "语音识别已连续中断多次，请点「停止」后重新「开始」。"
            Self.diag("自动重连超过 5 次，停止重试")
            return
        }
        Self.diag("识别异常，3 秒后自动重连（第 \(autoRestartFailures) 次）…")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.isRecording, !self.isSegmenting else { return }
            self.startRecognitionSegment()
        }
    }

    /// 每 60 秒触发一次自动分段。
    private func startSegmentationLoop() {
        segmentLoopTask?.cancel()
        segmentLoopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.isRecording {
                    self.segmentRecognition()
                }
            }
        }
    }

    /// 每秒刷新一次已运行时长（界面显示课堂进行时间）。
    private func startDurationTimer() {
        sessionDurationTask?.cancel()
        sessionDurationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if let start = self.sessionStartDate, self.isRecording {
                    self.sessionDuration = Date().timeIntervalSince(start)
                }
            }
        }
    }

    /// 清空当前识别与翻译文本（不影响权限与录音状态）。
    func clear() {
        finalText = ""
        recognizedText = ""
        translatedText = ""
        translatedSentenceKeys.removeAll()
        translationDebounceTask?.cancel()
        translationDebounceTask = nil
        translationChain?.cancel()
        translationChain = nil
        lastError = nil
        translationEntries.removeAll()
        completedCourse = nil
    }

    // MARK: - 课程控制

    /// 开始一节课程：记录开始时间并清空上一节状态。
    /// 视图层通常联动「开始录音」一起调用。
    func startCourse() {
        courseStartDate = Date()
        courseDuration = 0
        isCourseActive = true
        completedCourse = nil
        startCourseTimer()
        Self.diag("课程开始")
    }

    /// 结束当前课程：归档本节课的翻译记录，供课后回看。
    func endCourse() {
        guard isCourseActive, let start = courseStartDate else { return }
        let entries = translationEntries.filter { $0.timestamp >= start }
        completedCourse = CourseSession(startDate: start, endDate: Date(), entries: entries)
        isCourseActive = false
        courseStartDate = nil
        courseTimerTask?.cancel()
        courseTimerTask = nil
        Self.diag("课程结束，共记录 \(entries.count) 条翻译")
    }

    private func startCourseTimer() {
        courseTimerTask?.cancel()
        courseTimerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if let start = self.courseStartDate, self.isCourseActive {
                    self.courseDuration = Date().timeIntervalSince(start)
                }
            }
        }
    }

    // MARK: - 翻译

    /// 根据最新识别文本，找出"已说完的完整句子"并增量翻译。
    ///
    /// 本地语音识别的结果通常**不带标点**，因此不能依赖句号/问号判断句子结束，
    /// 改为「停顿判句」：识别文本稳定约 1.2 秒（用户说完一句话的自然停顿）即视为
    /// 一句话结束并翻译；带终止标点的句子则立即按句翻译。已翻译的句子通过
    /// `translatedSentenceKeys` 去重，避免识别修正导致重复翻译。
    private func updateTranslationIfNeeded(for text: String) {
        guard isTranslationEnabled else { return }
        guard #available(macOS 15.0, *) else {
            translationUnavailable = true
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 先收集已明确的完整句子（带终止标点，或非最后一段）。
        let sentences = Self.splitIntoSentences(trimmed)
        var pending: [String] = []
        for (i, sentence) in sentences.enumerated() {
            let t = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if i < sentences.count - 1 || Self.endsWithTerminalPunctuation(sentence) {
                guard !translatedSentenceKeys.contains(t) else { continue }
                translatedSentenceKeys.insert(t)
                pending.append(t)
            }
        }
        // 最后一段未终止的文本：停顿后一并翻译。
        let openSentence = sentences.last?.trimmingCharacters(in: .whitespacesAndNewlines)

        translationDebounceTask?.cancel()
        translationDebounceTask = Task { @MainActor [weak self] in
            // 长防抖：用户停顿 ≈ 一句话结束（识别结果一般不带标点）。
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, !Task.isCancelled else { return }
            // 防抖期间识别文本又被更新 → 还在说话，本轮跳过，等下一轮。
            if self.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines) != trimmed { return }

            var toTranslate = pending
            if let openSentence, !openSentence.isEmpty,
               !translatedSentenceKeys.contains(openSentence) {
                translatedSentenceKeys.insert(openSentence)
                toTranslate.append(openSentence)
            }
            Self.diag("停顿判句，待翻译: \(toTranslate.joined(separator: " | "))")
            guard !toTranslate.isEmpty else { return }
            await self.enqueueTranslation(toTranslate)
        }
    }

    /// 把一组待翻译句子追加到串行队列，保证译文按顺序追加，杜绝并发乱序。
    private func enqueueTranslation(_ sentences: [String]) {
        let previous = translationChain
        translationChain = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self, !Task.isCancelled else { return }
            await self.translateSentences(sentences)
        }
    }

    private func translateSentences(_ sentences: [String]) async {
        guard #available(macOS 15.0, *) else { return }
        // 会话未就绪（视图层 .translationTask 尚未执行）时直接放弃本轮，等下一轮。
        guard let session = translationSessionBox as? TranslationSession else {
            Self.diag("翻译会话未就绪，跳过本轮")
            return
        }
        let service: TranslationService
        if let existing = translationServiceBox as? TranslationService {
            service = existing
        } else {
            service = TranslationService()
            translationServiceBox = service
        }
        isTranslating = true
        Self.diag("开始翻译: \(sentences.joined(separator: " | "))")
        do {
            let results = try await service.translate(sentences, session: session)
            Self.diag("翻译完成: \(results.joined(separator: " | "))")
            for (source, result) in zip(sentences, results) where !result.isEmpty {
                translationEntries.append(TranslationEntry(timestamp: Date(), source: source, target: result))
                // 上限保护：只保留最近 N 条，防止长时间运行内存膨胀。
                if translationEntries.count > Self.maxTranslationEntries {
                    translationEntries.removeFirst(translationEntries.count - Self.maxTranslationEntries)
                }
                if !translatedText.isEmpty {
                    translatedText += "\n"
                }
                translatedText += result
            }
        } catch {
            Self.diag("翻译失败: \(error)")
            if #available(macOS 26.0, *) {
                switch error {
                case TranslationError.notInstalled:
                    lastError = "需要下载英中翻译语言包：系统将弹出下载提示，请允许下载后重试；或在「系统设置 → 通用 → 翻译」中手动下载。"
                default:
                    lastError = "翻译失败：\(error.localizedDescription)"
                }
            } else {
                lastError = "翻译失败：\(error.localizedDescription)"
            }
        }
        isTranslating = false
    }

    /// 按句子终止符（. ! ? …）切分文本，返回句子列表（含结尾标点）。
    private static func splitIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for char in text {
            current.append(char)
            if Self.isTerminalPunctuation(char) {
                sentences.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            sentences.append(current)
        }
        return sentences
    }

    private static func isTerminalPunctuation(_ char: Character) -> Bool {
        char == "." || char == "!" || char == "?" || char == "…"
    }

    private static func endsWithTerminalPunctuation(_ sentence: String) -> Bool {
        guard let last = sentence.last else { return false }
        return isTerminalPunctuation(last)
    }

    /// 将系统错误转为用户可操作的中文提示。
    private func friendlyMessage(for error: Error) -> String {
        let ns = error as NSError
        let desc = ns.localizedDescription
        if desc.localizedCaseInsensitiveContains("no speech") {
            return "未检测到语音：请确认已选中正确的麦克风、麦克风权限已开启、系统输入音量不为 0，并靠近麦克风清晰说话。"
        }
        if ns.domain == "kAFAssistantErrorDomain" {
            switch ns.code {
            case 203:
                return "语音识别不可用：请到「系统设置 → 隐私与安全性 → 语音识别」开启权限并下载英语语言包。"
            case 1101:
                return "识别任务中断，正在自动重连…（如连续失败请点「停止」后重新「开始」）"
            case 2096, 2161:
                return "语音识别服务暂时不可用，请稍后重试。"
            default:
                break
            }
        }
        return "识别错误：\(desc)"
    }

    // MARK: - CoreAudio 设备管理

    /// 恢复系统默认输入设备（录音开始时切换前的设备）。
    private func restoreInput() {
        if previousDefaultInputID != 0 {
            _ = Self.setDefaultInputDevice(previousDefaultInputID)
            previousDefaultInputID = 0
        }
    }

    /// 将 AVCaptureDevice.uniqueID 匹配到对应的系统音频设备 ID。
    /// 优先按设备 UID 精确匹配，其次按设备名称匹配。
    private static func audioDeviceID(for captureDeviceID: String) -> AudioDeviceID? {
        let devices = inputDeviceIDs()
        if let hit = devices.first(where: { deviceUID($0) == captureDeviceID }) {
            return hit
        }
        if let name = AVCaptureDevice(uniqueID: captureDeviceID)?.localizedName,
           let hit = devices.first(where: { deviceName($0) == name }) {
            return hit
        }
        return nil
    }

    private static func allAudioDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
        return status == noErr ? ids : []
    }

    private static func inputDeviceIDs() -> [AudioDeviceID] {
        allAudioDeviceIDs().filter { deviceHasInput($0) }
    }

    private static func deviceHasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static func deviceStringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        guard status == noErr, let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }

    private static func deviceUID(_ id: AudioDeviceID) -> String? {
        deviceStringProperty(id, kAudioDevicePropertyDeviceUID)
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        deviceStringProperty(id, kAudioDevicePropertyDeviceNameCFString)
    }

    private static func defaultInputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    @discardableResult
    private static func setDefaultInputDevice(_ id: AudioDeviceID) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = id
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &deviceID
        )
    }
}

// MARK: - 音频缓冲转发器

/// 音频缓冲转发器：在采集线程上完成 PCM 转换、送入识别请求并计算电平。
/// 独立于 @MainActor 之外，避免 tap 回调与主线程隔离冲突。
private final class AudioForwarder {
    var request: SFSpeechAudioBufferRecognitionRequest?
    var converter: AVAudioConverter?
    let targetFormat: AVAudioFormat
    var onLevel: ((Float) -> Void)?
    var onAudioActive: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

    init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
    }

    private static let diagLogPath = "/tmp/realtimetranslator_diag.log"
    private static func diag(_ message: String) {
        let line = "[\(Date())] [forwarder] \(message)\n"
        if let data = line.data(using: .utf8) {
            if let handle = FileHandle(forWritingAtPath: diagLogPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: diagLogPath))
            }
        }
    }

    func handle(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let request else {
            // 分段切换间隙或尚未启动识别请求时静默丢弃（避免刷日志）。
            return
        }
        guard let converted = Self.convert(buffer, with: converter, to: targetFormat) else {
            Self.diag("handle: 转换失败（输入 \(buffer.format.sampleRate)Hz/\(buffer.format.channelCount)ch/\(buffer.frameLength)frames）")
            onError?("音频格式转换失败，请尝试更换输入设备。")
            return
        }
        request.append(converted)
        onLevel?(Self.computeLevel(converted))
        onAudioActive?(true)
    }

    /// 统一转换到目标格式；已是目标格式则直接复用。
    private static func convert(_ pcm: AVAudioPCMBuffer, with converter: AVAudioConverter, to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        if pcm.format.sampleRate == target.sampleRate,
           pcm.format.channelCount == target.channelCount,
           pcm.format.commonFormat == target.commonFormat {
            return pcm
        }
        let ratio = target.sampleRate / pcm.format.sampleRate
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var consumed = false
        var convertError: NSError?
        let status = converter.convert(to: output, error: &convertError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return pcm
        }
        guard convertError == nil, status == .haveData || status == .inputRanDry else { return nil }
        return output
    }

    /// 计算输入电平（Float 格式的 RMS，映射到 0…1）。
    private static func computeLevel(_ pcm: AVAudioPCMBuffer) -> Float {
        guard let channel = pcm.floatChannelData?[0] else { return 0 }
        let frameCount = Int(pcm.frameLength)
        guard frameCount > 0 else { return 0 }

        let stride = max(1, frameCount / 128)
        var sum: Float = 0
        var count = 0
        var i = 0
        while i < frameCount {
            let v = channel[i]
            sum += v * v
            count += 1
            i += stride
        }
        let rms = sqrt(sum / Float(count))
        return min(max(rms * 12, 0), 1)
    }
}
