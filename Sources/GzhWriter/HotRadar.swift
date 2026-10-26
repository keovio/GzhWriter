import AppKit
import SwiftUI
import WebKit

// MARK: - 数据

/// 一条上过榜的公众号热文
struct HotArticle: Identifiable, Codable, Hashable {
    var id: String          // 文章链接
    var title: String
    var reads: String       // 榜单显示的阅读数，如「10.0万」
    var readsNum: Int
    var category: String
    var biz: String         // 公众号标识（链接里的 __biz）
    var firstSeen = Date()
    var lastSeen = Date()
    var seen = 1            // 上榜次数（按天累计）
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

    static func readsNumber(_ s: String) -> Int {
        let t = s.replacingOccurrences(of: "+", with: "").trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("万"), let v = Double(t.dropLast()) { return Int(v * 10000) }
        return Int(t) ?? 0
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

    struct Row { let title: String; let link: String; let reads: String }

    private static let extractJS = """
    (function() {
      var out = [];
      document.querySelectorAll('table tr').forEach(function(tr) {
        var a = tr.querySelector('a[href*="mp.weixin.qq.com"]');
        if (!a) return;
        var tds = tr.querySelectorAll('td');
        var reads = tds.length > 2 ? tds[2].textContent.trim() : '';
        out.push([a.textContent.trim(), a.href, reads]);
      });
      return JSON.stringify({ title: document.title, rows: out });
    })()
    """

    private func extract() async -> (title: String, rows: [Row]) {
        guard let s = try? await web.evaluateJavaScript(Self.extractJS) as? String,
              let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return ("", []) }
        let title = o["title"] as? String ?? ""
        var rows: [Row] = []
        for r in (o["rows"] as? [[String]]) ?? [] where r.count >= 3 {
            rows.append(Row(title: r[0], link: r[1], reads: r[2]))
        }
        return (title, rows)
    }

