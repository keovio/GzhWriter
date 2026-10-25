import Foundation
import UserNotifications

struct HotItem: Identifiable, Hashable {
    var id: String { source + title }
    let title: String
    let source: String
}

/// 公开热榜，只作选题参考
enum HotList {
    static func fetchAll() async -> [HotItem] {
        async let a = toutiao()
        async let b = baidu()
        let (x, y) = await (a, b)
        var seen = Set<String>()
        return (x + y).filter { seen.insert($0.title).inserted }
    }

    static func get(_ url: String) async -> Data? {
        guard let u = URL(string: url) else { return nil }
        var r = URLRequest(url: u)
        r.timeoutInterval = 15
        r.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        return try? await URLSession.shared.data(for: r).0
    }

    static func toutiao() async -> [HotItem] {
        guard let d = await get("https://www.toutiao.com/hot-event/hot-board/?origin=toutiao_pc"),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else { return [] }
        return list.prefix(30).compactMap { ($0["Title"] as? String).map { HotItem(title: $0, source: "头条") } }
    }

    static func baidu() async -> [HotItem] {
        guard let d = await get("https://top.baidu.com/board?tab=realtime"),
              let html = String(data: d, encoding: .utf8),
              let re = try? NSRegularExpression(pattern: #""word":"([^"]+)""#) else { return [] }
        let ns = html as NSString
        let words = re.matches(in: html, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
        var seen = Set<String>()
        return words.filter { seen.insert($0).inserted }.prefix(30).map { HotItem(title: $0, source: "百度") }
    }
}

/// 去 AI 味：本地规则（替换破折号，标出套话）
enum Humanize {
    static let cliches = ["不是.{1,20}而是", "值得一提的是", "总而言之", "综上所述", "在当今社会", "让我们一起", "赋能", "抓手",
                          "闭环", "底层逻辑", "不禁让人", "毋庸置疑", "众所周知", "首先.{0,40}其次"]

    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "——", with: "，")
            .replacingOccurrences(of: "，，", with: "，")
    }

    static func hits(_ s: String) -> [String] {
        cliches.compactMap { pat in
            guard let r = s.range(of: pat, options: .regularExpression) else { return nil }
            return String(s[r])
        }
    }
}

/// 一键成稿：选题 → 大纲 → 正文 → 自审 → 不及格自动返修 → 排版。只生成本地草稿，不发布。
@MainActor
final class Pipeline: ObservableObject {
    let store: Store
    @Published var running: [UUID: String] = [:]     // 稿件 id → 当前步骤
    @Published var hot: [HotItem] = []
    @Published var hotLoadedAt: Date?
    @Published var lastError: String?
    private var queue: [(String, UUID?)] = []
    private var working = false
    private var timer: Timer?

