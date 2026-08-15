import AppKit
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import _Translation_SwiftUI

// MARK: - 背景管理器

/// 管理应用背景：支持从系统相册（照片）或本地文件选择图片作为背景，
/// 图片会复制到应用支持目录并持久化，下次启动自动恢复。
@MainActor
final class BackgroundManager: ObservableObject {
    @Published private(set) var backgroundImage: NSImage?
    @Published private(set) var hasCustomBackground = false

    private static let pathKey = "customBackgroundImagePath"
    private let fileManager = FileManager.default

    init() {
        loadSavedBackground()
    }

    private var backgroundDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("RealTimeTranslator", isDirectory: true)
            .appendingPathComponent("Backgrounds", isDirectory: true)
        try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    func loadSavedBackground() {
        guard let path = UserDefaults.standard.string(forKey: Self.pathKey),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let image = NSImage(data: data) else {
            backgroundImage = nil
            hasCustomBackground = false
            return
        }
        backgroundImage = image
        hasCustomBackground = true
    }

    func setBackground(imageData: Data) throws {
        let url = backgroundDirectory.appendingPathComponent("background-\(Int(Date().timeIntervalSince1970)).png")
        try imageData.write(to: url)
        UserDefaults.standard.set(url.path, forKey: Self.pathKey)
        loadSavedBackground()
    }

    func setBackground(fromFile url: URL) throws {
        let data = try Data(contentsOf: url)
        try setBackground(imageData: data)
    }

    func clearBackground() {
        UserDefaults.standard.removeObject(forKey: Self.pathKey)
        backgroundImage = nil
        hasCustomBackground = false
    }
}

// MARK: - 主界面

struct ContentView: View {
    @StateObject private var permissions = PermissionManager()
    @StateObject private var deviceManager = AudioDeviceManager()
    @StateObject private var engine = SpeechEngine()
    @StateObject private var background = BackgroundManager()
    @State private var isRequestingPermissions = false
    @State private var isShowingCourseReview = false
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var isSubtitleVisible = false
    @State private var subtitlePanel: NSPanel?

    private static let subtitleFrameKey = "floatingSubtitleFrame"

    var body: some View {
        Group {
            if permissions.allGranted {
                mainView
            } else {
                permissionView
            }
        }
        .frame(minWidth: 560, minHeight: 440)
        .task { deviceManager.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            // 退出时停止录音并恢复系统默认输入设备。
            engine.stop()
        }
        .onChange(of: deviceManager.selectedDeviceID) { _, newID in
            // 录音中切换设备：自动重启识别以应用新设备。
            if engine.isRecording, let newID {
                engine.start(deviceID: newID)
            }
        }
    }

    // MARK: - 主界面

