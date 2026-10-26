import AppKit
import SwiftUI
import WebKit

// MARK: - 数据

/// 一条上过榜的内容：公众号热文，或头条/百度/知乎/微博/抖音/小红书热榜上的话题
struct HotArticle: Identifiable, Codable, Hashable {
    var id: String          // 链接
    var title: String
    var reads: String       // 榜单显示的阅读数 / 热度，如「10.0万」
    var readsNum: Int
    var category: String    // 公众号热文的领域；其他平台就是平台名
    var biz: String         // 公众号标识（链接里的 __biz）
    var platform = "wechat" // wechat / toutiao / baidu / zhihu / weibo / douyin / xiaohongshu
    var rank = 0            // 最近一次在榜单上的名次
    var firstSeen = Date()
    var lastSeen = Date()
    var seen = 1            // 上榜天数（按天累计）

    enum CodingKeys: String, CodingKey { case id, title, reads, readsNum, category, biz, platform, rank, firstSeen, lastSeen, seen }
    init(id: String, title: String, reads: String, readsNum: Int, category: String, biz: String, platform: String = "wechat", rank: Int = 0) {
        self.id = id; self.title = title; self.reads = reads; self.readsNum = readsNum
        self.category = category; self.biz = biz; self.platform = platform; self.rank = rank
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        reads = (try? c.decode(String.self, forKey: .reads)) ?? ""
        readsNum = (try? c.decode(Int.self, forKey: .readsNum)) ?? 0
        category = (try? c.decode(String.self, forKey: .category)) ?? ""
        biz = (try? c.decode(String.self, forKey: .biz)) ?? ""
        platform = (try? c.decode(String.self, forKey: .platform)) ?? "wechat"
        rank = (try? c.decode(Int.self, forKey: .rank)) ?? 0
        firstSeen = (try? c.decode(Date.self, forKey: .firstSeen)) ?? Date()
        lastSeen = (try? c.decode(Date.self, forKey: .lastSeen)) ?? Date()
        seen = (try? c.decode(Int.self, forKey: .seen)) ?? 1
    }

    var isWechat: Bool { platform == "wechat" }
}

enum HotCategory {
    /// 今日热榜（tophub.today）上的微信 24h 热文榜节点
    static let all: [(String, String)] = [
        ("综合", "WnBe01o371"), ("教育", "MZd7BVYvrO"), ("职场", "DOvn33ydEB"), ("财经", "Ywv4BJRePa"),
        ("情感", "1VdJ77keLQ"), ("健康", "Q0orrr0o8B"), ("社会", "KGoRGRDvl6"), ("科技", "5PdMaaadmg"),
        ("生活", "nBe0xxje37"), ("文化", "proPGGOeq6"), ("历史", "x9ozmmYeXb"), ("育儿", "aqeE55je9R"),
        ("房产", "YKd6RJwdaP"), ("汽车", "RrvWVOQo5z"), ("美食", "m4ejxxyvxE"), ("娱乐", "6YoVqqGeZa"),
        ("影视", "47o8RRQdMm"), ("旅行", "qndgqqLoLl"), ("体育", "JndkaEVo3V"), ("军事", "WmoOxxDv4E"),
        ("时尚", "b0vmYYWvB1"), ("搞笑", "wkvlBMgez1"), ("星座", "YqoXllKoOD"), ("游戏", "4qv9abqvaK"),
        ("宠物", "1Vd588av85"), ("农业", "0MdKVVJvw1"), ("文学", "7GdagbYoQy"), ("摄影", "3moBKKPvN5"),
        ("动漫", "aEdZZqOdrO"),
    ]

    static func url(_ name: String) -> URL? {
        guard let node = all.first(where: { $0.0 == name })?.1 else { return nil }
        return URL(string: "https://tophub.today/n/\(node)")
    }

    /// 「10.0万」「918.6w」「1.2亿」「108706314次播放」都转成数字
    static func readsNumber(_ s: String) -> Int {
        var num = ""
        var unit: Double = 1
        for ch in s {
            if ch.isNumber || ch == "." { num.append(ch) }
            else if !num.isEmpty {
                if ch == "万" || ch == "w" || ch == "W" { unit = 10000 }
                else if ch == "亿" { unit = 100_000_000 }
                else if ch == "k" || ch == "K" { unit = 1000 }
                break
            }
        }
        return Int((Double(num) ?? 0) * unit)
    }

