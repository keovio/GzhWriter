import SwiftUI

/// 工作台：一键成稿 + 正在写 + 最近稿件 + 今日热榜
struct WorkbenchView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var pipeline: Pipeline
    var open: (UUID) -> Void

    @State private var direction = ""
    @State private var styleId: UUID?
    @State private var count = 1
    @State private var showAllHot = false

    var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<11: return "早上好"
        case 11..<14: return "中午好"
        case 14..<18: return "下午好"
        default: return "晚上好"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(greeting).font(.largeTitle.bold())
                    Text(subtitle).foregroundStyle(.secondary)
                }

                composer

                if !pipeline.running.isEmpty || pipeline.queued > 0 { runningCard }

                if let e = pipeline.lastError {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(e).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button("关闭") { pipeline.lastError = nil }.buttonStyle(.borderless)
                    }
                    .card()
                }

                recent
                hotCard
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .task {
            if styleId == nil { styleId = store.data.styles.first?.id }
            if pipeline.hot.isEmpty { await pipeline.refreshHot() }
        }
    }

    var subtitle: String {
        let today = store.data.articles.filter { Calendar.current.isDateInToday($0.created) }
        let words = today.reduce(0) { $0 + $1.wordCount }
        if store.data.connections.isEmpty { return "先去「模型设置」接一个模型，就能开始一键成稿。" }
        return today.isEmpty ? "今天还没写，给个方向或者直接点一键成稿。" : "今天写了 \(today.count) 篇，共 \(words) 字。"
    }

    // MARK: 一键成稿

    var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("写什么？留空就按你的赛道和今日热榜自动选题", text: $direction, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.title3)
                .lineLimit(1...4)
                .padding(12)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
                .onSubmit(go)
            HStack(spacing: 14) {
                Picker("账号", selection: $styleId) {
                    ForEach(store.data.styles) { Text($0.name).tag(Optional($0.id)) }
                }
                .frame(maxWidth: 200)
                Stepper("连写 \(count) 篇", value: $count, in: 1...5).fixedSize()
                Text("约 \(store.data.auto.targetWords) 字 · 及格线 \(store.data.auto.passScore)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: go) {
                    Label("一键成稿", systemImage: "sparkles")
                        .font(.headline)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(store.data.connections.isEmpty)
            }
            Text("自动选题 → 大纲 → 全文 → 自审，不及格自动返修，排好版放进稿件库。发之前你过一眼，复制到公众号后台自己发。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }

    func go() {
        pipeline.enqueue(direction: direction.trimmingCharacters(in: .whitespacesAndNewlines), styleId: styleId, count: count)
        direction = ""
    }

    // MARK: 正在写

    var runningCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("正在写").font(.headline)
                if pipeline.queued > 0 { Text("· 还有 \(pipeline.queued) 篇排队").foregroundStyle(.secondary) }
            }
            ForEach(Array(pipeline.running.keys), id: \.self) { id in
                Button { open(id) } label: {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(store.article(id)?.displayTitle ?? "新稿件").lineLimit(1)
                        Spacer()
                        Text(pipeline.running[id] ?? "").foregroundStyle(.secondary).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .card()
    }

    // MARK: 最近稿件

    var recent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("最近稿件").font(.headline)
            if store.data.articles.isEmpty {
                Text("还没有稿件").foregroundStyle(.secondary).card()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                    ForEach(store.data.articles.prefix(9)) { a in
                        Button { open(a.id) } label: { ArticleCard(article: a, running: pipeline.running[a.id]) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: 热榜

    var hotCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("今日热榜").font(.headline)
                Text("只作选题参考").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await pipeline.refreshHot() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
            }
            if pipeline.hot.isEmpty {
                Text("热榜暂时拉不到").foregroundStyle(.secondary)
            }
            ForEach(Array(pipeline.hot.prefix(showAllHot ? 40 : 10).enumerated()), id: \.element.id) { i, h in
                HStack {
                    Text("\(i + 1)").font(.callout.monospacedDigit()).foregroundStyle(i < 3 ? Color.orange : Color.secondary)
                        .frame(width: 22, alignment: .trailing)
                    Text(h.title).lineLimit(1)
                    Text(h.source).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("写这个") {
                        pipeline.enqueue(direction: "结合热点「\(h.title)」写一篇和我赛道相关的文章", styleId: styleId)
                    }
                    .buttonStyle(.borderless)
                    .disabled(store.data.connections.isEmpty)
                }
            }
            if pipeline.hot.count > 10 {
                Button(showAllHot ? "收起" : "展开更多") { showAllHot.toggle() }.buttonStyle(.borderless)
            }
        }
        .card()
    }
}

struct ArticleCard: View {
    let article: Article
    let running: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let r = running {
                    ProgressView().controlSize(.mini)
                    Text(r).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(article.stage.title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let score = article.review?.total, running == nil {
                    Text("\(score)")
                        .font(.caption.bold())
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background((score >= 80 ? Color.green : Color.orange).opacity(0.18), in: Capsule())
                        .foregroundStyle(score >= 80 ? Color.green : Color.orange)
                }
            }
            Text(article.displayTitle)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            HStack {
                Text("\(article.wordCount) 字")
                if article.auto { Text("· 一键成稿") }
                Spacer()
                Text(article.updated, style: .relative)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.12)))
        .contentShape(Rectangle())
    }
}

extension View {
    func card() -> some View {
        self.padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.12)))
    }
}

/// 自动化设置
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
        Form {
            Section("一键成稿") {
                Stepper("目标字数 \(store.data.auto.targetWords)", value: b(\.targetWords), in: 600...4000, step: 100)
                Stepper("审稿及格线 \(store.data.auto.passScore) 分", value: b(\.passScore), in: 50...95, step: 5)
                Stepper("不及格最多返修 \(store.data.auto.maxRounds) 轮", value: b(\.maxRounds), in: 0...4)
                Toggle("自动选题时参考今日热榜", isOn: b(\.useHot))
            }
            Section {
                Toggle("每天自动写一篇", isOn: b(\.dailyEnabled))
                DatePicker("时间", selection: dailyTime, displayedComponents: .hourAndMinute)
                    .disabled(!store.data.auto.dailyEnabled)
                Picker("用哪个账号设定", selection: b(\.dailyStyleId)) {
                    ForEach(store.data.styles) { Text($0.name).tag(Optional($0.id)) }
                }
                .disabled(!store.data.auto.dailyEnabled)
            } header: {
                Text("定时")
            } footer: {
                Text("到点自动写好放进稿件库并发通知，不会发到公众号。需要软件开着（可以最小化）。")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
