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
    var image = ""              // 配图的本地文件名（在稿件图片目录里）

    enum CodingKeys: String, CodingKey { case id, heading, body, image }
    init(id: UUID = UUID(), heading: String, body: String, image: String = "") {
        self.id = id; self.heading = heading; self.body = body; self.image = image
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        heading = (try? c.decode(String.self, forKey: .heading)) ?? ""
        body = (try? c.decode(String.self, forKey: .body)) ?? ""
        image = (try? c.decode(String.self, forKey: .image)) ?? ""
    }
}

/// 其他平台的版本。长文平台（头条/百家/知乎）只改标题、开头和标签，正文沿用主稿；
/// 短内容平台（小红书/微博）整篇重写在 body 里。
struct PlatformVariant: Codable, Hashable {
    var title = ""
    var intro = ""              // 改写过的开头一段
    var tags: [String] = []
    var body = ""               // 整篇重写的正文（小红书、微博）
    var posted = false          // 作者点了「我发了」
    var postedAt: Date?

    enum CodingKeys: String, CodingKey { case title, intro, tags, body, posted, postedAt }
    init(title: String = "", intro: String = "", tags: [String] = [], body: String = "") {
        self.title = title; self.intro = intro; self.tags = tags; self.body = body
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        intro = (try? c.decode(String.self, forKey: .intro)) ?? ""
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
        body = (try? c.decode(String.self, forKey: .body)) ?? ""
        posted = (try? c.decode(Bool.self, forKey: .posted)) ?? false
        postedAt = try? c.decodeIfPresent(Date.self, forKey: .postedAt)
    }
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
    var kind = "auto"           // 文章类型，见 ArticleKind
    var auto = false            // 一键成稿生成的
    var log: [String] = []      // 自动流程的运行记录
    var wechatDraft = ""        // 推到公众号草稿箱后的 media_id
    var cover = ""              // 封面图文件名
    var digest = ""             // 摘要
    var variants: [String: PlatformVariant] = [:]   // key 是 Platform.rawValue
    var titleOptions: [TitleOption] = []            // 标题多选
    var refId: UUID?                                // 参考的爆文拆解
    var materialIds: [UUID] = []                    // 用上的素材
    var scheduled: Date?                            // 计划发布时间
    var reminded = false
    var published = false
    var failed = ""             // 自动流程停在哪一步出错（空=没出错），可以从断点继续
    var accountId: UUID?        // 写给哪个账号
    var primary = "wechat"      // 主平台：wechat=公众号长文；xiaohongshu/weibo=直接写的短内容，正文在 variants[primary]
    var created = Date()
    var updated = Date()

    enum CodingKeys: String, CodingKey {
        case id, title, topic, viewpoint, material, styleId, outline, sections, review, stage,
             template, accent, fontSize, aiNotice, auto, log, kind, wechatDraft, cover, digest, variants, titleOptions, refId, materialIds, scheduled, reminded, published, failed, primary, accountId, created, updated
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
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "auto"
        auto = (try? c.decode(Bool.self, forKey: .auto)) ?? false
        log = (try? c.decode([String].self, forKey: .log)) ?? []
        wechatDraft = (try? c.decode(String.self, forKey: .wechatDraft)) ?? ""
        cover = (try? c.decode(String.self, forKey: .cover)) ?? ""
        digest = (try? c.decode(String.self, forKey: .digest)) ?? ""
        variants = (try? c.decode([String: PlatformVariant].self, forKey: .variants)) ?? [:]
        titleOptions = (try? c.decode([TitleOption].self, forKey: .titleOptions)) ?? []
        refId = try? c.decodeIfPresent(UUID.self, forKey: .refId)
        materialIds = (try? c.decode([UUID].self, forKey: .materialIds)) ?? []
        scheduled = try? c.decodeIfPresent(Date.self, forKey: .scheduled)
        reminded = (try? c.decode(Bool.self, forKey: .reminded)) ?? false
        published = (try? c.decode(Bool.self, forKey: .published)) ?? false
        failed = (try? c.decode(String.self, forKey: .failed)) ?? ""
        primary = (try? c.decode(String.self, forKey: .primary)) ?? "wechat"
        accountId = try? c.decodeIfPresent(UUID.self, forKey: .accountId)
        created = (try? c.decode(Date.self, forKey: .created)) ?? d.created
        updated = (try? c.decode(Date.self, forKey: .updated)) ?? d.updated
    }

