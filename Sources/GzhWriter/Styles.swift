import SwiftUI

// MARK: - 风格分析结果

struct StyleGuide: Decodable {
    var summary = "", persona = "", tone = "", structure = "", sentences = "", wording = "", titles = ""
    var dos: [String] = [], donts: [String] = [], topics: [String] = []

    enum K: String, CodingKey { case summary, persona, tone, structure, sentences, wording, titles, dos, donts, topics }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        func s(_ k: K) -> String { (try? c.decode(String.self, forKey: k)) ?? "" }
        func l(_ k: K) -> [String] { (try? c.decode([String].self, forKey: k)) ?? [] }
        summary = s(.summary); persona = s(.persona); tone = s(.tone); structure = s(.structure)
        sentences = s(.sentences); wording = s(.wording); titles = s(.titles)
        dos = l(.dos); donts = l(.donts); topics = l(.topics)
    }

    /// 存成一段文字，用户可以直接改；写稿时整段给模型
    var text: String {
        var parts: [String] = []
        func add(_ h: String, _ v: String) {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { parts.append("【\(h)】\n\(t)") }
        }
        func addList(_ h: String, _ v: [String]) {
            let items = v.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !items.isEmpty { parts.append("【\(h)】\n" + items.map { "· " + $0 }.joined(separator: "\n")) }
        }
        add("一句话风格", summary)
        add("人设", persona)
        add("语气", tone)
        add("结构", structure)
        add("句子与节奏", sentences)
        add("用词习惯", wording)
        add("标题", titles)
        addList("要这样写", dos)
        addList("别这样写", donts)
        addList("适合的选题", topics)
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - 风格页

struct StylesView: View {
    @EnvironmentObject var store: Store
    @State private var selected: UUID?
    @State private var link = ""
    @State private var reading = false
    @State private var analyzing = false
    @State private var note = ""
    @State private var editingGuide = false
    @State private var showSample = false
    @State private var confirmDelete = false

    /// 嵌进设置页右栏时为 true：不自己包 Page（避免嵌套滚动）
    var embedded = false

    var body: some View {
        Group {
            if embedded { inner } else { Page(maxWidth: 900) { inner } }
        }
        .onAppear { if selected == nil { selected = store.data.styles.first?.id } }
        .onChange(of: selected) { _ in note = ""; editingGuide = false; link = "" }
        .confirmationDialog("删除风格「\(selectedName)」？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { deleteSelected() }
        } message: {
            Text("用这套风格的账号和稿件会改用「\(fallbackName)」。")
        }
    }

    @ViewBuilder var inner: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "风格", subtitle: "填定位、给几篇范文，AI 总结出这个号的写法，之后写稿都照它来。", compact: embedded) {
                Button {
                    let s = StylePreset(name: "新风格")
                    store.data.styles.append(s); store.save(); selected = s.id
                } label: { Label("添加风格", systemImage: "plus") }
                .buttonStyle(GhostButton())
            }

            chips

            if let id = selected, let cur = store.data.styles.first(where: { $0.id == id }) {
                // 按 id 取，不按下标：删除后旧下标会越界闪退
                let b = Binding(
                    get: { store.data.styles.first(where: { $0.id == id }) ?? cur },
                    set: { v in
                        guard let i = store.data.styles.firstIndex(where: { $0.id == id }) else { return }
                        store.data.styles[i] = v; store.save()
                    })
                positioning(b)
                samples(b)
                guideCard(b)
                signature(b)
            }
        }
    }

    var selectedName: String { store.data.styles.first { $0.id == selected }?.name ?? "" }
    var fallbackName: String { store.data.styles.first { $0.id != selected }?.name ?? "" }

    func deleteSelected() {
        guard let id = selected, store.data.styles.count > 1 else { return }
        let next = store.data.styles.first { $0.id != id }?.id
        selected = next          // 先切走，再删
        store.data.styles.removeAll { $0.id == id }
        for i in store.data.accounts.indices where store.data.accounts[i].styleId == id { store.data.accounts[i].styleId = next }
        for i in store.data.articles.indices where store.data.articles[i].styleId == id { store.data.articles[i].styleId = next }
        if store.data.auto.dailyStyleId == id { store.data.auto.dailyStyleId = next }
        store.save()
    }

    // 顶部风格切换
    var chips: some View {
        HStack(spacing: 8) {
            ForEach(store.data.styles) { s in
                Button { selected = s.id } label: {
                    HStack(spacing: 6) {
                        Text(String(s.name.prefix(1))).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 20, height: 20).background(Theme.navy, in: Circle())
                        Text(s.name).font(.system(size: 13, weight: selected == s.id ? .semibold : .regular))
                        if !s.guide.isEmpty {
                            Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(Theme.violet)
                        }
                    }
                    .foregroundStyle(selected == s.id ? Theme.blue : Theme.ink)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(selected == s.id ? Theme.blueBg : Theme.sheet, in: Capsule())
                    .overlay(Capsule().stroke(selected == s.id ? Theme.blue.opacity(0.3) : Theme.rule))
                }
                .buttonStyle(RowButton())
                .contextMenu {
                    if store.data.styles.count > 1 {
                        Button("删除", role: .destructive) { selected = s.id; confirmDelete = true }
                    }
                }
            }
            Spacer()
            if store.data.styles.count > 1 {
                Button { confirmDelete = true } label: { Label("删除这套", systemImage: "trash") }
                    .buttonStyle(LinkButton(color: Theme.red))
                    .help("删除当前选中的风格")
            }
        }
    }

    // ① 定位
    func positioning(_ b: Binding<StylePreset>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            step(1, "定位", "写什么、写给谁")
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    field("风格名称", "比如：公考干货", b.name)
                    field("赛道", "比如：公考备考经验", b.track)
                }
                GridRow {
                    field("读者是谁", "比如：在职备考的 25–35 岁上班族", b.audience)
                    field("不写的话题", "比如：明星八卦、股票推荐", b.avoid)
                }
            }
        }
        .card()
    }

    // ② 范文
    func samples(_ b: Binding<StylePreset>) -> some View {
        let st = b.wrappedValue
        return VStack(alignment: .leading, spacing: 12) {
            step(2, "范文", "贴文章链接（公众号、头条、知乎都行），读两三篇效果最好")
            HStack(spacing: 8) {
                HStack {
                    Image(systemName: "link").foregroundStyle(Theme.faint)
                    TextField("粘贴文章链接，回车读取", text: $link).textFieldStyle(.plain)
                        .onSubmit { read(b) }
                }
                .fieldBox()
                Button { read(b) } label: {
                    HStack(spacing: 4) {
                        if reading { ProgressView().controlSize(.small) }
                        Text(reading ? "读取中…" : "读取")
                    }
                }
                .buttonStyle(GhostButton())
                .disabled(reading || link.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !st.links.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(st.links, id: \.self) { l in
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(Theme.blue)
                            Text(l).font(.system(size: 12)).foregroundStyle(Theme.sub).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { b.wrappedValue.links.removeAll { $0 == l } } label: { Image(systemName: "xmark") }
                                .buttonStyle(LinkButton(color: Theme.faint))
                                .help("从列表去掉（已读进范文的文字不会删，可在下面改）")
                        }
                    }
                }
            }
            HStack {
                Button { showSample.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showSample ? "chevron.down" : "chevron.right").font(.system(size: 10))
                        Text(st.sample.isEmpty ? "或者直接粘贴文字" : "范文原文 \(st.sample.count) 字")
                    }
                }
                .buttonStyle(LinkButton(color: Theme.sub))
                Spacer()
                if !note.isEmpty {
                    Text(note).font(.system(size: 12)).foregroundStyle(note.hasPrefix("✓") ? Theme.green : Theme.orange).lineLimit(2)
                }
            }
            if showSample || (st.sample.isEmpty && st.links.isEmpty) {
                TextEditor(text: b.sample)
                    .font(.system(size: 13)).lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 180)
                    .padding(10)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                Spacer()
                Button { analyze(b) } label: {
                    HStack(spacing: 6) {
                        if analyzing { ProgressView().controlSize(.small).tint(.white) } else { Image(systemName: "sparkles") }
                        Text(analyzing ? "分析中…" : (st.guide.isEmpty ? "分析风格" : "重新分析"))
                    }
                }
                .buttonStyle(PrimaryButton())
                .disabled(analyzing || st.sample.trimmingCharacters(in: .whitespacesAndNewlines).count < 200)
                .help("至少 200 字范文")
            }
        }
        .card()
    }

    // ③ 风格说明
    func guideCard(_ b: Binding<StylePreset>) -> some View {
        let st = b.wrappedValue
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                step(3, "风格说明", st.guide.isEmpty ? "分析完会出现在这里，写稿时 AI 按它来" : "写稿时 AI 按它来，哪里不对直接改")
                Spacer()
                if !st.guide.isEmpty {
                    Button(editingGuide ? "完成" : "编辑") { editingGuide.toggle() }.buttonStyle(GhostButton())
                }
            }
            if st.guide.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "text.badge.star").font(.system(size: 22)).foregroundStyle(Theme.faint)
                    Text("还没有风格说明。给上面范文后点「分析风格」，会总结出人设、语气、结构、句子、用词、标题和要/别这样写。")
                        .font(.system(size: 12)).foregroundStyle(Theme.sub)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
            } else if editingGuide {
                TextEditor(text: b.guide)
                    .font(.system(size: 13)).lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 320)
                    .padding(10)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
            } else {
                GuideBlocks(text: st.guide)
                if let d = st.guideAt {
                    Text("分析于 \(d.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 11)).foregroundStyle(Theme.faint)
                }
            }
        }
        .card()
    }

    // ④ 署名
    func signature(_ b: Binding<StylePreset>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            step(4, "署名", "推到草稿箱和排版时用")
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    field("作者名", "比如：小 K", b.author)
                    field("文末一句话", "比如：我是小 K，陪你上岸。", b.signature)
                }
            }
        }
        .card()
    }

    // MARK: 小组件

    func step(_ n: Int, _ title: String, _ hint: String) -> some View {
        HStack(spacing: 10) {
            Text("\(n)").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(Theme.brand, in: Circle())
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(hint).font(.system(size: 12)).foregroundStyle(Theme.faint).lineLimit(1)
        }
    }

    func field(_ label: String, _ ph: String, _ v: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.sub)
            TextField(ph, text: v).fieldBox()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 动作

    func read(_ b: Binding<StylePreset>) {
        let l = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty, !reading else { return }
        if b.wrappedValue.links.contains(l) { note = "这篇已经读过了"; return }
        reading = true
        note = ""
        Task {
            do {
                let page = try await PageReader.read(l)
                let text = page.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.count < 100 { throw LLMError.readFail("没读到正文") }
                var s = b.wrappedValue.sample.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { s += "\n\n———\n\n" }
                s += (page.title.isEmpty ? "" : "《\(page.title)》\n") + text
                b.wrappedValue.sample = s
                b.wrappedValue.links.append(l)
                link = ""
                note = "✓ 读到《\(page.title.isEmpty ? "文章" : page.title)》\(text.count) 字" + (b.wrappedValue.links.count < 2 ? "，再加一两篇更准" : "")
            } catch {
                note = error.localizedDescription
            }
            reading = false
        }
    }

    func analyze(_ b: Binding<StylePreset>) {
        analyzing = true
        note = ""
        let st = b.wrappedValue
        Task {
            do {
                let g = try await store.runJSON(.review, StyleGuide.self, Prompts.analyzeStyle(st))
                let text = g.text
                if text.isEmpty { throw LLMError.empty }
                b.wrappedValue.guide = text
                b.wrappedValue.guideAt = Date()
                // 赛道、读者没填时用分析结果补上
                editingGuide = false
                note = "✓ 分析完成，风格说明已更新"
                Theme.tap()
            } catch {
                note = "分析失败：\(error.localizedDescription)"
            }
            analyzing = false
        }
    }
}