    init(store: Store) {
        self.store = store
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkDaily() }
        }
    }

    var queued: Int { queue.count }

    func refreshHot() async {
        hot = await HotList.fetchAll()
        hotLoadedAt = Date()
    }

    /// 排入队列，按顺序一篇一篇写
    func enqueue(direction: String, styleId: UUID?, count: Int = 1) {
        for _ in 0..<max(1, count) { queue.append((direction, styleId)) }
        if !working { Task { await drain() } }
    }

    private func drain() async {
        working = true
        while !queue.isEmpty {
            let (dir, sid) = queue.removeFirst()
            await produce(direction: dir, styleId: sid)
        }
        working = false
    }

    private func checkDaily() {
        let s = store.data.auto
        guard s.dailyEnabled else { return }
        let cal = Calendar.current
        let now = Date()
        guard let fire = cal.date(bySettingHour: s.dailyHour, minute: s.dailyMinute, second: 0, of: now), now >= fire else { return }
        if let last = s.lastDaily, cal.isDate(last, inSameDayAs: now) { return }
        store.data.auto.lastDaily = now
        store.save()
        enqueue(direction: "", styleId: s.dailyStyleId ?? store.data.styles.first?.id)
    }

    private func log(_ id: UUID, _ msg: String) {
        running[id] = msg
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        store.update(id) { $0.log.append("\(f.string(from: Date()))  \(msg)") }
    }

    @discardableResult
    func produce(direction: String, styleId: UUID?) async -> UUID {
        let settings = store.data.auto
        let style = store.style(styleId)
        let id = store.newArticle(topic: direction)
        store.update(id) { $0.auto = true; $0.styleId = style?.id; $0.topic = direction.isEmpty ? "自动选题中…" : direction }
        defer { running[id] = nil }
        do {
            // 1 选题
            log(id, "选题")
            var hotTitles: [String] = []
            if settings.useHot {
                if hot.isEmpty || (hotLoadedAt.map { Date().timeIntervalSince($0) > 3600 } ?? true) { await refreshHot() }
                hotTitles = hot.map(\.title)
            }
            let existing = store.data.articles.filter { $0.id != id }.map(\.displayTitle)
            let t = try await store.runJSON(.topic, TopicReply.self,
                                            Prompts.pickTopic(direction: direction, style: style, hot: hotTitles, existing: existing))
            store.update(id) {
                $0.topic = t.topic
                $0.viewpoint = t.viewpoint ?? ""
                if let a = t.angle, !a.isEmpty { $0.material = "切入角度：\(a)" }
            }
            log(id, "选题：\(t.topic)")

            // 2 大纲
            log(id, "写大纲")
            guard let a1 = store.article(id) else { return id }
            let o = try await store.runJSON(.topic, OutlineReply.self, Prompts.outline(a1, style: style))
            store.update(id) {
                if let tt = o.title, !tt.isEmpty { $0.title = tt }
                $0.outline = o.outline
                $0.sections = o.outline.map { ArticleSection(heading: ArticleEditor.headingOf($0), body: "") }
                $0.stage = .draft
            }

            // 3 正文
            let n = max(1, o.outline.count)
            let per = max(250, settings.targetWords / n)
            for i in 0..<n {
                log(id, "写第 \(i + 1)/\(n) 节")
                guard let a = store.article(id), i < a.sections.count else { break }
                let text = try await store.run(.draft, Prompts.section(a, index: i, style: style, words: per))
                store.update(id) { if i < $0.sections.count { $0.sections[i].body = Humanize.clean(text) } }
            }

            // 4 自审 + 返修
            var round = 0
            var best: (score: Int, sections: [ArticleSection], review: ReviewResult)?
            while true {
                log(id, round == 0 ? "审稿" : "第 \(round) 轮返修后重审")
                guard let a = store.article(id) else { break }
                let r = try await store.runJSON(.review, ReviewResult.self, Prompts.review(a))
                store.update(id) { $0.review = r; $0.stage = .review }
                if best == nil || r.total > best!.score { best = (r.total, a.sections, r) }
                log(id, "得分 \(r.total)")
                if r.total >= settings.passScore || round >= settings.maxRounds { break }
                round += 1
                let fixes = r.suggestions.filter { ($0.section ?? 0) >= 1 }
                let grouped = Dictionary(grouping: fixes, by: { $0.section! - 1 })
                for (idx, list) in grouped.sorted(by: { $0.key < $1.key }) {
                    guard let cur = store.article(id), idx < cur.sections.count else { continue }
                    log(id, "返修第 \(idx + 1) 节")
                    let ins = list.map { "问题：\($0.issue)；改法：\($0.fix)" }.joined(separator: "\n")
                    let text = try await store.run(.draft, Prompts.revise(cur, index: idx, instruction: ins, style: style))
                    store.update(id) { if idx < $0.sections.count { $0.sections[idx].body = Humanize.clean(text) } }
                }
            }
            // 用分数最高的一版
            if let b = best, let cur = store.article(id), (cur.review?.total ?? 0) < b.score {
                store.update(id) { $0.sections = b.sections; $0.review = b.review }
                log(id, "回退到最高分版本（\(b.score)）")
            }

            // 5 排版
            store.update(id) { $0.stage = .layout }
            let score = store.article(id)?.review?.total ?? 0
            log(id, "完成，\(score) 分，等你过目")
            notify("草稿写好了（\(score) 分）", store.article(id)?.displayTitle ?? "")
        } catch {
            log(id, "出错：\(error.localizedDescription)")
            lastError = error.localizedDescription
            notify("自动写稿失败", error.localizedDescription)
        }
        return id
    }

    func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