    var isShort: Bool { primary == "xiaohongshu" || primary == "weibo" }
    var shortVariant: PlatformVariant? { isShort ? variants[primary] : nil }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if let v = shortVariant {
            if !v.title.isEmpty { return v.title }
            let first = v.body.split(separator: "\n").first.map(String.init) ?? ""
            if !first.isEmpty { return String(first.prefix(24)) }
        }
        if !topic.isEmpty { return topic }
        return "未命名稿件"
    }

    /// 纯文本全文（审稿、字数统计用）
    var plainText: String {
        if let v = shortVariant { return v.title + "\n\n" + v.body }
        var s = title.isEmpty ? "" : "# \(title)\n\n"
        for (i, sec) in sections.enumerated() {
            s += "## \(i + 1). \(sec.heading)\n\n\(sec.body)\n\n"
        }
        return s
    }

    var wordCount: Int {
        if let v = shortVariant { return v.body.filter { !$0.isWhitespace }.count }
        return sections.reduce(0) { $0 + $1.body.filter { !$0.isWhitespace }.count }
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
    var track: String = ""      // 赛道
    var audience: String = ""   // 读者是谁
    var sample: String = ""
    var avoid: String = ""
    var signature: String = ""  // 文末一句话 / 署名
    var author: String = ""     // 作者名（草稿箱里显示）

    enum CodingKeys: String, CodingKey { case id, name, track, audience, sample, avoid, signature, author }
    init(name: String, sample: String = "", avoid: String = "") {
        self.name = name; self.sample = sample; self.avoid = avoid
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "我的号"
        track = (try? c.decode(String.self, forKey: .track)) ?? ""
        audience = (try? c.decode(String.self, forKey: .audience)) ?? ""
        sample = (try? c.decode(String.self, forKey: .sample)) ?? ""
        avoid = (try? c.decode(String.self, forKey: .avoid)) ?? ""
        signature = (try? c.decode(String.self, forKey: .signature)) ?? ""
        author = (try? c.decode(String.self, forKey: .author)) ?? ""
    }
}

/// 自动化设置
struct AutoSettings: Codable, Hashable {
    var passScore = 80          // 审稿及格线
    var maxRounds = 2           // 不及格最多自动返修几轮
    var useHot = true           // 自动选题参考热榜
    var targetWords = 1500
    var dailyEnabled = false    // 每天定时写一篇（只生成草稿，不发布）
    var dailyHour = 8
    var dailyMinute = 0
    var dailyStyleId: UUID?
    var lastDaily: Date?
    var images = true           // 自动配图
    var imageEvery = 2          // 每几节配一张
    var imageStyle = "扁平插画"
    var variants = true         // 自动出头条号、百家号版本
    var autoTitle = true        // 自动出 5 个标题并换上最高分的
    var autoCompliance = true   // 自动改掉敏感词
    var useMaterials = true     // 写稿时自动用上素材库里相关的素材
    var autoSchedule = true     // 写好自动排进发布日历
    var publishDays: [Int] = [2, 4, 6]   // 1=周日 … 7=周六
    var publishHour = 20
    var publishMinute = 0
    var hotCategories: [String] = ["综合"]
    var hotAuto = true
    var hotForTopic = true
    var lastHotFetch: Date?
    var hotSources: [String] = HotSource.all.map(\.key)       // 雷达要看的其他平台热榜
    var platforms: [String] = Platform.allCases.map(\.rawValue) // 我在做的平台

