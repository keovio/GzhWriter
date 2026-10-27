import Foundation

/// 所有提示词集中在这里，方便以后调。
/// 原则：作者是真人，观点和取舍以作者为准；AI 只起草和提建议，不编造事实。
enum Prompts {
    static let base = """
    你是一位资深的微信公众号编辑，正在协助一位真人作者写作。
    规则：
    1. 作者的观点、经历和取舍优先，你负责把它们写清楚、写好读，不替作者编造经历。
    2. 不编造数据、案例、引用、政策条文；需要具体数字或出处时，写成【待核实：说明】占位，让作者自己补。
    3. 语言自然口语化，少用"首先/其次/综上所述/在当今社会"这类套话，不用 emoji 堆砌。
    4. 去 AI 味：不用「最」「第一」「唯一」「稳赚」「包过」等绝对化和承诺性用语，不写「点赞、在看、转发」之类的诱导语；不用「不是……而是……」「值得一提的是」「总而言之」「让我们」「赋能」「抓手」这类句式和黑话；不用破折号；结尾不拔高、不喊口号；多用具体场景和短句。
    5. 严格按要求的格式输出，不要多余解释。
    """

    static func profile(_ s: StylePreset?) -> String {
        guard let s else { return "" }
        var t = ""
        if !s.track.isEmpty { t += "公众号赛道：\(s.track)\n" }
        if !s.audience.isEmpty { t += "读者：\(s.audience)\n" }
        if !s.avoid.isEmpty { t += "不写的话题：\(s.avoid)\n" }
        return t
    }

    /// 自动选题：从方向 / 热榜 / 赛道里挑一个最值得写的，并替作者拟一个立场
    static func pickTopic(direction: String, style: StylePreset?, hot: [String], existing: [String], avoidSimilar: [String] = [], ref: Breakdown? = nil) -> [ChatMessage] {
        [.system(base), .user("""
        \(profile(style))
        \(direction.isEmpty ? "作者没有指定方向，请按赛道和读者自己挑。" : "作者想写的方向：\(direction)")
        \(hot.isEmpty ? "" : "今日热榜和同领域公众号热文（可以借势，但只选和赛道相关、能写出干货的，不要硬蹭；热文只借选题方向，换自己的角度，不能照搬标题）：\n" + hot.prefix(60).joined(separator: "\n"))
        \(existing.isEmpty ? "" : "已经写过的选题（不要重复，也不要换个说法写同一件事）：" + existing.prefix(80).joined(separator: "；"))
        \(avoidSimilar.isEmpty ? "" : "你刚才挑的「" + avoidSimilar.joined(separator: "」「") + "」和写过的太像了，这次换一个不同的点。")
        \(ref.map { "这篇要套用一篇爆文的写法，挑一个适合这种写法的选题。这种写法适合：" + $0.fitTopics.joined(separator: "、") } ?? "")

        挑 1 个最值得写的选题，给出切入角度，并写一段这篇文章要表达的核心观点（3 到 5 句，立场鲜明、具体，像作者本人会说的话）。
        只输出 JSON：{"topic":"选题","angle":"切入角度","viewpoint":"核心观点"}
        """)]
    }

    static func materialsBlock(_ mats: [Material]) -> String {
        if mats.isEmpty { return "" }
        var t = "作者自己的真实素材（来自作者本人）。适合这部分的就自然用上，可以换说法但不改事实；不合适就不用；不要另外编造作者的经历：\n"
        for m in mats { t += "· [\(m.kind)] \(m.text.prefix(400))\n" }
        return t
    }

    static func kindBlock(_ a: Article) -> String {
        let k = ArticleKind.of(a.kind)
        if k != .auto { return "文章类型：\(k.name)。\(k.outlineRule)" }
        let list = ArticleKind.allCases.filter { $0 != .auto }
            .map { "· \($0.rawValue)（\($0.name)）：\($0.outlineRule)" }.joined(separator: "\n")
        return "先按选题和作者观点，从下面的文章类型里挑最合适的一种，按它的结构出大纲（作者没给真实经历时不要选 review）：\n\(list)"
    }