    private var mainView: some View {
        ZStack {
            AppBackground(background: background)
            VStack(spacing: 12) {
                header
                controlBar
                courseBar
                transcriptArea
            }
            .padding(14)
            .background {
                // 用 .translationTask 创建翻译会话：系统会自动管理会话生命周期，
                // 且 canRequestDownloads 为 true，英→中语言包缺失时系统会弹出下载提示。
                if #available(macOS 15.0, *) {
                    Color.clear
                        .translationTask(
                            source: Locale.Language(identifier: "en-US"),
                            target: Locale.Language(identifier: "zh-Hans")
                        ) { session in
                            engine.setTranslationSession(session)
                        }
                }
            }
        }
        .sheet(isPresented: $isShowingCourseReview) {
            if let course = engine.completedCourse {
                CourseReviewView(course: course)
            }
        }
    }

    /// 顶部封面栏：应用图标 + 名称 + 背景设置 + 录音状态。
    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.0, green: 0.90, blue: 1.0),
                                Color(red: 0.55, green: 0.35, blue: 1.0),
                                Color(red: 1.0, green: 0.23, blue: 0.58)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                    )
                Image(systemName: "waveform")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
            }
            .frame(width: 46, height: 46)
            .shadow(color: Color(red: 1.0, green: 0.23, blue: 0.58).opacity(0.6), radius: 8, y: 0)
            .shadow(color: Color(red: 0.0, green: 0.90, blue: 1.0).opacity(0.5), radius: 6, y: 0)

            VStack(alignment: .leading, spacing: 2) {
                Text("实时语音翻译")
                    .font(.title3.bold())
                Text("RealTimeTranslator · 英语实时识别与翻译")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            subtitleToggleButton

            backgroundMenu

            StatusBadge(isRecording: engine.isRecording)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color(red: 0.0, green: 0.90, blue: 1.0).opacity(0.35), lineWidth: 1)
        )
        .shadow(color: Color(red: 0.0, green: 0.90, blue: 1.0).opacity(0.18), radius: 12, y: 0)
        .onChange(of: photoPickerItem) { _, item in
            loadPhoto(item)
        }
    }

    /// 悬浮字幕窗开关。
    private var subtitleToggleButton: some View {
        Button {
            toggleSubtitle()
        } label: {
            Image(systemName: isSubtitleVisible ? "captions.bubble.fill" : "captions.bubble")
                .font(.body)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("弹出 / 收起悬浮字幕窗（仅显示最近两句）")
    }

    /// 背景设置菜单：从相册选择 / 从文件选择 / 恢复默认。
    private var backgroundMenu: some View {
        Menu {
            PhotosPicker(selection: $photoPickerItem, matching: .images) {
                Label("从相册选择", systemImage: "photo.on.rectangle.angled")
            }
            Button {
                chooseBackgroundFile()
            } label: {
                Label("从文件选择", systemImage: "folder")
            }
            if background.hasCustomBackground {
                Divider()
                Button(role: .destructive) {
                    background.clearBackground()
                } label: {
                    Label("恢复默认背景", systemImage: "arrow.counterclockwise")
                }
            }
        } label: {
            Image(systemName: background.hasCustomBackground ? "photo.fill" : "photo")
                .font(.body)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("更换应用背景")
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Label("输入设备", systemImage: "mic.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("输入设备", selection: $deviceManager.selectedDeviceID) {
                ForEach(deviceManager.devices) { device in
                    Text(device.name).tag(Optional(device.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260)
            .fixedSize()

            Button {
                deviceManager.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("刷新设备列表")

            Spacer()

            if engine.translationUnavailable {
                Label("翻译需 macOS 15+", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Toggle(isOn: $engine.isTranslationEnabled) {
                    Label("中文翻译", systemImage: "character.bubble")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("将识别出的英语实时翻译为中文")
            }

            LevelMeter(level: engine.level, isRecording: engine.isRecording, audioActive: engine.audioActive)

            if engine.isRecording {
                Text(formattedDuration(engine.sessionDuration))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("课堂已运行时长")
            }

            recordingButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color(red: 0.0, green: 0.90, blue: 1.0).opacity(0.28), lineWidth: 1)
        )
        .shadow(color: Color(red: 0.0, green: 0.90, blue: 1.0).opacity(0.12), radius: 10, y: 0)
    }

    private var recordingButton: some View {
        Button {
            toggleRecording()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: engine.isRecording ? "stop.circle.fill" : "record.circle.fill")
                    .font(.title2)
                Text(engine.isRecording ? "停止" : "开始")
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .tint(engine.isRecording ? .red : Color(red: 0.0, green: 0.85, blue: 1.0))
        .keyboardShortcut(.space, modifiers: .command)
        .help("开始 / 停止语音识别（⌘+空格）")
    }

    private var courseBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "graduationcap.fill")
                .font(.callout)
                .foregroundStyle(.tint)
            Text("课堂模式")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            if engine.isCourseActive {
                Text(formattedDuration(engine.courseDuration))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(Color(red: 1.0, green: 0.35, blue: 0.70))
                    .help("本节课已进行时长")
                Text("已记录 \(engine.translationEntries.count) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    endCourse()
                } label: {
                    Label("课程结束", systemImage: "stop.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .help("结束本节课：归档全部翻译记录，可课后回看")
            } else if let course = engine.completedCourse {
                Text("本节课已结束（\(course.entries.count) 条翻译）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    isShowingCourseReview = true
                } label: {
                    Label("回看本节课", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.bordered)
                .tint(Color(red: 0.0, green: 0.85, blue: 1.0))
                .help("查看本节课完整翻译记录")
                Button {
                    startCourse()
                } label: {
                    Label("开始新课", systemImage: "play.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 1.0, green: 0.23, blue: 0.58))
            } else {
                Spacer()
                Button {
                    startCourse()
                } label: {
                    Label("课程开始", systemImage: "play.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 1.0, green: 0.23, blue: 0.58))
                .help("开始课堂记录：自动开始录音，界面仅显示最近 1 分钟翻译，其余保留待课后回看")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color(red: 0.0, green: 0.90, blue: 1.0).opacity(0.28), lineWidth: 1)
        )
        .shadow(color: Color(red: 1.0, green: 0.23, blue: 0.58).opacity(0.15), radius: 10, y: 0)
    }

    private var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // 英文原文区
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "textformat")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("英语识别")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        if engine.recognizedText.isEmpty {
                            emptyHint
                                .id("empty")
                        } else {
                            Text(engine.recognizedText)
                                .font(.system(size: 19, design: .rounded))
                                .lineSpacing(6)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("text")
                            if engine.isRecording {
                                Text("▍")
                                    .font(.system(size: 19))
                                    .foregroundStyle(.tint)
                                    .transition(.opacity)
                                    .id("cursor")
                            }
                        }
                    }
                    .padding(16)

                    // 中文翻译区（仅显示最近 1 分钟，其余保留待课后回看）
                    if engine.isTranslationEnabled {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "character.bubble")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("中文翻译（最近 1 分钟）")
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                                if engine.isTranslating {
                                    ProgressView()
                                        .controlSize(.mini)
                                }
                                Spacer()
                            }
                            if engine.translationUnavailable {
                                Text("翻译功能需要 macOS 15 或更高版本。")
                                    .font(.callout)
                                    .foregroundStyle(.orange)
                            } else {
                                TimelineView(.periodic(from: .now, by: 1)) { _ in
                                    RecentTranslationList(entries: recentTranslationEntries)
                                        .id("translation")
                                }
                            }
                        }
                        .padding(16)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.regularMaterial)
            .onChange(of: engine.recognizedText) { _, _ in
                withAnimation {
                    proxy.scrollTo(engine.isRecording ? "cursor" : "text", anchor: .bottom)
                }
            }
            .onChange(of: engine.translatedText) { _, _ in
                withAnimation {
                    proxy.scrollTo(engine.translatedText.isEmpty ? "text" : "translation", anchor: .bottom)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color(red: 1.0, green: 0.23, blue: 0.58).opacity(0.25), lineWidth: 1)
        )
        .shadow(color: Color(red: 0.0, green: 0.90, blue: 1.0).opacity(0.12), radius: 10, y: 0)
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "mic.slash")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("点击「开始」并说出英语\n这里将实时显示识别出的英文原文")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - 权限引导

    private var permissionView: some View {
        ZStack {
            AppBackground(background: background)
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "mic.fill.badge.plus")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text("需要麦克风与语音识别权限")
                    .font(.title3.bold())
                Text("本应用完全在本地处理语音：\n识别您的英语发音并实时转换为文字。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let hint = permissions.denialHint {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }

                Button {
                    isRequestingPermissions = true
                    Task {
                        await permissions.requestAll()
                        isRequestingPermissions = false
                    }
                } label: {
                    if isRequestingPermissions {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 90)
                    } else {
                        Text(permissions.microphoneStatus == .denied || permissions.speechStatus == .denied ? "已打开系统设置后，点此重试" : "授权并继续")
                            .frame(width: 90)
                    }
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 动作

    private func toggleRecording() {
        if engine.isRecording {
            engine.stop()
            // 录音停止时若课程仍在进行，一并结束课程，保证课堂记录完整归档。
            if engine.isCourseActive {
                engine.endCourse()
            }
        } else {
            guard let deviceID = deviceManager.selectedDeviceID else { return }
            engine.start(deviceID: deviceID)
        }
    }

    /// 开始课堂：自动开始录音并记录本节课翻译。
    private func startCourse() {
        engine.startCourse()
        guard let deviceID = deviceManager.selectedDeviceID else { return }
        if !engine.isRecording {
            engine.start(deviceID: deviceID)
        }
    }

    /// 结束课堂：归档本节课记录并停止录音。
    private func endCourse() {
        engine.endCourse()
        if engine.isRecording {
            engine.stop()
        }
    }

    /// 最近 1 分钟内产生的翻译记录（界面仅显示这一窗口）。
    private var recentTranslationEntries: [TranslationEntry] {
        let cutoff = Date().addingTimeInterval(-SpeechEngine.visibleTranslationWindow)
        return engine.translationEntries.filter { $0.timestamp >= cutoff }
    }

    // MARK: - 悬浮字幕窗

    private func toggleSubtitle() {
        if isSubtitleVisible {
            hideSubtitle()
        } else {
            showSubtitle()
        }
    }

    private func showSubtitle() {
        if let panel = subtitlePanel {
            panel.orderFront(nil)
            isSubtitleVisible = true
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 230),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(
            rootView: FloatingSubtitleView(engine: engine) {
                self.hideSubtitle()
            }
        )
        // 恢复上次位置，否则默认放在屏幕上方居中。
        let screenFrame = NSScreen.main?.visibleFrame
        if let saved = UserDefaults.standard.string(forKey: Self.subtitleFrameKey) {
            let rect = NSRectFromString(saved)
            if let screenFrame,
               rect.width > 0, rect.minX >= screenFrame.minX, rect.maxX <= screenFrame.maxX,
               rect.minY >= screenFrame.minY, rect.maxY <= screenFrame.maxY {
                panel.setFrame(rect, display: true)
            } else if let screenFrame {
                panel.setFrameOrigin(NSPoint(x: screenFrame.midX - 180, y: screenFrame.maxY - 240))
            }
        } else if let screenFrame {
            panel.setFrameOrigin(NSPoint(x: screenFrame.midX - 180, y: screenFrame.maxY - 240))
        }
        subtitlePanel = panel
        panel.orderFront(nil)
        isSubtitleVisible = true
    }

    private func hideSubtitle() {
        if let panel = subtitlePanel {
            UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.subtitleFrameKey)
            panel.orderOut(nil)
        }
        isSubtitleVisible = false
    }

    // MARK: - 背景选择

    /// 处理相册（照片选择器）返回的图片。
    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self) {
                try? background.setBackground(imageData: data)
            }
            photoPickerItem = nil
        }
    }

    /// 从本地文件选择背景图片。
    private func chooseBackgroundFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择一张图片作为应用背景"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? background.setBackground(fromFile: url)
        }
    }

    private func formattedDuration(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

// MARK: - 背景层

/// 应用背景层：默认渐变主题，或用户选择的相册/文件图片（自动压暗保证可读性）。
private struct AppBackground: View {
    @ObservedObject var background: BackgroundManager
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if let image = background.backgroundImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                // 压暗蒙版：保证前景文字与卡片可读。
                Rectangle()
                    .fill(colorScheme == .dark ? Color.black.opacity(0.5) : Color.black.opacity(0.35))
                    .ignoresSafeArea()
                // 霓虹氛围光：叠在用户图片上呼应赛博朋克主题。
                Color(red: 0.0, green: 0.90, blue: 1.0).opacity(0.06)
                    .ignoresSafeArea()
            } else {
                // 赛博朋克默认背景：深色基底 + 霓虹渐变 + 品红/电青光斑。
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(red: 0.04, green: 0.05, blue: 0.10),
                            Color(red: 0.10, green: 0.04, blue: 0.18),
                            Color(red: 0.03, green: 0.08, blue: 0.14)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    // 电青光斑（左上）
                    Circle()
                        .fill(Color(red: 0.0, green: 0.85, blue: 1.0).opacity(0.22))
                        .frame(width: 380, height: 380)
                        .blur(radius: 90)
                        .offset(x: -180, y: -160)
                    // 品红光斑（右下）
                    Circle()
                        .fill(Color(red: 1.0, green: 0.23, blue: 0.58).opacity(0.20))
                        .frame(width: 420, height: 420)
                        .blur(radius: 100)
                        .offset(x: 200, y: 180)
                    // 微弱扫描网格
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.03),
                            Color.white.opacity(0.0),
                            Color.white.opacity(0.03)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .ignoresSafeArea()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: background.backgroundImage)
    }
}

