import AppKit
import SwiftUI

enum Pane: Hashable {
    /// 三项：工作台（= 题材流，case 名沿用 compose）/ 稿件 / 设置
    /// 稿件详情不再是独立 pane：改成稿件页右栏的局部状态（§3.1 真分栏）
    case compose, articles, settings
}

struct ContentView: View {
    /// CI 截图用：GZH_PANE=topics 之类，直接打开那一页。
    /// 旧页名保留映射，避免 CI 脚本与本地截图命令一起失效。
    static var startPane: Pane {
        switch ProcessInfo.processInfo.environment["GZH_PANE"] ?? "" {
        case "compose", "workbench", "topics", "ideas", "radar", "breakdown": return .compose
        case "articles", "library": return .articles
        case "settings", "models", "accounts", "styles", "publish", "auto", "materials": return .settings
        default: return .compose
        }
    }

    @EnvironmentObject var store: Store
    @EnvironmentObject var pipeline: Pipeline
    @State private var pane: Pane = ContentView.startPane
    /// 稿件页右栏选中哪一篇
    @State private var selected: UUID?
    /// 小红书 / 微博这类短内容仍是整页（不套分栏）
    @State private var shortId: UUID?

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(pane: $pane, newArticle: newArticle, openArticle: open)
                .frame(width: 216)
            Rectangle().fill(Theme.rule).frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.light)
        .onReceive(NotificationCenter.default.publisher(for: .newArticle)) { _ in newArticle() }
        .onChange(of: pipeline.focus) { id in
            if let id { open(id); pipeline.focus = nil }
        }
        .sheet(isPresented: Binding(get: { shortId != nil }, set: { if !$0 { shortId = nil } })) {
            if let id = shortId {
            ShortArticleView(articleId: id, close: { shortId = nil })
                .frame(minWidth: 760, minHeight: 620)
            }
        }
    }

    /// 四页各自只有一页，顶部切换条已取消（§1：HubTabs 删除）
    var detail: some View {
        page.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder var page: some View {
        switch pane {
        case .compose: TopicsView(open: open, goArticles: { pane = .articles })
        case .articles: ArticlePage(selected: $selected)
        case .settings: SettingsShell()
        }
    }

    /// 打开一篇：短内容（小红书/微博）还是整页编辑器，长文进稿件页右栏
    func open(_ id: UUID) {
        guard let a = store.article(id) else { return }
        if a.isShort {
            shortId = id
        } else {
            selected = id
            pane = .articles
        }
    }

    func newArticle() { open(store.newArticle()) }
}

struct Sidebar: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var pipeline: Pipeline
    @Binding var pane: Pane
    var newArticle: () -> Void
    var openArticle: (UUID) -> Void

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

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(NavItem.all, id: \.pane) { n in
                        SideItem(title: n.name, icon: n.icon, on: pane == n.pane, badge: badge(n)) { pane = n.pane }
                    }

                    if !recent.isEmpty {
                        group("最近")
                        ForEach(recent) { a in
                            Button { openArticle(a.id) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: pipeline.running[a.id] != nil ? "hourglass" : "doc")
                                        .font(.system(size: 13)).frame(width: 18)
                                    Text(a.displayTitle).font(.system(size: 13)).lineLimit(1)
                                    Spacer()
                                }
                                .foregroundStyle(Theme.ink.opacity(0.88))
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(RowButton())
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

    func badge(_ n: NavItem) -> String? {
        switch n.pane {
        case .compose: return pipeline.running.isEmpty ? (pipeline.failedArticles.isEmpty ? nil : "!") : "\(pipeline.running.count)"
        case .settings: return store.data.connections.isEmpty ? "!" : nil
        case .articles: return nil
        }
    }

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


/// 侧栏三项，一页一件事（§1.3）
struct NavItem {
    let name: String
    let icon: String
    let pane: Pane

    static let all: [NavItem] = [
        NavItem(name: "工作台", icon: "flame", pane: .compose),
        NavItem(name: "稿件", icon: "doc.text", pane: .articles),
        NavItem(name: "设置", icon: "gearshape", pane: .settings),
    ]
}