    static func styleBlock(_ s: StylePreset?) -> String {
        guard let s else { return "" }
        var out = ""
        let guide = s.guide.trimmingCharacters(in: .whitespacesAndNewlines)
        if !guide.isEmpty { out += "\n【这个号的写作风格说明，严格按它写】\n\(guide)\n" }
        let sample = s.sample.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sample.isEmpty {
            out += "\n【作者范文，模仿它的口吻、句子长短和用词习惯，不要照抄内容】\n\(sample.prefix(guide.isEmpty ? 3000 : 1500))\n"
        }
        return out
    }

    /// 分析范文，结合赛道和读者，总结成可执行的风格说明
    static func analyzeStyle(_ s: StylePreset) -> [ChatMessage] {
        [.system("你是资深新媒体主编，擅长把一个号的文风拆成写手能照着执行的规则。说具体的、可模仿的做法，不说空话。"), .user("""
        赛道：\(s.track.isEmpty ? "（没填，从范文判断）" : s.track)
        读者：\(s.audience.isEmpty ? "（没填，从范文判断）" : s.audience)
        不写的话题：\(s.avoid.isEmpty ? "无" : s.avoid)

        范文：
        \(s.sample.prefix(9000))

        分析范文的写法，结合赛道和读者，总结这个号的风格。每一项写一两句具体做法，能举例就从范文里摘短句举例。
        只输出 JSON：
        {"summary":"一句话概括这个号的风格和人设",
         "persona":"作者以什么身份、什么姿态跟读者说话",
         "tone":"语气和情绪",
         "structure":"文章常用结构：怎么开头、怎么展开、怎么收尾",
         "sentences":"句子长短、段落长短、节奏",
         "wording":"常用词、口头禅、称呼读者的方式、标点习惯",
         "titles":"标题的写法和套路",
         "dos":["要这样写，3到5条"],
         "donts":["别这样写，3到5条"],
         "topics":["适合这个号写的选题方向，3到5个"]}
        """)]
    }

    static func ideas(direction: String, avoid: String, existing: [String]) -> [ChatMessage] {
        let ex = existing.prefix(40).joined(separator: "；")
        return [.system(base), .user("""
        作者想写的方向：\(direction)
        \(avoid.isEmpty ? "" : "作者不写的话题：\(avoid)")
        \(ex.isEmpty ? "" : "已经写过或记下的选题（避免重复）：\(ex)")

        请给出 10 个具体的选题角度，每个要有明确的切入点和读者获得感，标题不要标题党。
        只输出 JSON：{"ideas":[{"title":"选题标题","angle":"一句话说明切入角度和为什么值得写"}]}
        """)]
    }

    static func outline(_ a: Article, style: StylePreset?, ref: Breakdown? = nil, mats: [Material] = []) -> [ChatMessage] {
        [.system(base), .user("""
        选题：\(a.topic)
        作者的观点 / 想说的话：\(a.viewpoint)
        \(a.material.isEmpty ? "" : "参考素材（只作参考，不要改写搬运）：\n\(a.material.prefix(5000))")
        \(profile(style))

        \(kindBlock(a))
        \(ref.map { $0.guide + "大纲结构尽量贴近上面的参考结构。" } ?? "")
        \(materialsBlock(mats))
        围绕作者的观点出一份公众号文章大纲，每部分一行，格式「小标题：这部分要讲的要点」。
        再给一个不标题党的文章标题。
        只输出 JSON：{"title":"文章标题","kind":"\(ArticleKind.of(a.kind) == .auto ? "所选类型英文代号" : a.kind)","outline":["小标题：要点", "..."]}
        """)]
    }