// MARK: - 子组件

/// 顶栏录音状态指示。
private struct StatusBadge: View {
    let isRecording: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isRecording ? Color.red : Color.secondary)
                .frame(width: 8, height: 8)
            Text(isRecording ? "识别中" : "就绪")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }
}

/// 输入电平指示：帮助确认麦克风是否真正采集到声音。
private struct LevelMeter: View {
    let level: Float
    let isRecording: Bool
    let audioActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(isRecording ? (audioActive ? Color.green : Color.orange) : Color.secondary)
                        .frame(width: max(4, geo.size.width * CGFloat(level)))
                }
            }
            .frame(height: 5)
            HStack(spacing: 4) {
                Text(isRecording ? (audioActive ? "采集正常" : "未采集到音频") : "输入电平")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if isRecording && !audioActive {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .frame(width: 130)
    }
}

/// 悬浮字幕窗：无边框置顶小窗，仅显示最近两句翻译（英文原文 + 中文译文）。
private struct FloatingSubtitleView: View {
    @ObservedObject var engine: SpeechEngine
    var onClose: () -> Void

    /// 最近两句翻译（不足两条时显示已有的）。
    private var recentTwo: [TranslationEntry] {
        Array(engine.translationEntries.suffix(2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "captions.bubble.fill")
                    .font(.caption)
                    .foregroundStyle(Color(red: 0.0, green: 0.90, blue: 1.0))
                Text("实时字幕 · 最近两句")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("收起字幕窗")
            }

            if recentTwo.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "captions.bubble")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text("开始说话后，最近两句译文将显示在这里")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(recentTwo) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.source)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Text(entry.target)
                                .font(.system(size: 15, weight: .medium))
                                .lineLimit(2)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color(red: 0.0, green: 0.90, blue: 1.0).opacity(0.28), lineWidth: 1)
                        )
                    }
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color(red: 0.0, green: 0.90, blue: 1.0).opacity(0.35), lineWidth: 1)
        )
        .shadow(color: Color(red: 0.0, green: 0.90, blue: 1.0).opacity(0.2), radius: 12, y: 0)
        .frame(width: 360)
    }
}

