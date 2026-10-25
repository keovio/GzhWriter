import Foundation
import SwiftUI

// MARK: - 敏感词 / 违规用语检测（本地规则，推草稿箱前过一遍）

enum Compliance {
    struct Rule { let category: String; let pattern: String; let tip: String }
    struct Hit: Identifiable, Hashable {
        var id: String { "\(section)-\(word)-\(category)" }
        let category: String
        let word: String
        let section: Int        // 从 0 开始；-1 表示标题
        let snippet: String
        let tip: String
    }

    static let rules: [Rule] = [
        Rule(category: "极限用语", pattern: #"最(好|佳|强|优|大|高|低|便宜|权威|专业|先进|全面|有效|安全|靠谱|火|牛|赚钱|划算)"#, tip: "广告法禁用的绝对化说法，改成「很」「比较」或给出具体数据"),
        Rule(category: "极限用语", pattern: #"(全网|全国|全球|行业|销量|排名)第一|No\.?\s?1|TOP\s?1|唯一|顶级|顶尖|极致|史上|国家级|世界级|首选|万能|百分之百|100%"#, tip: "绝对化说法，换成可证实的描述"),
        Rule(category: "承诺收益", pattern: #"稳赚|保本|躺赚|零风险|无风险|日入|轻松赚|暴富|翻倍|月入\s?[0-9一二三四五六七八九十百千万]+"#, tip: "不能承诺收益，删掉或改成「有人做到过」并注明条件"),
        Rule(category: "承诺结果", pattern: #"包过|保过|必过|稳过|必上岸|一定(能|会)(考上|上岸|通过|成功)|百分百(考上|上岸|通过)"#, tip: "不能保证结果，改成「提高通过率」之类"),
        Rule(category: "医疗功效", pattern: #"治愈|根治|药到病除|包治|疗效|治百病|抗癌|降血压|降血糖|延年益寿|排毒"#, tip: "非医疗号不能宣称功效，删掉或改成「建议咨询医生」"),
        Rule(category: "诱导分享", pattern: #"(点|求)个?(赞|在看)|转发(到|给)|分享到朋友圈|不转不是|必须转|赶紧转|关注(我|本号|公众号)(才|就)"#, tip: "微信禁止诱导分享、点赞、关注，删掉或改成自然的一句"),
        Rule(category: "站外引流", pattern: #"加(我)?(微信|V|v|vx|VX|威信)|微信号[:：]|私信领取|扫码(领|加)"#, tip: "站外引流容易被限流，删掉或用公众号自带的留言、菜单"),
        Rule(category: "未核实", pattern: #"【待核实[^】]*】"#, tip: "还有没补的事实或数字，发之前补上或删掉"),
    ]

    static func scan(_ a: Article) -> [Hit] {
        var out: [Hit] = []
        var seen = Set<String>()
        func check(_ text: String, _ idx: Int) {
            let ns = text as NSString
            for r in rules {
                guard let re = try? NSRegularExpression(pattern: r.pattern) else { continue }
                for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    let word = ns.substring(with: m.range)
                    let key = "\(idx)|\(word)"
                    guard seen.insert(key).inserted else { continue }
                    let lo = max(0, m.range.location - 10)
                    let hi = min(ns.length, m.range.location + m.range.length + 10)
                    let snip = ns.substring(with: NSRange(location: lo, length: hi - lo))
                        .replacingOccurrences(of: "\n", with: " ")
                    out.append(Hit(category: r.category, word: word, section: idx, snippet: snip, tip: r.tip))
                }
            }
        }
        check(a.title, -1)
        for (i, s) in a.sections.enumerated() { check(s.body, i) }
        return out
    }

    /// 让模型改掉某一部分里的问题说法
    static func fixInstruction(_ hits: [Hit]) -> String {
        let list = hits.map { "「\($0.word)」（\($0.category)：\($0.tip)）" }.joined(separator: "\n")
        return "下面这些说法不合规，改成合规、不夸大的表达，【待核实】的地方保留不动；其他内容一字不改：\n\(list)"
    }

    /// 自动修：按部分逐个改。返回改了几部分
    @MainActor
    static func autoFix(_ store: Store, _ id: UUID, log: (String) -> Void) async throws -> Int {
        guard let a = store.article(id) else { return 0 }
        let hits = scan(a).filter { $0.category != "未核实" }
        if hits.isEmpty { return 0 }
        var fixed = 0
        // 标题
        let th = hits.filter { $0.section == -1 }
        if !th.isEmpty {
            log("标题有不合规用语，改一下")
            var t = a.title
            for h in th { t = t.replacingOccurrences(of: h.word, with: "") }
            store.update(id) { $0.title = t.trimmingCharacters(in: .whitespaces) }
        }
        for (idx, list) in Dictionary(grouping: hits.filter { $0.section >= 0 }, by: \.section).sorted(by: { $0.key < $1.key }) {
            guard let cur = store.article(id), idx < cur.sections.count else { continue }
            log("改掉第 \(idx + 1) 部分的敏感用语")
            let text = try await store.run(.draft, Prompts.revise(cur, index: idx, instruction: fixInstruction(list), style: store.style(cur.styleId)))
            store.update(id) { if idx < $0.sections.count { $0.sections[idx].body = Humanize.clean(text) } }
            fixed += 1
        }
        return fixed
    }
}

// MARK: - 选题去重

enum Dedupe {
    static func norm(_ s: String) -> [Character] {
        s.lowercased().filter { $0.isLetter || $0.isNumber }.map { $0 }
    }
    static func bigrams(_ s: String) -> Set<String> {
        let c = norm(s)
        guard c.count > 1 else { return Set(c.map { String($0) }) }
        return Set((0..<(c.count - 1)).map { String(c[$0]) + String(c[$0 + 1]) })
    }
    /// 0~1，越大越像
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = bigrams(a), y = bigrams(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        let inter = Double(x.intersection(y).count)
        // 用较短的一方做分母，短标题被长标题包含也算像
        return inter / Double(min(x.count, y.count))
    }
    static let threshold = 0.6

    static func closest(_ s: String, in list: [String]) -> (String, Double)? {
        list.map { ($0, similarity(s, $0)) }.max { $0.1 < $1.1 }
    }

    /// 已经写过或记下的选题（稿件标题 + 选题 + 已用选题）
    @MainActor
    static func history(_ store: Store, except: UUID? = nil) -> [String] {
        var out: [String] = []
        for a in store.data.articles where a.id != except {
            if !a.title.isEmpty { out.append(a.title) }
            if !a.topic.isEmpty, a.topic != "自动选题中…" { out.append(a.topic) }
        }
        out += store.data.ideas.filter(\.used).map(\.title)
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }
}

// MARK: - 提示词：标题多选、爆文拆解

extension Prompts {
    static func titles(_ a: Article, ref: Breakdown?) -> [ChatMessage] {
        [.system(base), .user("""
        为下面这篇公众号文章想 5 个标题，风格各不相同：数字清单型、悬念好奇型、痛点共鸣型、利益结果型、观点态度型。
        \(ref.map { "可以参考这个标题套路：\($0.titleFormula)" } ?? "")
        要求：每个 14 到 28 字；和正文内容一致，不夸大、不标题党；不用「最」「第一」「必看」「震惊」这类词；
        给每个标题打分（0-100，看读者在朋友圈或订阅号列表里想不想点开，标题党和文不对题要扣分），一句话说理由。
        原标题：\(a.title)

        \(a.plainText.prefix(4000))

        只输出 JSON：{"titles":[{"title":"标题","style":"数字清单型","score":80,"reason":"一句话理由"}]}
        """)]
    }

    static func breakdown(title: String, text: String) -> [ChatMessage] {
        [.system(base), .user("""
        拆解下面这篇公众号爆文的写法，目的是学方法，不是搬内容。
        标题：\(title)

        \(text.prefix(6000))

        提炼：
        1. 标题套路（抽象成公式，比如「数字+人群+结果」）
        2. 开头用了什么手法抓人（一两句）
        3. 全文结构，每部分一句话说它在做什么（不写具体内容）
        4. 3 到 6 条可以复用的写作技巧
        5. 结尾手法
        6. 这套写法适合套用到哪些选题方向（3 个）
        只输出 JSON：{"titleFormula":"","hook":"","structure":["..."],"techniques":["..."],"ending":"","fitTopics":["..."]}
        """)]
    }
}

struct TitlesReply: Decodable { let titles: [TitleOption] }
struct BreakdownReply: Decodable {
    let titleFormula: String?; let hook: String?; let structure: [String]?
    let techniques: [String]?; let ending: String?; let fitTopics: [String]?
}

enum TitleMaker {
    @MainActor
    static func make(_ store: Store, _ id: UUID) async throws {
        guard let a = store.article(id) else { return }
        let r = try await store.runJSON(.review, TitlesReply.self, Prompts.titles(a, ref: store.breakdown(a.refId)))
        var opts = r.titles.filter { !$0.title.isEmpty }.sorted { $0.score > $1.score }
        if !a.title.isEmpty, !opts.contains(where: { $0.title == a.title }) {
            opts.append(TitleOption(title: a.title, style: "原标题"))
        }
        store.update(id) { $0.titleOptions = opts }
    }
}

extension Store {
    func breakdown(_ id: UUID?) -> Breakdown? {
        guard let id else { return nil }
        return data.breakdowns.first { $0.id == id }
    }
}

// MARK: - 编辑器卡片：敏感词

struct ComplianceCard: View {
    @EnvironmentObject var store: Store
    let articleId: UUID
    @StateObject private var busy = Busy()
    var a: Article { store.article(articleId) ?? Article() }

    var body: some View {
        let hits = Compliance.scan(a)
        let fixable = hits.filter { $0.category != "未核实" }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: hits.isEmpty ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .foregroundStyle(hits.isEmpty ? Theme.green : Theme.red)
                SectionTitle(text: "敏感词检测", hint: hits.isEmpty ? "没发现问题" : "\(hits.count) 处要注意")
                Spacer()
                if !fixable.isEmpty {
                    Button { fixAll() } label: { HStack(spacing: 4) { Image(systemName: "wand.and.stars"); Text("一键改掉") } }
                        .buttonStyle(PrimaryButton()).disabled(busy.label != nil)
                }
            }
            BusyBar(busy: busy)
            ForEach(hits) { h in
                HStack(alignment: .top, spacing: 10) {
                    Chip(text: h.category, fg: h.category == "未核实" ? Theme.orange : Theme.red,
                         bg: h.category == "未核实" ? Theme.orangeBg : Theme.redBg)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(h.section < 0 ? "标题" : "第 \(h.section + 1) 部分").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.sub)
                            Text("「\(h.word)」").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                        }
                        Text("…\(h.snippet)…").font(.system(size: 12)).foregroundStyle(Theme.sub).lineLimit(1)
                        Text(h.tip).font(.system(size: 11)).foregroundStyle(Theme.faint)
                    }
                    Spacer()
                }
                .padding(10)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .card()
    }

    func fixAll() {
        busy.run("正在改掉敏感用语…") {
            _ = try await Compliance.autoFix(store, articleId) { busy.label = $0 }
        }
    }
}

// MARK: - 编辑器卡片：标题多选

struct TitleCard: View {
    @EnvironmentObject var store: Store
    let articleId: UUID
    @StateObject private var busy = Busy()
    var a: Article { store.article(articleId) ?? Article() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(text: "标题多选", hint: "点一下就换上")
                Spacer()
                Button { run() } label: {
                    HStack(spacing: 4) { Image(systemName: "sparkles"); Text(a.titleOptions.isEmpty ? "出 5 个标题" : "再来 5 个") }
                }
                .buttonStyle(GhostButton())
                .disabled(busy.label != nil || a.sections.allSatisfy { $0.body.isEmpty })
            }
            BusyBar(busy: busy)
            if a.titleOptions.isEmpty {
                Text("按数字、悬念、痛点、利益、观点五种风格各出一个，并打分。")
                    .font(.system(size: 12)).foregroundStyle(Theme.sub)
            }
            ForEach(a.titleOptions) { t in
                let on = t.title == a.title
                Button { store.update(articleId) { $0.title = t.title } } label: {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 16)).foregroundStyle(on ? Theme.navy : Theme.faint)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(t.title).font(.system(size: 14, weight: on ? .semibold : .regular)).foregroundStyle(Theme.ink)
                                .multilineTextAlignment(.leading)
                            HStack(spacing: 6) {
                                if !t.style.isEmpty { Chip(text: t.style, fg: Theme.violet, bg: Theme.blueBg) }
                                if !t.reason.isEmpty { Text(t.reason).font(.system(size: 11)).foregroundStyle(Theme.sub).lineLimit(1) }
                            }
                        }
                        Spacer()
                        if t.score > 0 { ScoreBadge(score: t.score) }
                    }
                    .padding(10)
                    .background(on ? Theme.blueBg : Theme.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(on ? Theme.navy.opacity(0.5) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowButton())
            }
        }
        .card()
    }

