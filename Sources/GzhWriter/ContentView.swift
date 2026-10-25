import SwiftUI

enum Pane: Hashable {
    case ideas, styles, models
    case article(UUID)
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var pane: Pane? = .ideas

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Section("写作") {
                    Label("选题池", systemImage: "lightbulb").tag(Pane.ideas)
                }
                Section {
                    ForEach(store.data.articles) { a in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.displayTitle).lineLimit(1)
                            Text("\(a.stage.title) · \(a.wordCount) 字")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(Pane.article(a.id))
                        .contextMenu {
                            Button("删除", role: .destructive) {
                                if pane == .article(a.id) { pane = .ideas }
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
                    Label("口吻与范文", systemImage: "text.quote").tag(Pane.styles)
                    Label("模型设置", systemImage: "cpu").tag(Pane.models)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            switch pane {
            case .ideas, .none:
                IdeasView(open: { pane = .article($0) })
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

    func newArticle() {
        pane = .article(store.newArticle())
    }
}
