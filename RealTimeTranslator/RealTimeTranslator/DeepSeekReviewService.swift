import Foundation
import Combine

// MARK: - 术语表

/// 一条术语表记录：用户自定义的专业词汇（英文 → 中文）。
struct GlossaryTerm: Codable, Identifiable, Hashable {
    var id = UUID()
    var source: String
    var target: String
    var note: String = ""

    init(source: String, target: String, note: String = "") {
        self.source = source
        self.target = target
        self.note = note
    }
}

/// 术语表管理器：负责术语的增删、持久化，以及从 Markdown 词库表格导入。
/// 术语表用于 DeepSeek 在线翻译时强制遵循，提升专业词汇的译文一致性。
@MainActor
final class GlossaryManager: ObservableObject {
    @Published private(set) var terms: [GlossaryTerm] = []

    private static let storageKey = "glossary_terms"

    init() {
        load()
    }

    // MARK: 增删改

    func add(source: String, target: String, note: String = "") {
        let src = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let dst = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !src.isEmpty, !dst.isEmpty else { return }
        // 英文大小写不敏感去重。
        if terms.contains(where: { $0.source.caseInsensitiveCompare(src) == .orderedSame }) {
            return
        }
        terms.append(GlossaryTerm(source: src, target: dst, note: note.trimmingCharacters(in: .whitespacesAndNewlines)))
        save()
    }

    // MARK: 候选提取与冲突检测

    /// 常见英文停用词（提取候选术语时过滤）。
    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "so", "for", "with", "without",
        "of", "to", "in", "on", "at", "by", "from", "into", "about", "as",
        "is", "are", "was", "were", "be", "been", "being", "have", "has", "had",
        "do", "does", "did", "can", "could", "will", "would", "should", "may", "might",
        "must", "not", "no", "yes", "this", "that", "these", "those", "there", "here",
        "it", "its", "i", "you", "we", "they", "he", "she", "him", "her",
        "all", "some", "any", "more", "most", "each", "every", "both", "other", "such",
        "what", "which", "who", "when", "where", "why", "how", "then", "than", "also",
        "just", "very", "really", "because", "if", "though", "although", "while", "until", "up",
        "down", "out", "off", "over", "under", "again", "first", "second", "let", "get",
    ]

    /// 从课堂翻译记录中提取高频候选词（忽略停用词与已收录词），供一键添加术语。
    func candidates(from sources: [String], limit: Int = 12) -> [(word: String, count: Int)] {
        var frequency: [String: Int] = [:]
        for source in sources {
            let tokens = source.lowercased().split(whereSeparator: { !$0.isLetter })
            for token in tokens {
                let word = String(token)
                guard word.count >= 4 else { continue }
                guard !Self.stopWords.contains(word) else { continue }
                guard !terms.contains(where: { $0.source.caseInsensitiveCompare(word) == .orderedSame }) else { continue }
                frequency[word, default: 0] += 1
            }
        }
        return frequency
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { (word: $0.key, count: $0.value) }
    }

    /// 冲突检测：返回添加该词条可能产生的提示（无冲突返回 nil）。
    /// - 译文与现有其他词条相同（一词多译冲突）。
    /// - 英文词已被收录。
    func conflictMessage(source: String, target: String) -> String? {
        let src = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let dst = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if terms.contains(where: { $0.source.caseInsensitiveCompare(src) == .orderedSame }) {
            return "该英文词汇已在术语表中（同一原文映射到不同译文会降低一致性）。"
        }
        if !dst.isEmpty, let existing = terms.first(where: { $0.target == dst }) {
            return "译文「\(dst)」已被「\(existing.source)」使用，请确认是否要与现有术语区分。"
        }
        return nil
    }

    func remove(_ term: GlossaryTerm) {
        terms.removeAll { $0.id == term.id }
        save()
    }

    func clear() {
        terms.removeAll()
        save()
    }

    // MARK: 导入

    /// 从 Markdown 表格词库（`| 英文 | 中文 | 注释 |`）导入术语，返回导入条数。
    func importFromMarkdown(url: URL) -> Int {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        let rows = Self.parseMarkdownTable(content)
        var added = 0
        for row in rows {
            guard !terms.contains(where: { $0.source.caseInsensitiveCompare(row.source) == .orderedSame }) else { continue }
            terms.append(GlossaryTerm(source: row.source, target: row.target, note: row.note))
            added += 1
        }
        save()
        return added
    }

    /// 解析 Markdown 表格前两列（英文 / 中文）及第三列注释（可选），跳过表头与分隔行。
    static func parseMarkdownTable(_ content: String) -> [(source: String, target: String, note: String)] {
        var result: [(source: String, target: String, note: String)] = []
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|") else { continue }
            // 跳过表头与分隔行（第二列包含"中文"字样，或整行是 - 分隔符）。
            if trimmed.contains("---") { continue }
            let cells = trimmed.split(separator: "|", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard cells.count >= 3 else { continue }
            let source = cells[1]
            let target = cells[2]
            guard !source.isEmpty, !target.isEmpty else { continue }
            if source == "英文" || target == "中文" { continue }
            let note = cells.count >= 4 ? cells[3] : ""
            result.append((source, target, note))
        }
        return result
    }

    // MARK: 持久化

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([GlossaryTerm].self, from: data) else { return }
        terms = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(terms) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

