import SwiftUI

struct IdeasView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var pipeline: Pipeline
    @StateObject private var busy = Busy()
    var open: (UUID) -> Void

    @State private var manual = ""
    @State private var direction = ""
    @State private var showUsed = false

    var body: some View {
        Page {
            PageHeader(title: "选题库", subtitle: "先攒一批候选，再挑着写。库里的选题不会自动生产，点「一键写」或「手动写」才会用。")

            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "让 AI 提候选", hint: "会避开写过的题目")
                HStack(spacing: 10) {
                    TextField("给个方向，比如：在职备考公务员怎么安排时间", text: $direction)
                        .fieldBox()
                        .onSubmit(generate)
                    Button(action: generate) { Label("提 10 个", systemImage: "sparkles") }
                        .buttonStyle(PrimaryButton())
                        .disabled(direction.trimmingCharacters(in: .whitespaces).isEmpty || busy.label != nil)
                }
                HStack(spacing: 10) {
                    TextField("或者自己记一个选题，回车加入", text: $manual)
                        .fieldBox()
                        .onSubmit(addManual)
                    Button("加入", action: addManual).buttonStyle(GhostButton())
                        .disabled(manual.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                BusyBar(busy: busy)
            }
            .card()

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    SectionTitle(text: "候选", hint: "\(visible.count) 个")
                    Spacer()
                    Toggle("显示已用的", isOn: $showUsed).toggleStyle(.checkbox).font(.system(size: 12))
                }
                .padding(.bottom, 8)
                if visible.isEmpty {
                    Text("还没有选题").font(.system(size: 13)).foregroundStyle(Theme.sub)
                        .frame(maxWidth: .infinity).padding(.vertical, 30)
                }
                ForEach(Array(visible.enumerated()), id: \.element.id) { i, idea in
                    if i > 0 { Divider().overlay(Theme.rule) }
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: idea.used ? "checkmark.circle.fill" : "lightbulb")
                            .foregroundStyle(idea.used ? Theme.green : Theme.orange)
                            .frame(width: 18).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(idea.title).font(.system(size: 13, weight: .medium))
                                .foregroundStyle(idea.used ? Theme.sub : Theme.ink)
                            if !idea.angle.isEmpty {
                                Text(idea.angle).font(.system(size: 12)).foregroundStyle(Theme.sub)
                            }
                        }
                        Spacer()
                        Button("一键写") { autoWrite(idea) }.buttonStyle(PrimaryButton())
                            .disabled(store.data.connections.isEmpty)
                        Button("手动写") { start(idea) }.buttonStyle(GhostButton())
                        Button { remove(idea) } label: { Image(systemName: "trash") }
                            .buttonStyle(LinkButton(color: Theme.faint))
                    }
                    .padding(.vertical, 10)
                }
            }
            .card()
        }
    }

    var visible: [TopicIdea] { store.data.ideas.filter { showUsed || !$0.used } }

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
            store.data.ideas.insert(contentsOf: r.ideas.map { TopicIdea(title: $0.title, angle: $0.angle ?? "") }, at: 0)
            store.save()
        }
    }

    func markUsed(_ idea: TopicIdea) {
        if let i = store.data.ideas.firstIndex(where: { $0.id == idea.id }) { store.data.ideas[i].used = true; store.save() }
    }

    func autoWrite(_ idea: TopicIdea) {
        markUsed(idea)
        let dir = idea.angle.isEmpty ? idea.title : "\(idea.title)（角度：\(idea.angle)）"
        pipeline.enqueue(direction: dir, styleId: store.data.styles.first?.id)
    }

    func start(_ idea: TopicIdea) {
        markUsed(idea)
        open(store.newArticle(topic: idea.title, angle: idea.angle))
    }

    func remove(_ idea: TopicIdea) {
        store.data.ideas.removeAll { $0.id == idea.id }
        store.save()
    }
}
