import Foundation

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