/// DeepSeek 审阅服务：对课堂翻译记录进行审阅改进，并生成美观的格式化 HTML 文档。
/// 文档包含总结、关键要点、主题分布图表、翻译改进对照与旁批、词汇表、完整记录。
/// 保存位置：桌面/课程记录/课程开始时间 课堂记录.html
enum DeepSeekReviewService {

    // MARK: - 常量

    private static let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!
    private static let model = "deepseek-v4-flash"
    private static let apiKeyDefaultsKey = "deepseek_api_key"
    /// 单次提交给 DeepSeek 的最大记录条数（超出时取最新内容）。
    private static let maxSubmittedEntries = 800

    static var savedAPIKey: String {
        get { UserDefaults.standard.string(forKey: apiKeyDefaultsKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: apiKeyDefaultsKey) }
    }

    // MARK: - 数据结构

    /// DeepSeek 返回的审阅结果。
    struct ReviewResult: Codable {
        var title: String = "课堂记录"
        var summary: String = ""
        var improvedEntries: [ImprovedEntry] = []
        var keyPoints: [String] = []
        var vocabulary: [VocabularyItem] = []
        var topics: [TopicCount] = []

        struct ImprovedEntry: Codable {
            var source: String = ""
            var translated: String = ""
            var improved: String = ""
            var note: String = ""
        }

        struct VocabularyItem: Codable {
            var word: String = ""
            var meaning: String = ""
            var example: String = ""
        }

        struct TopicCount: Codable {
            var name: String = ""
            var count: Int = 0
        }
    }

    // MARK: - 调用 DeepSeek

