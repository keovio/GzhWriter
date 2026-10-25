import SwiftUI

// MARK: 工作台

struct WorkbenchView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var pipeline: Pipeline
    var open: (UUID) -> Void

    @State private var direction = ""
    @State private var styleId: UUID?
    @State private var count = 1
    @State private var showAllHot = false

    var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<11: return "早上好"
        case 11..<14: return "中午好"
        case 14..<18: return "下午好"
        default: return "晚上好"
        }
    }

    var body: some View {
        Page {
            PageHeader(title: greeting, subtitle: store.data.connections.isEmpty
                       ? "先到「模型与分工」接一个模型，就能开始一键成稿。"
                       : "看看今天写到哪了。") {
                if pipeline.queued > 0 || !pipeline.running.isEmpty {
                    Chip(text: "后台在写 \(pipeline.running.count + pipeline.queued) 篇", fg: Theme.blue, bg: Theme.blueBg)
                }
            }
            stats
            composer
            if !pipeline.running.isEmpty || pipeline.queued > 0 { runningCard }
            if let e = pipeline.lastError { errorCard(e) }
            HStack(alignment: .top, spacing: 20) {
                recent.frame(maxWidth: .infinity)
                hotCard.frame(width: 360)
            }
        }
        .task {
            if styleId == nil { styleId = store.data.auto.dailyStyleId ?? store.data.styles.first?.id }
            if pipeline.hot.isEmpty { await pipeline.refreshHot() }
        }
    }

    // MARK: 数据块

    var stats: some View {
        let cal = Calendar.current
        let today = store.data.articles.filter { cal.isDateInToday($0.created) }
        let week = store.data.articles.filter { cal.isDate($0.created, equalTo: Date(), toGranularity: .weekOfYear) }
        let scored = store.data.articles.compactMap { $0.review?.total }
        let avg = scored.isEmpty ? 0 : scored.reduce(0, +) / scored.count
        let ready = store.data.articles.filter { $0.stage == .layout }.count
        return HStack(spacing: 14) {
            tile("今日成稿", "\(today.count)", "篇", "\(today.reduce(0) { $0 + $1.wordCount }) 字")
            tile("本周", "\(week.count)", "篇", "\(week.reduce(0) { $0 + $1.wordCount }) 字")
            tile("平均分", scored.isEmpty ? "—" : "\(avg)", scored.isEmpty ? "" : "分", "及格线 \(store.data.auto.passScore)")
            tile("待发布", "\(ready)", "篇", "已排好版")
        }
    }

    func tile(_ label: String, _ value: String, _ unit: String, _ foot: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.sub)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(Theme.ink)
                Text(unit).font(.system(size: 12)).foregroundStyle(Theme.sub)
            }
            Text(foot).font(.system(size: 11)).foregroundStyle(Theme.faint)
        }
        .card(padding: 16)
    }

    // MARK: 一键成稿

    var composer: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionTitle(text: "写一篇", hint: "留空就按赛道和今日热榜自动选题")
                Spacer()
            }
            TextField("想写什么？比如：在职备考公务员，每天两小时怎么安排", text: $direction, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(2...4)
                .padding(14)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onSubmit(go)
            HStack(spacing: 18) {
                labeled("账号") {
                    Picker("", selection: $styleId) {
                        ForEach(store.data.styles) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden().frame(width: 150)
                }
                labeled("篇数") {
                    HStack(spacing: 0) {
                        ForEach([1, 3, 5], id: \.self) { n in
                            Button { count = n } label: {
                                Text("\(n)").font(.system(size: 12, weight: .medium))
                                    .frame(width: 32, height: 24)
                                    .foregroundStyle(count == n ? .white : Theme.ink)
                                    .background(count == n ? Theme.navy : Color.clear)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(Theme.sheet)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.rule))
                }
                Text("约 \(store.data.auto.targetWords) 字 · 不到 \(store.data.auto.passScore) 分自动返修")
                    .font(.system(size: 12)).foregroundStyle(Theme.faint)
                Spacer()
                Button(action: go) {
                    HStack(spacing: 6) { Image(systemName: "sparkles"); Text("开始生产") }
                }
                .buttonStyle(PrimaryButton(large: true))
                .disabled(store.data.connections.isEmpty)
            }
            HStack(spacing: 6) {
                ForEach(["选题", "大纲", "正文", "审稿", "返修", "排版"], id: \.self) { s in
                    Chip(text: s)
                    if s != "排版" { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(Theme.faint) }
                }
                Spacer()
                Text("只生成草稿，发布由你来").font(.system(size: 11)).foregroundStyle(Theme.faint)
            }
        }
        .card()
    }

    func labeled<C: View>(_ t: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 8) {
            Text(t).font(.system(size: 12)).foregroundStyle(Theme.sub)
            c()
        }
    }

    func go() {
        pipeline.enqueue(direction: direction.trimmingCharacters(in: .whitespacesAndNewlines), styleId: styleId, count: count)
        direction = ""
    }

    // MARK: 正在写

    var runningCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(text: "正在生产")
                if pipeline.queued > 0 { Chip(text: "排队 \(pipeline.queued)") }
            }
            ForEach(Array(pipeline.running.keys), id: \.self) { id in
                Button { open(id) } label: {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text(store.article(id)?.displayTitle ?? "新稿件").font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.ink).lineLimit(1)
                        Spacer()
                        Text(pipeline.running[id] ?? "").font(.system(size: 12)).foregroundStyle(Theme.blue).lineLimit(1)
                        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.faint)
                    }
                    .padding(12)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .card()
    }

    func errorCard(_ e: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange)
            Text(e).font(.system(size: 12)).foregroundStyle(Theme.ink).textSelection(.enabled)
            Spacer()
            Button("知道了") { pipeline.lastError = nil }.buttonStyle(LinkButton())
        }
        .padding(14)
        .background(Theme.orangeBg, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: 最近稿件

    var recent: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "最近稿件")
            if store.data.articles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text").font(.system(size: 26)).foregroundStyle(Theme.faint)
                    Text("还没有稿件，点上面「开始生产」写第一篇").font(.system(size: 13)).foregroundStyle(Theme.sub)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 30)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(store.data.articles.prefix(8).enumerated()), id: \.element.id) { i, a in
                        if i > 0 { Divider().overlay(Theme.rule) }
                        ArticleRow(article: a, running: pipeline.running[a.id]) { open(a.id) }
                    }
                }
            }
        }
        .card()
    }

    // MARK: 热榜

    var hotCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(text: "今日热榜", hint: "选题参考")
                Spacer()
                Button { Task { await pipeline.refreshHot() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(LinkButton(color: Theme.sub))
            }
            if pipeline.hot.isEmpty {
                Text("暂时拉不到热榜").font(.system(size: 12)).foregroundStyle(Theme.sub).padding(.vertical, 20)
            }
            ForEach(Array(pipeline.hot.prefix(showAllHot ? 40 : 12).enumerated()), id: \.element.id) { i, h in
                HotRow(index: i, item: h, disabled: store.data.connections.isEmpty) {
                    pipeline.enqueue(direction: "结合热点「\(h.title)」写一篇和我赛道相关的文章", styleId: styleId)
                }
            }
            if pipeline.hot.count > 12 {
                Button(showAllHot ? "收起" : "展开全部 \(pipeline.hot.count) 条") { showAllHot.toggle() }
                    .buttonStyle(LinkButton())
            }
        }
        .card()
    }
}

