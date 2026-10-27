import SwiftUI

struct ArticleRow: View {
    @EnvironmentObject var store: Store
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

    /// 这个平台有没有号存过草稿
    func drafted(_ platform: String) -> Bool {
        store.accounts(on: platform).contains { article.drafts[$0.id.uuidString] != nil }
            || (platform == "wechat" && !article.wechatDraft.isEmpty)
    }

    /// 每个平台一个小点：浅色=有版本，空心圈=存了草稿，实心=发了
    var platformDots: some View {
        let keys = ["wechat"] + Platform.allCases.filter { $0 != .wechat }.map(\.rawValue)
        return HStack(spacing: 3) {
            ForEach(keys, id: \.self) { k in
                let p = Platform.of(k)!
                let has = k == "wechat" ? article.stage == .layout : article.variants[k] != nil
                let done = k == "wechat" ? article.published : (article.variants[k]?.posted ?? false)
                let dr = !done && drafted(k)
                if has || dr {
                    Circle().fill(done ? p.color : p.color.opacity(dr ? 0.1 : 0.25))
                        .overlay(Circle().stroke(dr ? p.color : Color.clear, lineWidth: 1.5))
                        .frame(width: 7, height: 7)
                        .help(p.name + (done ? "已发" : dr ? "已存草稿，还没发" : "未发"))
                }
            }
        }
    }

    var statusText: String {
        switch article.stage {
        case .layout:
            return article.drafts.isEmpty && article.wechatDraft.isEmpty ? "已完成，待发布" : "已存草稿，待你去平台发布"
        case .review: return "待审稿"
        default: return "写作中 · \(article.stage.name)"
        }
    }
}

// MARK: 稿件库

/// 一期未挂载（侧栏只有 工作台/稿件/设置）。内含 BatchBar → Batch.schedule → PublishPlan.schedule，会真写 scheduled。二期若要复用，必须先删「排进日历」按钮（Batch.swift:243）。
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

/// 一期未挂载。内含「定时生产」整段与 dailyEnabled 开关（:230-249）。二期若要复用，必须先删该段，否则定时生产复活。
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
