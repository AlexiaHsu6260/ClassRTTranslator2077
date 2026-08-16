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
/// 一条翻译记录（英文原文 + 中文译文 + 发生时间 + 录音偏移）。
struct TranslationEntry: Identifiable, Equatable, Codable {
    let id = UUID()
    let timestamp: Date
    let source: String
    let target: String
    /// 该句在课堂录音中的起始偏移（秒）。0 表示不可用（历史数据或未开启录音）。
    var audioTime: TimeInterval = 0

    init(timestamp: Date, source: String, target: String, audioTime: TimeInterval = 0) {
        self.timestamp = timestamp
        self.source = source
        self.target = target
        self.audioTime = audioTime
    }

    /// 归档时不编码 id（加载时自动生成新的即可）。
    private enum CodingKeys: String, CodingKey {
        case timestamp, source, target, audioTime
    }
}

/// 一节课程（用于课后回看完整翻译记录）。
struct CourseSession: Identifiable, Equatable, Codable {
    let id = UUID()
    let startDate: Date
    let endDate: Date
    let entries: [TranslationEntry]
    /// 本节课同步保存的课堂录音文件地址（边录边存，可选）。
    var recordingURL: URL?

    /// 课程时长（秒）。
    var duration: TimeInterval { endDate.timeIntervalSince(startDate) }

    /// 归档时不编码 id（加载时自动生成新的即可）。
    private enum CodingKeys: String, CodingKey {
        case startDate, endDate, entries, recordingURL
    }
}

// MARK: - 离线翻译 KV 缓存

/// 离线翻译 KV 缓存：同一句子（同一术语表）首次翻译后落盘，断网或重复出现时直接命中，
/// 降低 API 依赖与费用。术语表变化会自动使缓存失效（指纹不同）。
enum TranslationCache {
    private static let defaults = UserDefaults.standard
    private static let keyPrefix = "translation_cache_v1_"
    /// 缓存放飞上限：超过后删除最早的键。
    private static let maxEntries = 1_000

    static func cached(_ sentence: String, glossaryFingerprint: String) -> String? {
        defaults.string(forKey: keyPrefix + glossaryFingerprint + "|" + sentence)
    }

    static func store(_ sentence: String, _ result: String, glossaryFingerprint: String) {
        defaults.set(result, forKey: keyPrefix + glossaryFingerprint + "|" + sentence)
        trimIfNeeded()
    }

    /// 稳定哈希（不依赖进程内随机的 String.hashValue，保证重启后仍有效）。
    static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 14695981039346656037
        for byte in s.utf8 {
            h = (h ^ UInt64(byte)) &* 1099511628211
        }
        return h
    }

    private static func trimIfNeeded() {
        let all = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(keyPrefix) }
        guard all.count > maxEntries * 2 else { return }
        for key in all.sorted().prefix(maxEntries) {
            defaults.removeObject(forKey: key)
        }
    }
}

// MARK: - 课程记录归档

/// 课程记录归档：课程结束后把完整记录（含录音偏移）保存为 JSON 到「桌面/课程记录/记录/」，
/// 供历史课程浏览与关键词检索（不依赖内存中的 completedCourse）。
enum CourseArchive {
    private static var folder: URL? {
        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else { return nil }
        return desktop
            .appendingPathComponent("课程记录", isDirectory: true)
            .appendingPathComponent("记录", isDirectory: true)
    }

    static func save(_ session: CourseSession) {
        guard let folder else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
            let name = "\(formatter.string(from: session.startDate)).json"
            if let data = try? JSONEncoder().encode(session) {
                try data.write(to: folder.appendingPathComponent(name))
            }
        } catch {
            // 归档失败不影响主流程（下次课程结束会再次尝试）。
        }
    }

    /// 按开始时间倒序返回全部历史课程。
    static func loadAll() -> [CourseSession] {
        guard let folder else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let sessions = files.filter { $0.pathExtension == "json" }.compactMap { url -> CourseSession? in
            guard let data = try? Data(contentsOf: url),
                  let session = try? JSONDecoder().decode(CourseSession.self, from: data) else { return nil }
            return session
        }
        return sessions.sorted { $0.startDate > $1.startDate }
    }

    /// 关键词检索：匹配原文或译文包含关键词的课程。
    static func search(_ keyword: String, in sessions: [CourseSession]) -> [CourseSession] {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return sessions }
        let lower = kw.lowercased()
        return sessions.filter { session in
            session.entries.contains { entry in
                entry.source.lowercased().contains(lower) || entry.target.contains(kw)
            }
        }
    }
}