    static func section(_ a: Article, index: Int, style: StylePreset?, words: Int = 400, ref: Breakdown? = nil, mats: [Material] = []) -> [ChatMessage] {
        // 大纲被单独删过行时和正文节数对不上，以正文各节小标题为准，避免下标越界闪退
        let plan = (a.outline.count == a.sections.count || a.sections.isEmpty) ? a.outline : a.sections.map(\.heading)
        let all = plan.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let cur = index >= 0 && index < plan.count ? plan[index] : ""
        let done = a.sections.prefix(index).map { "· \($0.heading)：\($0.body.prefix(80))…" }.joined(separator: "\n")
        return [.system(base + styleBlock(style)), .user("""
        文章标题：\(a.title)
        作者的观点：\(a.viewpoint)
        \(a.material.isEmpty ? "" : "参考素材（只作参考）：\n\(a.material.prefix(3000))")

        完整大纲：
        \(all)

        \(done.isEmpty ? "" : "前面已经写好的部分（保持衔接，不要重复）：\n\(done)\n")
        \(materialsBlock(mats))
        现在只写第 \(index + 1) 部分：\(cur)
        \(ArticleKind.of(a.kind).writeRule)
        \(ref.map { $0.guide + (index == 0 ? "这是第一部分，用上面的开头手法。" : (index == plan.count - 1 ? "这是最后一部分，用上面的结尾手法。" : "")) } ?? "")

        要求：\(max(200, words - 80)) 到 \(words + 120) 字；段落之间空一行；每段不超过 4 行；可以用 **加粗** 标出一两句关键句，可以用「> 」开头写一句引用。
        不要写小标题，只输出这部分的正文。
        """)]
    }

    enum Op: String, CaseIterable, Identifiable {
        case rewrite = "重写", expand = "扩写", shrink = "精简", plain = "更口语"
        var id: String { rawValue }
        var instruction: String {
            switch self {
            case .rewrite: return "换一种写法重写，意思不变，更好读。"
            case .expand: return "在不编造事实的前提下扩写到原来的 1.5 倍左右，补充解释或作者视角的细节。"
            case .shrink: return "精简到原来的 60% 左右，保留关键信息。"
            case .plain: return "改得更口语、更像一个人在聊天，去掉书面套话。"
            }
        }
    }

    static func revise(_ a: Article, index: Int, instruction: String, style: StylePreset?) -> [ChatMessage] {
        let sec = a.sections[index]
        return [.system(base + styleBlock(style)), .user("""
        文章标题：\(a.title)
        这部分的小标题：\(sec.heading)
        这部分原文：
        \(sec.body)

        修改要求：\(instruction)
        格式同原文（段落之间空一行，可用 **加粗** 和「> 」引用）。只输出改好的这部分正文，不要小标题。
        """)]
    }

    static func review(_ a: Article) -> [ChatMessage] {
        [.system(base), .user("""
        请审阅下面这篇公众号文章，像一位严格但友善的主编。

        \(a.plainText.prefix(12000))

        按五个维度打分（0-100）：标题、可读性、实用性、合规、人味（是否像真人在表达观点，而不是 AI 套话）。
        合规要看：夸大承诺、绝对化用语、医疗/金融等敏感建议、未核实的数据、诱导关注分享。
        给出最多 8 条具体修改建议，每条注明是第几部分（全文性问题 section 填 null），说清问题和改法。
        列出文中需要作者核实的事实、数字、引用、政策。
        再给 3 个备选标题。
        total 是 0-100 的总分（五项的平均分），不是五项相加。
        只输出 JSON：
        {"scores":{"标题":0,"可读性":0,"实用性":0,"合规":0,"人味":0},"total":0,"summary":"一句话总评",
         "suggestions":[{"section":1,"issue":"问题","fix":"改法"}],
         "factChecks":["需要核实的内容"],"titles":["备选标题1","备选标题2","备选标题3"]}
        """)]
    }
}

struct IdeasReply: Decodable { let ideas: [IdeaItem]; struct IdeaItem: Decodable { let title: String; let angle: String? } }
struct TopicReply: Decodable { let topic: String; let angle: String?; let viewpoint: String? }
struct OutlineReply: Decodable { let title: String?; let kind: String?; let outline: [String] }
