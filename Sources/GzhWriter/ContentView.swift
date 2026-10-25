import SwiftUI

enum Pane: Hashable {
    case workbench, ideas, styles, models, auto
    case article(UUID)
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var pipeline: Pipeline
    @State private var pane: Pane? = .workbench

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Section("写作") {
                    Label("工作台", systemImage: "sparkles").tag(Pane.workbench)
                    Label("选题池", systemImage: "lightbulb").tag(Pane.ideas)
                }
                Section {
                    ForEach(store.data.articles) { a in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.displayTitle).lineLimit(1)
                            Text(pipeline.running[a.id] ?? sidebarLine(a))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .tag(Pane.article(a.id))
                        .contextMenu {
                            Button("删除", role: .destructive) {
                                if pane == .article(a.id) { pane = .workbench }
                                store.deleteArticle(a.id)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("稿件库")
                        Spacer()
                        Button { newArticle() } label: { Image(systemName: "plus") }
                            .buttonStyle(.borderless)
                            .help("新建稿件 ⌘N")
                    }
                }
                Section("设置") {
                    Label("账号设定", systemImage: "person.text.rectangle").tag(Pane.styles)
                    Label("自动化", systemImage: "bolt.badge.clock").tag(Pane.auto)
                    Label("模型设置", systemImage: "cpu").tag(Pane.models)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            switch pane {
            case .workbench, .none:
                WorkbenchView(open: { pane = .article($0) })
            case .ideas:
                IdeasView(open: { pane = .article($0) })
            case .auto:
                AutoSettingsView()
            case .styles:
                StylesView()
            case .models:
                ModelsView()
            case .article(let id):
                if store.article(id) != nil {
                    ArticleEditor(articleId: id).id(id)
                } else {
                    Text("稿件已删除").foregroundStyle(.secondary)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newArticle)) { _ in newArticle() }
        .onAppear {
            if store.data.connections.isEmpty { pane = .models }
        }
    }

    func sidebarLine(_ a: Article) -> String {
        var t = "\(a.stage.title) · \(a.wordCount) 字"
        if let r = a.review { t += " · \(r.total) 分" }
        return t
    }

    func newArticle() {
        pane = .article(store.newArticle())
    }
}
