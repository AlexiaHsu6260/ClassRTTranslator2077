# ClassRTTranslator2077 — 实时语音翻译器

赛博朋克风格的 macOS 实时语音翻译应用。

## 功能特性

- 实时语音识别与翻译（中英文互译）
- 赛博朋克霓虹主题界面（电青 / 品红）
- 可自定义背景（从相册 / 文件选择）
- 独立悬浮字幕窗，实时显示最近两句话
- DeepSeek API 翻译引擎
- 课程模式：开始新课 / 回看历史记录

## 技术栈

- SwiftUI + AppKit（macOS）
- Speech Framework（语音识别）
- DeepSeek Chat Completions API（翻译）

## 使用

1. 使用 Xcode 打开 `RealTimeTranslator.xcodeproj`
2. 在应用设置中配置 DeepSeek API Key
3. 点击"开始"进行实时语音翻译

## 构建

```bash
xcodebuild -project RealTimeTranslator/RealTimeTranslator.xcodeproj \
  -scheme RealTimeTranslator -configuration Debug \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build
```
