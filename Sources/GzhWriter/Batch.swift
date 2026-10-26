import SwiftUI
import AppKit

/// 稿件批量处理：只处理本地稿件，不批量推草稿箱、不自动发布（公众号 3.27）。
@MainActor
final class Batch: ObservableObject {
    static let shared = Batch()

    @Published var title = ""          // 正在做什么
    @Published var done = 0
    @Published var total = 0
    @Published var current = ""        // 当前稿件
    @Published var failed: [UUID: String] = [:]
    @Published var message = ""        // 做完的结果
    private var stopFlag = false
    private var lastJob: ((UUID) async throws -> Void)?
    private var lastTitle = ""

    var busy: Bool { total > 0 && done < total }

    func stop() { stopFlag = true }

    /// 能交给模型处理的长文（有正文，不是小红书/微博短内容）
    static func longForm(_ store: Store, _ ids: [UUID]) -> [UUID] {
        ids.filter { id in
            guard let a = store.article(id) else { return false }
            return !a.isShort && !a.sections.isEmpty
        }
    }

    /// 排队逐篇跑模型操作
    func run(_ title: String, _ ids: [UUID], pipeline: Pipeline, job: @escaping (UUID) async throws -> Void) {
        guard !busy, !ids.isEmpty else { return }
        let store = pipeline.store
        self.title = title
        lastTitle = title
        lastJob = job
        stopFlag = false
        failed = [:]
        message = ""
        done = 0
        total = ids.count
        Task {
            var ok = 0
            for id in ids {
                if stopFlag { break }
                current = store.article(id)?.displayTitle ?? ""
                pipeline.running[id] = "批量：\(title)"
                do {
                    try await job(id)
                    ok += 1
                } catch {
                    failed[id] = error.localizedDescription
                    store.update(id) { $0.log.append("批量\(title)出错：\(error.localizedDescription)") }
                }
                pipeline.running[id] = nil
                done += 1
            }
            let skipped = total - done
            done = total
            current = ""
            var msg = "\(title)：完成 \(ok) 篇"
            if !failed.isEmpty { msg += "，失败 \(failed.count) 篇" }
            if skipped > 0 { msg += "，停下没做 \(skipped) 篇" }
            message = msg
        }
    }

    func retryFailed(pipeline: Pipeline) {
        guard let job = lastJob, !failed.isEmpty else { return }
        run(lastTitle, Array(failed.keys), pipeline: pipeline, job: job)
    }

    // MARK: 具体操作

    /// 审稿 + 低于及格线返修，留分数最高的一版
    static func review(_ store: Store, _ id: UUID) async throws {
        let settings = store.data.auto
        func log(_ s: String) { store.update(id) { $0.log.append(s) } }
        var round = 0
        var best: (score: Int, sections: [ArticleSection], review: ReviewResult)?
        while true {
            guard let a = store.article(id) else { return }
            let style = store.style(a.styleId)
            let r = try await store.runJSON(.review, ReviewResult.self, Prompts.review(a))
            store.update(id) { $0.review = r }
            if best == nil || r.total > best!.score { best = (r.total, a.sections, r) }
            log("批量审稿得分 \(r.total)")
            if r.total >= settings.passScore || round >= settings.maxRounds { break }
            round += 1
            let fixes = r.suggestions.filter { ($0.section ?? 0) >= 1 }
            let grouped = Dictionary(grouping: fixes, by: { $0.section! - 1 })
            for (idx, list) in grouped.sorted(by: { $0.key < $1.key }) {
                guard let cur = store.article(id), idx < cur.sections.count else { continue }
                let lines: [String] = list.map { "问题：\($0.issue)；改法：\($0.fix)" }
                let ins = lines.joined(separator: "\n")
                let text = try await store.run(.draft, Prompts.revise(cur, index: idx, instruction: ins, style: style))
                store.update(id) { if idx < $0.sections.count { $0.sections[idx].body = Humanize.clean(text) } }
            }
        }
        if let b = best, let cur = store.article(id), (cur.review?.total ?? 0) < b.score {
            store.update(id) { $0.sections = b.sections; $0.review = b.review }
        }
    }

    /// 按顺序排进发布日历，已排过、已发过的跳过
    static func schedule(_ store: Store, _ ids: [UUID]) -> Int {
        var n = 0
        for id in ids {
            guard let a = store.article(id), a.scheduled == nil, !a.published else { continue }
            if PublishPlan.schedule(store, id) != nil { n += 1 }
        }
        return n
    }

    /// 记为这个号发过了（已记的不动）
    static func markPosted(_ store: Store, _ ids: [UUID], _ acc: Account) -> Int {
        var n = 0
        for id in ids {
            guard let a = store.article(id), !store.isPosted(a, acc) else { continue }
            store.togglePosted(id, acc.platform, acc)
            n += 1
        }
        return n
    }

    /// 导出：每篇一个 Word（.docx）和一个 Markdown，放进选的文件夹
    static func export(_ store: Store, _ ids: [UUID]) -> Int? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "导出到这里"
        guard panel.runModal() == .OK, let dir = panel.url else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        let folder = dir.appendingPathComponent("稿件导出-\(f.string(from: Date()))")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var n = 0
        var used = Set<String>()
        for id in ids {
            guard let a = store.article(id) else { continue }
            var name = safeName(a.displayTitle)
            if used.contains(name) { name += "-\(n + 1)" }
            used.insert(name)
            let text = a.isShort ? (a.variants[a.primary]?.body ?? a.plainText) : a.plainText
            try? text.write(to: folder.appendingPathComponent(name + ".md"), atomically: true, encoding: .utf8)
            if !a.isShort {
                let sig = store.style(a.styleId)?.signature ?? ""
                let title = a.title.isEmpty ? "" : "<h1>\(Layout.esc(a.title))</h1>"
                let html = "<html><head><meta charset=\"utf-8\"></head><body>\(title)\(Layout.html(a, signature: sig))</body></html>"
                if let data = html.data(using: .utf8),
                   let attr = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil),
                   let docx = try? attr.data(from: NSRange(location: 0, length: attr.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]) {
                    try? docx.write(to: folder.appendingPathComponent(name + ".docx"))
                }
            }
            n += 1
        }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
        return n
    }

    static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r")
        let cleaned = s.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let name = cleaned.isEmpty ? "未命名" : cleaned
        return String(name.prefix(60))
    }
}