/// 把「【标题】内容」分块显示
struct GuideBlocks: View {
    let text: String

    var blocks: [(String, String)] {
        var out: [(String, String)] = []
        for chunk in text.components(separatedBy: "\n\n") {
            let t = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            if t.hasPrefix("【"), let r = t.range(of: "】") {
                let head = String(t[t.index(after: t.startIndex)..<r.lowerBound])
                let body = String(t[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                out.append((head, body))
            } else {
                out.append(("", t))
            }
        }
        return out
    }

    var body: some View {
        let list = blocks
        VStack(alignment: .leading, spacing: 10) {
            if let first = list.first, first.0 == "一句话风格" {
                Text(first.1).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.blueBg, in: RoundedRectangle(cornerRadius: 10))
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10, alignment: .top), GridItem(.flexible(), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                ForEach(Array(list.enumerated()).filter { $0.element.0 != "一句话风格" }, id: \.offset) { _, blk in
                    VStack(alignment: .leading, spacing: 6) {
                        if !blk.0.isEmpty {
                            HStack(spacing: 6) {
                                Circle().fill(color(blk.0)).frame(width: 6, height: 6)
                                Text(blk.0).font(.system(size: 12, weight: .semibold)).foregroundStyle(color(blk.0))
                            }
                        }
                        Text(blk.1).font(.system(size: 12)).foregroundStyle(Theme.ink).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    func color(_ h: String) -> Color {
        switch h {
        case "要这样写": return Theme.green
        case "别这样写": return Theme.red
        case "适合的选题": return Theme.violet
        default: return Theme.blue
        }
    }
}
