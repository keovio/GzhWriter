import AppKit
import SwiftUI

enum Pane: Hashable {
    case workbench, ideas, library, styles, models, auto, publish
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

    @ViewBuilder var detail: some View {
        switch pane {
        case .workbench: WorkbenchView(open: open)
        case .ideas: IdeasView(open: open)
        case .library: LibraryView(open: open)
        case .styles: StylesView()
        case .models: ModelsView()
        case .auto: AutoSettingsView()
        case .publish: PublishSettingsView()
        case .article(let id):
            if store.article(id) != nil {
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
                    group("内容")
                    item("工作台", "square.grid.2x2", .workbench, badge: pipeline.running.isEmpty ? nil : "\(pipeline.running.count)")
                    item("选题库", "lightbulb", .ideas, badge: openIdeas == 0 ? nil : "\(openIdeas)")
                    item("稿件库", "doc.text", .library, badge: store.data.articles.isEmpty ? nil : "\(store.data.articles.count)")
                    group("配置")
                    item("账号设定", "person.crop.rectangle", .styles)
                    item("模型与分工", "cpu", .models, badge: store.data.connections.isEmpty ? "!" : nil)
                    item("自动化", "bolt", .auto, badge: store.data.auto.dailyEnabled ? "开" : nil)
                    item("发布与分发", "paperplane", .publish, badge: store.data.wechat.autoPush ? "开" : nil)

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

    var openIdeas: Int { store.data.ideas.filter { !$0.used }.count }
    var recent: [Article] { Array(store.data.articles.prefix(5)) }

    func group(_ t: String) -> some View {
        Text(t).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
            .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
    }

    func item(_ title: String, _ icon: String, _ p: Pane, badge: String? = nil) -> some View {
        let on = pane == p
        return Button { pane = p } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13)).frame(width: 18)
                Text(title).font(.system(size: 13, weight: on ? .semibold : .regular)).lineLimit(1)
                Spacer()
                if let b = badge {
                    Text(b).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(on ? Theme.blue : Theme.sub)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(on ? Color.white : Color(hex: "#EEF0F3"), in: Capsule())
                }
            }
            .foregroundStyle(on ? Theme.blue : Theme.ink.opacity(0.85))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Theme.blueBg : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