    /// 读一页；碰到验证就亮窗口，等作者过完（最多 3 分钟）
    private func fetch(_ name: String) async -> [Row] {
        guard let u = HotCategory.url(name) else { return [] }
        await load(u)
        var r = await extract()
        if !r.rows.isEmpty { return r.rows }
        if r.title.contains("验证") || r.rows.isEmpty {
            showWindow()
            needsVerify = true
            status = "榜单网站要做一次安全验证，在弹出的窗口里过一下就好"
            for _ in 0..<90 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                r = await extract()
                if !r.rows.isEmpty { break }
            }
            needsVerify = false
            hideWindow()
        }
        return r.rows
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
            status = "正在读「\(name)」热文榜…"
            let rows = await fetch(name)
            merge(rows, category: name)
            total += rows.count
        }
        store.data.auto.lastHotFetch = Date()
        prune()
        store.save()
        status = total == 0 ? "没读到榜单，稍后再试" : "已更新 \(total) 条"
        await fillNames()
    }

    private func merge(_ rows: [Row], category: String) {
        let cal = Calendar.current
        let now = Date()
        for r in rows where !r.title.isEmpty {
            if let i = store.data.hot.firstIndex(where: { $0.id == r.link }) {
                if !cal.isDate(store.data.hot[i].lastSeen, inSameDayAs: now) { store.data.hot[i].seen += 1 }
                store.data.hot[i].lastSeen = now
                store.data.hot[i].reads = r.reads
                store.data.hot[i].readsNum = HotCategory.readsNumber(r.reads)
            } else {
                store.data.hot.append(HotArticle(id: r.link, title: r.title, reads: r.reads,
                                                 readsNum: HotCategory.readsNumber(r.reads),
                                                 category: category, biz: HotCategory.biz(r.link)))
            }
        }
    }

    /// 只留最近 7 天
    private func prune() {
        let cut = Date().addingTimeInterval(-7 * 86400)
        store.data.hot.removeAll { $0.lastSeen < cut }
        if store.data.hot.count > 1500 {
            store.data.hot.sort { $0.lastSeen > $1.lastSeen }
            store.data.hot = Array(store.data.hot.prefix(1500))
        }
    }

    /// 补公众号名字：读文章页里的 nickname
    func fillNames() async {
        var todo: [String: String] = [:]
        for h in store.data.hot where !h.biz.isEmpty && store.data.hotNames[h.biz] == nil {
            todo[h.biz] = h.id
        }
        let pairs = Array(todo.prefix(60))
        if pairs.isEmpty { return }
        status += "，正在补公众号名…"
        var found: [String: String] = [:]
        await withTaskGroup(of: (String, String?).self) { g in
            var it = pairs.makeIterator()
            for _ in 0..<5 {
                if let (biz, link) = it.next() { g.addTask { (biz, await Self.nickname(link)) } }
            }
            while let (biz, name) = await g.next() {
                if let name, !name.isEmpty { found[biz] = name }
                if let (b, l) = it.next() { g.addTask { (b, await Self.nickname(l)) } }
            }
        }
        for (k, v) in found { store.data.hotNames[k] = v }
        store.save()
        status = status.replacingOccurrences(of: "，正在补公众号名…", with: "")
    }

    nonisolated static func nickname(_ link: String) async -> String? {
        guard let u = URL(string: link) else { return nil }
        var req = URLRequest(url: u)
        req.timeoutInterval = 15
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (d, _) = try? await URLSession.shared.data(for: req) else { return nil }
        let html = String(decoding: d, as: UTF8.self)
        let pats = [#"var nickname = htmlDecode\("([^"]+)"\)"#, #"var nickname = "([^"]+)""#,
                    #"id="js_name">\s*([^<\n]+?)\s*<"#, #"nick_name:\s*"([^"]+)""#]
        for p in pats {
            if let re = try? NSRegularExpression(pattern: p),
               let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let r = Range(m.range(at: 1), in: html) {
                return String(html[r]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // MARK: 给选题和拆解用

    /// 一键成稿自动选题时参考的热文标题
    static func titlesForTopic(_ store: Store, limit: Int = 30) -> [String] {
        let cut = Date().addingTimeInterval(-2 * 86400)
        let cats = store.data.auto.hotCategories.isEmpty ? ["综合"] : store.data.auto.hotCategories
        let list = store.data.hot.filter { $0.lastSeen >= cut && cats.contains($0.category) }
            .sorted { $0.readsNum > $1.readsNum }
        return list.prefix(limit).map { "【公众号热文】" + $0.title }
    }

    struct Account: Identifiable {
        var id: String { biz }
        let biz: String
        let name: String
        let count: Int
        let reads: Int
        let top: HotArticle
    }

    func accounts() -> [Account] {
        var groups: [String: [HotArticle]] = [:]
        for h in store.data.hot where !h.biz.isEmpty { groups[h.biz, default: []].append(h) }
        var out: [Account] = []
        for (biz, list) in groups {
            let sorted = list.sorted { $0.readsNum > $1.readsNum }
            var count = 0
            var reads = 0
            for h in list { count += h.seen; reads += h.readsNum }
            out.append(Account(biz: biz, name: store.data.hotNames[biz] ?? "未知公众号",
                               count: count, reads: reads, top: sorted[0]))
        }
        out.sort { ($0.count, $0.reads) > ($1.count, $1.reads) }
        return out
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
    @State private var tab = 0
    @State private var filter = "全部"
    @State private var showCats = false
    @State private var done: Set<String> = []

    var articles: [HotArticle] {
        let cut = Date().addingTimeInterval(-2 * 86400)
        var list = store.data.hot.filter { $0.lastSeen >= cut }
        if filter != "全部" { list = list.filter { $0.category == filter } }
        list.sort { $0.readsNum != $1.readsNum ? $0.readsNum > $1.readsNum : $0.lastSeen > $1.lastSeen }
        return Array(list.prefix(150))
    }

    var body: some View {
        Page {
            PageHeader(title: "热文雷达", subtitle: "看你关注的领域里，公众号这两天什么文章在爆、哪些号在爆。只学选题和写法，不搬原文。") {
                Button { Task { await radar.refresh() } } label: {
                    HStack(spacing: 4) { Image(systemName: "arrow.clockwise"); Text(radar.loading ? "读取中…" : "刷新") }
                }
                .buttonStyle(PrimaryButton())
                .disabled(radar.loading)
            }
            controls
            BusyBar(busy: busy)
            if tab == 0 { articleList } else { accountList }
        }
        .task { if radar.stale && !radar.loading { await radar.refresh() } }
    }

    var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("", selection: $tab) {
                    Text("热文").tag(0)
                    Text("爆款公众号").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                if tab == 0 {
                    Picker("", selection: $filter) {
                        Text("全部").tag("全部")
                        ForEach(radar.categories, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 110)
                }
                Spacer()
                if !radar.status.isEmpty {
                    Text(radar.status).font(.system(size: 12))
                        .foregroundStyle(radar.needsVerify ? Theme.orange : Theme.sub).lineLimit(1)
                }
                Button(showCats ? "收起" : "选领域（\(radar.categories.joined(separator: "、")))") { showCats.toggle() }
                    .buttonStyle(LinkButton())
            }
            if showCats { categoryPicker }
        }
        .card()
    }

    var categoryPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 10), spacing: 6) {
                ForEach(HotCategory.all, id: \.0) { item in catChip(item.0) }
            }
            HStack {
                Toggle("每 6 小时自动更新（app 开着时）", isOn: Binding(get: { store.data.auto.hotAuto },
                                                              set: { store.data.auto.hotAuto = $0; store.save() }))
                    .toggleStyle(.checkbox).font(.system(size: 12))
                Toggle("一键成稿选题时参考这些热文", isOn: Binding(get: { store.data.auto.hotForTopic },
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

    @ViewBuilder var articleList: some View {
        if articles.isEmpty {
            Text(radar.loading ? "正在读取榜单…" : "还没有数据，点右上角刷新。")
                .font(.system(size: 13)).foregroundStyle(Theme.sub)
        }
        VStack(spacing: 0) {
            ForEach(Array(articles.enumerated()), id: \.element.id) { i, h in
                articleRow(i + 1, h)
                if i < articles.count - 1 { Divider() }
            }
        }
        .card(padding: 6)
    }

    func articleRow(_ rank: Int, _ h: HotArticle) -> some View {
        let similar = Dedupe.closest(h.title, in: Dedupe.history(store)).map { $0.1 >= 0.6 } ?? false
        return HStack(spacing: 12) {
            Text("\(rank)").font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(rank <= 3 ? Theme.orange : Theme.faint).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Button(h.title) { if let u = URL(string: h.id) { NSWorkspace.shared.open(u) } }
                    .buttonStyle(LinkButton(color: Theme.ink))
                    .lineLimit(2).multilineTextAlignment(.leading)
                HStack(spacing: 8) {
                    Text(h.reads).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.pink)
                    Text(store.data.hotNames[h.biz] ?? "").font(.system(size: 11)).foregroundStyle(Theme.sub)
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

    @ViewBuilder var accountList: some View {
        let list = radar.accounts()
        if list.isEmpty {
            Text("还没有数据，点右上角刷新。").font(.system(size: 13)).foregroundStyle(Theme.sub)
        }
        VStack(spacing: 0) {
            ForEach(Array(list.prefix(60).enumerated()), id: \.element.id) { i, a in
                HStack(spacing: 12) {
                    Text("\(i + 1)").font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(i < 3 ? Theme.orange : Theme.faint).frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(a.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                        Button("代表作：" + a.top.title) { if let u = URL(string: a.top.id) { NSWorkspace.shared.open(u) } }
                            .buttonStyle(LinkButton(color: Theme.sub)).lineLimit(1)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("上榜 \(a.count) 次").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.navy)
                        Text(Self.wan(a.reads) + " 阅读").font(.system(size: 11)).foregroundStyle(Theme.faint)
                    }
                    Button("拆解代表作") { breakdown(a.top, write: false) }
                        .buttonStyle(GhostButton()).disabled(busy.label != nil)
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
                if i < min(list.count, 60) - 1 { Divider() }
            }
        }
        .card(padding: 6)
        Text("按最近 7 天各领域热文榜的上榜次数统计。").font(.system(size: 11)).foregroundStyle(Theme.faint)
    }

    static func wan(_ n: Int) -> String {
        n >= 10000 ? String(format: "%.1f万", Double(n) / 10000) : "\(n)"
    }

    func addIdea(_ h: HotArticle) {
        store.data.ideas.insert(TopicIdea(title: h.title, angle: "参考热文（\(h.reads) 阅读），换自己的角度写"), at: 0)
        store.save()
        done.insert("i" + h.id)
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