    func run() {
        busy.run("正在想标题…") { try await TitleMaker.make(store, articleId) }
    }
}

// MARK: - 爆文拆解页

struct BreakdownView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var pipeline: Pipeline
    @StateObject private var busy = Busy()
    @State private var url = ""
    @State private var pasted = ""
    @State private var showPaste = false
    @State private var expanded: UUID?
    @State private var direction: [UUID: String] = [:]

    var body: some View {
        Page {
            PageHeader(title: "爆文拆解", subtitle: "贴一篇写得好的文章，提炼它的标题套路、开头、结构和技巧。只学方法，不存原文。")
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    TextField("公众号文章链接 https://mp.weixin.qq.com/s/…", text: $url).fieldBox().onSubmit(run)
                    Button { run() } label: { HStack(spacing: 4) { Image(systemName: "scissors"); Text("拆解") } }
                        .buttonStyle(PrimaryButton())
                        .disabled(busy.label != nil || (url.trimmingCharacters(in: .whitespaces).isEmpty && pasted.isEmpty))
                }
                Button(showPaste ? "收起" : "链接打不开？直接粘贴正文") { showPaste.toggle() }.buttonStyle(LinkButton())
                if showPaste {
                    TextEditor(text: $pasted)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(height: 160)
                        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
                }
                BusyBar(busy: busy)
            }
            .card()

            if store.data.breakdowns.isEmpty {
                Text("还没有拆解过文章。").font(.system(size: 13)).foregroundStyle(Theme.sub)
            }
            ForEach(store.data.breakdowns) { b in card(b) }
        }
    }

    func card(_ b: Breakdown) -> some View {
        let open = expanded == b.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(b.sourceTitle.isEmpty ? "未命名文章" : b.sourceTitle)
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                    if !b.titleFormula.isEmpty {
                        HStack(spacing: 6) { Chip(text: "标题公式", fg: Theme.violet, bg: Theme.blueBg); Text(b.titleFormula).font(.system(size: 12)).foregroundStyle(Theme.sub) }
                    }
                }
                Spacer()
                Button(open ? "收起" : "看拆解") { expanded = open ? nil : b.id }.buttonStyle(LinkButton())
                Button("删除") {
                    store.data.breakdowns.removeAll { $0.id == b.id }
                    store.save()
                }
                .buttonStyle(LinkButton(color: Theme.red))
            }
            if open {
                item("开头手法", b.hook)
                if !b.structure.isEmpty {
                    Text("结构").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink)
                    ForEach(Array(b.structure.enumerated()), id: \.offset) { i, s in
                        Text("\(i + 1). \(s)").font(.system(size: 12)).foregroundStyle(Theme.sub)
                    }
                }
                if !b.techniques.isEmpty {
                    Text("可复用技巧").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink)
                    ForEach(b.techniques, id: \.self) { Text("· \($0)").font(.system(size: 12)).foregroundStyle(Theme.sub) }
                }
                item("结尾手法", b.ending)
                if !b.fitTopics.isEmpty {
                    HStack(spacing: 6) {
                        Text("适合套用").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink)
                        ForEach(b.fitTopics, id: \.self) { t in
                            Button(t) { direction[b.id] = t }.buttonStyle(LinkButton(color: Theme.teal))
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                TextField("用这套写法写什么？留空就按赛道自动选题", text: Binding(
                    get: { direction[b.id] ?? "" }, set: { direction[b.id] = $0 })).fieldBox()
                Button { write(b) } label: { HStack(spacing: 4) { Image(systemName: "sparkles"); Text("用它写一篇") } }
                    .buttonStyle(PrimaryButton())
                    .disabled(store.data.connections.isEmpty)
            }
        }
        .card()
    }

    @ViewBuilder func item(_ label: String, _ text: String) -> some View {
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(text).font(.system(size: 12)).foregroundStyle(Theme.sub).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func write(_ b: Breakdown) {
        let dir = (direction[b.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        pipeline.enqueue(direction: dir, styleId: store.data.auto.dailyStyleId ?? store.data.styles.first?.id, refId: b.id)
        direction[b.id] = ""
    }

    func run() {
        let link = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let paste = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        busy.run("正在读文章…") {
            var title = ""
            var text = paste
            if !link.isEmpty, paste.isEmpty {
                let r = try await PageReader.read(link)
                title = r.title; text = r.text
            }
            guard text.count > 200 else { throw ReadError() }
            if title.isEmpty { title = String(text.prefix(30)) }
            busy.label = "正在拆解写法…"
            let r = try await store.runJSON(.review, BreakdownReply.self, Prompts.breakdown(title: title, text: text))
            var b = Breakdown()
            b.url = link; b.sourceTitle = title
            b.titleFormula = r.titleFormula ?? ""; b.hook = r.hook ?? ""
            b.structure = r.structure ?? []; b.techniques = r.techniques ?? []
            b.ending = r.ending ?? ""; b.fitTopics = r.fitTopics ?? []
            store.data.breakdowns.insert(b, at: 0)
            store.save()
            expanded = b.id
            url = ""; pasted = ""
        }
    }
}

struct ReadError: LocalizedError {
    var errorDescription: String? { "没读到正文，点「直接粘贴正文」把文章贴进来试试。" }
}
