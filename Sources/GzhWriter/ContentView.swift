import AppKit
import SwiftUI

enum Pane: Hashable {
    case workbench, ideas, library, radar, breakdown, materials, plan, styles, models, auto, publish
    case article(UUID)
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var pipeline: Pipeline
    @State private var pane: Pane = .workbench
    @State private var back: Pane = .workbench

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(pane: $pane, newArticle: newArticle)
                .frame(width: 216)
            Rectangle().fill(Theme.rule).frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.light)
        .onReceive(NotificationCenter.default.publisher(for: .newArticle)) { _ in newArticle() }
        .onAppear { if store.data.connections.isEmpty { pane = .models } }
    }

    var detail: some View {
        VStack(spacing: 0) {
            if let g = NavGroup.of(pane), g.tabs.count > 1 {
                HubTabs(group: g, pane: $pane)
            }
            page.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder var page: some View {
        switch pane {
        case .workbench: WorkbenchView(open: open)
        case .ideas: IdeasView(open: open)
        case .library: LibraryView(open: open)
        case .radar: RadarView()
        case .breakdown: BreakdownView()
        case .materials: MaterialsView()
        case .plan: PlanView(open: open)
        case .styles: StylesView()
        case .models: ModelsView()
        case .auto: AutoSettingsView()
        case .publish: PublishSettingsView()
        case .article(let id):
            if let a = store.article(id), a.isShort {
                ShortArticleView(articleId: id, close: { pane = back }).id(id)
            } else if store.article(id) != nil {
                ArticleEditor(articleId: id, close: { pane = back }).id(id)
            } else {
                Page { Text("稿件已删除").foregroundStyle(Theme.sub) }
            }
        }
    }

    func open(_ id: UUID) {
        if case .article = pane {} else { back = pane }
        pane = .article(id)
    }

    func newArticle() { open(store.newArticle()) }
}

struct Sidebar: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var pipeline: Pipeline
    @Binding var pane: Pane
    var newArticle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 给红绿灯留位置
            Color.clear.frame(height: 38)
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                    .resizable().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("公众号写稿助手").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.ink)
                    Text("AI 起草 · 你来定稿").font(.system(size: 11)).foregroundStyle(Theme.faint)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)

            Button(action: newArticle) {
                HStack { Image(systemName: "square.and.pencil"); Text("新建稿件"); Spacer(); Text("⌘N").foregroundStyle(.white.opacity(0.6)) }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButton())
            .padding(.horizontal, 12)
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(NavGroup.allCases, id: \.self) { g in
                        SideItem(title: g.name, icon: g.icon, on: NavGroup.of(pane) == g, badge: badge(g)) { pane = g.tabs[0].1 }
                    }

                    if !recent.isEmpty {
                        group("最近")
                        ForEach(recent) { a in
                            item(a.displayTitle, pipeline.running[a.id] != nil ? "hourglass" : "doc", .article(a.id))
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Circle().fill(store.data.connections.isEmpty ? Theme.orange : Theme.green).frame(width: 7, height: 7)
                Text(store.data.connections.isEmpty ? "未接模型" : "已接 \(store.data.connections.count) 个模型")
                    .font(.system(size: 11)).foregroundStyle(Theme.sub)
            }
            .padding(16)
        }
        .background(Theme.sidebar)
    }

    func badge(_ g: NavGroup) -> String? {
        switch g {
        case .home: return pipeline.running.isEmpty ? (pipeline.failedArticles.isEmpty ? nil : "!") : "\(pipeline.running.count)"
        case .articles: return upcoming == 0 ? nil : "\(upcoming)"
        case .settings: return store.data.connections.isEmpty ? "!" : nil
        case .hot, .writing: return nil
        }
    }

    var upcoming: Int { store.data.articles.filter { $0.scheduled != nil && !$0.published }.count }
    var openIdeas: Int { store.data.ideas.filter { !$0.used }.count }
    var recent: [Article] { Array(store.data.articles.prefix(5)) }

    func group(_ t: String) -> some View {
        Text(t).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
            .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
    }

    func item(_ title: String, _ icon: String, _ p: Pane, badge: String? = nil) -> some View {
        SideItem(title: title, icon: icon, on: pane == p, badge: badge) { pane = p }
    }
}

struct SideItem: View {
    let title: String
    let icon: String
    let on: Bool
    var badge: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13)).frame(width: 18)
                Text(title).font(.system(size: 13, weight: on ? .semibold : .regular)).lineLimit(1)
                Spacer()
                if let b = badge {
                    Text(b).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(on ? Theme.navy : Theme.sub)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(on ? Color.white : Color(hex: "#DFE4F2"), in: Capsule())
                }
            }
            .foregroundStyle(on ? Color.white : Theme.ink.opacity(0.88))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(on ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(hover ? Color.white : Color.clear))
                    .shadow(color: on ? Theme.navy.opacity(0.3) : .clear, radius: 6, y: 2)
            }
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: hover)
        }
        .buttonStyle(RowButton())
    }
}


/// 侧栏只有四项，每项里面用顶部标签切换
enum NavGroup: CaseIterable {
    case home, hot, articles, writing, settings

    var name: String {
        switch self {
        case .home: return "工作台"
        case .hot: return "选题"
        case .articles: return "稿件"
        case .writing: return "我的风格"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .home: return "square.grid.2x2"
        case .hot: return "flame"
        case .articles: return "doc.text"
        case .writing: return "person.text.rectangle"
        case .settings: return "gearshape"
        }
    }

    var tabs: [(String, Pane)] {
        switch self {
        case .home: return [("工作台", .workbench)]
        case .hot: return [("热点雷达", .radar), ("选题库", .ideas), ("爆文拆解", .breakdown)]
        case .articles: return [("全部稿件", .library), ("发布日历", .plan)]
        case .writing: return [("账号设定", .styles), ("素材库", .materials)]
        case .settings: return [("模型", .models), ("平台与发布", .publish), ("自动化", .auto)]
        }
    }

    static func of(_ p: Pane) -> NavGroup? {
        allCases.first { g in g.tabs.contains { $0.1 == p } }
    }
}

struct HubTabs: View {
    let group: NavGroup
    @Binding var pane: Pane

    var body: some View {
        HStack(spacing: 4) {
            ForEach(group.tabs, id: \.0) { name, p in
                Button { pane = p } label: {
                    Text(name)
                        .font(.system(size: 13, weight: pane == p ? .semibold : .regular))
                        .foregroundStyle(pane == p ? Theme.navy : Theme.sub)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(pane == p ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color.clear)).frame(height: 2)
                        }
                }
                .buttonStyle(RowButton())
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 30)
        .background(Theme.sheet)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }
    }
}
