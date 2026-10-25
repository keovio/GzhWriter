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
    4. 严格按要求的格式输出，不要多余解释。
    """

    static func styleBlock(_ s: StylePreset?) -> String {
        guard let s, !s.sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return "\n【作者范文，模仿它的口吻、句子长短和用词习惯，不要照抄内容】\n\(s.sample.prefix(3000))\n"
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

    static func outline(_ a: Article, style: StylePreset?) -> [ChatMessage] {
        [.system(base), .user("""
        选题：\(a.topic)
        作者的观点 / 想说的话：\(a.viewpoint)
        \(a.material.isEmpty ? "" : "参考素材（只作参考，不要改写搬运）：\n\(a.material.prefix(5000))")
        \(style?.avoid.isEmpty == false ? "不写的话题：\(style!.avoid)" : "")

        围绕作者的观点出一份公众号文章大纲：4 到 6 节，每节一行，格式「小标题：这一节要讲的要点」。
        再给一个不标题党的文章标题。
        只输出 JSON：{"title":"文章标题","outline":["小标题：要点", "..."]}
        """)]
    }

    static func section(_ a: Article, index: Int, style: StylePreset?) -> [ChatMessage] {
        let all = a.outline.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let done = a.sections.prefix(index).map { "· \($0.heading)：\($0.body.prefix(80))…" }.joined(separator: "\n")
        return [.system(base + styleBlock(style)), .user("""
        文章标题：\(a.title)
        作者的观点：\(a.viewpoint)
        \(a.material.isEmpty ? "" : "参考素材（只作参考）：\n\(a.material.prefix(3000))")

        完整大纲：
        \(all)

        \(done.isEmpty ? "" : "前面已经写好的部分（保持衔接，不要重复）：\n\(done)\n")
        现在只写第 \(index + 1) 节：\(a.outline[index])

        要求：300 到 500 字；段落之间空一行；每段不超过 4 行；可以用 **加粗** 标出一两句关键句，可以用「> 」开头写一句引用。
        不要写小标题，只输出这一节的正文。
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
        这一节的小标题：\(sec.heading)
        这一节原文：
        \(sec.body)

        修改要求：\(instruction)
        格式同原文（段落之间空一行，可用 **加粗** 和「> 」引用）。只输出改好的这一节正文，不要小标题。
        """)]
    }

    static func review(_ a: Article) -> [ChatMessage] {
        [.system(base), .user("""
        请审阅下面这篇公众号文章，像一位严格但友善的主编。

        \(a.plainText.prefix(12000))

        按五个维度打分（0-100）：标题、可读性、实用性、合规、人味（是否像真人在表达观点，而不是 AI 套话）。
        合规要看：夸大承诺、绝对化用语、医疗/金融等敏感建议、未核实的数据、诱导关注分享。
        给出最多 8 条具体修改建议，每条注明是第几节（全文性问题 section 填 null），说清问题和改法。
        列出文中需要作者核实的事实、数字、引用、政策。
        再给 3 个备选标题。
        只输出 JSON：
        {"scores":{"标题":0,"可读性":0,"实用性":0,"合规":0,"人味":0},"total":0,"summary":"一句话总评",
         "suggestions":[{"section":1,"issue":"问题","fix":"改法"}],
         "factChecks":["需要核实的内容"],"titles":["备选标题1","备选标题2","备选标题3"]}
        """)]
    }
}

struct IdeasReply: Decodable { let ideas: [IdeaItem]; struct IdeaItem: Decodable { let title: String; let angle: String? } }
struct OutlineReply: Decodable { let title: String?; let outline: [String] }
