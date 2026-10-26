import SwiftUI

// MARK: 工作台

struct WorkbenchView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var pipeline: Pipeline
    var open: (UUID) -> Void

    @State private var direction = ""
    @State private var styleId: UUID?
    @State private var count = 1
    @State private var refId: UUID?
    @State private var accountId: UUID?
    var account: Account? { store.account(accountId) ?? store.data.accounts.first }
    var target: String { account?.platform ?? "wechat" }
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
                       ? "先到「设置 → 模型」接一个模型，就能开始一键成稿。"
                       : "看看今天写到哪了。") {
                if pipeline.queued > 0 || !pipeline.running.isEmpty {
                    Chip(text: "后台在写 \(pipeline.running.count + pipeline.queued) 篇", fg: Theme.blue, bg: Theme.blueBg)
                }
            }
            stats
            composer
            if !pipeline.running.isEmpty || pipeline.queued > 0 { runningCard }
            if !pipeline.failedArticles.isEmpty { failedCard }
            HStack(alignment: .top, spacing: 20) {
                recent.frame(maxWidth: .infinity)
                hotCard.frame(width: 360)
            }
        }
        .task {
            if styleId == nil { styleId = store.data.auto.dailyStyleId ?? store.data.styles.first?.id }
            if accountId == nil { accountId = store.data.accounts.first { $0.styleId == styleId }?.id ?? store.data.accounts.first?.id }
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
            tile(Theme.navy, "doc.text.fill", "今日成稿", "\(today.count)", "篇", "\(today.reduce(0) { $0 + $1.wordCount }) 字")
            tile(Theme.violet, "calendar", "本周", "\(week.count)", "篇", "\(week.reduce(0) { $0 + $1.wordCount }) 字")
            tile(Theme.green, "star.fill", "平均分", scored.isEmpty ? "—" : "\(avg)", scored.isEmpty ? "" : "分", "及格线 \(store.data.auto.passScore)")
            tile(Theme.orange, "paperplane.fill", "待发布", "\(ready)", "篇", "已排好版")
        }
    }

    func tile(_ accent: Color, _ icon: String, _ label: String, _ value: String, _ unit: String, _ foot: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22).background(accent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.sub)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(Theme.ink)
                Text(unit).font(.system(size: 12)).foregroundStyle(Theme.sub)
            }
            Text(foot).font(.system(size: 11)).foregroundStyle(Theme.faint)
        }
        .card(padding: 16)
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: 2).fill(accent).frame(height: 3).padding(.horizontal, 16)
        }
    }

    // MARK: 一键成稿

    var composer: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                SectionTitle(text: "写一篇", hint: "留空自动选题")
                Spacer()
                let labels = Role.allCases.map { store.modelLabel($0) }
                if Set(labels).count == 1 {
                    ModelTag(text: labels[0], prefix: "用")
                } else {
                    ForEach(Role.allCases) { RoleModelTag(role: $0) }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text("发到").font(.system(size: 12)).foregroundStyle(Theme.sub).fixedSize()
                    ForEach(store.data.accounts) { acc in
                        let on = account?.id == acc.id
                        let p = Platform.of(acc.platform)
                        Button { accountId = acc.id } label: {
                            HStack(spacing: 5) {
                                Text(p?.name ?? "").font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(on ? Color.white.opacity(0.85) : (p?.color ?? Theme.sub))
                                Text(acc.name).font(.system(size: 12, weight: on ? .semibold : .regular))
                                    .foregroundStyle(on ? Color.white : Theme.ink)
                            }
                            .fixedSize()
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(on ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.bg), in: Capsule())
                        }
                        .buttonStyle(RowButton())
                    }
                }
            }
            TextField("想写什么？比如：在职备考公务员，每天两小时怎么安排", text: $direction, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(2...4)
                .padding(14)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onSubmit(go)
            HStack(spacing: 18) {
                labeled("篇数") {
                    HStack(spacing: 0) {
                        ForEach([1, 3, 5], id: \.self) { n in
                            Button { count = n } label: {
                                Text("\(n)").font(.system(size: 12, weight: .medium))
                                    .frame(width: 32, height: 24)
                                    .foregroundStyle(count == n ? .white : Theme.ink)
                                    .background(count == n ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color.clear))
                            }
                            .buttonStyle(RowButton())
                        }
                    }
                    .background(Theme.sheet)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.rule))
                }
                if !store.data.breakdowns.isEmpty && target == "wechat" {
                    labeled("参考写法") {
                        Picker("", selection: $refId) {
                            Text("不参考").tag(UUID?.none)
                            ForEach(store.data.breakdowns) { Text($0.sourceTitle).tag(Optional($0.id)) }
                        }
                        .labelsHidden().frame(width: 150)
                    }
                }
                Text(targetHint)
                    .lineLimit(2).frame(maxWidth: 260, alignment: .leading)
                    .font(.system(size: 12)).foregroundStyle(Theme.faint)
                Spacer()
                Button(action: go) {
                    HStack(spacing: 6) { Image(systemName: "sparkles"); Text("开始生产") }
                }
                .buttonStyle(PrimaryButton(large: true))
                .disabled(store.data.connections.isEmpty)
            }
        }
        .card()
    }

    var targetHint: String {
        switch target {
        case "xiaohongshu": return "300–600 字笔记，直接写"
        case "weibo": return "140–300 字短帖，直接写"
        case "wechat": return "约 \(store.data.auto.targetWords) 字长文，写完顺带出其他平台版"
        default: return "约 \(store.data.auto.targetWords) 字长文，按\(Platform.of(target)?.name ?? "")的规则出标题和标签"
        }
    }

    func labeled<C: View>(_ t: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 8) {
            Text(t).font(.system(size: 12)).foregroundStyle(Theme.sub)
                .lineLimit(1).fixedSize()
            c()
        }
    }

    func go() {
        pipeline.enqueue(direction: direction.trimmingCharacters(in: .whitespacesAndNewlines), styleId: account?.styleId ?? styleId, count: count,
                         refId: target == "wechat" ? refId : nil, platform: target, accountId: account?.id)
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
                    RunLog(articleId: id, compact: true).contentShape(Rectangle())
                }
                .buttonStyle(RowButton())
            }
        }
        .card()
    }

    var failedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(text: "停下来的稿件", hint: "已写好的部分都留着，点「接着写」从断点继续")
                Spacer()
                if pipeline.failedArticles.count > 1 {
                    Button("全部接着写") { for a in pipeline.failedArticles { pipeline.resume(a.id) } }
                        .buttonStyle(GhostButton())
                }
            }
            ForEach(pipeline.failedArticles) { a in
                VStack(alignment: .leading, spacing: 6) {
                    Button(a.displayTitle) { open(a.id) }.buttonStyle(LinkButton(color: Theme.ink))
                    RunLog(articleId: a.id, compact: true)
                }
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
                platformDots
                if article.auto { Chip(text: "一键成稿") }
                if let s = article.review?.total, running == nil { ScoreBadge(score: s) }
            }
            .padding(.vertical, 10).padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Theme.bg : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButton())
        .onHover { hover = $0 }
    }

    /// 每个平台一个小点：灰=没版本，浅色=有版本没发，实心=发了
    var platformDots: some View {
        let keys = ["wechat"] + Platform.allCases.filter { $0 != .wechat }.map(\.rawValue)
        return HStack(spacing: 3) {
            ForEach(keys, id: \.self) { k in
                let p = Platform.of(k)!
                let has = k == "wechat" ? article.stage == .layout : article.variants[k] != nil
                let done = k == "wechat" ? article.published : (article.variants[k]?.posted ?? false)
                if has {
                    Circle().fill(done ? p.color : p.color.opacity(0.25)).frame(width: 7, height: 7)
                        .help(p.name + (done ? "已发" : "未发"))
                }
            }
        }
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
    @State private var accountFilter: UUID?
    @State private var selecting = false
    @State private var selected = Set<UUID>()

    var items: [Article] {
        store.data.articles.filter { a in
            (query.isEmpty || a.displayTitle.localizedCaseInsensitiveContains(query) || a.topic.localizedCaseInsensitiveContains(query))
            && (filter == 0 || (filter == 1 ? a.stage == .layout : a.stage != .layout))
            && (accountFilter == nil || a.accountId == accountFilter)
        }
    }

    var body: some View {
        Page {
            PageHeader(title: "稿件库", subtitle: "写过的文章都在这里，自动选题会避开这些题目。") {
                HStack(spacing: 8) {
                    Button { selecting.toggle(); if !selecting { selected = [] } } label: {
                        Label(selecting ? "退出批量" : "批量", systemImage: "checklist")
                    }
                    .buttonStyle(GhostButton())
                    Button { open(store.newArticle()) } label: { Label("新建", systemImage: "plus") }
                        .buttonStyle(GhostButton())
                }
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
                        .buttonStyle(RowButton())
                        .font(.system(size: 12, weight: filter == i ? .semibold : .regular))
                        .foregroundStyle(filter == i ? Theme.blue : Theme.sub)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(filter == i ? Theme.blueBg : Color.clear, in: Capsule())
                }
                if store.data.accounts.count > 1 {
                    Picker("", selection: $accountFilter) {
                        Text("全部账号").tag(UUID?.none)
                        ForEach(store.data.accounts) { acc in
                            Text("\(Platform.of(acc.platform)?.name ?? "")·\(acc.name)").tag(Optional(acc.id))
                        }
                    }
                    .labelsHidden().frame(width: 170)
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
                    HStack(spacing: 4) {
                        if selecting {
                            Image(systemName: selected.contains(a.id) ? "checkmark.square.fill" : "square")
                                .font(.system(size: 16))
                                .foregroundStyle(selected.contains(a.id) ? Theme.blue : Theme.faint)
                                .padding(.leading, 6)
                        }
                        ArticleRow(article: a, running: pipeline.running[a.id]) {
                            if selecting {
                                if selected.contains(a.id) { selected.remove(a.id) } else { selected.insert(a.id) }
                            } else { open(a.id) }
                        }
                    }
                        .contextMenu {
                            Button("复制富文本") { Layout.copyRichText(a, signature: store.style(a.styleId)?.signature ?? "") }
                            Divider()
                            Button("删除", role: .destructive) { store.deleteArticle(a.id) }
                        }
                }
            }
            .card(padding: 12)
            if selecting { Color.clear.frame(height: 110) }
        }
        .overlay(alignment: .bottom) {
            if selecting {
                BatchBar(selected: $selected, visible: items.map(\.id)) { selecting = false; selected = [] }
                    .padding(.horizontal, 24).padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: selecting)
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
                Divider()
                SettingRow(label: "自动改敏感词", hint: "审完稿扫一遍极限词、收益承诺、诱导分享、站外引流，有就让 AI 改掉") {
                    Toggle("", isOn: b(\.autoCompliance)).toggleStyle(.switch).labelsHidden()
                }
                Divider()
                SettingRow(label: "自动选标题", hint: "出 5 个不同风格的标题打分，换上分数最高的；稿件里可以再换") {
                    Toggle("", isOn: b(\.autoTitle)).toggleStyle(.switch).labelsHidden()
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

// MARK: 运行日志（编辑器顶部、工作台都用）

struct RunLog: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var pipeline: Pipeline
    let articleId: UUID
    var compact = false
    @State private var all = false

    var body: some View {
        let a = store.article(articleId)
        let lines = a?.log ?? []
        let step = pipeline.running[articleId]
        let failed = a?.failed ?? ""
        let shown = all ? lines : Array(lines.suffix(compact ? 3 : 8))
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if step != nil {
                    ProgressView().controlSize(.small)
                    Text("正在写：\(step!)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.blue)
                    if let m = store.calling { ModelTag(text: m) }
                } else if !failed.isEmpty {
                    Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(Theme.orange)
                    Text("停下了").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.orange)
                } else {
                    Image(systemName: "list.bullet.rectangle").foregroundStyle(Theme.sub)
                    Text("运行日志").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                }
                Spacer()
                if lines.count > shown.count || all {
                    Button(all ? "收起" : "全部 \(lines.count) 条") { all.toggle() }.buttonStyle(LinkButton(color: Theme.sub))
                }
                if !lines.isEmpty {
                    Button("复制日志") { Publisher.copyText(lines.joined(separator: "\n")) }.buttonStyle(LinkButton(color: Theme.sub))
                }
                if step == nil && !failed.isEmpty {
                    Button { pipeline.resume(articleId) } label: {
                        HStack(spacing: 4) { Image(systemName: "play.fill"); Text("接着写") }
                    }
                    .buttonStyle(PrimaryButton())
                }
            }
            if !failed.isEmpty && step == nil {
                Text(failed).font(.system(size: 12)).foregroundStyle(Theme.ink).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.orangeBg, in: RoundedRectangle(cornerRadius: 8))
            }
            if !shown.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(RunLog.isError(line) ? Theme.orange : Theme.sub)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .textSelection(.enabled)
            }
        }
        .padding(14)
        .background(step != nil ? Theme.blueBg : (failed.isEmpty ? Color.white : Color.white),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(!failed.isEmpty && step == nil ? Theme.orange.opacity(0.5) : Theme.rule, lineWidth: 1))
    }

    static func isError(_ line: String) -> Bool {
        line.contains("出错") || line.contains("失败") || line.contains("停下")
    }
}


// MARK: 直接写的小红书 / 微博

struct ShortArticleView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var pipeline: Pipeline
    let articleId: UUID
    var close: () -> Void

    var body: some View {
        let a = store.article(articleId) ?? Article()
        Page(maxWidth: 820) {
            HStack(spacing: 10) {
                Button { close() } label: { HStack(spacing: 4) { Image(systemName: "chevron.left"); Text("返回") } }
                    .buttonStyle(LinkButton(color: Theme.sub))
                PlatformTag(key: a.primary)
                Text(a.displayTitle).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer()
            }
            if !a.topic.isEmpty && a.topic != "自动选题中…" {
                VStack(alignment: .leading, spacing: 4) {
                    Text("选题：" + a.topic).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                    if !a.viewpoint.isEmpty { Text(a.viewpoint).font(.system(size: 12)).foregroundStyle(Theme.sub) }
                }
                .card(padding: 14)
            }
            if pipeline.running[articleId] != nil || !a.failed.isEmpty || a.variants[a.primary] == nil {
                RunLog(articleId: articleId)
            }
            if a.variants[a.primary] != nil {
                DistributeCard(articleId: articleId, only: Platform.of(a.primary))
            }
        }
    }
}
