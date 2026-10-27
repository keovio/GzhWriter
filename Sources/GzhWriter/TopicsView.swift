import SwiftUI

// MARK: 工作台（首页 = 题材流，规格 `docs/design/01-界面规格.md` §2）

struct TopicsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var pipeline: Pipeline
    @EnvironmentObject var radar: HotRadar
    @StateObject private var busy = Busy()

    /// 点标题 / 「用这个」后由 ContentView 打开那篇稿件
    var open: (UUID) -> Void
    /// 跳稿件页列表（状态行面板「还有 N 篇」用，不复用 open）
    var goArticles: () -> Void = {}

    @State private var direction = ""
    @State private var onlyNew = false
    @State private var domain = "全部"

    @State private var panelOpen = false
    @State private var confirmDelete: UUID?
    @State private var lastFailedCount = 0

    @State private var showBreakdown = false
    @State private var pasted = ""
    @State private var result: BreakdownReply?
    @State private var note = ""

    @State private var loadingHot = false
    @State private var offline = false

    var noModel: Bool { store.data.connections.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let e = store.loadError, !e.isEmpty { loadErrorBar(e) }
                if offline { offlineBar }
                if hasStatus { statusRow }
                if panelOpen && !panelItems.isEmpty { panel }
                inputRow
                filterRow
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 10)

            flow
        }
        .frame(maxWidth: 1040, alignment: .leading)
        .frame(maxWidth: .infinity)
        .background(Theme.bg)
        .overlay(alignment: .trailing) {
            if showBreakdown { drawer.transition(.move(edge: .trailing)) }
        }
        .animation(.easeOut(duration: 0.2), value: showBreakdown)
        .task {
            await loadHot()
            lastFailedCount = pipeline.failedArticles.count
        }
        .onChange(of: pipeline.failedArticles.count) { n in
            // 生成失败：面板自动展开一次（用户收起后不重复弹）
            if n > lastFailedCount && !panelOpen { panelOpen = true }
            lastFailedCount = n
        }
    }

    // MARK: 页头

    var header: some View {
        PageHeader(title: "今天写什么",
                   subtitle: noModel ? "先到「设置 → 模型」接一个模型，才能开始写。"
                                     : "选一个，剩下的交给我。")
    }

    /// 数据文件读不出来时的警示条（样式同 offlineBar）。
    /// 解码失败那次会话是空数据 + 不写盘，用户会以为稿子全没了，所以必须放在页头下面第一眼能看到。
    /// 唯一解除方式，必须手动点：不点的话写盘闸一直关着，这个应用一直是只读的。
    /// 不给 x 图标，用文字按钮，因为点下去是不可逆动作（等于接受以空数据继续）。
    func loadErrorBar(_ msg: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 12))
            Text(msg).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("我知道了，开始新文档") { store.clearLoadError() }
                .buttonStyle(LinkButton(color: Theme.red))
        }
        .foregroundStyle(Theme.red)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.redBg, in: RoundedRectangle(cornerRadius: 8))
    }

    var offlineBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash").font(.system(size: 12))
            Text("热榜取不到，检查一下网络。候选和拆解不受影响").font(.system(size: 12))
            Spacer()
            Button { offline = false } label: { Image(systemName: "xmark") }
                .buttonStyle(LinkButton(color: Theme.orange))
        }
        .foregroundStyle(Theme.orange)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.orangeBg, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: 状态行（§2.3）

    var runningIds: [UUID] { store.data.articles.filter { pipeline.running[$0.id] != nil }.map(\.id) }
    var hasStatus: Bool { !runningIds.isEmpty || !pipeline.failedArticles.isEmpty }

    var statusRow: some View {
        HStack(spacing: 8) {
            if !runningIds.isEmpty {
                Button { panelOpen.toggle() } label: {
                    Chip(text: "正在写 \(runningIds.count) 篇", fg: Theme.blue, bg: Theme.blueBg)
                }
                .buttonStyle(RowButton())
            }
            if !pipeline.failedArticles.isEmpty {
                Button { panelOpen.toggle() } label: {
                    Chip(text: "\(pipeline.failedArticles.count) 篇没写完", fg: Theme.orange, bg: Theme.orangeBg)
                }
                .buttonStyle(RowButton())
            }
            if panelOpen {
                Image(systemName: "chevron.up").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.faint)
            } else {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.faint)
            }
            Spacer()
        }
        .font(.system(size: 12))
    }

    /// 生成中的在前，没写完的在后
    var panelItems: [(id: UUID, title: String, state: String, kind: Int)] {
        var out: [(UUID, String, String, Int)] = []
        for id in runningIds {
            guard let a = store.article(id) else { continue }
            out.append((id, a.topic.isEmpty ? "自动选题中…" : a.topic, pipeline.running[id] ?? "生成中", 0))
        }
        for a in pipeline.failedArticles {
            out.append((a.id, a.topic.isEmpty ? a.displayTitle : a.topic, a.failed, a.failed == "已停止" ? 2 : 1))
        }
        return out.map { (id: $0.0, title: $0.1, state: $0.2, kind: $0.3) }
    }

    var panel: some View {
        VStack(spacing: 0) {
            let items = panelItems
            ForEach(Array(items.prefix(5).enumerated()), id: \.element.id) { i, it in
                if i > 0 { Divider().overlay(Theme.rule) }
                panelRow(it)
            }
            if items.count > 5 {
                Button { goArticles() } label: {
                    Text("还有 \(items.count - 5) 篇 →").font(.system(size: 11)).foregroundStyle(Theme.faint)
                }
                .buttonStyle(LinkButton(color: Theme.faint))
                .padding(.top, 6)
            }
        }
        .padding(12)
        .background(Theme.sheet, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.rule))
    }

    func panelRow(_ it: (id: UUID, title: String, state: String, kind: Int)) -> some View {
        HStack(spacing: 10) {
            Button { open(it.id) } label: {
                Text(it.title).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink).lineLimit(1)
            }
            .buttonStyle(RowButton())

            Text(it.state)
                .font(.system(size: 11))
                .foregroundStyle(it.kind == 0 ? Theme.blue : (it.kind == 1 ? Theme.orange : Theme.faint))
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)

            Spacer(minLength: 8)

            if it.kind == 0 {
                Button("停止") { pipeline.stop(it.id) }.buttonStyle(GhostButton())
            } else {
                Button("接着写") { pipeline.resume(it.id) }.buttonStyle(GhostButton())
            }
            Button(confirmDelete == it.id ? "确认删除?" : "删除") { askDelete(it.id) }
                .buttonStyle(GhostButton())
                .foregroundStyle(confirmDelete == it.id ? Theme.red : Theme.ink)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 4)
        .background(it.kind == 1 ? Theme.orangeBg.opacity(0.5) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
    }

    func askDelete(_ id: UUID) {
        if confirmDelete == id {
            if pipeline.running[id] != nil { pipeline.stop(id) }
            store.deleteArticle(id)
            confirmDelete = nil
            return
        }
        confirmDelete = id
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if confirmDelete == id { confirmDelete = nil }
        }
    }

    // MARK: 输入行（§2.4）

    var inputRow: some View {
        HStack(spacing: 8) {
            TextEditor(text: $direction)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 6).padding(.vertical, 6)
                .frame(height: 36)
                .background(Theme.sheet, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.rule))
                .overlay(alignment: .topLeading) {
                    if direction.isEmpty {
                        Text("想写什么？留个方向，我按这个提候选")
                            .font(.system(size: 13)).foregroundStyle(Theme.faint)
                            .padding(.leading, 11).padding(.top, 9)
                            .allowsHitTesting(false)
                    }
                }

            Button { run() } label: {
                HStack(spacing: 6) {
                    if busy.label != nil { ProgressView().controlSize(.small) }
                    Text("找候选")
                }
            }
            .buttonStyle(GhostButton())
            .disabled(noModel || busy.label != nil)

            if noModel {
                Text("先到设置接一个模型").font(.system(size: 11)).foregroundStyle(Theme.faint)
            }
        }
        .padding(.bottom, 2)
        .overlay(alignment: .bottomLeading) {
            if let e = busy.error {
                Text(e).font(.system(size: 11)).foregroundStyle(Theme.orange).lineLimit(2).offset(y: 16)
            }
        }
    }

    // MARK: 筛选行（§2.5）

    var filterRow: some View {
        HStack(spacing: 4) {
            pill("全部", on: !onlyNew) { onlyNew = false }
            pill("只看没写过", on: onlyNew) { onlyNew = true }

            Picker("", selection: $domain) {
                Text("全部").tag("全部")
                ForEach(HotCategory.all.map(\.0), id: \.self) { c in Text(c).tag(c) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .font(.system(size: 12))
            .frame(width: 120)

            Spacer()

            Button("拆解一篇爆文") { showBreakdown = true }
                .buttonStyle(LinkButton(color: Theme.blue))
                .font(.system(size: 12))
        }
        .padding(.top, 4)
    }

    func pill(_ t: String, on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(t)
                .font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Theme.blue : Theme.sub)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(on ? Theme.blueBg : Color.clear, in: Capsule())
        }
        .buttonStyle(RowButton())
    }

    // MARK: 题材流（§2.6 / §2.7）

    var flow: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if loadingHot && visibleRows.isEmpty {
                    skeleton
                } else if visibleRows.isEmpty {
                    emptyState
                } else if domain == "全部" {
                    ForEach(visibleRows) { r in FlowRowView(row: r, similar: similarTo(r.title), use: { use(r) }, openSimilar: { openSimilar(r.title) }) }
                } else {
                    sectionTitle("\(domain) · 热榜 \(filteredHotRows.count) 条")
                    ForEach(filteredHotRows) { r in FlowRowView(row: r, similar: similarTo(r.title), use: { use(r) }, openSimilar: { openSimilar(r.title) }) }
                    if !filteredOtherRows.isEmpty {
                        sectionTitle("其他来源 \(filteredOtherRows.count) 条")
                        ForEach(filteredOtherRows) { r in FlowRowView(row: r, similar: similarTo(r.title), use: { use(r) }, openSimilar: { openSimilar(r.title) }) }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .frame(maxHeight: .infinity)
    }

    func sectionTitle(_ t: String) -> some View {
        Text(t).font(.system(size: 11)).foregroundStyle(Theme.faint)
            .padding(.top, 12).padding(.bottom, 4)
    }

    var skeleton: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(hex: "#E6E9F2"))
                    .frame(width: i == 0 ? 420 : (i == 1 ? 320 : 380), height: 14)
                    .padding(.leading, 100)
            }
            Text("正在取今天的热榜…").font(.system(size: 11)).foregroundStyle(Theme.faint)
                .padding(.leading, 100)
        }
        .padding(.top, 16)
    }

    var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "flame").font(.system(size: 26)).foregroundStyle(Theme.faint)
            Text("还没有题材").font(.system(size: 13)).foregroundStyle(Theme.sub)
            Text("点上面「找候选」，或贴一个爆文链接拆解").font(.system(size: 12)).foregroundStyle(Theme.faint)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
    }

    // MARK: 流数据

    var hotItems: [HotArticle] {
        let day = Calendar.current.startOfDay(for: Date())
        var list = store.data.hot.filter { $0.lastSeen >= day }
        list.sort { a, b in
            let ra = a.rank == 0 ? 999 : a.rank
            let rb = b.rank == 0 ? 999 : b.rank
            if ra != rb { return ra < rb }
            return a.readsNum > b.readsNum
        }
        return Array(list.prefix(60))
    }

    var hotRows: [FlowRow] {
        hotItems.map {
            FlowRow(id: "hot-" + $0.id, title: $0.title, source: .hot,
                    reads: $0.reads, category: $0.category, seen: $0.seen, rank: $0.rank)
        }
    }

    var otherRows: [FlowRow] {
        var out: [FlowRow] = []
        let hotTitles = Set(hotItems.map(\.title))
        for idea in store.data.ideas where !idea.used {
            let src: FlowRow.Source = idea.origin == "ai" ? .ai : (idea.origin == "hot" ? .hot : .manual)
            // 同一标题既在 live 热榜、又在 ideas（origin == "hot"）里，只显示一行，优先 live 那条
            if src == .hot && hotTitles.contains(idea.title) { continue }
            out.append(FlowRow(id: "idea-" + idea.id.uuidString, title: idea.title, source: src, ideaId: idea.id))
        }
        for b in store.data.breakdowns {
            for (i, t) in b.fitTopics.enumerated() {
                out.append(FlowRow(id: "bd-\(b.id.uuidString)-\(i)", title: t, source: .breakdown))
            }
        }
        return out
    }

    /// 领域为「全部」时一条流；否则热榜在前、其他来源在后
    var filteredHotRows: [FlowRow] {
        var r = domain == "全部" ? hotRows : hotRows.filter { $0.category == domain }
        if onlyNew { r = r.filter { similarTo($0.title).isEmpty } }
        return r
    }
    var filteredOtherRows: [FlowRow] {
        onlyNew ? otherRows.filter { similarTo($0.title).isEmpty } : otherRows
    }
    var visibleRows: [FlowRow] { filteredHotRows + filteredOtherRows }

    func similarTo(_ title: String) -> String {
        let pool = store.data.articles.flatMap { [$0.displayTitle, $0.topic] }.filter { !$0.isEmpty }
        guard let near = Dedupe.closest(title, in: pool), near.1 >= Dedupe.threshold else { return "" }
        return near.0
    }

    func openSimilar(_ title: String) {
        guard let a = store.data.articles.first(where: {
            Dedupe.similarity(title, $0.displayTitle) >= Dedupe.threshold || Dedupe.similarity(title, $0.topic) >= Dedupe.threshold
        }) else { return }
        open(a.id)
    }

    func use(_ r: FlowRow) {
        if let id = r.ideaId, let i = store.data.ideas.firstIndex(where: { $0.id == id }) {
            store.data.ideas[i].used = true
            store.save()
        }
        pipeline.enqueue(direction: r.title, styleId: store.data.styles.first?.id, count: 1)
    }

    // MARK: 动作

    func loadHot() async {
        loadingHot = true
        await radar.autoRefresh()
        loadingHot = false
        // 只有真去拉过、拉完还是空的，才提示网络
        offline = store.data.auto.hotAuto && !radar.loading && hotItems.isEmpty
    }

    func run() {
        guard !noModel, busy.label == nil else { return }
        let dir = direction.trimmingCharacters(in: .whitespacesAndNewlines)
        let avoid = store.data.styles.map(\.avoid).filter { !$0.isEmpty }.joined(separator: "；")
        let existing = store.data.ideas.map(\.title) + store.data.articles.map(\.displayTitle)
        busy.run("正在想候选…") {
            let r = try await store.runJSON(.topic, IdeasReply.self,
                                            Prompts.ideas(direction: dir, avoid: avoid, existing: existing))
            var pool = existing
            var fresh: [TopicIdea] = []
            for i in r.ideas {
                if let near = Dedupe.closest(i.title, in: pool), near.1 >= Dedupe.threshold { continue }
                pool.append(i.title)
                fresh.append(TopicIdea(title: i.title, angle: i.angle ?? "", origin: "ai"))
            }
            store.data.ideas.insert(contentsOf: fresh, at: 0)
            store.save()
            direction = ""
            Theme.tap()
        }
    }

    // MARK: 拆解抽屉（§2.8）

    var drawer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("拆解一篇爆文").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.ink)
                Spacer()
                Button { showBreakdown = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(LinkButton(color: Theme.faint))
            }

            TextEditor(text: $pasted)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 160)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.rule))
                .overlay(alignment: .topLeading) {
                    if pasted.isEmpty {
                        Text("贴公众号链接，或直接粘正文").font(.system(size: 12))
                            .foregroundStyle(Theme.faint).padding(.leading, 13).padding(.top, 14)
                            .allowsHitTesting(false)
                    }
                }

            HStack(spacing: 10) {
                Button { split() } label: { Text("拆解") }
                    .buttonStyle(PrimaryButton())
                    .disabled(busy.label != nil || pasted.trimmingCharacters(in: .whitespacesAndNewlines).count < 100)
                if busy.label != nil { ProgressView().controlSize(.small) }
                if !note.isEmpty {
                    Text(note).font(.system(size: 12)).foregroundStyle(Theme.orange).lineLimit(2)
                }
                Spacer()
            }
            if let e = busy.error {
                Text(e).font(.system(size: 12)).foregroundStyle(Theme.orange).lineLimit(3)
            }

            if let r = result { resultView(r) }

            Spacer(minLength: 0)

            if result != nil {
                Button { useBreakdown() } label: { Text("用它写一篇").frame(maxWidth: .infinity) }
                    .buttonStyle(PrimaryButton())
            }
        }
        .padding(20)
        .frame(width: 420)
        .frame(maxHeight: .infinity)
        .background(Theme.sheet)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.rule).frame(width: 1) }
    }

    func resultView(_ r: BreakdownReply) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let v = r.titleFormula, !v.isEmpty { line("标题公式", v) }
                if let v = r.hook, !v.isEmpty { line("开头手法", v) }
                if let v = r.structure, !v.isEmpty { listLine("结构", v) }
                if let v = r.techniques, !v.isEmpty { listLine("可复用技巧", v) }
                if let v = r.fitTopics, !v.isEmpty { listLine("适合套用的题材", v) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func line(_ h: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(h).font(.system(size: 11)).foregroundStyle(Theme.faint)
            Text(v).font(.system(size: 12)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func listLine(_ h: String, _ v: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(h).font(.system(size: 11)).foregroundStyle(Theme.faint)
            ForEach(Array(v.enumerated()), id: \.offset) { _, s in
                Text("· " + s).font(.system(size: 12)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func split() {
        let t = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 100 else { note = "至少贴 100 字才拆得出来"; return }
        guard !noModel else { note = "先到设置接一个模型"; return }
        note = ""
        let title = String(t.prefix(20))
        busy.run("正在拆结构…") {
            let r = try await store.runJSON(.review, BreakdownReply.self,
                                            Prompts.breakdown(title: title, text: t))
            result = r
            // 拆解产出进库，fitTopics 自动进题材流（来源「拆解来的」）
            var b = Breakdown()
            b.sourceTitle = title
            b.titleFormula = r.titleFormula ?? ""; b.hook = r.hook ?? ""
            b.structure = r.structure ?? []; b.techniques = r.techniques ?? []
            b.ending = r.ending ?? ""; b.fitTopics = r.fitTopics ?? []
            store.data.breakdowns.insert(b, at: 0)
            store.save()
            Theme.tap()
        }
    }

    func useBreakdown() {
        guard let r = result, let t = r.fitTopics?.first, !t.isEmpty else { return }
        showBreakdown = false
        pipeline.enqueue(direction: t, styleId: store.data.styles.first?.id, count: 1)
    }
}

// MARK: 流的一行

struct FlowRow: Identifiable {
    enum Source { case hot, ai, manual, breakdown }
    var id: String
    var title: String
    var source: Source
    var reads = ""
    var category = ""
    var seen = 0
    var rank = 0
    var ideaId: UUID?
}

struct FlowRowView: View {
    let row: FlowRow
    let similar: String
    let use: () -> Void
    let openSimilar: () -> Void

    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if row.source == .hot {
                Text(row.rank == 0 ? "·" : "\(row.rank)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(row.rank > 0 && row.rank <= 3 ? .white : Theme.sub)
                    .frame(width: 20, height: 20)
                    .background(row.rank > 0 && row.rank <= 3 ? Theme.orange : Color(hex: "#EEF0F3"),
                                in: RoundedRectangle(cornerRadius: 5))
            } else {
                Color.clear.frame(width: 20, height: 20)
            }

            sourceTag.frame(width: 72, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(row.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(similar.isEmpty ? Theme.ink : Theme.faint)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !sub.isEmpty {
                    HStack(spacing: 0) {
                        Text(sub).font(.system(size: 11)).foregroundStyle(Theme.sub)
                        if !similar.isEmpty {
                            Text(" · ").font(.system(size: 11)).foregroundStyle(Theme.faint)
                            Text("写过类似的").font(.system(size: 11)).foregroundStyle(Theme.orange)
                        }
                    }
                    .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            if hover {
                Button("用这个", action: use).buttonStyle(GhostButton())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 64, alignment: .top)
        .background(hover ? Theme.bg : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { if !similar.isEmpty { openSimilar() } }
    }

    var sub: String {
        var parts: [String] = []
        if row.source == .hot {
            if !row.category.isEmpty { parts.append(row.category) }
            if !row.reads.isEmpty { parts.append(row.reads) }
            if row.seen > 1 { parts.append("上榜 \(row.seen) 天") }
        }
        return parts.joined(separator: " · ")
    }

    var sourceTag: some View {
        let (text, color): (String, Color) = {
            switch row.source {
            case .hot: return ("热榜", Theme.orange)
            case .ai: return ("AI 候选", Theme.blue)
            case .manual: return ("我记的", Theme.faint)
            case .breakdown: return ("拆解来的", Theme.violet)
            }
        }()
        return Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .overlay(Capsule().stroke(color, lineWidth: 1))
            .fixedSize()
    }
}
