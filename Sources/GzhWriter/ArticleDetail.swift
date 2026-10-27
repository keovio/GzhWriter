import SwiftUI

// MARK: 稿件页（真分栏，规格 `docs/design/01-界面规格.md` §3）

struct ArticlePage: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var pipeline: Pipeline

    /// 右栏选中的稿件（局部状态，不再是一个整页 pane）
    @Binding var selected: UUID?

    @State private var query = ""
    @State private var filter = 0          // 0 全部 / 1 待发 / 2 已发

    var items: [Article] {
        store.data.articles.filter { a in
            (query.isEmpty
             || a.displayTitle.localizedCaseInsensitiveContains(query)
             || a.topic.localizedCaseInsensitiveContains(query))
            && (filter == 0 || (filter == 1 ? !a.published : a.published))
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            leftList
            rightDetail
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(maxWidth: 800, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg)
    }

    // MARK: 左列表（§3.2）

    var leftList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.faint)
                TextField("搜索标题或选题", text: $query).textFieldStyle(.plain).font(.system(size: 13))
            }
            .fieldBox()
            .frame(height: 32)

            HStack(spacing: 4) {
                pill("全部", 0)
                pill("待发", 1)
                pill("已发", 2)
                Spacer()
            }

            ScrollView {
                VStack(spacing: 2) {
                    if items.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "doc.text").font(.system(size: 24)).foregroundStyle(Theme.faint)
                            Text("还没有稿件").font(.system(size: 13)).foregroundStyle(Theme.sub)
                            Text("到「工作台」挑一个题材，写完就在这").font(.system(size: 12)).foregroundStyle(Theme.faint)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                    ForEach(items) { a in
                        listRow(a)
                    }
                }
            }
        }
        .frame(width: 320)
    }

    func pill(_ t: String, _ i: Int) -> some View {
        Button { filter = i } label: {
            Text(t)
                .font(.system(size: 12, weight: filter == i ? .semibold : .regular))
                .foregroundStyle(filter == i ? Theme.blue : Theme.sub)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(filter == i ? Theme.blueBg : Color.clear, in: Capsule())
        }
        .buttonStyle(RowButton())
    }

    func listRow(_ a: Article) -> some View {
        let on = selected == a.id
        return Button { selected = a.id } label: {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(on ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color.clear))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
                RoundedRectangle(cornerRadius: 8).fill(Theme.blueBg)
                    .frame(width: 30, height: 30)
                    .overlay(Image(systemName: "doc.text").font(.system(size: 12)).foregroundStyle(Theme.blue))
                VStack(alignment: .leading, spacing: 3) {
                    Text(a.displayTitle).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.ink).lineLimit(1)
                    HStack(spacing: 5) {
                        BadgeView(a: a, running: pipeline.running[a.id], size: 11, height: 18)
                        Text("· \(a.wordCount) 字").font(.system(size: 11)).foregroundStyle(Theme.sub)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.trailing, 8)
            .frame(height: 52)
            .background(on ? Theme.blueBg.opacity(0.55) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButton())
    }

    // MARK: 右详情（§3.4）

    @ViewBuilder var rightDetail: some View {
        if let id = selected, let a = store.article(id) {
            ArticleDetail(articleId: id, article: a)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.text").font(.system(size: 30)).foregroundStyle(Theme.faint)
                Text("左边选一篇").font(.system(size: 13)).foregroundStyle(Theme.sub)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: 徽标（§3.3，四种，先命中先生效）

struct BadgeView: View {
    let a: Article
    let running: String?
    var size: CGFloat = 11
    var height: CGFloat = 18

    var spec: (text: String, fg: Color, bg: Color) {
        if running != nil { return ("生成中", Theme.blue, Theme.blueBg) }
        if !a.failed.isEmpty { return ("生成失败", Theme.red, Theme.redBg) }
        if a.published { return ("已发", Theme.green, Theme.greenBg) }
        return ("待发", Theme.orange, Theme.orangeBg)
    }

    var body: some View {
        Text(spec.text)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(spec.fg)
            .padding(.horizontal, size > 11 ? 7 : 7)
            .frame(height: height)
            .background(spec.bg, in: Capsule())
    }
}

// MARK: 右详情

struct ArticleDetail: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var pipeline: Pipeline
    let articleId: UUID
    let article: Article
    @StateObject private var busy = Busy()

    @State private var editing = false
    @State private var confirmingRegen = false
    @State private var showTitles = false
    @State private var toast = ""
    @State private var adviceOpen = false

    var a: Article { store.article(articleId) ?? article }
    var signature: String { store.style(a.styleId)?.signature ?? "" }
    var running: String? { pipeline.running[articleId] }
    var locked: Bool { running != nil }

    func edit(_ f: (inout Article) -> Void) { store.update(articleId, f) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                head
                if confirmingRegen { regenBar }
                if showTitles { titlePicker }
                bodyArea
                if adviceOpen { advice }
                else if !(a.review?.suggestions.isEmpty ?? true) { adviceToggle }
            }
            .padding(.bottom, 24)
        }
        .overlay(alignment: .topTrailing) {
            if !toast.isEmpty {
                Text(toast).font(.system(size: 12)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.ink.opacity(0.85), in: Capsule())
                    .padding(.top, 44).padding(.trailing, 4)
                    .transition(.opacity)
            }
        }
    }

    // 标题 + 徽标 + 操作行
    var head: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                TextField("文章标题", text: Binding(
                    get: { a.title },
                    set: { v in edit { $0.title = v } }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.ink)
                BadgeView(a: a, running: running, size: 12, height: 20)
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                if a.published {
                    Text("已发").font(.system(size: 12)).foregroundStyle(Theme.green)
                } else {
                    Button(editing ? "改完了" : "改字") { editing.toggle() }
                        .buttonStyle(GhostButton())
                    Button("重新生成") { confirmingRegen = true }.buttonStyle(GhostButton())
                    Button("换标题") { showTitles = true }.buttonStyle(GhostButton())
                    Button("复制富文本") { copyRich() }.buttonStyle(GhostButton())
                    Spacer()
                    if !a.failed.isEmpty {
                        Button("重试") { pipeline.resume(articleId) }.buttonStyle(PrimaryButton())
                    } else {
                        Button("标为已发") { markPublished() }.buttonStyle(PrimaryButton())
                    }
                }
                if a.published { Spacer() }
            }
            .opacity(locked ? 0.4 : 1)
            .disabled(locked)

            if let r = running {
                Text("正在写第 \(a.stage.rawValue + 1) 步「\(r)」，写完就能改")
                    .font(.system(size: 11)).foregroundStyle(Theme.faint)
            }
        }
    }

    var regenBar: some View {
        HStack(spacing: 10) {
            Text("重新生成会覆盖现在这篇").font(.system(size: 12)).foregroundStyle(Theme.orange)
            Spacer()
            Button("继续") {
                confirmingRegen = false
                pipeline.resume(articleId)
            }
            .buttonStyle(GhostButton())
            Button("取消") { confirmingRegen = false }.buttonStyle(GhostButton())
        }
        .padding(10)
        .background(Theme.orangeBg, in: RoundedRectangle(cornerRadius: 8))
    }

    var titlePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("换标题").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Button("再来 5 个") { busy.run("正在想标题…") { try await TitleMaker.make(store, articleId) } }
                    .buttonStyle(LinkButton())
                Button("收起") { showTitles = false }.buttonStyle(LinkButton(color: Theme.faint))
            }
            if a.titleOptions.isEmpty {
                Text("还没有备选标题，点「再来 5 个」生成").font(.system(size: 12)).foregroundStyle(Theme.sub)
            }
            ForEach(a.titleOptions) { t in
                Button {
                    edit { $0.title = t.title }
                    showTitles = false
                } label: {
                    HStack(spacing: 8) {
                        Text(t.title).font(.system(size: 13)).foregroundStyle(Theme.ink).multilineTextAlignment(.leading)
                        Spacer()
                        if t.score > 0 { ScoreBadge(score: t.score) }
                    }
                    .padding(8)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowButton())
            }
        }
        .padding(12)
        .background(Theme.sheet, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.rule))
    }

    // 正文区
    @ViewBuilder var bodyArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(meta).font(.system(size: 11)).foregroundStyle(Theme.faint)
            if let r = running {
                progressBlock(r)
            } else if !a.failed.isEmpty {
                failedBlock
            } else if editing {
                editorBlock
            } else {
                WebPreview(html: Layout.previewPage(a, signature: signature))
                    .frame(minHeight: 520)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.rule))
                    .padding(20)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.rule))
            }
        }
    }

    var meta: String {
        var parts = ["\(a.wordCount) 字"]
        if let r = a.review { parts.append("\(r.total) 分") }
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
        parts.append(f.string(from: a.updated))
        return parts.joined(separator: " · ")
    }

    func progressBlock(_ step: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(step).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
            HStack(spacing: 6) {
                ForEach(Stage.allCases) { s in
                    Circle()
                        .fill(s.rawValue < a.stage.rawValue ? Theme.green
                              : (s == a.stage ? Theme.blue.opacity(0.5) : Theme.rule))
                        .frame(width: 10, height: 10)
                }
            }
            RunLog(articleId: articleId)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sheet, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.rule))
    }

    var failedBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(a.failed).font(.system(size: 13)).foregroundStyle(Theme.red)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("重试") { pipeline.resume(articleId) }.buttonStyle(PrimaryButton())
                Spacer()
            }
            RunLog(articleId: articleId)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sheet, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.rule))
    }

    var editorBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(a.sections.enumerated()), id: \.element.id) { i, sec in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(String(format: "%02d", i + 1))
                            .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Theme.blue)
                        TextField("小标题", text: Binding(
                            get: { store.article(articleId)?.sections.first { $0.id == sec.id }?.heading ?? "" },
                            set: { v in edit { art in
                                if let k = art.sections.firstIndex(where: { $0.id == sec.id }) { art.sections[k].heading = v }
                            } }))
                            .textFieldStyle(.plain).font(.system(size: 13, weight: .semibold))
                        Spacer()
                    }
                    TextEditor(text: Binding(
                        get: { store.article(articleId)?.sections.first { $0.id == sec.id }?.body ?? "" },
                        set: { v in edit { art in
                            if let k = art.sections.firstIndex(where: { $0.id == sec.id }) { art.sections[k].body = v }
                        } }))
                        .font(.system(size: 13))
                        .lineSpacing(4)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 160)
                        .padding(8)
                        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(12)
                .background(Theme.sheet, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.rule))
            }
        }
    }

    var adviceToggle: some View {
        Button { adviceOpen = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                Text("AI 建议").font(.system(size: 13, weight: .semibold))
                Text("\(a.review?.suggestions.count ?? 0) 条").font(.system(size: 11)).foregroundStyle(Theme.faint)
                Spacer()
            }
            .foregroundStyle(Theme.ink)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButton())
    }

    var advice: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                Text("AI 建议").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("收起") { adviceOpen = false }.buttonStyle(LinkButton(color: Theme.faint))
            }
            .foregroundStyle(Theme.ink)

            let hits = Humanize.hits(a.plainText)
            if !hits.isEmpty {
                Text("敏感 / 套路词：").font(.system(size: 11)).foregroundStyle(Theme.faint)
                Text(hits.joined(separator: "、")).font(.system(size: 12)).foregroundStyle(Theme.red)
            }
            ForEach(a.review?.suggestions ?? []) { s in
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.issue).font(.system(size: 12)).foregroundStyle(Theme.ink)
                    if !s.fix.isEmpty {
                        Text("建议：" + s.fix).font(.system(size: 11)).foregroundStyle(Theme.sub)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sheet, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.rule))
    }

    // MARK: 动作

    func copyRich() {
        Layout.copyRichText(a, signature: signature)
        toast = "已复制"
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            toast = ""
        }
    }

    /// 红线 1：全仓唯一能写 published 的入口
    func markPublished() {
        edit { $0.published = true }
        Theme.tap()
    }
}
