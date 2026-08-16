# CLASSRT TRANSLATOR 2077 · macOS Edition

赛博朋克风格的 macOS 实时语音翻译应用（macOS 原版，独立仓库）。

Windows 移植版见 [ClassRTTranslatorWindows](https://github.com/AlexiaHsu6260/ClassRTTranslatorWindows)（独立项目，不影响本应用）。

实时英语语音识别 → 双引擎实时翻译 → 置顶悬浮字幕 → 课堂记录 + 边录边存课堂录音 + 课后重听 / 重新翻译 / DeepSeek 审阅 HTML 文档。

## 功能特性

- **实时英语语音识别**：基于系统 Speech Framework（`SFSpeechRecognizer`），完全本地离线识别，不联网、不上传语音
- **双引擎实时翻译**：
  - **系统离线翻译**（macOS 15+）：免费、无网可用、数据不出本机，首次使用需下载英中语言包
  - **DeepSeek 在线翻译**：质量更高，可严格遵循术语表，失败时自动降级为系统翻译，翻译不中断
- **停顿判句**：本地识别结果一般不带标点，采用「停顿约 1.2 秒即视为一句话结束」判句翻译，带终止标点的句子立即翻译；去重 + 串行队列保证译文不重复、不乱序
- **课程模式**：开始新课 / 课程计时 / 结束课程归档全部翻译记录 / 回看本节课
- **边录边存课堂录音**：与识别共用同一份 16kHz 单声道音频流，实时写入 CAF 文件到「桌面/课程记录/课堂录音」，零额外采集开销；课后可重听
- **课后回看弹窗**：
  - 完整翻译记录列表（时间 + 英文原文 + 中文译文）
  - 课堂录音播放条（播放/暂停、进度）与「在访达中显示」
  - **课后重新翻译**：把整节课英文原文一次性批量交给 DeepSeek（带整课上下文与术语表），译文质量优于实时逐句翻译，可再次生成审阅文档
  - **DeepSeek 审阅**：生成格式化 HTML 文档（课程总结、审阅改进译文与旁批、关键要点、主题分布图表、重点词汇表、完整课堂记录）
- **术语表**：手动添加 / 从 Markdown 词库表格导入（`| 英文 | 中文 | 注释 |`），英文大小写不敏感去重，DeepSeek 翻译与重新翻译时强制遵循
- **置顶悬浮字幕窗**：无边框透明 NSPanel，仅显示最近两句译文，位置记忆、随开随关
- **赛博朋克霓虹主题**：电青 / 品红渐变、暗色基底，可自定义背景（从系统相册或本地文件选择，自动压暗保证可读性）
- **输入设备切换**：CoreAudio 实时切换系统默认输入设备为所选外置麦克风，停止/退出自动恢复
- **输入电平指示**：实时 RMS 电平 + 「采集正常 / 未采集到音频」诊断
- **长时间运行保护**：每 60 秒自动分段识别防止延迟累积；识别异常 3 秒后自动重连（上限 5 次）；3 秒无音频看门狗提示（区分权限问题与说话问题）
- **快捷键**：`⌘+空格` 开始 / 停止
- **诊断日志**：`/tmp/realtimetranslator_diag.log` 便于排查权限 / 设备问题

## 项目结构

```
RealTimeTranslator/
├── RealTimeTranslator.xcodeproj/        # Xcode 工程
└── RealTimeTranslator/
    ├── RealTimeTranslatorApp.swift      # 应用入口（SwiftUI App）
    ├── ContentView.swift                # 主界面 + 背景管理 + 悬浮字幕窗 + 翻译设置 + 课程回看弹窗
    ├── SpeechEngine.swift               # 语音识别引擎（AVAudioEngine + SFSpeechRecognizer）
    │                                     #   + 课程控制 + 翻译管线 + 边录边存课堂录音
    ├── TranslationService.swift         # 系统离线翻译（macOS 15+ Translation 框架，带句子缓存）
    ├── DeepSeekReviewService.swift      # 术语表管理 + DeepSeek 在线翻译 + DeepSeek 审阅/HTML 文档生成
    ├── AudioDeviceManager.swift         # 麦克风输入设备枚举与选择
    ├── PermissionManager.swift          # 麦克风 / 语音识别权限申请与状态管理
    └── Assets.xcassets/                 # 应用图标等资源
```

## 环境要求（构建）

- macOS 14+（系统离线翻译功能需 macOS 15+ 并下载英中语言包）
- Xcode 16+（含 macOS SDK），Swift 5.9+ / SwiftUI
- DeepSeek API Key（仅用于「DeepSeek 在线翻译」与「课程审阅」，可选）

## 构建与运行

1. 用 Xcode 打开 `RealTimeTranslator.xcodeproj`
2. 选择 scheme `RealTimeTranslator`，⌘R 运行；或 ⌘B 构建
3. （可选）在设置中填写 DeepSeek API Key

命令行构建：

```bash
xcodebuild -project RealTimeTranslator/RealTimeTranslator.xcodeproj \
  -scheme RealTimeTranslator -configuration Debug \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build
```

## 使用步骤

1. 首次启动点击「授权并继续」：依次授予 **麦克风** 与 **语音识别** 权限；若误拒，前往「系统设置 → 隐私与安全性 → 麦克风 / 语音识别」手动允许后重试
2. 在主界面顶部选择输入设备（内置 / 外置麦克风），点刷新可重新枚举
3. 点击右上角「⚙ 设置」：
   - 选择翻译引擎：系统离线翻译（免费、无网可用）或 DeepSeek 在线翻译（质量更高）
   - 填入 DeepSeek API Key（[platform.deepseek.com](https://platform.deepseek.com) 获取，密钥仅存本机 UserDefaults）
   - 可添加术语或从 Markdown 词库导入（`| 英文 | 中文 | 注释 |`）
   - 可选：通过相册菜单更换应用背景
4. 点击「课程开始」或「开始」：对着麦克风说英语，实时显示识别原文与中文译文；输入电平变绿表示采集正常
5. 可选：点击悬浮字幕按钮弹出置顶字幕窗（显示最近两句）
6. 点击「课程结束」：归档本节课全部翻译记录并自动停止录音，课堂录音已同步保存到「桌面/课程记录/课堂录音」
7. 点击「回看本节课」：
   - 左侧查看完整翻译记录；有录音时可「播放录音」重听、「在访达中显示」
   - 右侧「课后重新翻译本课」：批量重译获得更高质量译文（建议先于审阅执行）
   - 「生成审阅文档」：DeepSeek 审阅并保存 HTML 到「桌面/课程记录」，可「打开文档」或「在访达中显示」

## 数据位置

- 设置与术语表：UserDefaults（应用卸载即清空，建议保留术语表 Markdown 源文件）
- 背景图片：`~/Library/Application Support/RealTimeTranslator/Backgrounds/`
- 课堂录音：`桌面/课程记录/课堂录音/yyyy-MM-dd HH-mm-ss 课堂录音.caf`（16kHz 单声道 Float32）
- 审阅文档：`桌面/课程记录/yyyy-MM-dd HH-mm-ss 课堂记录.html`
- 诊断日志：`/tmp/realtimetranslator_diag.log`

## 已知限制与后续路线

- 仅支持英语（en-US）识别与英文 → 中文翻译
- 系统离线翻译依赖 macOS 15+，首次使用需在系统弹出提示中下载英中语言包；否则请改用 DeepSeek 在线翻译
- 识别为「边说边出字」，翻译采用停顿判句（约 1.2 秒停顿触发），连续快速说话时句子可能合并
- 切换输入设备需通过 CoreAudio 修改系统默认输入设备，若外部程序同时占用可能切换失败（会自动恢复原设备）
- 未签名构建产物首次打开可能被 Gatekeeper 拦截：右键 → 打开
- 后续可接入 sherpa-onnx 离线流式识别与离线翻译，摆脱对 macOS 15 与网络的依赖