struct HotRow: View {
    let index: Int
    let item: HotItem
    let disabled: Bool
    let write: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(index < 3 ? .white : Theme.sub)
                .frame(width: 20, height: 20)
                .background(index < 3 ? Theme.orange : Color(hex: "#EEF0F3"), in: RoundedRectangle(cornerRadius: 5))
            Text(item.title).font(.system(size: 13)).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer(minLength: 4)
            if hover && !disabled {
                Button("写这个", action: write).buttonStyle(LinkButton())
            } else {
                Text(item.source).font(.system(size: 11)).foregroundStyle(Theme.faint)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

struct ArticleRow: View {
    let article: Article
    let running: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8).fill(Theme.blueBg)
                    .frame(width: 34, height: 34)
                    .overlay(Image(systemName: running != nil ? "hourglass" : (article.stage == .layout ? "checkmark" : "doc.text"))
                        .font(.system(size: 13)).foregroundStyle(Theme.blue))
                VStack(alignment: .leading, spacing: 3) {
                    Text(article.displayTitle).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(running ?? statusText).foregroundStyle(running != nil ? Theme.blue : Theme.sub)
                        Text("·").foregroundStyle(Theme.faint)
                        Text("\(article.wordCount) 字")
                        Text("·").foregroundStyle(Theme.faint)
                        Text(article.updated, style: .relative)
                    }
                    .font(.system(size: 11)).foregroundStyle(Theme.faint)
                }
                Spacer()
                if article.auto { Chip(text: "一键成稿") }
                if let s = article.review?.total, running == nil { ScoreBadge(score: s) }
            }
            .padding(.vertical, 10).padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Theme.bg : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    var statusText: String {
        switch article.stage {
        case .layout: return "已完成，待发布"
        case .review: return "待审稿"
        default: return "写作中 · \(article.stage.name)"
        }
    }
}

// MARK: 稿件库