    static func biz(_ link: String) -> String {
        guard let c = URLComponents(string: link) else { return "" }
        return c.queryItems?.first(where: { $0.name == "__biz" })?.value ?? ""
    }
}

// MARK: - 抓取

/// 用内置浏览器打开榜单页读表格。网站弹安全验证时把窗口亮出来，作者自己过一下就行。
@MainActor
final class HotRadar: NSObject, ObservableObject, WKNavigationDelegate {
    let store: Store
    @Published var status = ""
    @Published var loading = false
    @Published var needsVerify = false

    private var web: WKWebView!
    private var window: NSWindow?
    private var loaded: CheckedContinuation<Void, Never>?
    private var timer: Timer?

    init(store: Store) {
        self.store = store
        super.init()
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 800), configuration: cfg)
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        web.navigationDelegate = self
        trends = computeTrends()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.autoRefresh() }
        }
    }

    var categories: [String] {
        let c = store.data.auto.hotCategories
        return c.isEmpty ? ["综合"] : c
    }

    var stale: Bool {
        guard let t = store.data.auto.lastHotFetch else { return true }
        return Date().timeIntervalSince(t) > 6 * 3600
    }

    /// app 开着时每 6 小时自动拉一次
    func autoRefresh() async {
        if store.data.auto.hotAuto && stale && !loading { await refresh() }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            loaded?.resume()
            loaded = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in loaded?.resume(); loaded = nil }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in loaded?.resume(); loaded = nil }
    }

    private func load(_ url: URL) async {
        if let c = loaded { c.resume(); loaded = nil }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            loaded = c
            web.load(URLRequest(url: url))
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                if let self, let c = self.loaded { self.loaded = nil; c.resume() }
            }
        }
    }

    struct Row { let title: String; let link: String; let reads: String; let rank: Int }
    @Published var updated: [String: String] = [:]     // 每个榜单页上写的更新时间
    @Published var trends: [Trend] = []
    private var nameTried = Set<String>()

    private static let extractJS = """
    (function() {
      var out = [];
      var n = 0;
      document.querySelectorAll('table tr').forEach(function(tr) {
        if (n >= 60) return;
        var tds = tr.querySelectorAll('td');
        if (tds.length < 2) return;
        var a = null;
        tr.querySelectorAll('a').forEach(function(x) { if (!a && x.textContent.trim().length > 0) a = x; });
        if (!a) return;
        var heat = '';
        for (var i = tds.length - 1; i >= 0; i--) {
          var t = tds[i].textContent.trim();
          if (t && !tds[i].contains(a) && !/^\\d+\\.?$/.test(t)) { heat = t; break; }
        }
        n += 1;
        out.push([a.textContent.trim(), a.href, heat]);
      });
      var body = document.body ? document.body.innerText : '';
      var m = body.match(/最新\\S*\\s*(\\S+?)更新/);
      return JSON.stringify({ title: document.title, rows: out, updated: m ? m[1] : '',
                              ok: !!document.querySelector('table') || /历史快照/.test(body) });
    })()
    """

    private struct Extract { var title = ""; var rows: [Row] = []; var updated = ""; var ok = false }

    private func extract() async -> Extract {
        guard let s = try? await web.evaluateJavaScript(Self.extractJS) as? String,
              let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return Extract() }
        var e = Extract()
        e.title = o["title"] as? String ?? ""
        e.updated = o["updated"] as? String ?? ""
        e.ok = o["ok"] as? Bool ?? false
        for (i, r) in ((o["rows"] as? [[String]]) ?? []).enumerated() where r.count >= 3 {
            e.rows.append(Row(title: r[0], link: r[1], reads: r[2], rank: i + 1))
        }
        return e
    }

    /// 读一页；碰到验证就亮窗口，等作者过完（最多 3 分钟）
    private func fetch(_ url: URL) async -> Extract {
        await load(url)
        var r = await extract()
        if !r.rows.isEmpty { return r }
        // 页面正常但榜单是空的（节点停更），不用验证
        if r.ok && !r.title.contains("验证") { return r }
        showWindow()
        needsVerify = true
        status = "榜单网站要做一次安全验证，在弹出的窗口里过一下就好"
        for _ in 0..<90 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            r = await extract()
            if !r.rows.isEmpty || window?.isVisible == false { break }
        }
        needsVerify = false
        hideWindow()
        return r
    }

    func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "今日热榜 · 安全验证（过完会自动关闭）"
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.contentView = web
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideWindow() {
        window?.orderOut(nil)
        window?.contentView = nil
    }

    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        var total = 0
        for name in categories {
            guard let u = HotCategory.url(name) else { continue }
            status = "正在读公众号「\(name)」热文榜…"
            let r = await fetch(u)
            merge(r.rows, category: name, platform: "wechat")
            if !r.updated.isEmpty { updated["wechat:" + name] = r.updated }
            total += r.rows.count
        }
        for src in HotSource.all where store.data.auto.hotSources.contains(src.key) {
            status = "正在读\(src.name)热榜…"
            let r = await fetch(src.url)
            merge(r.rows, category: src.name, platform: src.key)
            if !r.updated.isEmpty { updated[src.key] = r.updated }
            total += r.rows.count
        }
        store.data.auto.lastHotFetch = Date()
        prune()
        store.save()
        trends = computeTrends()
        status = total == 0 ? "没读到榜单，稍后再试" : "已更新 \(total) 条"
        await fillNames()
    }

    private func merge(_ rows: [Row], category: String, platform: String) {
        let cal = Calendar.current
        let now = Date()
        for r in rows where !r.title.isEmpty {
            let num = HotCategory.readsNumber(r.reads)
            if let i = store.data.hot.firstIndex(where: { $0.id == r.link }) {
                if !cal.isDate(store.data.hot[i].lastSeen, inSameDayAs: now) { store.data.hot[i].seen += 1 }
                store.data.hot[i].lastSeen = now
                store.data.hot[i].reads = r.reads
                store.data.hot[i].readsNum = num
                store.data.hot[i].rank = r.rank
            } else {
                store.data.hot.append(HotArticle(id: r.link, title: r.title, reads: r.reads, readsNum: num,
                                                 category: category,
                                                 biz: platform == "wechat" ? HotCategory.biz(r.link) : "",
                                                 platform: platform, rank: r.rank))
            }
        }
    }

    /// 只留最近 7 天
    private func prune() {
        let cut = Date().addingTimeInterval(-7 * 86400)
        store.data.hot.removeAll { $0.lastSeen < cut }
        if store.data.hot.count > 3000 {
            store.data.hot.sort { $0.lastSeen > $1.lastSeen }
            store.data.hot = Array(store.data.hot.prefix(3000))
        }
    }

    /// 补公众号名：用内置浏览器打开文章读 #js_name。先补阅读量高的。
    func fillNames(limit: Int = 30) async {
        var todo: [String: (String, Int)] = [:]
        for h in store.data.hot where h.isWechat && !h.biz.isEmpty
            && (store.data.hotNames[h.biz] ?? "").isEmpty && !nameTried.contains(h.biz) {
            if (todo[h.biz]?.1 ?? -1) < h.readsNum { todo[h.biz] = (h.id, h.readsNum) }
        }
        let list = todo.sorted { $0.value.1 > $1.value.1 }.prefix(limit)
        if list.isEmpty { return }
        let base = status
        var n = 0
        var blocked = 0
        for (biz, v) in list {
            n += 1
            status = base + "，正在补公众号名 \(n)/\(list.count)…"
            nameTried.insert(biz)
            if let p = await WebReader.shared.read(v.0, timeout: 12), !p.name.isEmpty {
                store.data.hotNames[biz] = p.name
                blocked = 0
                store.save()
            } else if WebReader.shared.lastWasCaptcha {
                blocked += 1
                if blocked >= 3 { status = base + "，微信要求验证，公众号名先补到这"; return }
            }
        }
        status = base
    }

    // MARK: 给选题和拆解用

    /// 一键成稿自动选题时参考的热文和各平台热点
    static func titlesForTopic(_ store: Store, limit: Int = 30) -> [String] {
        let cut = Date().addingTimeInterval(-2 * 86400)
        let cats = store.data.auto.hotCategories.isEmpty ? ["综合"] : store.data.auto.hotCategories
        let list = store.data.hot.filter { $0.isWechat && $0.lastSeen >= cut && cats.contains($0.category) }
            .sorted { $0.readsNum > $1.readsNum }
        var out = list.prefix(limit).map { "【公众号热文】" + $0.title }
        let day = Date().addingTimeInterval(-86400)
        let others = store.data.hot.filter { !$0.isWechat && $0.lastSeen >= day && $0.rank > 0 && $0.rank <= 10 }
            .sorted { $0.rank < $1.rank }
        out += others.prefix(30).map { "【\(HotSource.name($0.platform))热榜】" + $0.title }
        return out
    }

    struct Account: Identifiable {
        var id: String { biz }
        let biz: String
        let name: String
        let count: Int      // 上榜篇次（按天累计）
        let articles: Int   // 上榜文章数
        let reads: Int
        let best: Int
        let top: HotArticle
    }

    func accounts(sort: Int) -> [Account] {
        var groups: [String: [HotArticle]] = [:]
        for h in store.data.hot where h.isWechat && !h.biz.isEmpty { groups[h.biz, default: []].append(h) }
        var out: [Account] = []
        for (biz, list) in groups {
            let sorted = list.sorted { $0.readsNum > $1.readsNum }
            var count = 0
            var reads = 0
            for h in list { count += h.seen; reads += h.readsNum }
            out.append(Account(biz: biz, name: store.data.hotNames[biz] ?? "", count: count, articles: list.count,
                               reads: reads, best: sorted[0].readsNum, top: sorted[0]))
        }
        switch sort {
        case 1: out.sort { ($0.reads, $0.count) > ($1.reads, $1.count) }
        case 2: out.sort { ($0.best, $0.count) > ($1.best, $1.count) }
        default: out.sort { ($0.count, $0.reads) > ($1.count, $1.reads) }
        }
        return out
    }

    /// 已经攒了几天的公众号数据
    var collectedDays: Int {
        guard let first = store.data.hot.filter(\.isWechat).map(\.firstSeen).min() else { return 0 }
        return (Calendar.current.dateComponents([.day], from: first, to: Date()).day ?? 0) + 1
    }

    // MARK: 全网最火：各平台在说同一件事的合在一起

    struct Trend: Identifiable {
        let id: String
        let title: String
        var items: [HotArticle]
        var platforms: [String]
        var score: Double
        var best: HotArticle
    }

    func computeTrends() -> [Trend] {
        let day = Date().addingTimeInterval(-36 * 3600)
        var pool = store.data.hot.filter { !$0.isWechat && $0.lastSeen >= day }
        let wechat = store.data.hot.filter { $0.isWechat && $0.lastSeen >= day }
            .sorted { $0.readsNum > $1.readsNum }.prefix(60)
        for (i, item) in wechat.enumerated() {
            var w = item
            w.rank = i + 1
            pool.append(w)
        }

        func weight(_ h: HotArticle) -> Double { max(0.05, 1 - Double(max(h.rank, 1) - 1) / 50) }
        pool.sort { weight($0) > weight($1) }

        var trends: [Trend] = []
        var heads: [Set<String>] = []
        for h in pool {
            let b = Dedupe.bigrams(h.title)
            var hit = -1
            for (k, hb) in heads.enumerated() {
                let inter = b.intersection(hb).count
                guard inter >= 3, !b.isEmpty, !hb.isEmpty else { continue }
                if Double(inter) / Double(min(b.count, hb.count)) >= 0.55 { hit = k; break }
            }
            if hit >= 0 {
                trends[hit].items.append(h)
                if !trends[hit].platforms.contains(h.platform) {
                    trends[hit].platforms.append(h.platform)
                    trends[hit].score += 1 + weight(h) * 0.5
                }
            } else {
                heads.append(b)
                trends.append(Trend(id: h.id, title: h.title, items: [h], platforms: [h.platform],
                                    score: 1 + weight(h), best: h))
            }
        }
        trends.sort { $0.score > $1.score }
        return Array(trends.prefix(80))
    }
}