    enum CodingKeys: String, CodingKey { case hotSources, platforms, hotCategories, hotAuto, hotForTopic, lastHotFetch, passScore, maxRounds, useHot, targetWords, dailyEnabled, dailyHour, dailyMinute, dailyStyleId, lastDaily, images, imageEvery, imageStyle, variants, autoTitle, autoCompliance, useMaterials, autoSchedule, publishDays, publishHour, publishMinute }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AutoSettings()
        passScore = (try? c.decode(Int.self, forKey: .passScore)) ?? d.passScore
        maxRounds = (try? c.decode(Int.self, forKey: .maxRounds)) ?? d.maxRounds
        useHot = (try? c.decode(Bool.self, forKey: .useHot)) ?? d.useHot
        targetWords = (try? c.decode(Int.self, forKey: .targetWords)) ?? d.targetWords
        dailyEnabled = (try? c.decode(Bool.self, forKey: .dailyEnabled)) ?? d.dailyEnabled
        dailyHour = (try? c.decode(Int.self, forKey: .dailyHour)) ?? d.dailyHour
        dailyMinute = (try? c.decode(Int.self, forKey: .dailyMinute)) ?? d.dailyMinute
        dailyStyleId = try? c.decodeIfPresent(UUID.self, forKey: .dailyStyleId)
        lastDaily = try? c.decodeIfPresent(Date.self, forKey: .lastDaily)
        images = (try? c.decode(Bool.self, forKey: .images)) ?? d.images
        imageEvery = (try? c.decode(Int.self, forKey: .imageEvery)) ?? d.imageEvery
        imageStyle = (try? c.decode(String.self, forKey: .imageStyle)) ?? d.imageStyle
        variants = (try? c.decode(Bool.self, forKey: .variants)) ?? d.variants
        autoTitle = (try? c.decode(Bool.self, forKey: .autoTitle)) ?? d.autoTitle
        autoCompliance = (try? c.decode(Bool.self, forKey: .autoCompliance)) ?? d.autoCompliance
        useMaterials = (try? c.decode(Bool.self, forKey: .useMaterials)) ?? d.useMaterials
        autoSchedule = (try? c.decode(Bool.self, forKey: .autoSchedule)) ?? d.autoSchedule
        publishDays = (try? c.decode([Int].self, forKey: .publishDays)) ?? d.publishDays
        publishHour = (try? c.decode(Int.self, forKey: .publishHour)) ?? d.publishHour
        publishMinute = (try? c.decode(Int.self, forKey: .publishMinute)) ?? d.publishMinute
        hotCategories = (try? c.decode([String].self, forKey: .hotCategories)) ?? d.hotCategories
        hotAuto = (try? c.decode(Bool.self, forKey: .hotAuto)) ?? d.hotAuto
        hotForTopic = (try? c.decode(Bool.self, forKey: .hotForTopic)) ?? d.hotForTopic
        lastHotFetch = try? c.decodeIfPresent(Date.self, forKey: .lastHotFetch)
        hotSources = (try? c.decode([String].self, forKey: .hotSources)) ?? d.hotSources
        platforms = (try? c.decode([String].self, forKey: .platforms)) ?? d.platforms
    }
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
    /// 哪些功能用这个模型
    var uses: String {
        switch self {
        case .topic: return "选题、大纲、选题库、配图规划"
        case .draft: return "写正文、返修、各平台版本、小红书/微博"
        case .review: return "审稿打分、标题多选、爆文拆解"
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
    var roleModels: [String: String] = [:]      // "角色.连接ID" → 这个角色在这个平台用哪个模型（不填用连接默认模型）
    var auto = AutoSettings()
    var wechat = WechatSettings()
    var breakdowns: [Breakdown] = []
    var materials: [Material] = []
    var accounts: [Account] = []
    var hot: [HotArticle] = []
    var hotNames: [String: String] = [:]

    enum CodingKeys: String, CodingKey { case articles, ideas, styles, connections, roles, auto, wechat, breakdowns, materials, hot, hotNames, accounts, roleModels }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        articles = (try? c.decode([Article].self, forKey: .articles)) ?? []
        ideas = (try? c.decode([TopicIdea].self, forKey: .ideas)) ?? []
        styles = (try? c.decode([StylePreset].self, forKey: .styles)) ?? []
        connections = (try? c.decode([ModelConnection].self, forKey: .connections)) ?? []
        roles = (try? c.decode([String: [UUID]].self, forKey: .roles)) ?? [:]
        roleModels = (try? c.decode([String: String].self, forKey: .roleModels)) ?? [:]
        auto = (try? c.decode(AutoSettings.self, forKey: .auto)) ?? AutoSettings()
        wechat = (try? c.decode(WechatSettings.self, forKey: .wechat)) ?? WechatSettings()
        breakdowns = (try? c.decode([Breakdown].self, forKey: .breakdowns)) ?? []
        materials = (try? c.decode([Material].self, forKey: .materials)) ?? []
        accounts = (try? c.decode([Account].self, forKey: .accounts)) ?? []
        hot = (try? c.decode([HotArticle].self, forKey: .hot)) ?? []
        hotNames = (try? c.decode([String: String].self, forKey: .hotNames)) ?? [:]
    }
}