struct LibraryView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var pipeline: Pipeline
    var open: (UUID) -> Void
    @State private var query = ""
    @State private var filter = 0      // 0 全部 1 待发布 2 写作中

    var items: [Article] {
        store.data.articles.filter { a in
            (query.isEmpty || a.displayTitle.localizedCaseInsensitiveContains(query) || a.topic.localizedCaseInsensitiveContains(query))
            && (filter == 0 || (filter == 1 ? a.stage == .layout : a.stage != .layout))
        }
    }

    var body: some View {
        Page {
            PageHeader(title: "稿件库", subtitle: "写过的文章都在这里，自动选题会避开这些题目。") {
                Button { open(store.newArticle()) } label: { Label("新建", systemImage: "plus") }
                    .buttonStyle(GhostButton())
            }
            HStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.faint)
                    TextField("搜索标题或选题", text: $query).textFieldStyle(.plain)
                }
                .fieldBox()
                .frame(maxWidth: 320)
                ForEach(Array(["全部", "待发布", "写作中"].enumerated()), id: \.offset) { i, t in
                    Button(t) { filter = i }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: filter == i ? .semibold : .regular))
                        .foregroundStyle(filter == i ? Theme.blue : Theme.sub)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(filter == i ? Theme.blueBg : Color.clear, in: Capsule())
                }
                Spacer()
                Text("\(items.count) 篇").font(.system(size: 12)).foregroundStyle(Theme.faint)
            }
            VStack(spacing: 0) {
                if items.isEmpty {
                    Text("没有符合条件的稿件").font(.system(size: 13)).foregroundStyle(Theme.sub)
                        .frame(maxWidth: .infinity).padding(.vertical, 40)
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { i, a in
                    if i > 0 { Divider().overlay(Theme.rule) }
                    ArticleRow(article: a, running: pipeline.running[a.id]) { open(a.id) }
                        .contextMenu {
                            Button("复制富文本") { Layout.copyRichText(a, signature: store.style(a.styleId)?.signature ?? "") }
                            Divider()
                            Button("删除", role: .destructive) { store.deleteArticle(a.id) }
                        }
                }
            }
            .card(padding: 12)
        }
    }
}

// MARK: 自动化设置

struct AutoSettingsView: View {
    @EnvironmentObject var store: Store

    func b<T>(_ kp: WritableKeyPath<AutoSettings, T>) -> Binding<T> {
        Binding(get: { store.data.auto[keyPath: kp] }, set: { store.data.auto[keyPath: kp] = $0; store.save() })
    }

    var dailyTime: Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: store.data.auto.dailyHour, minute: store.data.auto.dailyMinute, second: 0, of: Date()) ?? Date()
        }, set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            store.data.auto.dailyHour = c.hour ?? 8
            store.data.auto.dailyMinute = c.minute ?? 0
            store.save()
        })
    }

    var body: some View {
        Page(maxWidth: 820) {
            PageHeader(title: "自动化", subtitle: "一键成稿和定时生产的规则。所有稿件只存在本机，发布由你来。")
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(text: "写作与审稿").padding(.bottom, 6)
                SettingRow(label: "目标字数", hint: "整篇大约多少字") {
                    Stepper("\(store.data.auto.targetWords) 字", value: b(\.targetWords), in: 600...4000, step: 100).fixedSize()
                }
                Divider()
                SettingRow(label: "及格线", hint: "五个维度合计，低于这个分数自动返修") {
                    Stepper("\(store.data.auto.passScore) 分", value: b(\.passScore), in: 50...95, step: 5).fixedSize()
                }
                Divider()
                SettingRow(label: "最多返修", hint: "一直不及格就用分数最高的那版") {
                    Stepper("\(store.data.auto.maxRounds) 轮", value: b(\.maxRounds), in: 0...4).fixedSize()
                }
                Divider()
                SettingRow(label: "参考热榜", hint: "自动选题时参考头条、百度热榜，只选和赛道相关的") {
                    Toggle("", isOn: b(\.useHot)).toggleStyle(.switch).labelsHidden()
                }
            }
            .card()

            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(text: "定时生产").padding(.bottom, 6)
                SettingRow(label: "每天自动写一篇", hint: "到点写好放进稿件库并发通知。需要软件开着，可以最小化。") {
                    Toggle("", isOn: b(\.dailyEnabled)).toggleStyle(.switch).labelsHidden()
                }
                Divider()
                SettingRow(label: "时间") {
                    DatePicker("", selection: dailyTime, displayedComponents: .hourAndMinute).labelsHidden().fixedSize()
                }
                .disabled(!store.data.auto.dailyEnabled)
                Divider()
                SettingRow(label: "用哪个账号") {
                    Picker("", selection: b(\.dailyStyleId)) {
                        Text("默认").tag(UUID?.none)
                        ForEach(store.data.styles) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden().frame(width: 180)
                }
                .disabled(!store.data.auto.dailyEnabled)
            }
            .card()
        }
    }
}