/// 最近 1 分钟翻译记录列表（时间 + 英文原文 + 中文译文）。
private struct RecentTranslationList: View {
    let entries: [TranslationEntry]

    var body: some View {
        if entries.isEmpty {
            Text("翻译结果将显示在这里（仅保留并显示最近 1 分钟）")
                .font(.callout)
                .foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(entries) { entry in
                    TranslationRow(entry: entry, compact: true)
                }
            }
        }
    }
}

/// 单条翻译记录行（时间 + 英文原文 + 中文译文）。
private struct TranslationRow: View {
    let entry: TranslationEntry
    var compact = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(Self.timeString(entry.timestamp))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.source)
                    .font(.system(size: compact ? 15 : 16))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(entry.target)
                    .font(.system(size: compact ? 17 : 18))
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static func timeString(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }
}

/// 课程回看弹窗：展示本节课完整翻译记录，并可调用 DeepSeek 审阅生成文档。
private struct CourseReviewView: View {
    let course: CourseSession
    @Environment(\.dismiss) private var dismiss
    @AppStorage("deepseek_api_key") private var apiKey = ""
    @State private var isReviewing = false
    @State private var reviewState: ReviewState = .idle

    enum ReviewState {
        case idle
        case working
        case done(URL)
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("本节课翻译记录回看")
                        .font(.headline)
                    Text("\(Self.fullTimeString(course.startDate)) ～ \(Self.fullTimeString(course.endDate)) · 时长 \(Self.durationString(course.duration)) · 共 \(course.entries.count) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding(16)
            Divider()
            HStack(spacing: 0) {
                entriesList
                Divider()
                reviewPanel
            }
        }
        .frame(width: 1020, height: 640)
        .onAppear {
            // 每次打开弹窗时同步已保存的 API Key。
            apiKey = DeepSeekReviewService.savedAPIKey
        }
    }

