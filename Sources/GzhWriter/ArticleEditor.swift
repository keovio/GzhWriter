import SwiftUI

struct ArticleEditor: View {
    @EnvironmentObject var store: Store
    let articleId: UUID
    var close: () -> Void = {}
    @StateObject private var busy = Busy()

    @State private var urlInput = ""
    @State private var custom: [UUID: String] = [:]     // 每节的自定义修改要求
    @State private var undo: [UUID: String] = [:]       // 每节上一次 AI 改动前的原文
    @State private var newOutline = ""
    @State private var copied = false

    @EnvironmentObject var pipeline: Pipeline
    var a: Article { store.article(articleId) ?? Article() }
    var signature: String { store.style(a.styleId)?.signature ?? "" }
    func edit(_ f: (inout Article) -> Void) { store.update(articleId, f) }

    func field<T>(_ kp: WritableKeyPath<Article, T>) -> Binding<T> {
        Binding(get: { a[keyPath: kp] }, set: { v in edit { $0[keyPath: kp] = v } })
    }

    func sectionField(_ id: UUID, _ kp: WritableKeyPath<ArticleSection, String>) -> Binding<String> {
        Binding(
            get: { a.sections.first(where: { $0.id == id })?[keyPath: kp] ?? "" },
            set: { v in edit { art in
                if let i = art.sections.firstIndex(where: { $0.id == id }) { art.sections[i][keyPath: kp] = v }
            } })
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(Theme.rule).frame(height: 1)
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        BusyBar(busy: busy)
                        if let step = pipeline.running[articleId] {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("正在自动生产：\(step)").font(.system(size: 13)).foregroundStyle(Theme.blue)
                                Spacer()
                            }
                            .padding(12)
                            .background(Theme.blueBg, in: RoundedRectangle(cornerRadius: 10))
                        }
                        let hits = Humanize.hits(a.plainText)
                        if !hits.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "wand.and.stars").foregroundStyle(Theme.orange)
                                Text("AI 味提醒：\(hits.prefix(4).joined(separator: "、"))").font(.system(size: 12)).foregroundStyle(Theme.ink).lineLimit(1)
                                Spacer()
                            }
                            .padding(10)
                            .background(Theme.orangeBg, in: RoundedRectangle(cornerRadius: 10))
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            switch a.stage {
                            case .topic: topicStage
                            case .outline: outlineStage
                            case .draft: draftStage
                            case .review: reviewStage
                            case .layout: layoutStage
                            }
                        }
                        .card()
                        if a.stage == .layout { DistributeCard(articleId: articleId) }
                        if !a.log.isEmpty {
                            DisclosureGroup("运行记录（\(a.log.count) 条）") {
                                Text(a.log.joined(separator: "\n"))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.sub)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 6)
                            }
                            .font(.system(size: 12))
                            .card(padding: 14)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }
                .background(Theme.bg)

                Rectangle().fill(Theme.rule).frame(width: 1)
                previewPanel.frame(width: 430)
            }
        }
        .background(Theme.bg)
    }

    var topBar: some View {
        HStack(spacing: 16) {
            Button(action: close) {
                HStack(spacing: 4) { Image(systemName: "chevron.left"); Text("返回") }
            }
            .buttonStyle(LinkButton(color: Theme.sub))
            TextField("文章标题", text: field(\.title))
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.ink)
                .frame(minWidth: 160)
            Spacer()
            StepBar(current: a.stage, done: { $0.rawValue < a.stage.rawValue || (a.stage == .layout && $0 == .layout) }) { s in
                edit { $0.stage = s }
            }
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)      // 红绿灯下方
        .padding(.bottom, 12)
        .background(Theme.sheet)
    }

    var previewPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("手机预览").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Text("\(a.wordCount) 字").font(.system(size: 12)).foregroundStyle(Theme.faint)
                if let r = a.review { ScoreBadge(score: r.total) }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            WebPreview(html: Layout.previewPage(a, signature: signature))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.rule, lineWidth: 6))
                .padding(.horizontal, 16)
            HStack(spacing: 10) {
                Button { copyRich() } label: {
                    HStack { Image(systemName: copied ? "checkmark" : "doc.on.doc"); Text(copied ? "已复制" : "复制富文本") }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButton(large: true))
                .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("纯文本") { Layout.copyMarkdown(a) }.buttonStyle(GhostButton())
            }
            .padding(16)
            Text("复制后粘到公众号后台的正文区，过一眼再发").font(.system(size: 11)).foregroundStyle(Theme.faint)
                .padding(.bottom, 14)
        }
        .background(Theme.sheet)
    }

    // MARK: ① 选题

    @ViewBuilder var topicStage: some View {
        label("选题")
        TextField("这篇写什么", text: field(\.topic)).fieldBox()

        label("你的观点 / 想说的话（必填）")
        hint("写几句你自己的看法、经历或结论。AI 只帮你把它写清楚，这也是平台要求的「真人表达」。")
        editor(field(\.viewpoint), height: 110)

        label("文章类型")
        Picker("", selection: field(\.kind)) {
            ForEach(ArticleKind.allCases) { Text($0.name).tag($0.rawValue) }
        }
        .pickerStyle(.segmented).labelsHidden()
        hint(ArticleKind.of(a.kind).hint)

        label("账号")
        Picker("", selection: field(\.styleId)) {
            ForEach(store.data.styles) { Text($0.name).tag(Optional($0.id)) }
        }
        .labelsHidden()
        .frame(maxWidth: 240)

        label("参考素材（可选，只作参考）")
        HStack {
            TextField("贴一个网页链接读取正文", text: $urlInput).fieldBox()
            Button("读取") { readURL() }.buttonStyle(GhostButton()).disabled(urlInput.isEmpty || busy.label != nil)
        }
        editor(field(\.material), height: 140)

        HStack {
            Spacer()
            Button("下一步：生成大纲 →") { makeOutline() }
                .buttonStyle(PrimaryButton())
                .disabled(a.topic.trimmingCharacters(in: .whitespaces).isEmpty
                          || a.viewpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || busy.label != nil)
        }
    }

    // MARK: ② 大纲

    @ViewBuilder var outlineStage: some View {
        hint("拖动顺序、改字、增删都可以。大纲定了再写正文，结构由你说了算。")
        ForEach(Array(a.outline.enumerated()), id: \.offset) { i, _ in
            HStack {
                Text("\(i + 1).").foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                TextField("小标题：要点", text: Binding(
                    get: { i < a.outline.count ? a.outline[i] : "" },
                    set: { v in edit { if i < $0.outline.count { $0.outline[i] = v } } }))
                    .fieldBox()
                Button { edit { if i > 0 { $0.outline.swapAt(i, i - 1) } } } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.borderless).disabled(i == 0)
                Button { edit { if i + 1 < $0.outline.count { $0.outline.swapAt(i, i + 1) } } } label: { Image(systemName: "arrow.down") }
                    .buttonStyle(.borderless).disabled(i + 1 >= a.outline.count)
                Button { edit { if i < $0.outline.count { $0.outline.remove(at: i) } } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
            }
        }
        HStack {
            TextField("加一个小标题", text: $newOutline).fieldBox().onSubmit(addOutline)
            Button("添加", action: addOutline).buttonStyle(GhostButton()).disabled(newOutline.isEmpty)
        }
        HStack {
            Button("重新生成大纲") { makeOutline() }.buttonStyle(GhostButton()).disabled(busy.label != nil)
            Spacer()
            Button("确认大纲，开始写正文 →") { confirmOutline() }
                .buttonStyle(PrimaryButton())
                .disabled(a.outline.isEmpty)
        }
    }

    // MARK: ③ 正文

    @ViewBuilder var draftStage: some View {
        HStack {
            hint("可以逐个小标题让 AI 起草，也可以自己写。写完一定通读一遍，加进你自己的经历和例子。")
            Spacer()
            Button("起草所有空白部分") { draftAllEmpty() }.buttonStyle(GhostButton())
                .disabled(busy.label != nil || !a.sections.contains { $0.body.isEmpty })
        }
        if a.sections.isEmpty {
            Text("先在「大纲」里确认大纲。").foregroundStyle(.secondary)
        }
        ForEach(Array(a.sections.enumerated()), id: \.element.id) { i, sec in
            Group {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(String(format: "%02d", i + 1)).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(Theme.blue)
                        TextField("小标题", text: sectionField(sec.id, \.heading))
                            .textFieldStyle(.plain).font(.headline)
                        Spacer()
                        Text("\(sec.body.filter { !$0.isWhitespace }.count) 字").font(.caption).foregroundStyle(.secondary)
                    }
                    editor(sectionField(sec.id, \.body), height: 180)
                    HStack {
                        if sec.body.isEmpty {
                            Button("AI 起草这部分") { draft(i) }.buttonStyle(GhostButton()).disabled(busy.label != nil)
                        } else {
                            Menu("AI 改写") {
                                ForEach(Prompts.Op.allCases) { op in
                                    Button(op.rawValue) { revise(sec.id, op.instruction, label: op.rawValue) }
                                }
                            }
                            .fixedSize()
                            .disabled(busy.label != nil)
                            TextField("或者说说怎么改，回车", text: Binding(
                                get: { custom[sec.id] ?? "" }, set: { custom[sec.id] = $0 }))
                                .fieldBox()
                                .onSubmit {
                                    let t = (custom[sec.id] ?? "").trimmingCharacters(in: .whitespaces)
                                    if !t.isEmpty { revise(sec.id, t, label: "按要求修改"); custom[sec.id] = "" }
                                }
                        }
                        if let old = undo[sec.id] {
                            Button("撤销 AI 改动") {
                                edit { art in
                                    if let k = art.sections.firstIndex(where: { $0.id == sec.id }) { art.sections[k].body = old }
                                }
                                undo[sec.id] = nil
                            }
                            .buttonStyle(LinkButton(color: Theme.orange))
                        }
                    }
                }
                .padding(14)
                .background(Theme.sheet, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.rule))
            }
        }
        if !a.sections.isEmpty {
            HStack {
                Spacer()
                Button("去审稿 →") { edit { $0.stage = .review } }.buttonStyle(PrimaryButton())
            }
        }
    }

    // MARK: ④ 审稿

    @ViewBuilder var reviewStage: some View {
        HStack {
            hint("审稿只给建议，点「采纳」才会改。改完可以再审一次。")
            Spacer()
            Button(a.review == nil ? "开始审稿" : "重新审稿") { review() }
                .buttonStyle(PrimaryButton())
                .disabled(a.sections.allSatisfy { $0.body.isEmpty } || busy.label != nil)
        }
        if let r = a.review {
            Group {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(r.total)").font(.system(size: 40, weight: .bold))
                            .foregroundStyle(Theme.scoreColor(r.total))
                        Text("总分").foregroundStyle(.secondary)
                        Spacer()
                        ForEach(["标题", "可读性", "实用性", "合规", "人味"], id: \.self) { k in
                            VStack {
                                Text("\(r.scores[k] ?? 0)").font(.headline)
                                Text(k).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(width: 52)
                        }
                    }
                    if !r.summary.isEmpty { Text(r.summary).font(.system(size: 13)).foregroundStyle(Theme.ink) }
                }
                .padding(16)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 12))
            }

            label("修改建议")
            ForEach(r.suggestions) { s in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(s.section.map { "第 \($0) 部分" } ?? "全文").font(.caption.bold()).foregroundStyle(.secondary)
                        Text(s.issue)
                        Text("→ \(s.fix)").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if s.applied {
                        Text("已处理").foregroundStyle(.green)
                    } else if let n = s.section, n >= 1, n <= a.sections.count {
                        Button("采纳") { apply(s) }.buttonStyle(PrimaryButton()).disabled(busy.label != nil)
                        Button("忽略") { markApplied(s.id) }.buttonStyle(GhostButton())
                    } else {
                        Button("我改好了") { markApplied(s.id) }.buttonStyle(GhostButton())
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }

            if !r.factChecks.isEmpty {
                label("需要你核实")
                ForEach(r.factChecks, id: \.self) { f in
                    Label(f, systemImage: "checkmark.seal").foregroundStyle(.orange)
                }
            }

            if !r.titles.isEmpty {
                label("备选标题")
                ForEach(r.titles, id: \.self) { t in
                    HStack {
                        Text(t)
                        Spacer()
                        Button("用这个") { edit { $0.title = t } }.buttonStyle(GhostButton())
                    }
                }
            }

            HStack {
                Spacer()
                Button("去排版 →") { edit { $0.stage = .layout } }.buttonStyle(PrimaryButton())
            }
        }
    }

    // MARK: ⑤ 排版

    @ViewBuilder var layoutStage: some View {
        label("模板")
        Picker("", selection: field(\.template)) {
            ForEach(Layout.templates) { Text($0.name).tag($0.id) }
        }
        .pickerStyle(.segmented).labelsHidden()

        label("强调色")
        HStack {
            ForEach(Layout.accents, id: \.0) { hex, name in
                Button { edit { $0.accent = hex } } label: {
                    Circle().fill(Color(hex: hex)).frame(width: 22, height: 22)
                        .overlay(Circle().stroke(Color.primary, lineWidth: a.accent == hex ? 2 : 0).padding(-3))
                }
                .buttonStyle(RowButton())
                .help(name)
            }
        }

        Stepper("正文字号 \(a.fontSize)px", value: field(\.fontSize), in: 14...18)
        Toggle("文末加「AI 辅助创作」声明", isOn: field(\.aiNotice))

        if Layout.plain(a).contains("待核实") {
            Label("文中还有【待核实】的地方，发之前补上或删掉。", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }

        Group {
            VStack(alignment: .leading, spacing: 6) {
                Text("发布步骤").font(.headline)
                Text("1. 点「复制富文本」")
                Text("2. 在公众号后台新建图文，粘贴到正文区，标题单独填")
                Text("3. 自己通读一遍，设封面，手动发表或群发")
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.sub)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
        }
        HStack {
            Button(copied ? "已复制 ✓" : "复制富文本") { copyRich() }.buttonStyle(PrimaryButton())
            Button("复制纯文本") { Layout.copyMarkdown(a) }.buttonStyle(GhostButton())
        }
    }

    // MARK: 小部件

    func label(_ s: String) -> some View {
        Text(s).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink).padding(.top, 4)
    }
    func hint(_ s: String) -> some View { Text(s).font(.system(size: 12)).foregroundStyle(Theme.sub) }
    func editor(_ b: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: b)
            .font(.system(size: 14))
            .lineSpacing(5)
            .scrollContentBackground(.hidden)
            .frame(minHeight: height)
            .padding(8)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: 动作

    func copyRich() {
        Layout.copyRichText(a, signature: signature)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }

    func readURL() {
        let u = urlInput
        busy.run("正在读取网页…") {
            let r = try await PageReader.read(u)
            edit { $0.material += ($0.material.isEmpty ? "" : "\n\n") + "【参考：\(r.title)】\n\(r.text)" }
            urlInput = ""
        }
    }

    func makeOutline() {
        let snap = a
        let style = store.style(snap.styleId)
        busy.run("正在生成大纲…") {
            let r = try await store.runJSON(.topic, OutlineReply.self, Prompts.outline(snap, style: style))
            edit {
                if let t = r.title, !t.isEmpty, $0.title.isEmpty { $0.title = t }
                if $0.kind == "auto", let k = r.kind, let kk = ArticleKind(rawValue: k), kk != .auto { $0.kind = kk.rawValue }
                $0.outline = r.outline
                $0.stage = .outline
            }
        }
    }

    func addOutline() {
        let t = newOutline.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        edit { $0.outline.append(t) }
        newOutline = ""
    }

    static func headingOf(_ line: String) -> String {
        for sep in ["：", ":"] {
            if let r = line.range(of: sep) { return String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespaces) }
        }
        return line
    }

    func confirmOutline() {
        edit { art in
            let old = art.sections
            art.sections = art.outline.enumerated().map { i, line in
                let h = Self.headingOf(line)
                if let keep = old.first(where: { $0.heading == h }) { return keep }
                if i < old.count, old[i].body.isEmpty { return ArticleSection(id: old[i].id, heading: h, body: "") }
                return ArticleSection(heading: h, body: "")
            }
            art.stage = .draft
        }
    }

    func draft(_ i: Int) {
        busy.run("正在起草第 \(i + 1) 部分…") { try await draftOne(i) }
    }

    func draftOne(_ i: Int) async throws {
        let snap = a
        guard i < snap.sections.count else { return }
        var s2 = snap
        // 大纲和正文节数不一致时，以正文节标题为准
        if s2.outline.count != s2.sections.count { s2.outline = s2.sections.map(\.heading) }
        let text = try await store.run(.draft, Prompts.section(s2, index: i, style: store.style(snap.styleId)))
        let id = snap.sections[i].id
        edit { art in
            if let k = art.sections.firstIndex(where: { $0.id == id }) { art.sections[k].body = text }
        }
    }

    func draftAllEmpty() {
        busy.run("正在逐个起草…") {
            for i in a.sections.indices where a.sections[i].body.isEmpty {
                busy.label = "正在起草第 \(i + 1) 部分…"
                try await draftOne(i)
            }
        }
    }

    func revise(_ id: UUID, _ instruction: String, label: String) {
        let snap = a
        guard let i = snap.sections.firstIndex(where: { $0.id == id }) else { return }
        busy.run("正在\(label)第 \(i + 1) 部分…") {
            let text = try await store.run(.draft, Prompts.revise(snap, index: i, instruction: instruction, style: store.style(snap.styleId)))
            undo[id] = snap.sections[i].body
            edit { art in
                if let k = art.sections.firstIndex(where: { $0.id == id }) { art.sections[k].body = text }
            }
        }
    }

    func review() {
        let snap = a
        busy.run("正在审稿…") {
            let r = try await store.runJSON(.review, ReviewResult.self, Prompts.review(snap))
            edit { $0.review = r }
        }
    }

    func markApplied(_ sid: UUID) {
        edit { art in
            if let k = art.review?.suggestions.firstIndex(where: { $0.id == sid }) { art.review?.suggestions[k].applied = true }
        }
    }

    func apply(_ s: Suggestion) {
        guard let n = s.section, n >= 1, n <= a.sections.count else { return }
        let snap = a
        let i = n - 1
        let secId = snap.sections[i].id
        busy.run("正在按建议修改第 \(n) 部分…") {
            let text = try await store.run(.draft, Prompts.revise(snap, index: i,
                instruction: "问题：\(s.issue)。改法：\(s.fix)。只改和这条建议相关的地方，其余保持原样。",
                style: store.style(snap.styleId)))
            undo[secId] = snap.sections[i].body
            edit { art in
                if let k = art.sections.firstIndex(where: { $0.id == secId }) { art.sections[k].body = text }
            }
            markApplied(s.id)
        }
    }
}

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt64(h, radix: 16) ?? 0x333333
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