// MARK: - 拆解（供雷达直接调用）

enum BreakdownMaker {
    @MainActor
    static func make(_ store: Store, url link: String) async throws -> Breakdown {
        let page = try await PageReader.read(link)
        guard page.text.count > 200 else { throw ReadError() }
        let title = page.title.isEmpty ? String(page.text.prefix(30)) : page.title
        let r = try await store.runJSON(.review, BreakdownReply.self, Prompts.breakdown(title: title, text: page.text))
        var b = Breakdown()
        b.url = link; b.sourceTitle = title
        b.titleFormula = r.titleFormula ?? ""; b.hook = r.hook ?? ""
        b.structure = r.structure ?? []; b.techniques = r.techniques ?? []
        b.ending = r.ending ?? ""; b.fitTopics = r.fitTopics ?? []
        store.data.breakdowns.insert(b, at: 0)
        store.save()
        return b
    }
}

// MARK: - 页面

struct RadarView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var pipeline: Pipeline
    @EnvironmentObject var radar: HotRadar
    @StateObject private var busy = Busy()
    @State private var tab = "trend"        // trend / wechat / 各平台 key
    @State private var wxMode = 0           // 0 热文 1 爆款号
    @State private var wxSort = 0           // 热文：0 阅读数 1 上榜天数 2 综合；爆款号：0 上榜次数 1 总阅读 2 单篇最高
    @State private var filter = "全部"
    @State private var showCats = false
    @State private var done: Set<String> = []

    var tabs: [(String, String)] {
        var t: [(String, String)] = [("trend", "全网最火"), ("wechat", "公众号")]
        for s in HotSource.all where store.data.auto.hotSources.contains(s.key) { t.append((s.key, s.name)) }
        return t
    }

    var articles: [HotArticle] {
        let cut = Date().addingTimeInterval(-2 * 86400)
        var list = store.data.hot.filter { $0.isWechat && $0.lastSeen >= cut }
        if filter != "全部" { list = list.filter { $0.category == filter } }
        switch wxSort {
        case 1: list.sort { ($0.seen, $0.readsNum) > ($1.seen, $1.readsNum) }
        case 2: list.sort { Double($0.readsNum) * Double($0.seen) > Double($1.readsNum) * Double($1.seen) }
        default: list.sort { $0.readsNum != $1.readsNum ? $0.readsNum > $1.readsNum : $0.lastSeen > $1.lastSeen }
        }
        // 同一篇在多个领域榜上只留一条
        var seen = Set<String>()
        list = list.filter { seen.insert($0.id).inserted }
        return Array(list.prefix(150))
    }

    func topics(_ key: String) -> [HotArticle] {
        let cut = Date().addingTimeInterval(-36 * 3600)
        let list = store.data.hot.filter { $0.platform == key && $0.lastSeen >= cut }
        let newest = list.map(\.lastSeen).max() ?? Date()
        // 只看最近一次刷新还在榜上的，按名次排
        return list.filter { newest.timeIntervalSince($0.lastSeen) < 1800 }.sorted { $0.rank < $1.rank }
    }

    var body: some View {
        Page {
            PageHeader(title: "热点雷达", subtitle: "公众号爆文，加上头条、百度、知乎、微博、小红书的热榜。只学选题和写法，不搬原文。") {
                Button { Task { await radar.refresh() } } label: {
                    HStack(spacing: 4) { Image(systemName: "arrow.clockwise"); Text(radar.loading ? "读取中…" : "刷新") }
                }
                .buttonStyle(PrimaryButton())
                .disabled(radar.loading)
            }
            controls
            BusyBar(busy: busy)
            switch tab {
            case "trend": trendList
            case "wechat": if wxMode == 0 { articleList } else { accountList }
            default: topicList(tab)
            }
        }
        .task { if radar.stale && !radar.loading { await radar.refresh() } }
    }

    // MARK: 顶部

    var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(tabs, id: \.0) { key, name in tabChip(key, name) }
                Spacer()
                if !radar.status.isEmpty {
                    Text(radar.status).font(.system(size: 12))
                        .foregroundStyle(radar.needsVerify ? Theme.orange : Theme.sub).lineLimit(1)
                }
            }
            if tab == "wechat" {
                HStack(spacing: 10) {
                    Picker("", selection: $wxMode) {
                        Text("热文").tag(0)
                        Text("爆款公众号").tag(1)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 190)
                    Picker("", selection: $wxSort) {
                        if wxMode == 0 {
                            Text("按阅读数").tag(0)
                            Text("按上榜天数").tag(1)
                            Text("综合热度").tag(2)
                        } else {
                            Text("按上榜次数").tag(0)
                            Text("按总阅读").tag(1)
                            Text("按单篇最高").tag(2)
                        }
                    }
                    .labelsHidden().frame(width: 120)
                    if wxMode == 0 {
                        Picker("", selection: $filter) {
                            Text("全部领域").tag("全部")
                            ForEach(radar.categories, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().frame(width: 110)
                    }
                    Spacer()
                    Button(showCats ? "收起" : "选领域（\(radar.categories.joined(separator: "、")))") { showCats.toggle() }
                        .buttonStyle(LinkButton()).lineLimit(1)
                }
                if showCats { categoryPicker }
            } else if tab == "trend" {
                HStack(spacing: 10) {
                    Text("把各平台榜单上说同一件事的合在一起，上榜平台越多越靠前。")
                        .font(.system(size: 12)).foregroundStyle(Theme.sub)
                    Spacer()
                    sourceToggles
                }
            } else if let u = radar.updated[tab] {
                Text("榜单更新于 \(u)").font(.system(size: 12)).foregroundStyle(Theme.sub)
            }
        }
        .card()
    }

    func tabChip(_ key: String, _ name: String) -> some View {
        let on = tab == key
        return Button {
            tab = key
            wxSort = 0
        } label: {
            Text(name).font(.system(size: 12, weight: on ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .foregroundStyle(on ? Color.white : Theme.sub)
                .background(on ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.bg), in: Capsule())
        }
        .buttonStyle(RowButton())
    }

    var sourceToggles: some View {
        Menu("要看的平台") {
            ForEach(HotSource.all) { s in
                let on = store.data.auto.hotSources.contains(s.key)
                Button((on ? "✓ " : "   ") + s.name) {
                    if on { store.data.auto.hotSources.removeAll { $0 == s.key } } else { store.data.auto.hotSources.append(s.key) }
                    store.save()
                }
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    var categoryPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 10), spacing: 6) {
                ForEach(HotCategory.all, id: \.0) { item in catChip(item.0) }
            }
            HStack {
                Button("全选") { store.data.auto.hotCategories = HotCategory.all.map(\.0); store.save() }.buttonStyle(LinkButton())
                Button("只留综合") { store.data.auto.hotCategories = ["综合"]; store.save() }.buttonStyle(LinkButton(color: Theme.sub))
                Text("领域越多刷新越慢，选完点刷新").font(.system(size: 11)).foregroundStyle(Theme.faint)
                Spacer()
                Toggle("每 6 小时自动更新（app 开着时）", isOn: Binding(get: { store.data.auto.hotAuto },
                                                              set: { store.data.auto.hotAuto = $0; store.save() }))
                    .toggleStyle(.checkbox).font(.system(size: 12))
                Toggle("一键成稿选题时参考热点", isOn: Binding(get: { store.data.auto.hotForTopic },
                                                       set: { store.data.auto.hotForTopic = $0; store.save() }))
                    .toggleStyle(.checkbox).font(.system(size: 12))
            }
        }
    }

    func catChip(_ name: String) -> some View {
        let on = store.data.auto.hotCategories.contains(name)
        return Button {
            if on { store.data.auto.hotCategories.removeAll { $0 == name } } else { store.data.auto.hotCategories.append(name) }
            store.save()
        } label: {
            Text(name).font(.system(size: 12, weight: on ? .semibold : .regular))
                .frame(maxWidth: .infinity).padding(.vertical, 5)
                .foregroundStyle(on ? Color.white : Theme.sub)
                .background(on ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.bg), in: Capsule())
        }
        .buttonStyle(RowButton())
    }

    func rankText(_ rank: Int) -> some View {
        Text("\(rank)").font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(rank <= 3 ? Theme.orange : Theme.faint).frame(width: 28)
    }

    func empty() -> some View {
        Text(radar.loading ? "正在读取榜单…" : "还没有数据，点右上角刷新。")
            .font(.system(size: 13)).foregroundStyle(Theme.sub)
    }

    // MARK: 全网最火

    @ViewBuilder var trendList: some View {
        let list = radar.trends
        if list.isEmpty { empty() }
        VStack(spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.element.id) { i, t in
                HStack(spacing: 12) {
                    rankText(i + 1)
                    VStack(alignment: .leading, spacing: 5) {
                        Button(t.title) { if let u = URL(string: t.best.id) { NSWorkspace.shared.open(u) } }
                            .buttonStyle(LinkButton(color: Theme.ink)).lineLimit(2).multilineTextAlignment(.leading)
                        HStack(spacing: 5) {
                            ForEach(t.platforms, id: \.self) { PlatformTag(key: $0) }
                            if t.platforms.count > 1 {
                                Text("\(t.platforms.count) 个平台在热议").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.orange)
                            }
                            if !t.best.reads.isEmpty {
                                Text(t.best.reads).font(.system(size: 11)).foregroundStyle(Theme.pink)
                            }
                        }
                    }
                    Spacer()
                    topicActions(t.best)
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
                if i < list.count - 1 { Divider() }
            }
        }
        .card(padding: 6)
    }

    // MARK: 其他平台热榜

    @ViewBuilder func topicList(_ key: String) -> some View {
        let list = topics(key)
        if list.isEmpty {
            Text(radar.loading ? "正在读取榜单…" : "这个榜单还没读到内容，点右上角刷新；如果一直是空的，可能是源网站停更了。")
                .font(.system(size: 13)).foregroundStyle(Theme.sub)
        }
        VStack(spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.element.id) { i, h in
                HStack(spacing: 12) {
                    rankText(h.rank)
                    VStack(alignment: .leading, spacing: 4) {
                        Button(h.title) { if let u = URL(string: h.id) { NSWorkspace.shared.open(u) } }
                            .buttonStyle(LinkButton(color: Theme.ink)).lineLimit(2).multilineTextAlignment(.leading)
                        HStack(spacing: 8) {
                            if !h.reads.isEmpty { Text(h.reads).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.pink) }
                            if h.seen > 1 { Text("连续上榜 \(h.seen) 天").font(.system(size: 11)).foregroundStyle(Theme.orange) }
                        }
                    }
                    Spacer()
                    topicActions(h)
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
                if i < list.count - 1 { Divider() }
            }
        }
        .card(padding: 6)
    }

    /// 热点话题：加选题 / 围绕它写一篇（公众号文章另外有拆解）
    @ViewBuilder func topicActions(_ h: HotArticle) -> some View {
        if h.isWechat {
            actions(h)
        } else {
            HStack(spacing: 6) {
                Button(done.contains("i" + h.id) ? "已加入" : "加选题") { addIdea(h) }
                    .buttonStyle(GhostButton()).disabled(done.contains("i" + h.id))
                Button { writeAbout(h) } label: {
                    HStack(spacing: 3) { Image(systemName: "sparkles"); Text(done.contains("w" + h.id) ? "已排队" : "借这个热点写") }
                }
                .buttonStyle(PrimaryButton()).disabled(done.contains("w" + h.id))
            }
        }
    }

    // MARK: 公众号热文

    @ViewBuilder var articleList: some View {
        if articles.isEmpty { empty() }
        VStack(spacing: 0) {
            ForEach(Array(articles.enumerated()), id: \.element.id) { i, h in
                articleRow(i + 1, h)
                if i < articles.count - 1 { Divider() }
            }
        }
        .card(padding: 6)
    }

    func accountName(_ h: HotArticle) -> String {
        let n = store.data.hotNames[h.biz] ?? ""
        if !n.isEmpty { return n }
        return radar.loading || radar.status.contains("公众号名") ? "公众号名读取中" : "公众号名暂未读到"
    }

    func articleRow(_ rank: Int, _ h: HotArticle) -> some View {
        let similar = Dedupe.closest(h.title, in: Dedupe.history(store)).map { $0.1 >= 0.6 } ?? false
        let named = !(store.data.hotNames[h.biz] ?? "").isEmpty
        return HStack(spacing: 12) {
            rankText(rank)
            VStack(alignment: .leading, spacing: 4) {
                Button(h.title) { if let u = URL(string: h.id) { NSWorkspace.shared.open(u) } }
                    .buttonStyle(LinkButton(color: Theme.ink))
                    .lineLimit(2).multilineTextAlignment(.leading)
                HStack(spacing: 8) {
                    Text(h.reads + " 阅读").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.pink)
                    HStack(spacing: 3) {
                        Image(systemName: "person.crop.square").font(.system(size: 10))
                        Text(accountName(h))
                    }
                    .font(.system(size: 11, weight: named ? .semibold : .regular))
                    .foregroundStyle(named ? Theme.ink : Theme.faint)
                    Chip(text: h.category)
                    if h.seen > 1 { Text("连续上榜 \(h.seen) 天").font(.system(size: 11)).foregroundStyle(Theme.orange) }
                    if similar { Text("和写过的选题相近").font(.system(size: 11)).foregroundStyle(Theme.faint) }
                }
            }
            Spacer()
            actions(h)
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
    }

    func actions(_ h: HotArticle) -> some View {
        HStack(spacing: 6) {
            Button(done.contains("i" + h.id) ? "已加入" : "加选题") { addIdea(h) }
                .buttonStyle(GhostButton()).disabled(done.contains("i" + h.id))
            Button("拆解") { breakdown(h, write: false) }
                .buttonStyle(GhostButton()).disabled(busy.label != nil)
            Button { breakdown(h, write: true) } label: {
                HStack(spacing: 3) { Image(systemName: "sparkles"); Text("用它写一篇") }
            }
            .buttonStyle(PrimaryButton()).disabled(busy.label != nil)
        }
    }

    // MARK: 爆款公众号

    @ViewBuilder var accountList: some View {
        let list = radar.accounts(sort: wxSort)
        let days = radar.collectedDays
        if list.isEmpty { empty() }
        if days > 0 && days < 3 {
            Text("已采集 \(days) 天。上榜次数要攒几天才准，先看「按单篇最高」更直观。")
                .font(.system(size: 12)).foregroundStyle(Theme.orange)
        }
        VStack(spacing: 0) {
            ForEach(Array(list.prefix(60).enumerated()), id: \.element.id) { i, a in
                HStack(spacing: 12) {
                    rankText(i + 1)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(a.name.isEmpty ? "公众号名暂未读到" : a.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(a.name.isEmpty ? Theme.faint : Theme.ink)
                        Button("代表作：" + a.top.title) { if let u = URL(string: a.top.id) { NSWorkspace.shared.open(u) } }
                            .buttonStyle(LinkButton(color: Theme.sub)).lineLimit(1)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("上榜 \(a.count) 次 · \(a.articles) 篇").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.navy)
                        Text("最高 " + Self.wan(a.best) + " · 合计 " + Self.wan(a.reads)).font(.system(size: 11)).foregroundStyle(Theme.faint)
                    }
                    Button("拆解代表作") { breakdown(a.top, write: false) }
                        .buttonStyle(GhostButton()).disabled(busy.label != nil)
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
                if i < min(list.count, 60) - 1 { Divider() }
            }
        }
        .card(padding: 6)
        HStack {
            Text("按最近 7 天各领域热文榜统计。公众号名靠打开文章读取，微信要求验证时会读不到。")
                .font(.system(size: 11)).foregroundStyle(Theme.faint)
            Spacer()
            Button("再补一批公众号名") { Task { await radar.fillNames(limit: 30) } }
                .buttonStyle(LinkButton()).disabled(radar.loading)
        }
    }

    static func wan(_ n: Int) -> String {
        n >= 10000 ? String(format: "%.1f万", Double(n) / 10000) : "\(n)"
    }

    // MARK: 动作

    func addIdea(_ h: HotArticle) {
        let angle = h.isWechat ? "参考热文（\(h.reads) 阅读），换自己的角度写" : "\(HotSource.name(h.platform))热榜话题，找和自己赛道相关的角度"
        store.data.ideas.insert(TopicIdea(title: h.title, angle: angle), at: 0)
        store.save()
        done.insert("i" + h.id)
    }

    func writeAbout(_ h: HotArticle) {
        let dir = "借「\(h.title)」这个热点写一篇，找和我的赛道、读者相关的角度，不复述新闻本身"
        pipeline.enqueue(direction: dir, styleId: store.data.auto.dailyStyleId ?? store.data.styles.first?.id)
        done.insert("w" + h.id)
        radar.status = "已排进写作队列，在工作台看进度"
    }

    func breakdown(_ h: HotArticle, write: Bool) {
        let link = h.id
        let title = h.title
        busy.run("正在拆解《\(title.prefix(18))》…") {
            let b: Breakdown
            if let old = store.data.breakdowns.first(where: { $0.url == link }) { b = old }
            else { b = try await BreakdownMaker.make(store, url: link) }
            if write {
                pipeline.enqueue(direction: "", styleId: store.data.auto.dailyStyleId ?? store.data.styles.first?.id, refId: b.id)
                radar.status = "已排进写作队列，写法参考《\(title.prefix(14))》"
            } else {
                radar.status = "拆解好了，在「爆文拆解」里看"
            }
        }
    }
}