    /// 调用 DeepSeek 对课程翻译记录进行审阅，返回结构化结果。
    static func review(entries: [TranslationEntry], apiKey: String) async throws -> ReviewResult {
        let systemPrompt = """
        你是一位资深的学术课堂记录审阅助手，精通英语与中文。
        用户的输入是一节课的实时翻译记录：每行格式为 [序号] 英文原文 || 中文译文。
        请完成以下任务：
        1. 总结：概括本节课的核心主题与内容要点（80-150 字，中文）。
        2. 审阅改进：找出明显翻译错误或生硬、不准确的条目，给出改进译文；仅列出需要改进的条目，最多 30 条。
        3. 旁批：为每个改进条目附加一条帮助理解的注释（术语解释、背景知识或易错点，20 字左右）。
        4. 关键要点：提炼 5-10 条本节课最重要的知识要点。
        5. 词汇表：提取 5-12 个重点词汇（专业术语或高频词），给出词义与中文例句。
        6. 主题统计：将全部记录按内容主题归类，返回主题名称与覆盖条目数量（用于绘制图表，4-8 个主题）。
        必须严格输出如下 JSON（不要输出任何其他文字，不要使用 markdown 代码块标记）：
        {"title":"本节课标题","summary":"总结","improvedEntries":[{"source":"英文原文","translated":"原译文","improved":"改进译文","note":"旁批"}],"keyPoints":["要点1"],"vocabulary":[{"word":"单词","meaning":"词义","example":"例句"}],"topics":[{"name":"主题","count":数字}]}
        """

        let prompt = buildPrompt(entries: entries)
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": prompt],
            ],
            "temperature": 0.3,
            "response_format": ["type": "json_object"],
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "DeepSeek", code: -1, userInfo: [NSLocalizedDescriptionKey: "网络请求失败"])
        }
        guard http.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "DeepSeek",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "DeepSeek API 错误（\(http.statusCode)）：\(message.prefix(200))"]
            )
        }

        let apiResponse = try JSONDecoder().decode(APIResponse.self, from: data)
        guard let content = apiResponse.choices.first?.message.content,
              let resultData = content.data(using: .utf8) else {
            throw NSError(domain: "DeepSeek", code: -2, userInfo: [NSLocalizedDescriptionKey: "未收到有效审阅结果"])
        }
        return try JSONDecoder().decode(ReviewResult.self, from: resultData)
    }

    private struct APIResponse: Codable {
        let choices: [Choice]
        struct Choice: Codable {
            let message: Message
            struct Message: Codable {
                let content: String
            }
        }
    }

    // MARK: - 要点提炼（实时摘要 / 课后快速要点）

    /// 摘要响应结构。
    private struct SummaryResponse: Codable {
        let points: [String]
    }

    /// 把翻译记录提炼为关键知识要点（用于每 10 分钟增量摘要或课后快速要点）。
    static func summarize(entries: [TranslationEntry], apiKey: String) async throws -> [String] {
        guard !apiKey.isEmpty else {
            throw NSError(domain: "DeepSeekReview", code: -1, userInfo: [NSLocalizedDescriptionKey: "未配置 API Key"])
        }
        let systemPrompt = """
        你是一位课堂笔记助手。用户会提供一节课堂的实时翻译记录（每行：[序号] 英文原文 || 中文译文）。
        请用简体中文提炼 5-8 条关键知识要点：每条 20-40 字，准确概括内容，适合直接用于复习，不要写序号。
        严格只输出 JSON，格式：{"points":["要点1","要点2",...]}，不要输出任何其他文字或 markdown 标记。
        """
        let limited = entries.suffix(maxSubmittedEntries)
        let lines = limited.enumerated().map { index, entry in
            "[\(index + 1)] \(entry.source) || \(entry.target)"
        }.joined(separator: "\n")
        let userPrompt = "课堂翻译记录（共 \(entries.count) 条，以下为全部或最新 \(limited.count) 条）：\n\(lines)"

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt],
            ],
            "temperature": 0.4,
            "response_format": ["type": "json_object"],
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "DeepSeekReview", code: -2, userInfo: [NSLocalizedDescriptionKey: "网络请求失败"])
        }
        guard http.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "DeepSeekReview",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "DeepSeek 摘要 API 错误（\(http.statusCode)）：\(message.prefix(160))"]
            )
        }
        let apiResponse = try JSONDecoder().decode(APIResponse.self, from: data)
        guard let content = apiResponse.choices.first?.message.content,
              let resultData = content.data(using: .utf8) else {
            throw NSError(domain: "DeepSeekReview", code: -3, userInfo: [NSLocalizedDescriptionKey: "未收到有效摘要结果"])
        }
        let parsed = try JSONDecoder().decode(SummaryResponse.self, from: resultData)
        return parsed.points
    }

    private static func buildPrompt(entries: [TranslationEntry]) -> String {
        let limited = entries.suffix(maxSubmittedEntries)
        let lines = limited.enumerated().map { index, entry in
            "[\(index + 1)] \(entry.source) || \(entry.target)"
        }.joined(separator: "\n")
        return "课程翻译记录（共 \(entries.count) 条，以下为全部或最新 \(limited.count) 条）：\n\(lines)"
    }

    // MARK: - 生成并保存文档

    /// 根据审阅结果生成 HTML 文档并保存到「桌面/课程记录」，返回文件地址。
    @discardableResult
    static func saveDocument(course: CourseSession, result: ReviewResult) throws -> URL {
        let fileManager = FileManager.default
        guard let desktop = fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "DeepSeek", code: -3, userInfo: [NSLocalizedDescriptionKey: "无法访问桌面目录"])
        }
        let folder = desktop.appendingPathComponent("课程记录", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        let nameFormatter = DateFormatter()
        nameFormatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let fileName = "\(nameFormatter.string(from: course.startDate)) 课堂记录.html"
        let url = folder.appendingPathComponent(fileName)

        let html = buildHTML(course: course, result: result)
        try html.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - HTML 生成

    private static func buildHTML(course: CourseSession, result: ReviewResult) -> String {
        let hero = heroSection(course: course, result: result)
        let summary = card("课程总结", number: 1, content: summaryHTML(result.summary))
        let keyPoints = card("关键要点", number: 2, content: keyPointsHTML(result.keyPoints))
        let topics = result.topics.isEmpty ? "" : card("主题分布图表", number: 3, content: topicsChartHTML(result.topics))
        let review = card("翻译审阅与旁批", number: 4, content: reviewTableHTML(result.improvedEntries))
        let vocab = result.vocabulary.isEmpty ? "" : card("重点词汇", number: 5, content: vocabularyHTML(result.vocabulary))
        let full = card("完整课堂记录", number: 6, content: fullEntriesHTML(course.entries))

        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>\(escapeHTML(result.title.isEmpty ? "课堂记录" : result.title))</title>
        <style>
        *{box-sizing:border-box;}
        body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Hiragino Sans GB","Segoe UI",sans-serif;background:#f6f7fb;color:#1f2937;line-height:1.6;}
        .page{max-width:920px;margin:0 auto;padding:36px 24px 64px;}
        .hero{background:linear-gradient(135deg,#ff7a18,#f43f5e 55%,#8b5cf6);color:#fff;border-radius:18px;padding:30px 34px;box-shadow:0 14px 34px rgba(244,63,94,.25);}
        .hero h1{margin:0 0 10px;font-size:27px;letter-spacing:.5px;}
        .hero .meta{opacity:.95;font-size:13.5px;}
        .badge{display:inline-block;background:rgba(255,255,255,.2);border:1px solid rgba(255,255,255,.35);border-radius:999px;padding:2px 11px;font-size:12px;margin:3px 6px 0 0;}
        .card{background:#fff;border:1px solid #e5e7eb;border-radius:14px;padding:22px 24px;margin-top:22px;box-shadow:0 2px 10px rgba(15,23,42,.05);}
        .card h2{margin:0 0 14px;font-size:17px;display:flex;align-items:center;gap:9px;}
        .card h2 .num{background:#fff7ed;color:#ea580c;border:1px solid #fed7aa;border-radius:8px;font-size:12px;padding:2px 9px;}
        .summary{font-size:15px;}
        ul.key{list-style:none;padding:0;margin:0;}
        ul.key li{padding:9px 14px;border-left:3px solid #f97316;background:#fffaf5;border-radius:0 8px 8px 0;margin-bottom:8px;font-size:14px;}
        table{width:100%;border-collapse:collapse;font-size:13px;}
        th,td{border:1px solid #e5e7eb;padding:9px 11px;text-align:left;vertical-align:top;}
        th{background:#f9fafb;font-weight:600;white-space:nowrap;}
        tbody tr:nth-child(even) td{background:#fcfcfd;}
        .src{color:#6b7280;}
        .improved{color:#059669;font-weight:600;}
        .note{color:#0891b2;font-size:12px;}
        .empty{color:#9ca3af;font-style:italic;font-size:14px;}
        .bar-row{display:flex;align-items:center;gap:10px;margin-bottom:9px;}
        .bar-label{width:130px;font-size:13px;flex-shrink:0;text-align:right;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
        .bar-track{flex:1;background:#eef0f4;border-radius:999px;height:20px;overflow:hidden;}
        .bar-fill{height:100%;border-radius:999px;background:linear-gradient(90deg,#fb923c,#f43f5e);min-width:6px;}
        .bar-count{width:56px;font-size:12px;color:#6b7280;}
        .vocab{display:grid;grid-template-columns:1fr 1fr;gap:12px;}
        .vocab-item{border:1px solid #e5e7eb;border-radius:10px;padding:13px 15px;background:#fbfcfe;}
        .vocab-item .w{font-weight:700;color:#ea580c;font-size:15px;}
        .vocab-item .m{font-size:13px;margin-top:4px;}
        .vocab-item .e{font-size:12px;color:#6b7280;font-style:italic;margin-top:6px;}
        details{margin-top:6px;}
        summary{cursor:pointer;font-weight:600;color:#f97316;font-size:14px;user-select:none;}
        .entry{display:flex;gap:12px;padding:9px 0;border-bottom:1px dashed #e5e7eb;font-size:13px;}
        .entry:last-child{border-bottom:none;}
        .entry .time{color:#9ca3af;width:66px;flex-shrink:0;font-variant-numeric:tabular-nums;}
        .entry .body{flex:1;}
        .entry .src{color:#6b7280;}
        .entry .dst{font-weight:500;}
        footer{text-align:center;color:#9ca3af;font-size:12px;margin-top:30px;}
        @media (max-width:640px){.vocab{grid-template-columns:1fr;}}
        </style>
        </head>
        <body>
        <div class="page">
        \(hero)
        \(summary)
        \(keyPoints)
        \(topics)
        \(review)
        \(vocab)
        \(full)
        <footer>由 DeepSeek 审阅生成 · 实时课堂翻译记录</footer>
        </div>
        </body>
        </html>
        """
    }

    private static func heroSection(course: CourseSession, result: ReviewResult) -> String {
        let title = result.title.isEmpty ? "课堂翻译记录" : result.title
        let start = timeString(course.startDate)
        let end = timeString(course.endDate)
        let date = fullDateString(course.startDate)
        return """
        <div class="hero">
        <h1>\(escapeHTML(title))</h1>
        <div class="meta">📅 \(escapeHTML(date)) · 🕐 \(start) ～ \(end)（时长 \(durationString(course.duration))）</div>
        <div>
        <span class="badge">共 \(course.entries.count) 条翻译</span>
        <span class="badge">\(result.improvedEntries.count) 处改进</span>
        <span class="badge">\(result.keyPoints.count) 个要点</span>
        <span class="badge">DeepSeek 审阅</span>
        </div>
        </div>
        """
    }

    private static func card(_ title: String, number: Int, content: String) -> String {
        return """
        <div class="card">
        <h2><span class="num">\(number)</span>\(title)</h2>
        \(content)
        </div>
        """
    }

    private static func summaryHTML(_ summary: String) -> String {
        if summary.isEmpty {
            return "<p class=\"empty\">暂无总结。</p>"
        }
        return "<p class=\"summary\">\(escapeHTML(summary))</p>"
    }

    private static func keyPointsHTML(_ points: [String]) -> String {
        guard !points.isEmpty else { return "<p class=\"empty\">暂无要点。</p>" }
        let items = points.map { "<li>\(escapeHTML($0))</li>" }.joined(separator: "\n")
        return "<ul class=\"key\">\n\(items)\n</ul>"
    }

    private static func topicsChartHTML(_ topics: [ReviewResult.TopicCount]) -> String {
        let maxCount = max(topics.map(\.count).max() ?? 1, 1)
        let rows = topics.map { topic in
            let percent = max(Int(Double(topic.count) / Double(maxCount) * 100), 3)
            return """
            <div class="bar-row">
            <div class="bar-label">\(escapeHTML(topic.name))</div>
            <div class="bar-track"><div class="bar-fill" style="width:\(percent)%"></div></div>
            <div class="bar-count">\(topic.count) 条</div>
            </div>
            """
        }.joined(separator: "\n")
        return rows
    }

    private static func reviewTableHTML(_ entries: [ReviewResult.ImprovedEntry]) -> String {
        guard !entries.isEmpty else { return "<p class=\"empty\">未发现明显翻译问题，本节课译文质量良好。</p>" }
        let rows = entries.enumerated().map { index, entry in
            let note = entry.note.isEmpty ? "" : "<div class=\"note\">💡 \(escapeHTML(entry.note))</div>"
            return """
            <tr>
            <td>\(index + 1)</td>
            <td class="src">\(escapeHTML(entry.source))</td>
            <td>\(escapeHTML(entry.translated))</td>
            <td class="improved">\(escapeHTML(entry.improved))</td>
            <td>\(note.isEmpty ? "" : note)</td>
            </tr>
            """
        }.joined(separator: "\n")
        return """
        <table>
        <thead><tr><th style="width:36px">#</th><th>英文原文</th><th>原译文</th><th>改进译文</th><th>旁批</th></tr></thead>
        <tbody>
        \(rows)
        </tbody>
        </table>
        """
    }

    private static func vocabularyHTML(_ items: [ReviewResult.VocabularyItem]) -> String {
        let cards = items.map { item in
            let example = item.example.isEmpty ? "" : "<div class=\"e\">例：\(escapeHTML(item.example))</div>"
            return """
            <div class="vocab-item">
            <div class="w">\(escapeHTML(item.word))</div>
            <div class="m">\(escapeHTML(item.meaning))</div>
            \(example)
            </div>
            """
        }.joined(separator: "\n")
        return "<div class=\"vocab\">\n\(cards)\n</div>"
    }

    private static func fullEntriesHTML(_ entries: [TranslationEntry]) -> String {
        guard !entries.isEmpty else { return "<p class=\"empty\">本节课没有翻译记录。</p>" }
        let rows = entries.map { entry in
            return """
            <div class="entry">
            <div class="time">\(timeString(entry.timestamp))</div>
            <div class="body">
            <div class="src">\(escapeHTML(entry.source))</div>
            <div class="dst">\(escapeHTML(entry.target))</div>
            </div>
            </div>
            """
        }.joined(separator: "\n")
        return """
        <details>
        <summary>展开 / 收起全部 \(entries.count) 条记录（点击切换）</summary>
        <div style="margin-top:12px">
        \(rows)
        </div>
        </details>
        """
    }

    // MARK: - 工具

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月d日"
        return formatter
    }()

    private static func timeString(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    private static func fullDateString(_ date: Date) -> String {
        fullDateFormatter.string(from: date)
    }

    private static func durationString(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

// MARK: - DeepSeek 在线翻译

/// 基于 DeepSeek 的实时在线翻译服务：质量优于系统离线翻译，且支持术语表强制遵循。
/// 与审阅服务共用同一个 API Key。
enum DeepSeekTranslationService {

    private static let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!
    private static let model = "deepseek-v4-flash"
    /// 单批提交的句子数上限（避免请求体过大、响应超时）。
    private static let maxBatchSize = 20
    private static let requestTimeout: TimeInterval = 45

    /// 在线翻译响应结构。
    private struct TranslationResponse: Codable {
        let translations: [String]
    }

    /// 批量翻译英文句子为中文，严格遵循术语表。
    /// - Parameter courseContext: 可选。传整节课的上下文说明（如"这些句子来自同一节课的连续课堂记录"），
    ///   用于课后重新翻译时提示模型保持术语、人名与前后表达一致，获得比实时逐句翻译更好的质量。
    /// - Parameter recentContext: 可选。传最近若干句的「原文 → 译文」对照，作为滑窗上下文，
    ///   帮助代词、省略句与前文保持一致，提升实时翻译的连贯性。
    /// - Parameter subject: 可选。当前课程科目（如"微积分"），用于提示学科术语偏好。
    static func translate(
        _ sentences: [String],
        glossary: [GlossaryTerm],
        apiKey: String,
        courseContext: String? = nil,
        recentContext: [(source: String, target: String)] = [],
        subject: String = ""
    ) async throws -> [String] {
        guard !sentences.isEmpty else { return [] }
        guard !apiKey.isEmpty else {
            throw NSError(domain: "DeepSeekTranslation", code: -1, userInfo: [NSLocalizedDescriptionKey: "未配置 API Key"])
        }

        var systemPrompt = """
        你是一位专业的中英文实时翻译引擎。将用户提供的英文句子翻译成简体中文。
        要求：忠实原文、通顺自然、符合中文表达习惯，保留专有名词与数字。
        """
        if !glossary.isEmpty {
            let glossaryLines = glossary.map { "\($0.source) → \($0.target)" }.joined(separator: "\n")
            systemPrompt += "\n\n必须遵循以下用户自定义术语表：术语表中出现的英文词汇必须使用指定中文翻译，不得意译或省略：\n\(glossaryLines)"
        }
        if !subject.isEmpty {
            systemPrompt += "\n\n当前课堂科目：\(subject)。翻译时优先使用该学科的常用术语与表达。"
        }
        if !recentContext.isEmpty {
            let contextLines = recentContext
                .map { "原文: \($0.source)\n译文: \($0.target)" }
                .joined(separator: "\n\n")
            systemPrompt += "\n\n以下是最近已经翻译的句子（滑窗上下文），翻译新句子时请保持代词指代、专有名词与表达风格的一致：\n\(contextLines)"
        }
        if let courseContext, !courseContext.isEmpty {
            systemPrompt += "\n\n\(courseContext)"
        }
        systemPrompt += "\n\n严格只输出 JSON，格式：{\"translations\":[\"译文1\",\"译文2\",...]}，译文数量必须与输入句子数量一致，不要输出任何其他文字或 markdown 标记。"

        var results: [String] = []
        for start in stride(from: 0, to: sentences.count, by: maxBatchSize) {
            let batch = Array(sentences[start..<min(start + maxBatchSize, sentences.count)])
            let userPrompt = "待翻译的英文句子：\n" + batch.enumerated()
                .map { "[\($0.offset + 1)] \($0.element)" }
                .joined(separator: "\n")

            let body: [String: Any] = [
                "model": model,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userPrompt],
                ],
                "temperature": 0.3,
                "response_format": ["type": "json_object"],
            ]

            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = requestTimeout
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw NSError(domain: "DeepSeekTranslation", code: -2, userInfo: [NSLocalizedDescriptionKey: "网络请求失败"])
            }
            guard http.statusCode == 200 else {
                let message = String(data: data, encoding: .utf8) ?? ""
                throw NSError(
                    domain: "DeepSeekTranslation",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "DeepSeek 翻译 API 错误（\(http.statusCode)）：\(message.prefix(160))"]
                )
            }

            struct APIResponse: Codable {
                struct Choice: Codable {
                    struct Message: Codable { let content: String }
                    let message: Message
                }
                let choices: [Choice]
            }
            let apiResponse = try JSONDecoder().decode(APIResponse.self, from: data)
            guard let content = apiResponse.choices.first?.message.content,
                  let resultData = content.data(using: .utf8) else {
                throw NSError(domain: "DeepSeekTranslation", code: -3, userInfo: [NSLocalizedDescriptionKey: "未收到有效翻译结果"])
            }
            let parsed = try JSONDecoder().decode(TranslationResponse.self, from: resultData)
            results.append(contentsOf: parsed.translations)
        }

        // 对齐数量：不足补空串，多余截断。
        if results.count < sentences.count {
            results.append(contentsOf: repeatElement("", count: sentences.count - results.count))
        }
        return Array(results.prefix(sentences.count))
    }
}
