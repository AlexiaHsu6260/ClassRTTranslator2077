import Foundation
import Translation

/// 端侧翻译服务：英文 → 简体中文。
///
/// 基于系统 `Translation` 框架（macOS 15+ 的 `TranslationSession`），
/// 翻译完全在本机完成，与语音识别一样不依赖网络。
///
/// 会话由视图层的 `.translationTask` 创建并注入：这样 `canRequestDownloads`
/// 为 `true`，当英→中语言包尚未安装时，系统会自动弹出下载提示，
/// 用户确认后即可离线使用。
@available(macOS 15.0, *)
final class TranslationService {
    /// 句子翻译缓存：避免同一句子反复翻译。
    private var cache: [String: String] = [:]

    /// 批量翻译一组文本（顺序与原数组一致）。
    /// 已缓存的结果直接复用；失败抛出错误。
    func translate(_ texts: [String], session: TranslationSession) async throws -> [String] {
        guard !texts.isEmpty else { return [] }

        var results: [String] = []
        var need: [String] = []
        var needIndex: [Int] = []
        for (i, text) in texts.enumerated() {
            if let hit = cache[text] {
                results.append(hit)
            } else {
                results.append("")
                need.append(text)
                needIndex.append(i)
            }
        }
        guard !need.isEmpty else { return results }

        let requests = need.map { TranslationSession.Request(sourceText: $0) }
        let responses = try await session.translations(from: requests)
        for (idx, response) in responses.enumerated() {
            let zh = response.targetText
            cache[need[idx]] = zh
            results[needIndex[idx]] = zh
        }
        return results
    }

    /// 翻译单条文本。
    func translate(_ text: String, session: TranslationSession) async throws -> String {
        let results = try await translate([text], session: session)
        return results.first ?? ""
    }
}
