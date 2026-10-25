import SwiftUI

struct IdeasView: View {
    @EnvironmentObject var store: Store
    @StateObject private var busy = Busy()
    var open: (UUID) -> Void

    @State private var manual = ""
    @State private var direction = ""
    @State private var showUsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("选题池").font(.title2.bold())
            Text("自己记选题，或者给个方向让 AI 列角度，你来挑。挑中的点「开写」进入大纲。")
                .foregroundStyle(.secondary)

            HStack {
                TextField("记一个选题，回车添加", text: $manual)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addManual)
                Button("添加", action: addManual).disabled(manual.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            GroupBox {
                HStack {
                    TextField("想写的方向，比如：在职备考公务员怎么安排时间", text: $direction)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(generate)
                    Button("AI 列 10 个角度", action: generate)
                        .disabled(direction.trimmingCharacters(in: .whitespaces).isEmpty || busy.label != nil)
                }
                BusyBar(busy: busy)
            }

            Toggle("显示已开写的", isOn: $showUsed).toggleStyle(.checkbox)

            List {
                ForEach(visible) { idea in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(idea.title).font(.body.weight(.medium))
                                .foregroundStyle(idea.used ? Color.secondary : Color.primary)
                            if !idea.angle.isEmpty {
                                Text(idea.angle).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("开写") { start(idea) }
                        Button { remove(idea) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
            }
            .overlay {
                if visible.isEmpty {
                    Text("还没有选题").foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
    }

    var visible: [TopicIdea] {
        store.data.ideas.filter { showUsed || !$0.used }
    }

    func addManual() {
        let t = manual.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        store.data.ideas.insert(TopicIdea(title: t), at: 0)
        store.save()
        manual = ""
    }

    func generate() {
        let dir = direction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty else { return }
        let avoid = store.data.styles.map(\.avoid).filter { !$0.isEmpty }.joined(separator: "；")
        let existing = store.data.ideas.map(\.title) + store.data.articles.map(\.displayTitle)
        busy.run("正在想选题…") {
            let r = try await store.runJSON(.topic, IdeasReply.self, Prompts.ideas(direction: dir, avoid: avoid, existing: existing))
            let new = r.ideas.map { TopicIdea(title: $0.title, angle: $0.angle ?? "") }
            store.data.ideas.insert(contentsOf: new, at: 0)
            store.save()
        }
    }

    func start(_ idea: TopicIdea) {
        if let i = store.data.ideas.firstIndex(where: { $0.id == idea.id }) {
            store.data.ideas[i].used = true
        }
        let id = store.newArticle(topic: idea.title, angle: idea.angle)
        open(id)
    }

    func remove(_ idea: TopicIdea) {
        store.data.ideas.removeAll { $0.id == idea.id }
        store.save()
    }
}