    /// 左侧：完整翻译记录列表。
    private var entriesList: some View {
        Group {
            if course.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.page")
                        .font(.system(size: 34))
                        .foregroundStyle(.tertiary)
                    Text("本节课没有翻译记录")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(course.entries) { entry in
                            TranslationRow(entry: entry)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                            Divider()
                                .padding(.leading, 86)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 右侧：DeepSeek 审阅面板。
    private var reviewPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("DeepSeek 审阅", systemImage: "sparkles")
                .font(.headline)
            Text("审阅并改进本节课翻译，生成带总结、关键要点、主题图表、词汇表与旁批的格式化文档，自动保存到「桌面 / 课程记录」，文件名为课程开始时间。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                SecureField("DeepSeek API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                Button("保存") {
                    DeepSeekReviewService.savedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .controlSize(.small)
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .onChange(of: apiKey) { _, newValue in
                DeepSeekReviewService.savedAPIKey = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            Button {
                startReview()
            } label: {
                if isReviewing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("DeepSeek 审阅中…")
                    }
                } else {
                    Label("生成审阅文档", systemImage: "doc.badge.gearshape")
                }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isReviewing)

            reviewStateView

            Divider()

            Text("文档内容")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                bullet("课程总结与标题")
                bullet("审阅改进译文与旁批")
                bullet("关键知识要点")
                bullet("主题分布图表")
                bullet("重点词汇表")
                bullet("完整课堂记录")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 340)
    }

    private func bullet(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green.opacity(0.8))
                .font(.system(size: 11))
            Text(text)
        }
    }

    @ViewBuilder
    private var reviewStateView: some View {
        switch reviewState {
        case .idle:
            EmptyView()
        case .working:
            HStack(spacing: 8) {
                Text("正在审阅本节课 \(course.entries.count) 条翻译，请稍候…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .done(let url):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("审阅完成，文档已保存")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                }
                Text(url.lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack {
                    Button("打开文档") {
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.green.opacity(0.08))
            .cornerRadius(8)
        case .failed(let message):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.08))
            .cornerRadius(8)
        }
    }

    private func startReview() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !isReviewing else { return }
        isReviewing = true
        reviewState = .working
        Task {
            do {
                let result = try await DeepSeekReviewService.review(entries: course.entries, apiKey: key)
                let url = try DeepSeekReviewService.saveDocument(course: course, result: result)
                reviewState = .done(url)
            } catch {
                reviewState = .failed("生成失败：\(error.localizedDescription)")
            }
            isReviewing = false
        }
    }

    private static let fullTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static func fullTimeString(_ date: Date) -> String {
        fullTimeFormatter.string(from: date)
    }

    private static func durationString(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

#Preview {
    ContentView()
}
