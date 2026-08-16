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

// MARK: - UI 主题

/// 界面主题：赛博朋克（默认）/ 极简瑞士 / OLED 暗黑 / 玻璃拟态。
/// 通过顶栏「主题」按钮切换，选择持久化到 UserDefaults（key: ui_theme）。
enum UITheme: String, CaseIterable, Identifiable {
    case cyberpunk
    case swiss
    case oled
    case glass

    var id: String { rawValue }

    /// UserDefaults 持久化键。
    static let storageKey = "ui_theme"

    /// 从存储读取当前主题。
    static func current() -> UITheme {
        UITheme(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .cyberpunk
    }

    var displayName: String {
        switch self {
        case .cyberpunk: return "赛博朋克"
        case .swiss: return "极简瑞士"
        case .oled: return "OLED 暗黑"
        case .glass: return "玻璃拟态"
        }
    }

    var iconName: String {
        switch self {
        case .cyberpunk: return "bolt.fill"
        case .swiss: return "square.grid.2x2.fill"
        case .oled: return "moon.fill"
        case .glass: return "drop.fill"
        }
    }

    /// 是否深色系（决定蒙版压暗强度等）。
    var isDark: Bool {
        switch self {
        case .cyberpunk, .oled: return true
        case .swiss, .glass: return false
        }
    }

    // MARK: 颜色

    /// 主强调色。
    var primary: Color {
        switch self {
        case .cyberpunk: return Color(red: 0.0, green: 0.90, blue: 1.0)
        case .swiss: return Color(red: 0.85, green: 0.10, blue: 0.10)
        case .oled: return Color(red: 0.35, green: 0.85, blue: 0.85)
        case .glass: return Color(red: 0.35, green: 0.60, blue: 1.0)
        }
    }

    /// 次强调色。
    var secondary: Color {
        switch self {
        case .cyberpunk: return Color(red: 1.0, green: 0.23, blue: 0.58)
        case .swiss: return Color(red: 0.12, green: 0.12, blue: 0.12)
        case .oled: return Color(red: 0.30, green: 0.80, blue: 1.0)
        case .glass: return Color(red: 0.70, green: 0.45, blue: 1.0)
        }
    }

    /// 渐变第三色（图标/背景渐变用）。
    var tertiary: Color {
        switch self {
        case .cyberpunk: return Color(red: 0.55, green: 0.35, blue: 1.0)
        case .swiss: return Color(red: 0.30, green: 0.30, blue: 0.30)
        case .oled: return Color(red: 0.10, green: 0.45, blue: 0.60)
        case .glass: return Color(red: 1.0, green: 0.55, blue: 0.80)
        }
    }

    /// 弹窗/面板背景色。
    var panelBackground: Color {
        switch self {
        case .cyberpunk: return Color(red: 0.05, green: 0.06, blue: 0.12)
        case .swiss: return Color(red: 0.97, green: 0.97, blue: 0.96)
        case .oled: return Color(red: 0.0, green: 0.0, blue: 0.0)
        case .glass: return Color(red: 0.90, green: 0.94, blue: 1.0)
        }
    }

    /// 卡片填充（材质或纯色）。
    var cardFill: AnyShapeStyle {
        switch self {
        case .cyberpunk: return AnyShapeStyle(.ultraThinMaterial)
        case .swiss: return AnyShapeStyle(Color(red: 0.99, green: 0.99, blue: 0.98))
        case .oled: return AnyShapeStyle(Color(red: 0.03, green: 0.03, blue: 0.03))
        case .glass: return AnyShapeStyle(.ultraThinMaterial)
        }
    }

    /// 卡片描边颜色。
    var stroke: Color {
        switch self {
        case .cyberpunk: return Color(red: 0.0, green: 0.90, blue: 1.0).opacity(0.35)
        case .swiss: return Color(red: 0.10, green: 0.10, blue: 0.10).opacity(0.14)
        case .oled: return Color(red: 0.35, green: 0.85, blue: 0.85).opacity(0.35)
        case .glass: return Color.white.opacity(0.65)
        }
    }

    /// 辉光/阴影颜色。
    var glow: Color {
        switch self {
        case .cyberpunk: return Color(red: 0.0, green: 0.90, blue: 1.0).opacity(0.18)
        case .swiss: return Color.black.opacity(0.08)
        case .oled: return Color(red: 0.35, green: 0.85, blue: 0.85).opacity(0.15)
        case .glass: return Color.black.opacity(0.12)
        }
    }

    /// 主图标渐变。
    var primaryGradient: LinearGradient {
        switch self {
        case .cyberpunk:
            return LinearGradient(
                colors: [primary, tertiary, secondary],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .swiss:
            return LinearGradient(
                colors: [primary, Color(red: 0.55, green: 0.08, blue: 0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .oled:
            return LinearGradient(
                colors: [Color(red: 0.35, green: 0.85, blue: 0.85), Color(red: 0.10, green: 0.45, blue: 0.60)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .glass:
            return LinearGradient(
                colors: [Color(red: 0.35, green: 0.60, blue: 1.0), secondary, tertiary],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
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
    @StateObject private var glossary = GlossaryManager()
    @State private var isShowingTranslationSettings = false
    @State private var isShowingHistory = false

    /// 当前界面主题（顶栏可切换，持久化到 UserDefaults）。
    @AppStorage(UITheme.storageKey) private var themeName = UITheme.cyberpunk.rawValue

    private var theme: UITheme { UITheme(rawValue: themeName) ?? .cyberpunk }

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
        // 浅色主题（极简瑞士/玻璃拟态）强制浅色模式，深色主题强制深色模式，保证文字对比度。
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .task { deviceManager.refresh() }
        .onAppear { engine.setGlossaryManager(glossary) }
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
                CourseReviewView(course: course, glossaryTerms: glossary.terms)
            }
        }
        .sheet(isPresented: $isShowingTranslationSettings) {
            TranslationSettingsView(engine: engine, glossary: glossary)
        }
        .sheet(isPresented: $isShowingHistory) {
            HistoryCoursesView(glossaryTerms: glossary.terms)
        }
    }

    /// 顶部封面栏：应用图标 + 名称 + 主题/背景设置 + 录音状态。
    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(theme.primaryGradient)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                    )
                Image(systemName: "waveform")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
            }
            .frame(width: 46, height: 46)
            .shadow(color: theme.secondary.opacity(0.6), radius: 8, y: 0)
            .shadow(color: theme.primary.opacity(0.5), radius: 6, y: 0)

            VStack(alignment: .leading, spacing: 2) {
                Text("实时语音翻译")
                    .font(.title3.bold())
                Text("RealTimeTranslator · 英语实时识别与翻译")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            subtitleToggleButton

            historyButton

            settingsButton

            themeMenu

            backgroundMenu

            StatusBadge(isRecording: engine.isRecording)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(theme.cardFill, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(theme.stroke, lineWidth: 1)
        )
        .shadow(color: theme.glow, radius: 12, y: 0)
        .onChange(of: photoPickerItem) { _, item in
            loadPhoto(item)
        }
    }

    /// 主题切换菜单：赛博朋克 / 极简瑞士 / OLED 暗黑 / 玻璃拟态。
    private var themeMenu: some View {
        Menu {
            ForEach(UITheme.allCases) { item in
                Button {
                    themeName = item.rawValue
                } label: {
                    Label(item.displayName, systemImage: item.iconName)
                    if item == theme {
                        Image(systemName: "checkmark")
                    }
                }
            }
            Divider()
            Text(theme.displayName + " · 当前主题")
                .font(.caption)
                .foregroundStyle(.secondary)
        } label: {
            Image(systemName: "paintpalette.fill")
                .font(.body)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("切换界面主题：赛博朋克 / 极简瑞士 / OLED 暗黑 / 玻璃拟态")
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

    /// 历史课程入口：浏览与检索已归档的课堂记录。
    private var historyButton: some View {
        Button {
            isShowingHistory = true
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.body)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("历史课程：浏览与检索已归档的课堂记录")
    }

    /// 翻译设置入口：翻译引擎选择 / DeepSeek API Key / 术语表。
    private var settingsButton: some View {
        Button {
            isShowingTranslationSettings = true
        } label: {
            Image(systemName: "gearshape")
                .font(.body)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("翻译设置：翻译引擎 / API Key / 术语表")
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
        .background(theme.cardFill, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(theme.stroke.opacity(0.8), lineWidth: 1)
        )
        .shadow(color: theme.glow.opacity(0.7), radius: 10, y: 0)
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
        .tint(engine.isRecording ? .red : theme.primary)
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
                    .foregroundStyle(theme.secondary)
                    .help("本节课已进行时长")
                Text("已记录 \(engine.translationEntries.count) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await engine.generateSummary() }
                } label: {
                    if engine.isSummarizing {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Label("生成要点", systemImage: "list.bullet.rectangle")
                    }
                }
                .buttonStyle(.bordered)
                .help("调用 DeepSeek 把本节课内容提炼为要点（每 10 分钟自动生成）")
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
                .tint(theme.primary)
                .help("查看本节课完整翻译记录")
                Button {
                    startCourse()
                } label: {
                    Label("开始新课", systemImage: "play.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.secondary)
            } else {
                Spacer()
                Button {
                    startCourse()
                } label: {
                    Label("课程开始", systemImage: "play.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.secondary)
                .help("开始课堂记录：自动开始录音，界面仅显示最近 1 分钟翻译，其余保留待课后回看")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.cardFill, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(theme.stroke.opacity(0.8), lineWidth: 1)
        )
        .shadow(color: theme.glow.opacity(0.8), radius: 10, y: 0)
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

                    // 实时要点（每 10 分钟由 DeepSeek 自动生成，也可点课程栏「生成要点」）
                    if !engine.summaryPoints.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "list.bullet.rectangle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("实时要点")
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(engine.summaryPoints.count) 条")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            ForEach(engine.summaryPoints, id: \.self) { point in
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(theme.primary.opacity(0.8))
                                    Text(point)
                                        .font(.callout)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .padding(16)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(theme.isDark ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color.black.opacity(0.04)))
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
                .strokeBorder(theme.secondary.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: theme.glow.opacity(0.7), radius: 10, y: 0)
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
        // 独立面板不继承主窗口配色，按当前主题设置外观保证文字对比度。
        panel.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
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

/// 应用背景层：按主题渲染（赛博朋克/极简瑞士/OLED/玻璃拟态），
/// 或用户选择的相册/文件图片（自动压暗保证可读性）。
private struct AppBackground: View {
    @ObservedObject var background: BackgroundManager
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(UITheme.storageKey) private var themeName = UITheme.cyberpunk.rawValue

    private var theme: UITheme { UITheme(rawValue: themeName) ?? .cyberpunk }

    var body: some View {
        ZStack {
            if let image = background.backgroundImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                // 压暗蒙版：保证前景文字与卡片可读（浅色主题压暗更轻）。
                Rectangle()
                    .fill(theme.isDark ? Color.black.opacity(0.5) : Color.black.opacity(0.30))
                    .ignoresSafeArea()
                // 氛围光：叠在用户图片上呼应当前主题。
                theme.primary.opacity(0.06)
                    .ignoresSafeArea()
            } else {
                themeBackground
                    .ignoresSafeArea()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: background.backgroundImage)
        .animation(.easeInOut(duration: 0.3), value: theme)
    }

    /// 各主题默认背景。
    @ViewBuilder
    private var themeBackground: some View {
        switch theme {
        case .cyberpunk:
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
                    colors: [Color.white.opacity(0.03), Color.white.opacity(0.0), Color.white.opacity(0.03)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        case .swiss:
            // 极简瑞士：米白基底 + 左上角瑞士红几何点缀 + 极淡网格。
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.98, green: 0.98, blue: 0.97), Color(red: 0.94, green: 0.94, blue: 0.92)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Rectangle()
                    .fill(Color(red: 0.85, green: 0.10, blue: 0.10).opacity(0.08))
                    .frame(width: 420, height: 420)
                    .offset(x: -220, y: -220)
                Canvas { context, size in
                    var path = Path()
                    let step: CGFloat = 48
                    var y: CGFloat = 0
                    while y < size.height {
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                        y += step
                    }
                    var x: CGFloat = 0
                    while x < size.width {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                        x += step
                    }
                    context.stroke(path, with: .color(Color.black.opacity(0.03)), lineWidth: 1)
                }
            }
        case .oled:
            // OLED 暗黑：纯黑基底，无渐变、无光斑（真黑省电 + 高对比）。
            Color.black
        case .glass:
            // 玻璃拟态：柔和多色渐变背景，衬托半透明磨砂卡片。
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.72, green: 0.82, blue: 1.0),
                        Color(red: 0.92, green: 0.80, blue: 1.0),
                        Color(red: 1.0, green: 0.84, blue: 0.92)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Circle()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: 420, height: 420)
                    .blur(radius: 110)
                    .offset(x: -180, y: -160)
                Circle()
                    .fill(Color(red: 0.60, green: 0.80, blue: 1.0).opacity(0.45))
                    .frame(width: 460, height: 460)
                    .blur(radius: 120)
                    .offset(x: 200, y: 180)
            }
        }
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
/// 支持调节透明度与字号（设置持久化到 UserDefaults）。
private struct FloatingSubtitleView: View {
    @ObservedObject var engine: SpeechEngine
    var onClose: () -> Void

    /// 字幕窗透明度（0.3…1.0，默认 0.95）。
    @AppStorage("subtitle_opacity") private var subtitleOpacity = 0.95
    /// 译文字号（11…24，默认 15）。
    @AppStorage("subtitle_font_size") private var subtitleFontSize = 15.0
    /// 原文字号（比译文略小）。
    private var sourceFontSize: Double { max(10, subtitleFontSize - 2) }
    /// 当前主题（跟随主界面切换）。
    @AppStorage(UITheme.storageKey) private var themeName = UITheme.cyberpunk.rawValue

    private var theme: UITheme { UITheme(rawValue: themeName) ?? .cyberpunk }

    /// 最近两句翻译（不足两条时显示已有的）。
    private var recentTwo: [TranslationEntry] {
        Array(engine.translationEntries.suffix(2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "captions.bubble.fill")
                    .font(.caption)
                    .foregroundStyle(theme.primary)
                Text("实时字幕 · 最近两句")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Text("透明度")
                                .frame(width: 40, alignment: .leading)
                            Slider(value: $subtitleOpacity, in: 0.3...1.0)
                                .frame(width: 130)
                        }
                        HStack(spacing: 8) {
                            Text("字号")
                                .frame(width: 40, alignment: .leading)
                            Slider(value: $subtitleFontSize, in: 11...24, step: 1)
                                .frame(width: 130)
                        }
                        Text("设置会自动记住")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(6)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("字幕窗样式：透明度 / 字号")
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
                                .font(.system(size: sourceFontSize))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Text(entry.target)
                                .font(.system(size: subtitleFontSize, weight: .medium))
                                .lineLimit(2)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.isDark ? Color.black.opacity(0.4) : Color.white.opacity(0.35),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(theme.stroke.opacity(0.8), lineWidth: 1)
                        )
                    }
                }
            }
        }
        .padding(12)
        .background(theme.cardFill.opacity(subtitleOpacity), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(theme.stroke, lineWidth: 1)
        )
        .shadow(color: theme.glow, radius: 12, y: 0)
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

/// 翻译设置弹窗：翻译引擎切换 / DeepSeek API Key / 术语表管理（手动添加或从 Markdown 词库导入）。
private struct TranslationSettingsView: View {
    @ObservedObject var engine: SpeechEngine
    @ObservedObject var glossary: GlossaryManager
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = DeepSeekReviewService.savedAPIKey
    @State private var newSource = ""
    @State private var newTarget = ""
    @State private var importMessage: String?
    @State private var subject = UserDefaults.standard.string(forKey: "course_subject") ?? ""
    @State private var conflictMessage = ""
    @AppStorage(UITheme.storageKey) private var themeName = UITheme.cyberpunk.rawValue

    private var theme: UITheme { UITheme(rawValue: themeName) ?? .cyberpunk }

    private var trimmedSource: String { newSource.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedTarget: String { newTarget.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 500, height: 560)
        .background(theme.panelBackground)
    }

    private var header: some View {
        HStack {
            Label("翻译设置", systemImage: "gearshape.2.fill")
                .font(.title3.bold())
                .foregroundStyle(theme.primary)
            Spacer()
            Button("完成") {
                dismiss()
            }
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(16)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                engineSection
                subjectSection
                apiKeySection
                glossarySection
            }
            .padding(16)
        }
    }

    // MARK: 翻译引擎

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("翻译引擎")
                .font(.headline)
            Picker("翻译引擎", selection: $engine.translationEngine) {
                ForEach(TranslationEngine.allCases) { item in
                    Text(item.displayName).tag(item)
                }
            }
            .pickerStyle(.segmented)
            Text("系统离线翻译：免费、无网可用、数据不出本机，但需 macOS 15+ 且质量一般。\nDeepSeek 在线翻译：翻译质量更高，可严格遵循下方术语表，需联网并配置 API Key。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 课程科目

    /// 课程科目：填写后 DeepSeek 翻译/摘要优先使用该学科术语。
    private var subjectSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("课程科目")
                .font(.headline)
            TextField("课程科目（可选，如：微积分、线性代数）", text: $subject)
                .textFieldStyle(.roundedBorder)
                .onChange(of: subject) { _, newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    UserDefaults.standard.set(trimmed, forKey: "course_subject")
                }
            Text("填写后，DeepSeek 翻译与摘要会优先使用该学科的术语与表达。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: API Key

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DeepSeek API Key")
                .font(.headline)
            SecureField("sk-...", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .onChange(of: apiKey) { _, newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        DeepSeekReviewService.savedAPIKey = trimmed
                    }
                }
            Text("用于「DeepSeek 在线翻译」与「课程审阅」。key 仅保存在本机（UserDefaults）。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 术语表

    private var glossarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("术语表")
                    .font(.headline)
                Spacer()
                Text("\(glossary.terms.count) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                TextField("英文术语", text: $newSource)
                    .textFieldStyle(.roundedBorder)
                TextField("中文译名", text: $newTarget)
                    .textFieldStyle(.roundedBorder)
                Button {
                    addTerm()
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(trimmedSource.isEmpty || trimmedTarget.isEmpty)
                .help("添加术语")
            }
            if !conflictMessage.isEmpty {
                Text(conflictMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 从本节课识别文本提取高频词，一键填入英文术语。
            let candidates = glossary.candidates(from: engine.translationEntries.map(\.source), limit: 8)
            if !candidates.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("本节课高频词（点击填入英文，补充中文译名后添加）")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4), spacing: 6) {
                        ForEach(candidates, id: \.word) { candidate in
                            Button {
                                newSource = candidate.word
                                conflictMessage = ""
                            } label: {
                                Text("\(candidate.word) ×\(candidate.count)")
                                    .lineLimit(1)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("填入「\(candidate.word)」（本节课出现 \(candidate.count) 次）")
                        }
                    }
                }
                .padding(.top, 2)
            }
            if glossary.terms.isEmpty {
                Text("暂无术语。DeepSeek 在线翻译时会强制遵循术语表，提升专业词汇译文一致性。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 6) {
                    ForEach(glossary.terms) { term in
                        HStack {
                            Text(term.source)
                                .font(.system(.body, design: .rounded).bold())
                                .foregroundStyle(theme.primary)
                            Image(systemName: "arrow.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(term.target)
                                .font(.body)
                            Spacer()
                            Button {
                                glossary.remove(term)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("删除术语")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(theme.secondary.opacity(0.35), lineWidth: 1)
                        )
                    }
                }
            }
            HStack(spacing: 10) {
                Button {
                    importGlossary()
                } label: {
                    Label("从 Markdown 词库导入…", systemImage: "square.and.arrow.down")
                }
                Button {
                    glossary.clear()
                } label: {
                    Label("清空全部", systemImage: "trash")
                        .foregroundStyle(.red)
                }
                .disabled(glossary.terms.isEmpty)
            }
            if let importMessage {
                Text(importMessage)
                    .font(.caption)
                    .foregroundStyle(theme.primary)
            }
        }
    }

    // MARK: 动作

    private func addTerm() {
        if let message = glossary.conflictMessage(source: trimmedSource, target: trimmedTarget) {
            conflictMessage = message
            return
        }
        glossary.add(source: trimmedSource, target: trimmedTarget)
        conflictMessage = ""
        newSource = ""
        newTarget = ""
    }

    private func importGlossary() {
        let panel = NSOpenPanel()
        var contentTypes: [UTType] = [.plainText]
        if let markdownType = UTType(filenameExtension: "md") {
            contentTypes.append(markdownType)
        }
        panel.allowedContentTypes = contentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择 Markdown 词库（表格格式：| 英文 | 中文 | 注释 |）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let count = glossary.importFromMarkdown(url: url)
        importMessage = count > 0
            ? "导入成功：新增 \(count) 条术语。"
            : "没有导入任何术语（文件为空、格式不符或术语已存在）。"
    }
}

/// 课程回看弹窗：展示本节课完整翻译记录，并可调用 DeepSeek 审阅生成文档。
private struct CourseReviewView: View {
    /// 当前回看的课程（重新翻译后同步更新其译文）。
    @State private var course: CourseSession
    /// 术语表（重新翻译时注入，保持术语一致）。
    let glossaryTerms: [GlossaryTerm]
    @Environment(\.dismiss) private var dismiss
    @AppStorage("deepseek_api_key") private var apiKey = ""
    @State private var isReviewing = false
    @State private var reviewState: ReviewState = .idle
    @State private var isRetranslating = false
    @State private var retranslateState: RetranslateState = .idle
    @State private var audioPlayer: AVAudioPlayer?
    @State private var isPlayingRecording = false
    @State private var playbackPosition: TimeInterval = 0
    @State private var playbackDuration: TimeInterval = 0
    @State private var playbackTimer: Timer?

    enum ReviewState {
        case idle
        case working
        case done(URL)
        case failed(String)
    }

    enum RetranslateState {
        case idle
        case working
        case done(Int)
        case failed(String)
    }

    init(course: CourseSession, glossaryTerms: [GlossaryTerm]) {
        _course = State(initialValue: course)
        self.glossaryTerms = glossaryTerms
    }

    /// 本节课是否有可用的课堂录音文件。
    private var recordingExists: Bool {
        guard let url = course.recordingURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
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
            if recordingExists {
                recordingBar
                Divider()
            }
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
        .onDisappear {
            audioPlayer?.stop()
            playbackTimer?.invalidate()
        }
    }

    /// 课堂录音控制条：播放/暂停、进度、在访达中显示。
    private var recordingBar: some View {
        HStack(spacing: 12) {
            Image(systemName: isPlayingRecording ? "pause.fill" : "play.fill")
                .font(.system(size: 13))
                .foregroundStyle(isPlayingRecording ? .red : .blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("课堂录音（边录边存，可重听）")
                    .font(.caption.bold())
                Text(playbackDuration > 0
                     ? "\(Self.durationString(playbackPosition)) / \(Self.durationString(playbackDuration))"
                     : (course.recordingURL?.lastPathComponent ?? ""))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if playbackDuration > 0 {
                ProgressView(value: playbackPosition, total: max(playbackDuration, 0.001))
                    .frame(maxWidth: 240)
            }
            Spacer()
            Button(isPlayingRecording ? "暂停" : "播放录音") {
                togglePlayback()
            }
            Menu {
                Button("导出 SRT 字幕（带时间轴）") {
                    exportSubtitle(format: .srt)
                }
                Button("导出 VTT 字幕（网页字幕）") {
                    exportSubtitle(format: .vtt)
                }
            } label: {
                Label("导出字幕", systemImage: "captions.bubble")
            }
            .help("把本节课翻译记录导出为标准字幕文件，可直接挂到课程录屏上")
            Button("在访达中显示") {
                revealRecording()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.blue.opacity(0.06))
    }

    private func togglePlayback() {
        guard let url = course.recordingURL else { return }
        if isPlayingRecording {
            audioPlayer?.pause()
            playbackTimer?.invalidate()
            isPlayingRecording = false
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            audioPlayer = player
            player.prepareToPlay()
            playbackDuration = player.duration
            playbackPosition = 0
            player.play()
            isPlayingRecording = true
            startPlaybackTimer()
        } catch {
            reviewState = .failed("无法播放录音：\(error.localizedDescription)")
        }
    }

    /// 启动播放进度定时器（首次播放 / 跳转后都会启用）。
    private func startPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            let current = audioPlayer?.currentTime ?? 0
            playbackPosition = current
            if let player = audioPlayer, !player.isPlaying, isPlayingRecording {
                isPlayingRecording = false
                playbackPosition = player.duration
                playbackTimer?.invalidate()
            }
        }
    }

    /// 点击某条译文：跳转课堂录音到该句起始位置并播放（录音识别有约 1.5s 延迟，已由 audioTime 补偿）。
    private func seekToEntry(_ entry: TranslationEntry) {
        guard recordingExists, entry.audioTime > 0, let url = course.recordingURL else { return }
        do {
            if audioPlayer == nil {
                let player = try AVAudioPlayer(contentsOf: url)
                audioPlayer = player
                player.prepareToPlay()
                playbackDuration = player.duration
            }
            guard let player = audioPlayer else { return }
            let target = min(max(entry.audioTime, 0), max(playbackDuration - 0.5, 0))
            player.currentTime = target
            player.play()
            isPlayingRecording = true
            startPlaybackTimer()
        } catch {
            reviewState = .failed("无法播放录音：\(error.localizedDescription)")
        }
    }

    /// 导出字幕（SRT / VTT）到「桌面/课程记录/字幕/」。
    private func exportSubtitle(format: SubtitleFormat) {
        guard !course.entries.isEmpty else { return }
        let content: String
        switch format {
        case .srt:
            content = SubtitleExporter.srt(entries: course.entries, base: course.startDate)
        case .vtt:
            content = SubtitleExporter.vtt(entries: course.entries, base: course.startDate)
        }
        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else { return }
        let folder = desktop.appendingPathComponent("课程记录", isDirectory: true)
            .appendingPathComponent("字幕", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = Self.subtitleFileName(for: course, format: format)
            let url = folder.appendingPathComponent(name)
            try content.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            reviewState = .failed("导出字幕失败：\(error.localizedDescription)")
        }
    }

    /// 字幕格式（内部枚举，避免与 SubtitleExporter 重名）。
    private enum SubtitleFormat {
        case srt, vtt
    }

    private static func subtitleFileName(for course: CourseSession, format: SubtitleFormat) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let base = formatter.string(from: course.startDate)
        switch format {
        case .srt: return "\(base) 课堂字幕.srt"
        case .vtt: return "\(base) 课堂字幕.vtt"
        }
    }

    private func revealRecording() {
        guard let url = course.recordingURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
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
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    seekToEntry(entry)
                                }
                                .help("点击跳转到课堂录音中的这句位置")
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

            Divider()

            Label("课后重新翻译", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)
            Text("把本节课 \(course.entries.count) 条英文原文一次性批量交给 DeepSeek 重新翻译（带整课上下文与术语表），译文质量优于实时逐句翻译；重新翻译后可再次生成审阅文档。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                retranslate()
            } label: {
                if isRetranslating {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("重新翻译中…")
                    }
                } else {
                    Label("重新翻译本课（DeepSeek）", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRetranslating || course.entries.isEmpty)

            retranslateStateView

            Divider()

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

    @ViewBuilder
    private var retranslateStateView: some View {
        switch retranslateState {
        case .idle, .working:
            EmptyView()
        case .done(let count):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("重新翻译完成，已更新 \(count) 条译文（可再次生成审阅文档）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
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
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.08))
            .cornerRadius(8)
        }
    }

    /// 课后重新翻译：把整节课英文原文一次性批量交给 DeepSeek，
    /// 带整课上下文与术语表，获得比实时逐句翻译更好的质量。
    private func retranslate() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !isRetranslating, !course.entries.isEmpty else { return }
        isRetranslating = true
        retranslateState = .working
        let sentences = course.entries.map(\.source)
        Task {
            do {
                let context = "这些句子来自同一节英语课的连续课堂记录，按时间顺序排列。" +
                    "请结合整节课的上下文进行翻译，保持术语、人名与表达前后一致，避免逐句生硬直译，使整体连贯自然。"
                let results = try await DeepSeekTranslationService.translate(
                    sentences, glossary: glossaryTerms, apiKey: key, courseContext: context)
                let updated = zip(course.entries, results).map { entry, target in
                    TranslationEntry(
                        timestamp: entry.timestamp,
                        source: entry.source,
                        target: target.isEmpty ? entry.target : target
                    )
                }
                course = CourseSession(
                    startDate: course.startDate,
                    endDate: course.endDate,
                    entries: updated,
                    recordingURL: course.recordingURL
                )
                retranslateState = .done(updated.count)
            } catch {
                retranslateState = .failed("重新翻译失败：\(error.localizedDescription)")
            }
            isRetranslating = false
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

/// 历史课程浏览与检索：列出「桌面/课程记录/记录/」下的归档课程，支持关键词搜索与打开回看。
private struct HistoryCoursesView: View {
    let glossaryTerms: [GlossaryTerm]
    @Environment(\.dismiss) private var dismiss
    @State private var keyword = ""
    @State private var courses: [CourseSession] = []
    @State private var reviewingCourse: CourseSession?
    @AppStorage(UITheme.storageKey) private var themeName = UITheme.cyberpunk.rawValue

    private var theme: UITheme { UITheme(rawValue: themeName) ?? .cyberpunk }

    private var filtered: [CourseSession] {
        CourseArchive.search(keyword, in: courses)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("历史课程", systemImage: "clock.arrow.circlepath")
                    .font(.title3.bold())
                    .foregroundStyle(theme.primary)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding(16)
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索关键词（匹配原文或译文）", text: $keyword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        // 无操作，过滤随输入实时生效
                    }
            }
            .padding(12)
            Divider()
            if filtered.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.system(size: 34))
                        .foregroundStyle(.tertiary)
                    Text(courses.isEmpty
                         ? "还没有归档课程。\n课程结束后记录会自动保存到「桌面/课程记录/记录/」。"
                         : "没有匹配「\(keyword)」的课程。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { course in
                            HistoryCourseRow(course: course)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    reviewingCourse = course
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                            Divider()
                                .padding(.leading, 16)
                        }
                    }
                }
            }
        }
        .frame(width: 700, height: 480)
        .background(theme.panelBackground)
        .onAppear { courses = CourseArchive.loadAll() }
        .sheet(item: $reviewingCourse) { course in
            CourseReviewView(course: course, glossaryTerms: glossaryTerms)
        }
    }
}

/// 历史课程行：开始时间 + 条数/时长 + 原文预览。
private struct HistoryCourseRow: View {
    let course: CourseSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Self.dateString(course.startDate))
                    .font(.body.bold())
                Spacer()
                Text("\(course.entries.count) 条翻译 · 时长 \(Self.durationString(course.duration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let first = course.entries.first {
                Text(first.source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .help("点击打开本节课回看（可重听录音 / 重新翻译 / 导出字幕 / 生成审阅）")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static func dateString(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private static func durationString(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

#Preview {
    ContentView()
}
