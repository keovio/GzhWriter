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
    private var queue: [(String, UUID?, UUID?, UUID?, String, UUID?)] = []   // 方向、账号、参考拆解、要续写的稿件
    private var working = false
    private var fresh: Set<UUID> = []        // 刚建好、还没开始写的稿件
    @Published var focus: UUID?              // 点了写一篇：跳到这篇稿件看它写
    private var timer: Timer?

    init(store: Store) {
        self.store = store
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        // 上次软件关掉时没写完的一键成稿，标成可继续
        for a in store.data.articles where a.auto && a.failed.isEmpty && a.stage != .layout
            && !(a.log.last ?? "").contains("完成") {
            store.update(a.id) { $0.failed = "上次没写完（软件被关了或中断）" }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkDaily(); self?.checkReminders() }
        }
    }

    var queued: Int { queue.count }
    var active: Int { running.count }

    func refreshHot() async {
        hot = await HotList.fetchAll()
        hotLoadedAt = Date()
    }

    /// 排入队列，按顺序一篇一篇写。稿件马上建好（标「排队中」），show=true 时直接跳到第一篇看它写
    @discardableResult
    func enqueue(direction: String, styleId: UUID?, count: Int = 1, refId: UUID? = nil, platform: String = "wechat", accountId: UUID? = nil, show: Bool = true) -> [UUID] {
        var ids: [UUID] = []
        let style = store.style(styleId)
        let ref = store.breakdown(refId)
        for _ in 0..<max(1, count) {
            let id = store.newArticle(topic: direction)
            store.update(id) {
                $0.auto = true; $0.primary = platform; $0.accountId = accountId
                $0.styleId = style?.id; $0.refId = ref?.id
                $0.topic = direction.isEmpty ? "自动选题中…" : direction
            }
            running[id] = ids.isEmpty && !working ? "准备开始" : "排队中，等前面的写完"
            fresh.insert(id)
            queue.append((direction, styleId, refId, id, platform, accountId))
            ids.append(id)
        }
        if show, let first = ids.first { focus = first }
        if !working { Task { await drain() } }
        return ids
    }

    /// 从出错的地方接着写：已经写好的选题、大纲、段落都保留
    func resume(_ id: UUID) {
        guard running[id] == nil, !queue.contains(where: { $0.3 == id }), let a = store.article(id) else { return }
        store.update(id) { $0.failed = "" }
        running[id] = "排队中，等前面的写完"
        queue.append((a.topic, a.styleId, a.refId, id, a.primary, a.accountId))
        if !working { Task { await drain() } }
    }

    /// 所有出错停下的稿件
    var failedArticles: [Article] { store.data.articles.filter { !$0.failed.isEmpty && running[$0.id] == nil } }

    private func drain() async {
        working = true
        while !queue.isEmpty {
            let (dir, sid, ref, rid, plat, acc) = queue.removeFirst()
            if let rid {
                // 稿件被删了就跳过
                guard store.article(rid) != nil else { running[rid] = nil; fresh.remove(rid); continue }
                let isNew = fresh.remove(rid) != nil
                await work(rid, direction: dir, styleId: sid, refId: ref, resumed: !isNew)
            }
            else { await produce(direction: dir, styleId: sid, refId: ref, platform: plat, accountId: acc) }
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
        enqueue(direction: "", styleId: s.dailyStyleId ?? store.data.styles.first?.id, show: false)
    }

    /// 到了计划发布时间，提醒作者去发
    private func checkReminders() {
        let now = Date()
        for a in store.data.articles where !a.published && !a.reminded {
            guard let d = a.scheduled, d <= now else { continue }
            store.update(a.id) { $0.reminded = true }
            // 过期太久（比如电脑关着）就不补提醒
            if now.timeIntervalSince(d) > 6 * 3600 { continue }
            notify("该发文章了", "《\(a.displayTitle)》" + (a.wechatDraft.isEmpty ? "，复制排版好的正文去公众号后台发" : "，已在草稿箱，打开手机看一眼就能发"))
        }
    }

    private func log(_ id: UUID, _ msg: String) {
        running[id] = msg
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        store.update(id) { $0.log.append("\(f.string(from: Date()))  \(msg)") }
    }

    @discardableResult
    func produce(direction: String, styleId: UUID?, refId: UUID? = nil, platform: String = "wechat", accountId: UUID? = nil) async -> UUID {
        let style = store.style(styleId)
        let ref = store.breakdown(refId)
        let id = store.newArticle(topic: direction)
        store.update(id) { $0.auto = true; $0.primary = platform; $0.accountId = accountId; $0.styleId = style?.id; $0.refId = ref?.id; $0.topic = direction.isEmpty ? "自动选题中…" : direction }
        await work(id, direction: direction, styleId: styleId, refId: refId, resumed: false)
        return id
    }

    /// 真正干活的流程。每一步先看稿件里是不是已经有了，有就跳过，所以出错后可以接着跑。
    /// 模型临时出错（超时、限流）会自动等一会儿再接着跑，最多 2 次。
    func work(_ id: UUID, direction: String, styleId: UUID?, refId: UUID?, resumed: Bool) async {
        var attempt = 0
        var step = ""
        while true {
            do {
                try await steps(id, direction: direction, styleId: styleId, refId: refId, resumed: resumed || attempt > 0)
                store.update(id) { $0.failed = "" }
                if lastError != nil, failedArticles.isEmpty { lastError = nil }
                break
            } catch {
                let msg = error.localizedDescription
                if attempt == 0 { step = running[id] ?? "" }
                attempt += 1
                if attempt <= 2 && Self.transient(error) {
                    log(id, "出错：\(msg)。\(attempt * 15) 秒后自动接着写（第 \(attempt) 次）")
                    try? await Task.sleep(nanoseconds: UInt64(attempt * 15) * 1_000_000_000)
                    continue
                }
                log(id, "停下了：\(msg)")
                store.update(id) { $0.failed = (step.isEmpty ? "" : "在「\(step)」这一步") + "出错：" + msg }
                lastError = "《\(store.article(id)?.displayTitle ?? "")》" + msg
                notify("自动写稿停下了", msg + "。在工作台点「接着写」可以从断点继续。")
                break
            }
        }
        running[id] = nil
    }

    /// 没填 Key、地址不对这种，重试也没用
    static func transient(_ error: Error) -> Bool {
        if let e = error as? LLMError {
            switch e {
            case .noConnection, .noKey, .badURL: return false
            case .http(let code, _): return code == 429 || code >= 500
            default: return true
            }
        }
        return true
    }

    private func steps(_ id: UUID, direction: String, styleId: UUID?, refId: UUID?, resumed: Bool) async throws {
        let settings = store.data.auto
        let style = store.style(styleId)
        let ref = store.breakdown(refId)
        if resumed { log(id, "从断点接着写") }
        log(id, "模型：选题 \(store.modelLabel(.topic))；正文 \(store.modelLabel(.draft))；审稿 \(store.modelLabel(.review))")
        do {
          if store.article(id)?.sections.isEmpty ?? true,
             let cur = store.article(id), !resumed || cur.viewpoint.isEmpty {
            // 1 选题
            log(id, "选题")
            var hotTitles: [String] = []
            if settings.useHot {
                if hot.isEmpty || (hotLoadedAt.map { Date().timeIntervalSince($0) > 3600 } ?? true) { await refreshHot() }
                hotTitles = hot.map(\.title)
            }
            if settings.hotForTopic {
                hotTitles = HotRadar.titlesForTopic(store) + hotTitles
            }
            let existing = Dedupe.history(store, except: id)
            var rejected: [String] = []
            var t = try await store.runJSON(.topic, TopicReply.self,
                                            Prompts.pickTopic(direction: direction, style: style, hot: hotTitles, existing: existing, ref: ref))
            // 选题去重：和写过的太像就换，最多换两次
            while rejected.count < 2, let near = Dedupe.closest(t.topic, in: existing), near.1 >= Dedupe.threshold {
                log(id, "「\(t.topic)」和写过的「\(near.0)」太像，换一个")
                rejected.append(t.topic)
                t = try await store.runJSON(.topic, TopicReply.self,
                                            Prompts.pickTopic(direction: direction, style: style, hot: hotTitles, existing: existing, avoidSimilar: rejected, ref: ref))
            }
            store.update(id) {
                $0.topic = t.topic
                $0.viewpoint = t.viewpoint ?? ""
                if let a = t.angle, !a.isEmpty { $0.material = "切入角度：\(a)" }
            }
            log(id, "选题：\(t.topic)")
          }

            // 直接写小红书 / 微博：不写长文，选完题就出短内容
            if let cur = store.article(id), cur.isShort, let p = Platform.of(cur.primary) {
                if cur.variants[p.rawValue] == nil || cur.variants[p.rawValue]!.body.isEmpty {
                    log(id, "写\(p.name)")
                    try await Publisher.makeShort(store, id, p, style: style)
                }
                store.update(id) { $0.stage = .layout }
                if let v = store.article(id)?.variants[p.rawValue] {
                    let hits = Compliance.scanText(v.title + "\n" + v.body)
                    if !hits.isEmpty { log(id, "可能不合规的词：" + hits.map(\.word).joined(separator: "、")) }
                }
                log(id, "完成，等你过目")
                notify("\(p.name)写好了", store.article(id)?.displayTitle ?? "")
                return
            }

            // 素材库：挑相关的真实素材
            var mats: [Material] = []
            if let ids = store.article(id)?.materialIds, !ids.isEmpty {
                mats = store.data.materials.filter { ids.contains($0.id) }
            } else if settings.useMaterials && !store.data.materials.isEmpty {
                mats = MaterialPicker.attach(store, id)
                if !mats.isEmpty { log(id, "用上 \(mats.count) 条素材") }
            }

            // 2 大纲
            guard let a1 = store.article(id) else { return }
            if a1.sections.isEmpty {
            log(id, "定文章类型、写大纲")
            let o = try await store.runJSON(.topic, OutlineReply.self, Prompts.outline(a1, style: style, ref: ref, mats: mats))
            store.update(id) {
                if let tt = o.title, !tt.isEmpty { $0.title = tt }
                if $0.kind == "auto", let k = o.kind, let kk = ArticleKind(rawValue: k), kk != .auto { $0.kind = kk.rawValue }
                $0.outline = o.outline
                $0.sections = o.outline.map { ArticleSection(heading: ArticleEditor.headingOf($0), body: "") }
                $0.stage = .draft
            }
            }

            // 3 正文（已经写好的部分跳过）
            let n = max(1, store.article(id)?.sections.count ?? 1)
            let per = max(250, settings.targetWords / n)
            for i in 0..<n {
                guard let a = store.article(id), i < a.sections.count else { break }
                if !a.sections[i].body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                log(id, "写第 \(i + 1)/\(n) 部分")
                let text = try await store.run(.draft, Prompts.section(a, index: i, style: style, words: per, ref: ref, mats: mats))
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
                    log(id, "返修第 \(idx + 1) 部分")
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

            // 敏感词：自动改掉
            if settings.autoCompliance {
                do {
                    let n = try await Compliance.autoFix(store, id) { self.log(id, $0) }
                    if n > 0 { log(id, "改掉了 \(n) 部分的敏感用语") }
                } catch { log(id, "敏感词修改出错：\(error.localizedDescription)") }
            }

            // 标题多选：换上最高分的
            if settings.autoTitle {
                log(id, "想 5 个标题")
                do {
                    try await TitleMaker.make(store, id)
                    if let top = store.article(id)?.titleOptions.first, !top.title.isEmpty {
                        store.update(id) { $0.title = top.title }
                        log(id, "标题换成「\(top.title)」（\(top.score) 分）")
                    }
                } catch { log(id, "标题生成出错：\(error.localizedDescription)") }
            }

            // 5 排版
            store.update(id) { $0.stage = .layout }

            // 6 配图、各平台版本（出错不影响稿件本身）
            if settings.images {
                do { try await Publisher.makeImages(store, id) { self.log(id, $0) } }
                catch { log(id, "配图出错：\(error.localizedDescription)") }
            }
            let main = store.article(id)?.primary ?? "wechat"
            if main != "wechat", let p = Platform.of(main) {
                log(id, "生成\(p.name)版本")
                do { try await Publisher.makeVariants(store, id, only: [p]) }
                catch { log(id, "\(p.name)版本出错：\(error.localizedDescription)") }
            } else if settings.variants {
                log(id, "生成各平台版本：" + Platform.others(store).map(\.name).joined(separator: "、"))
                do { try await Publisher.makeVariants(store, id) }
                catch { log(id, "平台版本出错：\(error.localizedDescription)") }
            }

            // 7 推公众号草稿箱（只存草稿，不发表）
            var pushed = false
            if main == "wechat", store.data.wechat.autoPush, let art = store.article(id), store.wechatAccount(for: art) != nil {
                do { try await Publisher.pushDraft(store, id) { self.log(id, $0) }; pushed = true }
                catch { log(id, "推草稿箱失败：\(error.localizedDescription)") }
            }

            // 8 排进发布日历
            var when = ""
            if settings.autoSchedule, let slot = PublishPlan.schedule(store, id) {
                when = PublishPlan.label(slot)
                log(id, "排到 \(when) 发布，到点提醒你")
            }

            let score = store.article(id)?.review?.total ?? 0
            log(id, "完成，\(score) 分，等你过目")
            notify(pushed ? "已进公众号草稿箱（\(score) 分）" : "草稿写好了（\(score) 分）",
                   (store.article(id)?.displayTitle ?? "") + (pushed ? "，在手机上看一眼再发表" : "") + (when.isEmpty ? "" : "。计划 \(when) 发"))
        }
    }

    func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