// MARK: - 稿件库底部的批量操作栏

struct BatchBar: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var pipeline: Pipeline
    @ObservedObject var batch = Batch.shared
    @Binding var selected: Set<UUID>
    let visible: [UUID]
    var done: () -> Void
    @State private var confirmDelete = false
    @State private var note = ""

    var ids: [UUID] { visible.filter { selected.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if batch.busy {
                HStack(spacing: 10) {
                    ProgressView(value: Double(batch.done), total: Double(max(batch.total, 1))).frame(width: 160)
                    Text("\(batch.title) \(batch.done)/\(batch.total)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.blue)
                    Text(batch.current).font(.system(size: 12)).foregroundStyle(Theme.sub).lineLimit(1)
                    if let m = store.calling { ModelTag(text: m) }
                    Spacer()
                    Button("停止") { batch.stop() }.buttonStyle(GhostButton())
                }
            } else if !(batch.message.isEmpty && note.isEmpty) {
                HStack(spacing: 8) {
                    Image(systemName: batch.failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(batch.failed.isEmpty ? Theme.green : Theme.orange)
                    Text(note.isEmpty ? batch.message : note).font(.system(size: 12)).foregroundStyle(Theme.ink)
                    if note.isEmpty && !batch.failed.isEmpty {
                        Button("重试失败的") { batch.retryFailed(pipeline: pipeline) }.buttonStyle(LinkButton(color: Theme.blue))
                        Button("只选失败的") { selected = Set(batch.failed.keys) }.buttonStyle(LinkButton(color: Theme.sub))
                    }
                    Spacer()
                }
            }
            HStack(spacing: 8) {
                Text("已选 \(ids.count) 篇").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink)
                Button(ids.count == visible.count && !visible.isEmpty ? "取消全选" : "全选") {
                    if ids.count == visible.count { selected = [] } else { selected = Set(visible) }
                }
                .buttonStyle(LinkButton(color: Theme.blue))
                Spacer()
                Group {
                    Menu {
                        Button("所有平台") { variants([]) }
                        Divider()
                        ForEach(Platform.others(store), id: \.self) { p in
                            Button(p.name) { variants([p]) }
                        }
                    } label: { Label("出平台版本", systemImage: "square.on.square") }
                    .menuStyle(.borderlessButton).fixedSize()

                    Button { modelJob("审稿返修") { try await Batch.review(store, $0) } } label: { Label("审稿返修", systemImage: "checkmark.seal") }
                    Button {
                        modelJob("改敏感词") { id in _ = try await Compliance.autoFix(store, id) { s in store.update(id) { $0.log.append(s) } } }
                    } label: { Label("改敏感词", systemImage: "exclamationmark.shield") }
                    Button {
                        let n = Batch.schedule(store, ids)
                        say(n == 0 ? "选中的都已排过或已发布" : "排进日历 \(n) 篇，按发布时间每天一篇")
                    } label: { Label("排进日历", systemImage: "calendar.badge.plus") }

                    if !store.data.accounts.isEmpty {
                        Menu {
                            ForEach(store.data.accounts) { acc in
                                Button("\(Platform.of(acc.platform)?.name ?? "")·\(acc.name)") {
                                    say("记为「\(acc.name)」已发 \(Batch.markPosted(store, ids, acc)) 篇")
                                }
                            }
                        } label: { Label("标记已发", systemImage: "paperplane") }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                    Button {
                        if let n = Batch.export(store, ids) { say("导出 \(n) 篇（Word + Markdown）") }
                    } label: { Label("导出", systemImage: "square.and.arrow.up") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("删除", systemImage: "trash") }
                        .foregroundStyle(Theme.red)
                }
                .buttonStyle(RowButton())
                .font(.system(size: 12))
                .disabled(ids.isEmpty || batch.busy)
                Button("完成") { done() }.buttonStyle(GhostButton())
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.sheet).shadow(color: .black.opacity(0.12), radius: 12, y: 2))
        .confirmationDialog("删除选中的 \(ids.count) 篇稿件？删除后找不回来。", isPresented: $confirmDelete) {
            Button("删除 \(ids.count) 篇", role: .destructive) {
                let list = ids
                for id in list { store.deleteArticle(id) }
                selected.subtract(list)
                say("删除了 \(list.count) 篇")
            }
        }
    }

    func say(_ s: String) {
        batch.message = ""
        batch.failed = [:]
        note = s
    }

    func modelJob(_ title: String, _ job: @escaping (UUID) async throws -> Void) {
        let list = Batch.longForm(store, ids)
        note = ""
        if list.isEmpty { say("选中的没有可处理的长文（短内容或还没正文的会跳过）"); return }
        batch.run(title, list, pipeline: pipeline, job: job)
    }

    func variants(_ only: [Platform]) {
        let s = store
        modelJob(only.count == 1 ? "出\(only[0].name)版" : "出平台版本") { try await Publisher.makeVariants(s, $0, only: only) }
    }
}