/// 公众号开发者接口：只用来存草稿箱，不发表
struct WechatSettings: Codable, Hashable {
    var appId = ""
    var autoPush = false        // 一键成稿完成后自动推到草稿箱
    var openComment = true

    enum CodingKeys: String, CodingKey { case appId, autoPush, openComment }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appId = (try? c.decode(String.self, forKey: .appId)) ?? ""
        autoPush = (try? c.decode(Bool.self, forKey: .autoPush)) ?? false
        openComment = (try? c.decode(Bool.self, forKey: .openComment)) ?? true
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


/// 文章类型：决定大纲结构和写法
enum ArticleKind: String, CaseIterable, Identifiable {
    case auto, guide, story, opinion, news, review
    var id: String { rawValue }

    var name: String {
        switch self {
        case .auto: return "自动挑"
        case .guide: return "干货清单"
        case .story: return "故事叙事"
        case .opinion: return "观点评论"
        case .news: return "热点解读"
        case .review: return "经验复盘"
        }
    }

    var hint: String {
        switch self {
        case .auto: return "按选题自动选最合适的类型"
        case .guide: return "小标题分条，每条一个方法，适合「怎么做」"
        case .story: return "不分小标题，按情节写一个人或一件事，结尾点一句感悟"
        case .opinion: return "开头亮观点，中间两三个理由或反驳，结尾回到观点"
        case .news: return "发生了什么、为什么重要、对读者的影响、怎么应对"
        case .review: return "自己做过的一件事：背景、踩的坑、数据、结论"
        }
    }

    /// 大纲怎么出
    var outlineRule: String {
        switch self {
        case .auto: return ""
        case .guide: return "干货清单文：4 到 6 部分，每部分一个具体方法或要点，小标题直接说方法。"
        case .story: return "故事叙事文：4 到 5 个情节段（起因、经过、转折、结果、感悟），小标题只是给作者看的段落提示，不会出现在文中。"
        case .opinion: return "观点评论文：3 到 5 部分，第一部分亮明观点，中间部分是理由或对反方的回应，最后一部分回到观点并给读者建议。"
        case .news: return "热点解读文：4 部分左右，依次是发生了什么、为什么重要、对读者有什么影响、读者该怎么做。"
        case .review: return "经验复盘文：4 到 5 部分，依次是背景和目标、做法、踩过的坑、结果和数据、可以复用的结论。经历和数据只用作者提供的，缺的写【待核实】。"
        }
    }

    /// 正文怎么写
    var writeRule: String {
        switch self {
        case .story: return "这是故事叙事文，用场景、细节和对话推进，和前文自然衔接，不要写成分点说明。"
        case .opinion: return "这是观点评论文，立场鲜明，论证具体，可以正面回应不同意见。"
        case .news: return "这是热点解读文，事实部分克制准确，不确定的写【待核实】，重点讲对读者的影响。"
        case .review: return "这是经验复盘文，用第一人称，具体到做了什么、结果如何。"
        case .guide: return "这是干货清单文，讲清楚方法和步骤，最好带一个具体例子。"
        case .auto: return ""
        }
    }