// MARK: - 字幕导出

/// 把课程翻译记录导出为标准字幕文件（SRT / WebVTT），可直接挂到课程录屏视频上。
enum SubtitleExporter {
    /// 每句的持续时长估算：按字符数缩放，限制在 1.5…8 秒。
    private static func duration(for entry: TranslationEntry) -> TimeInterval {
        max(1.5, min(8, Double(entry.source.count) * 0.06))
    }

    /// 返回该句在录音中的起始秒（优先用 audioTime，兼容旧数据用时间戳偏移）。
    private static func startTime(for entry: TranslationEntry, base: Date) -> TimeInterval {
        if entry.audioTime > 0 { return entry.audioTime }
        return entry.timestamp.timeIntervalSince(base)
    }

    private static func formatSRTTime(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        let ms = Int((t - floor(t)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", total / 3600, (total % 3600) / 60, total % 60, ms)
    }

    private static func formatVTTTime(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        let ms = Int((t - floor(t)) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", total / 3600, (total % 3600) / 60, total % 60, ms)
    }

    static func srt(entries: [TranslationEntry], base: Date) -> String {
        var lines: [String] = []
        for (index, entry) in entries.enumerated() {
            let start = startTime(for: entry, base: base)
            let end = start + duration(for: entry)
            lines.append("\(index + 1)")
            lines.append("\(formatSRTTime(start)) --> \(formatSRTTime(end))")
            lines.append(entry.source)
            lines.append(entry.target)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func vtt(entries: [TranslationEntry], base: Date) -> String {
        var lines: [String] = ["WEBVTT", ""]
        for (index, entry) in entries.enumerated() {
            let start = startTime(for: entry, base: base)
            let end = start + duration(for: entry)
            lines.append("\(index + 1)")
            lines.append("\(formatVTTTime(start)) --> \(formatVTTTime(end))")
            lines.append("\(entry.source)\n\(entry.target)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

/// 翻译引擎类型：系统离线翻译（免费/无网可用）或 DeepSeek 在线翻译（质量更高、可遵循术语表）。
enum TranslationEngine: String, CaseIterable, Identifiable {
    case system
    case deepseek

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "系统离线翻译"
        case .deepseek: return "DeepSeek 在线翻译"
        }
    }
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
    /// 当前翻译引擎（可在设置中切换）。
    @Published var translationEngine: TranslationEngine = .system
    /// 术语表管理器（由界面注入，DeepSeek 翻译时强制遵循）。
    var glossaryManager: GlossaryManager?

    /// 注入术语表管理器（在 ContentView 初始化时调用）。
    func setGlossaryManager(_ manager: GlossaryManager) {
        glossaryManager = manager
    }

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var forwarder: AudioForwarder?
    private var previousDefaultInputID: AudioDeviceID = 0
    private var finalText = ""

    // MARK: - 课堂录音（边录边存）

    /// 正在写入的课堂录音文件（与识别同源的 16kHz 单声道 Float32，CAF 容器）。
    private var recordingFile: AVAudioFile?
    /// 当前正在保存的课堂录音文件地址。
    private(set) var currentRecordingURL: URL?
    /// 最近一次已完成的课堂录音文件地址（供课程归档 / 课后回看）。
    private(set) var lastRecordingURL: URL?

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
    /// 上一次 VAD 停顿时翻译过的开放句原文，用于计算下一次停顿的"新增后缀"，
    /// 避免教授连续说话时同一段内容被反复从头翻译。
    private var lastOpenSentence: String = ""
    /// 防抖任务：识别停止一段时间后才翻译，避免随每帧识别结果抖动。
    private var translationDebounceTask: Task<Void, Never>?
    /// 翻译串行链：保证翻译按顺序执行，避免并发导致译文乱序。
    private var translationChain: Task<Void, Never>?
    /// 最近已翻译的句子（原文+译文），作为 DeepSeek 滑窗上下文，提升代词/省略句的连贯性。
    private var recentContext: [(source: String, target: String)] = []
    /// 滑窗上下文保留条数。
    private static let maxRecentContext = 5

    // MARK: - 课程科目（翻译上下文）

    /// 当前课程科目（在翻译设置中配置，用于提升 DeepSeek 翻译的专业术语一致性）。
    private var courseSubject: String {
        UserDefaults.standard.string(forKey: "course_subject") ?? ""
    }

    // MARK: - 实时摘要

    /// 本节课已生成的要点（每 10 分钟自动增量生成，也可手动触发）。
    @Published private(set) var summaryPoints: [String] = []
    /// 是否正在生成摘要。
    @Published private(set) var isSummarizing = false
    /// 上次摘要覆盖到的时间点（增量摘要，避免重复生成）。
    private var summaryAnchorDate: Date?
    /// 摘要定时任务（每 10 分钟一次）。
    private var summaryTimerTask: Task<Void, Never>?
    /// 自动摘要间隔。
    private static let summaryInterval: TimeInterval = 600

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

        // 0.5 语音识别权限：与麦克风权限相互独立。
        // 当「系统设置 → Siri 和听写」中关闭「听写」时，系统不会弹出授权框、
        // 也不会回调授权结果，识别会静默失败——这里主动请求并用超时判定听写是否开启。
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined:
            Self.diag("语音识别权限 notDetermined，主动请求…")
            let sem = DispatchSemaphore(value: 0)
            SFSpeechRecognizer.requestAuthorization { _ in
                Self.diag("语音识别授权回调")
                sem.signal()
            }
            let timedOut = sem.wait(timeout: .now() + 1.5) == .timedOut
            if timedOut {
                Self.diag("语音识别授权请求超时：疑似「听写」未开启")
                lastError = "语音识别不可用：请先在「系统设置 → Siri 和听写」中开启「听写」，再点「开始」重试。"
                return
            }
        case .denied, .restricted:
            lastError = "语音识别权限未开启：请在「系统设置 → 隐私与安全性 → 语音识别」中允许本应用，并确认「系统设置 → Siri 和听写」中的「听写」已开启。"
            Self.diag("语音识别权限 denied/restricted")
            return
        default:
            Self.diag("语音识别权限已授权")
        }

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            lastError = "语音识别不可用：请确认「系统设置 → Siri 和听写」中的「听写」已开启、本应用已获语音识别权限，并已下载英语语言包（如缺失，系统设置 → 通用 → 翻译 中可管理语言包）。"
            Self.diag("语音识别器不可用（isAvailable=false）")
            return
        }
        guard let audioDeviceID = Self.audioDeviceID(for: deviceID) else {
            lastError = "找不到所选麦克风对应的系统音频设备，请重新选择或刷新设备列表。"
            Self.diag("audioDeviceID(for:) 匹配失败: \(deviceID)")
            return
        }
        Self.diag("所选设备 \(deviceID) → CoreAudio id=\(audioDeviceID)")

        // 开始新的识别流，重置开放句累计状态。
        lastOpenSentence = ""

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
            // 音频级停顿检测（VAD）：静音约 0.9 秒立即判句，比纯文本防抖更跟手。
            forwarder.onPauseDetected = { [weak self] in
                Task { @MainActor in
                    self?.handlePauseDetected()
                }
            }
            self.forwarder = forwarder

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak forwarder] buffer, _ in
                forwarder?.handle(buffer)
            }

            engine.prepare()
            try engine.start()
            Self.diag("AVAudioEngine.start() 成功")

            // 2.1 边录边存：把课堂音频同步写入「桌面/课程记录/课堂录音」，
            //     识别与录音共用同一份转换后的音频（16kHz 单声道 Float32）。
            if let url = Self.recordingURL(start: courseStartDate ?? Date()) {
                do {
                    let file = try AVAudioFile(
                        forWriting: url,
                        settings: targetFormat.settings,
                        commonFormat: .pcmFormatFloat32,
                        interleaved: false
                    )
                    forwarder.recordingFile = file
                    recordingFile = file
                    currentRecordingURL = url
                    Self.diag("课堂录音文件已创建: \(url.path)")
                } catch {
                    Self.diag("创建课堂录音文件失败: \(error)")
                }
            }

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

            // 3.5 识别无结果检测：音频流正常但 8 秒内没有任何识别结果，
            //     通常是「系统设置 → Siri 和听写」中「听写」未开启导致的静默失败。
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self, self.isRecording, self.audioActive, self.lastError == nil else { return }
                guard self.recognizedText.isEmpty else { return }
                self.lastError = "已采集到音频但未产生识别结果：请到「系统设置 → Siri 和听写」确认「听写」已开启（若已开启，先关闭再重新打开以重新初始化语音识别），并确认已下载英语语言包。"
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
        forwarder?.recordingFile = nil
        // 收尾判句：把未翻译的最后一句话也提交翻译，避免停止后丢失。
        translationDebounceTask?.cancel()
        translationDebounceTask = nil
        if isTranslationEnabled {
            let trimmed = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let (pending, openSentence) = collectPendingSentences(trimmed, includeOpen: true)
                finalizeSentenceTranslation(pending, openSentence: nil)
                if let openSentence {
                    finalizeOpenSentenceIncrement(openSentence)
                }
            }
        }
        finalizeRecording()
        forwarder = nil
        restoreInput()
        isRecording = false
        level = 0
        audioActive = false
    }

    /// 收尾课堂录音：无有效音频数据时删除空文件，否则记为最近一次录音。
    private func finalizeRecording() {
        guard let file = recordingFile else { return }
        if file.length > 0, let url = currentRecordingURL {
            lastRecordingURL = url
            Self.diag("课堂录音已保存: \(url.path)")
        } else if let url = currentRecordingURL {
            try? FileManager.default.removeItem(at: url)
            Self.diag("课堂录音无音频数据，已删除: \(url.path)")
        }
        recordingFile = nil
        currentRecordingURL = nil
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
        lastOpenSentence = ""
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
        summaryPoints.removeAll()
        summaryAnchorDate = nil
        startCourseTimer()
        startAutoSummaryIfNeeded()
        Self.diag("课程开始")
    }

    /// 结束当前课程：归档本节课的翻译记录与课堂录音，供课后回看。
    func endCourse() {
        guard isCourseActive, let start = courseStartDate else { return }
        let entries = translationEntries.filter { $0.timestamp >= start }
        var session = CourseSession(startDate: start, endDate: Date(), entries: entries)
        session.recordingURL = currentRecordingURL ?? lastRecordingURL
        completedCourse = session
        // 课程记录持久化到「桌面/课程记录/记录/」，供历史浏览与关键词检索。
        CourseArchive.save(session)
        isCourseActive = false
        courseStartDate = nil
        courseTimerTask?.cancel()
        courseTimerTask = nil
        summaryTimerTask?.cancel()
        summaryTimerTask = nil
        Self.diag("课程结束，共记录 \(entries.count) 条翻译，录音: \(session.recordingURL?.path ?? "无")")
    }

    // MARK: - 实时摘要

    /// 自动摘要：每 10 分钟增量生成一次要点（仅 DeepSeek 配置了 API Key 时）。
    private func startAutoSummaryIfNeeded() {
        guard !DeepSeekReviewService.savedAPIKey.isEmpty else { return }
        summaryTimerTask?.cancel()
        summaryTimerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.summaryInterval * 1_000_000_000))
                guard let self, !Task.isCancelled, self.isCourseActive else { return }
                await self.generateSummary()
            }
        }
    }

    /// 把 startCourse 以来（或上次摘要以来）新增的翻译记录交给 DeepSeek 提炼要点。
    func generateSummary() async {
        guard !isSummarizing else { return }
        guard !DeepSeekReviewService.savedAPIKey.isEmpty else {
            lastError = "实时摘要需要 DeepSeek API Key：请点击「翻译设置」填写后重试。"
            return
        }
        let anchor = summaryAnchorDate ?? courseStartDate ?? Date()
        let fresh = translationEntries.filter { $0.timestamp > anchor }
        summaryAnchorDate = Date()
        guard !fresh.isEmpty else { return }
        isSummarizing = true
        defer { isSummarizing = false }
        do {
            let points = try await DeepSeekReviewService.summarize(entries: fresh, apiKey: DeepSeekReviewService.savedAPIKey)
            summaryPoints.append(contentsOf: points)
            Self.diag("实时摘要完成，新增 \(points.count) 条要点")
        } catch {
            Self.diag("实时摘要失败: \(error)")
            lastError = "实时摘要失败：\(error.localizedDescription)"
        }
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
    /// 归一化后的 `translatedSentenceKeys` 去重，避免识别修正导致重复翻译。
    ///
    /// 注意：文本防抖期间只翻译已确认的完整句；仍在变化的"开放句"（未终止）
    /// 交给 VAD 检测到的真实停顿时再翻译，避免识别结果逐字补充时同一句被反复输出。
    private func updateTranslationIfNeeded(for text: String) {
        guard isTranslationEnabled else { return }
        // 仅系统离线翻译依赖 macOS 15+ 与本地语言包；DeepSeek 在线翻译不依赖。
        if translationEngine == .system {
            guard #available(macOS 15.0, *) else {
                translationUnavailable = true
                return
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 先收集已明确的完整句子（带终止标点，或非最后一段），延迟到停顿确认后再翻译。
        let (pending, _) = collectPendingSentences(trimmed, includeOpen: false)

        translationDebounceTask?.cancel()
        translationDebounceTask = Task { @MainActor [weak self] in
            // 长防抖：用户停顿 ≈ 一句话结束（识别结果一般不带标点）。
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, !Task.isCancelled else { return }
            // 防抖期间识别文本又被更新 → 还在说话，本轮跳过，等下一轮。
            if self.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines) != trimmed { return }
            // 文本防抖只翻译已确认的完整句；开放句留给 VAD 的真实停顿触发，
            // 避免识别结果逐字补充时同一句被反复翻译。
            self.finalizeSentenceTranslation(pending, openSentence: nil)
        }
    }

    /// 音频级 VAD（静音检测）触发的停顿：静音持续约 0.9 秒视为"一句话说完"。
    /// 给识别引擎约 0.4 秒收尾（让最终结果稳定、标点落定），再按停顿判句翻译，
    /// 比纯文本防抖更快、更贴近真实停顿；收尾期间文本被更新则让位于下一轮识别。
    private func handlePauseDetected() {
        guard isTranslationEnabled, isRecording else { return }
        let trimmed = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        translationDebounceTask?.cancel()
        translationDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            // 收尾期间文本又被更新 → 识别仍在修正，本轮跳过，等下一轮（防抖会兜底）。
            if self.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines) != trimmed { return }
            // 停顿即句界：已确认的完整句直接翻译；仍在变化的开放句只翻译
            // 相对于上一次停顿的"新增后缀"，避免教授连续说话时同一段被反复输出。
            let (pending, openSentence) = self.collectPendingSentences(trimmed, includeOpen: true)
            self.finalizeSentenceTranslation(pending, openSentence: nil)
            if let openSentence {
                self.finalizeOpenSentenceIncrement(openSentence)
            }
        }
    }

    /// 从文本中收集"已确认的完整句子"（带终止标点，或非最后一段），并去重。
    /// `includeOpen` 为 true 时同时返回最后一段未终止的文本（停顿即句界）。
    private func collectPendingSentences(_ text: String, includeOpen: Bool) -> ([String], String?) {
        let sentences = Self.splitIntoSentences(text)
        var pending: [String] = []
        var openSentence: String?
        for (i, sentence) in sentences.enumerated() {
            let t = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if i < sentences.count - 1 || Self.endsWithTerminalPunctuation(sentence) {
                let key = Self.translationKey(for: t)
                guard !translatedSentenceKeys.contains(key) else { continue }
                translatedSentenceKeys.insert(key)
                pending.append(t)
            } else if includeOpen {
                openSentence = t
            }
        }
        return (pending, openSentence)
    }

    /// 生成用于去重的句子 key：忽略大小写、标点和多余空格。
    /// 识别结果常在大小写、标点和个别单词上修正，归一化后可避免同一句话被重复翻译。
    private static func translationKey(for sentence: String) -> String {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        let punctuation = CharacterSet.punctuationCharacters.union(.symbols)
        let normalized = lowercased.components(separatedBy: punctuation)
            .joined(separator: " ")
        return normalized.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// 提交一批已确认的完整句子翻译。
    /// 每句会带上其在课堂录音中的起始偏移（audioTime），供回看跳转与字幕导出使用。
    private func finalizeSentenceTranslation(_ pending: [String], openSentence: String?) {
        var toTranslate = pending
        if let openSentence, !openSentence.isEmpty {
            // 兜底：极少数情况下外部仍传入开放句时，按完整句去重翻译。
            let key = Self.translationKey(for: openSentence)
            if !translatedSentenceKeys.contains(key) {
                translatedSentenceKeys.insert(key)
                toTranslate.append(openSentence)
            }
        }
        guard !toTranslate.isEmpty else { return }

        // 该句在录音中的近似起始偏移：识别结果通常滞后于真实语音约 1.5 秒，向前补偿。
        let recordingOffset = currentRecordingTime - Self.recognitionLagCompensation
        let audioTimes = Array(repeating: recordingOffset, count: toTranslate.count)
        Self.diag("停顿判句，待翻译: \(toTranslate.joined(separator: " | "))")
        enqueueTranslation(toTranslate, audioTimes: audioTimes)
    }

    /// 提交开放句（未终止文本）的**增量后缀**翻译。
    ///
    /// VAD 检测到的真实停顿时，语音识别可能仍在补充同一段话。若直接翻译整段开放句，
    /// 会导致"You can change..."这类基础句被反复输出。这里只取当前开放句相对于
    /// 上一次停顿时的新增后缀进行翻译，大幅提升连续长句场景下的体验。
    private func finalizeOpenSentenceIncrement(_ openSentence: String) {
        let current = openSentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return }
        let last = lastOpenSentence.trimmingCharacters(in: .whitespacesAndNewlines)

        let increment: String
        if last.isEmpty {
            increment = current
        } else if current.hasPrefix(last) {
            increment = String(current.dropFirst(last.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            // 发生识别修正或跳变（如 lastOpenSentence 前缀与当前不一致），
            // 回退为翻译整个当前开放句；小幅重复优于漏译。
            increment = current
        }

        guard !increment.isEmpty else { return }
        let key = Self.translationKey(for: increment)
        guard !translatedSentenceKeys.contains(key) else { return }
        translatedSentenceKeys.insert(key)

        let recordingOffset = currentRecordingTime - Self.recognitionLagCompensation
        Self.diag("开放句增量翻译: \(increment)")
        enqueueTranslation([increment], audioTimes: [recordingOffset])

        // 记录本次开放句，供下一次停顿计算新增后缀。
        lastOpenSentence = current
    }

    /// 当前录音文件已写入的时长（秒），0 表示未在录音。
    private var currentRecordingTime: TimeInterval {
        guard let file = recordingFile else { return 0 }
        return Double(file.length) / Double(targetFormat.sampleRate)
    }

    /// 识别结果相对于真实语音的滞后补偿（秒）。
    private static let recognitionLagCompensation: TimeInterval = 1.5

    /// 把一组待翻译句子追加到串行队列，保证译文按顺序追加，杜绝并发乱序。
    private func enqueueTranslation(_ sentences: [String], audioTimes: [TimeInterval]) {
        let previous = translationChain
        translationChain = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self, !Task.isCancelled else { return }
            await self.translateSentences(sentences, audioTimes: audioTimes)
        }
    }

    private func translateSentences(_ sentences: [String], audioTimes: [TimeInterval]) async {
        // 优先命中离线缓存：同一句子（同一术语表）不重复调 API。
        if let cached = cachedResults(for: sentences) {
            Self.diag("命中离线翻译缓存: \(sentences.joined(separator: " | "))")
            appendTranslationResults(cached, for: sentences, audioTimes: audioTimes)
            return
        }
        // DeepSeek 在线翻译：不依赖 macOS 15 与本地语言包，失败时自动降级为系统翻译。
        if translationEngine == .deepseek {
            await translateViaDeepSeek(sentences, audioTimes: audioTimes)
            return
        }
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
            cacheResults(results, for: sentences)
            appendTranslationResults(results, for: sentences, audioTimes: audioTimes)
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

    /// DeepSeek 在线翻译：遵循术语表，携带滑窗上下文；失败时自动降级为系统离线翻译。
    private func translateViaDeepSeek(_ sentences: [String], audioTimes: [TimeInterval]) async {
        let key = DeepSeekReviewService.savedAPIKey
        guard !key.isEmpty else {
            lastError = "DeepSeek 在线翻译需要 API Key：请点击「翻译设置」填写后重试。"
            return
        }
        isTranslating = true
        Self.diag("DeepSeek 翻译: \(sentences.joined(separator: " | "))")
        do {
            let results = try await DeepSeekTranslationService.translate(
                sentences,
                glossary: glossaryManager?.terms ?? [],
                apiKey: key,
                recentContext: recentContext,
                subject: courseSubject
            )
            Self.diag("DeepSeek 翻译完成: \(results.joined(separator: " | "))")
            cacheResults(results, for: sentences)
            appendTranslationResults(results, for: sentences, audioTimes: audioTimes)
            isTranslating = false
        } catch {
            Self.diag("DeepSeek 翻译失败，尝试降级系统翻译: \(error)")
            lastError = "DeepSeek 翻译失败，已自动切换为系统离线翻译：\(error.localizedDescription)"
            isTranslating = false
            // 降级到系统翻译，保证翻译不中断。
            guard #available(macOS 15.0, *) else { return }
            guard let session = translationSessionBox as? TranslationSession else { return }
            let service: TranslationService
            if let existing = translationServiceBox as? TranslationService {
                service = existing
            } else {
                service = TranslationService()
                translationServiceBox = service
            }
            isTranslating = true
            do {
                let results = try await service.translate(sentences, session: session)
                cacheResults(results, for: sentences)
                appendTranslationResults(results, for: sentences, audioTimes: audioTimes)
            } catch {
                Self.diag("系统降级翻译也失败: \(error)")
            }
            isTranslating = false
        }
    }

    // MARK: - 离线翻译缓存

    /// 术语表指纹：术语表内容变化时缓存自动失效。
    private var glossaryFingerprint: String {
        let terms = glossaryManager?.terms ?? []
        let joined = terms.map { "\($0.source.lowercased())=\($0.target)" }.joined(separator: ";")
        return String(TranslationCache.stableHash(joined), radix: 36)
    }

    /// 整批句子全部命中缓存则返回结果，否则返回 nil（交给引擎翻译）。
    private func cachedResults(for sentences: [String]) -> [String]? {
        let fingerprint = glossaryFingerprint
        var results: [String] = []
        for sentence in sentences {
            guard let hit = TranslationCache.cached(sentence, glossaryFingerprint: fingerprint) else { return nil }
            results.append(hit)
        }
        return results
    }

    /// 把本轮翻译结果写入缓存（仅写非空译文）。
    private func cacheResults(_ results: [String], for sentences: [String]) {
        let fingerprint = glossaryFingerprint
        for (sentence, result) in zip(sentences, results) where !result.isEmpty {
            TranslationCache.store(sentence, result, glossaryFingerprint: fingerprint)
        }
    }

    /// 将翻译结果追加到记录与译文文本（带上限保护）。
    private func appendTranslationResults(_ results: [String], for sentences: [String], audioTimes: [TimeInterval]) {
        for (i, (source, result)) in zip(sentences, results).enumerated() where !result.isEmpty {
            let audioTime = i < audioTimes.count ? audioTimes[i] : 0
            let entry = TranslationEntry(timestamp: Date(), source: source, target: result, audioTime: audioTime)
            translationEntries.append(entry)
            // 维护 DeepSeek 滑窗上下文（最近 N 条原文+译文）。
            recentContext.append((source: source, target: result))
            if recentContext.count > Self.maxRecentContext {
                recentContext.removeFirst(recentContext.count - Self.maxRecentContext)
            }
            // 上限保护：只保留最近 N 条，防止长时间运行内存膨胀。
            if translationEntries.count > Self.maxTranslationEntries {
                translationEntries.removeFirst(translationEntries.count - Self.maxTranslationEntries)
            }
            if !translatedText.isEmpty {
                translatedText += "\n"
            }
            translatedText += result
        }
    }

    /// 按句子终止符（中英文 . ! ? 。！？…）切分文本，返回句子列表（含结尾标点）。
    /// 识别结果即使带了中文标点也能正确切句；英文缩写/数字中的点（如 U.S.A、3.5）不切分。
    private static func splitIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        let chars = Array(text)
        for (index, char) in chars.enumerated() {
            current.append(char)
            if Self.isTerminalPunctuation(char) {
                // 小数点或缩写点（前后紧跟字母/数字）不是句末标点，不切分。
                if char == "." {
                    let prev = index > 0 ? chars[index - 1] : nil
                    let next = index + 1 < chars.count ? chars[index + 1] : nil
                    if let prev, prev.isLetter || prev.isNumber,
                       let next, next.isLetter || next.isNumber {
                        continue
                    }
                }
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
            || char == "。" || char == "！" || char == "？"
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

    // MARK: - 课堂录音文件路径

    /// 生成课堂录音文件保存路径：`桌面/课程记录/课堂录音/yyyy-MM-dd HH-mm-ss 课堂录音.caf`。
    private static func recordingURL(start: Date) -> URL? {
        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = desktop
            .appendingPathComponent("课程记录", isDirectory: true)
            .appendingPathComponent("课堂录音", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            Self.diag("创建课堂录音目录失败: \(error)")
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let name = "\(formatter.string(from: start)) 课堂录音.caf"
        return dir.appendingPathComponent(name)
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
    /// 课堂录音文件（边录边存；与识别共用同一份转换后音频）。
    var recordingFile: AVAudioFile?
    let targetFormat: AVAudioFormat
    var onLevel: ((Float) -> Void)?
    var onAudioActive: ((Bool) -> Void)?
    var onError: ((String) -> Void)?
    /// 音频级停顿检测回调：连续静音达到阈值后触发（VAD 判句用）。
    var onPauseDetected: (() -> Void)?

    // VAD 状态（仅在采集线程访问，无需加锁）
    private var silenceDuration: TimeInterval = 0
    private var hasSpoken = false
    private var lastPauseAt: TimeInterval = 0
    /// 判定为"一句话说完"的连续静音时长。
    private static let pauseThreshold: TimeInterval = 0.9
    /// 两次停顿回调之间的最小间隔，避免紧挨的短句重复触发。
    private static let pauseCooldown: TimeInterval = 1.5

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
        // 边录边存：写入课堂录音文件（AVAudioFile.write 立即拷贝数据，不阻塞识别）。
        if let recordingFile {
            try? recordingFile.write(from: converted)
        }
        let level = Self.computeLevel(converted)
        onLevel?(level)
        onAudioActive?(true)
        detectPause(level: level, duration: Double(converted.frameLength) / Double(targetFormat.sampleRate))
    }

    /// 音频级停顿检测：统计连续静音时长，达到阈值且处于"冷却期之外"时回调。
    /// 静音阈值用原始 RMS（而非映射后的电平），避免低增益麦克风误判。
    private func detectPause(level: Float, duration: TimeInterval) {
        // computeLevel 返回 rms * 12；rms < 0.006 视为静音（≈ 映射后 0.072）。
        let rms = level / 12
        if rms < 0.006 {
            if hasSpoken {
                silenceDuration += duration
                let now = CACurrentMediaTime()
                if silenceDuration >= Self.pauseThreshold, now - lastPauseAt >= Self.pauseCooldown {
                    lastPauseAt = now
                    silenceDuration = 0
                    onPauseDetected?()
                }
            }
        } else {
            hasSpoken = true
            silenceDuration = 0
        }
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
