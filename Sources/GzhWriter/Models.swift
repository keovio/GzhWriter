import Foundation

/// 写作流程的五个阶段。每一步都由作者确认后才进入下一步。
enum Stage: Int, Codable, CaseIterable, Identifiable {
    case topic, outline, draft, review, layout
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .topic: return "① 选题"
        case .outline: return "② 大纲"
        case .draft: return "③ 正文"
        case .review: return "④ 审稿"
        case .layout: return "⑤ 排版"
        }
    }
}

/// 正文的一节：一个小标题 + 若干段落（段落之间空一行，支持 **加粗** 和 > 引用）
struct ArticleSection: Identifiable, Codable, Hashable {
    var id = UUID()
    var heading: String
    var body: String
}

/// 审稿给出的一条建议。只有作者点「采纳」才会改稿。
struct Suggestion: Identifiable, Codable, Hashable {
    var id = UUID()
    var section: Int?       // 对应第几节（从 1 开始），nil 表示全文
    var issue: String
    var fix: String
    var applied = false

    enum CodingKeys: String, CodingKey { case section, issue, fix, applied }
    init(section: Int?, issue: String, fix: String) {
        self.section = section; self.issue = issue; self.fix = fix
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        section = try? c.decodeIfPresent(Int.self, forKey: .section)
        issue = (try? c.decodeIfPresent(String.self, forKey: .issue)) ?? ""
        fix = (try? c.decodeIfPresent(String.self, forKey: .fix)) ?? ""
        applied = (try? c.decodeIfPresent(Bool.self, forKey: .applied)) ?? false
    }
}

struct ReviewResult: Codable, Hashable {
    var scores: [String: Int] = [:]
    var total: Int = 0
    var summary: String = ""
    var suggestions: [Suggestion] = []
    var factChecks: [String] = []
    var titles: [String] = []

    enum CodingKeys: String, CodingKey { case scores, total, summary, suggestions, factChecks, titles }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scores = (try? c.decodeIfPresent([String: Int].self, forKey: .scores)) ?? [:]
        total = (try? c.decodeIfPresent(Int.self, forKey: .total)) ?? 0
        summary = (try? c.decodeIfPresent(String.self, forKey: .summary)) ?? ""
        suggestions = (try? c.decodeIfPresent([Suggestion].self, forKey: .suggestions)) ?? []
        factChecks = (try? c.decodeIfPresent([String].self, forKey: .factChecks)) ?? []
        titles = (try? c.decodeIfPresent([String].self, forKey: .titles)) ?? []
    }
}

struct Article: Identifiable, Codable, Hashable {
    var id = UUID()
    var title = ""
    var topic = ""
    var viewpoint = ""          // 作者自己的观点 / 想说的话（必填，保证是真人表达）
    var material = ""           // 参考素材，只作参考
    var styleId: UUID?
    var outline: [String] = []
    var sections: [ArticleSection] = []
    var review: ReviewResult?
    var stage: Stage = .topic
    var template = "magazine"
    var accent = "#3F68A8"
    var fontSize = 16
    var aiNotice = true
    var created = Date()
    var updated = Date()