    /// 是否在成文里显示小标题
    var showsHeadings: Bool { self != .story }

    static func of(_ s: String) -> ArticleKind { ArticleKind(rawValue: s) ?? .auto }
}


/// 标题候选
struct TitleOption: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var style = ""              // 数字型 / 悬念型 …
    var score = 0
    var reason = ""

    enum CodingKeys: String, CodingKey { case title, style, score, reason }
    init(title: String, style: String = "", score: Int = 0, reason: String = "") {
        self.title = title; self.style = style; self.score = score; self.reason = reason
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        style = (try? c.decode(String.self, forKey: .style)) ?? ""
        score = (try? c.decode(Int.self, forKey: .score)) ?? 0
        reason = (try? c.decode(String.self, forKey: .reason)) ?? ""
    }
}

/// 爆文拆解：只提炼写法，不保存原文
struct Breakdown: Identifiable, Codable, Hashable {
    var id = UUID()
    var url = ""
    var sourceTitle = ""
    var titleFormula = ""       // 标题套路
    var hook = ""               // 开头手法
    var structure: [String] = []
    var techniques: [String] = []
    var ending = ""             // 结尾手法
    var fitTopics: [String] = []
    var created = Date()

    enum CodingKeys: String, CodingKey { case id, url, sourceTitle, titleFormula, hook, structure, techniques, ending, fitTopics, created }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        url = (try? c.decode(String.self, forKey: .url)) ?? ""
        sourceTitle = (try? c.decode(String.self, forKey: .sourceTitle)) ?? ""
        titleFormula = (try? c.decode(String.self, forKey: .titleFormula)) ?? ""
        hook = (try? c.decode(String.self, forKey: .hook)) ?? ""
        structure = (try? c.decode([String].self, forKey: .structure)) ?? []
        techniques = (try? c.decode([String].self, forKey: .techniques)) ?? []
        ending = (try? c.decode(String.self, forKey: .ending)) ?? ""
        fitTopics = (try? c.decode([String].self, forKey: .fitTopics)) ?? []
        created = (try? c.decode(Date.self, forKey: .created)) ?? Date()
    }

    /// 给写作提示词用的一段说明
    var guide: String {
        var t = "参考写法（来自一篇爆文的拆解，只学方法，不用它的内容、例子和句子）：\n"
        if !titleFormula.isEmpty { t += "· 标题套路：\(titleFormula)\n" }
        if !hook.isEmpty { t += "· 开头手法：\(hook)\n" }
        if !structure.isEmpty { t += "· 结构：" + structure.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "；") + "\n" }
        if !techniques.isEmpty { t += "· 技巧：" + techniques.joined(separator: "；") + "\n" }
        if !ending.isEmpty { t += "· 结尾手法：\(ending)\n" }
        return t
    }
}


/// 素材库：作者自己的经历、观点、金句、数据、案例
struct Material: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind = "经历"
    var text = ""
    var tags: [String] = []
    var uses = 0
    var created = Date()

    static let kinds = ["经历", "观点", "金句", "数据", "案例"]

    enum CodingKeys: String, CodingKey { case id, kind, text, tags, uses, created }
    init(kind: String = "经历", text: String = "", tags: [String] = []) {
        self.kind = kind; self.text = text; self.tags = tags
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "经历"
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
        uses = (try? c.decode(Int.self, forKey: .uses)) ?? 0
        created = (try? c.decode(Date.self, forKey: .created)) ?? Date()
    }
}


/// 一个账号 = 平台 + 名字 + 用哪套风格。同赛道的号共用一套风格。
struct Account: Identifiable, Codable, Hashable {
    var id = UUID()
    var platform = "wechat"
    var name = ""
    var styleId: UUID?
    var appId = ""              // 只有公众号用：草稿箱接口

    var secretKey: String { "wechat.appsecret." + id.uuidString }
}