    enum CodingKeys: String, CodingKey {
        case id, title, topic, viewpoint, material, styleId, outline, sections, review, stage,
             template, accent, fontSize, aiNotice, created, updated
    }
    init() {}
    // 宽松解码：以后加字段不会让旧数据读不出来
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Article()
        id = (try? c.decode(UUID.self, forKey: .id)) ?? d.id
        title = (try? c.decode(String.self, forKey: .title)) ?? d.title
        topic = (try? c.decode(String.self, forKey: .topic)) ?? d.topic
        viewpoint = (try? c.decode(String.self, forKey: .viewpoint)) ?? d.viewpoint
        material = (try? c.decode(String.self, forKey: .material)) ?? d.material
        styleId = try? c.decodeIfPresent(UUID.self, forKey: .styleId)
        outline = (try? c.decode([String].self, forKey: .outline)) ?? d.outline
        sections = (try? c.decode([ArticleSection].self, forKey: .sections)) ?? d.sections
        review = try? c.decodeIfPresent(ReviewResult.self, forKey: .review)
        stage = (try? c.decode(Stage.self, forKey: .stage)) ?? d.stage
        template = (try? c.decode(String.self, forKey: .template)) ?? d.template
        accent = (try? c.decode(String.self, forKey: .accent)) ?? d.accent
        fontSize = (try? c.decode(Int.self, forKey: .fontSize)) ?? d.fontSize
        aiNotice = (try? c.decode(Bool.self, forKey: .aiNotice)) ?? d.aiNotice
        created = (try? c.decode(Date.self, forKey: .created)) ?? d.created
        updated = (try? c.decode(Date.self, forKey: .updated)) ?? d.updated
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if !topic.isEmpty { return topic }
        return "未命名稿件"
    }

    /// 纯文本全文（审稿、字数统计用）
    var plainText: String {
        var s = title.isEmpty ? "" : "# \(title)\n\n"
        for (i, sec) in sections.enumerated() {
            s += "## \(i + 1). \(sec.heading)\n\n\(sec.body)\n\n"
        }
        return s
    }

    var wordCount: Int {
        sections.reduce(0) { $0 + $1.body.filter { !$0.isWhitespace }.count }
    }
}

struct TopicIdea: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var angle: String = ""
    var created = Date()
    var used = false
}

/// 口吻：一篇或几篇作者自己的范文 + 不写的话题
struct StylePreset: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var sample: String = ""
    var avoid: String = ""
}

/// 一个 OpenAI 兼容的模型连接。API Key 存在钥匙串里，不进数据文件。
struct ModelConnection: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var baseURL: String
    var model: String
}

enum Role: String, Codable, CaseIterable, Identifiable {
    case topic, draft, review
    var id: String { rawValue }
    var title: String {
        switch self {
        case .topic: return "选题与大纲"
        case .draft: return "写正文"
        case .review: return "审稿"
        }
    }
}

struct AppData: Codable {
    var articles: [Article] = []
    var ideas: [TopicIdea] = []
    var styles: [StylePreset] = []
    var connections: [ModelConnection] = []
    /// 每个角色按顺序尝试的连接；前一个失败自动换下一个
    var roles: [String: [UUID]] = [:]

    enum CodingKeys: String, CodingKey { case articles, ideas, styles, connections, roles }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        articles = (try? c.decode([Article].self, forKey: .articles)) ?? []
        ideas = (try? c.decode([TopicIdea].self, forKey: .ideas)) ?? []
        styles = (try? c.decode([StylePreset].self, forKey: .styles)) ?? []
        connections = (try? c.decode([ModelConnection].self, forKey: .connections)) ?? []
        roles = (try? c.decode([String: [UUID]].self, forKey: .roles)) ?? [:]
    }
}

/// 常用模型服务的预设（都兼容 OpenAI 的 /chat/completions 接口）
struct ProviderPreset: Identifiable {
    let id: String
    let name: String
    let baseURL: String
    let model: String
    static let all: [ProviderPreset] = [
        .init(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com", model: "deepseek-chat"),
        .init(id: "glm", name: "智谱 GLM", baseURL: "https://open.bigmodel.cn/api/paas/v4", model: "glm-4-plus"),
        .init(id: "kimi", name: "Kimi", baseURL: "https://api.moonshot.cn/v1", model: "kimi-latest"),
        .init(id: "qwen", name: "通义千问", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-plus"),
        .init(id: "doubao", name: "豆包（火山方舟）", baseURL: "https://ark.cn-beijing.volces.com/api/v3", model: ""),
        .init(id: "custom", name: "自定义 / 中转站", baseURL: "https://", model: ""),
    ]
}
