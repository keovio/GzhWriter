import AppKit
import SwiftUI
import WebKit

// MARK: - 平台

/// 我在做的平台。公众号是主稿，其他平台是从主稿改出来的版本。
enum Platform: String, CaseIterable, Identifiable {
    case wechat, toutiao, baijiahao, zhihu, xiaohongshu, weibo
    var id: String { rawValue }

    var name: String {
        switch self {
        case .wechat: return "公众号"
        case .toutiao: return "头条号"
        case .baijiahao: return "百家号"
        case .zhihu: return "知乎"
        case .xiaohongshu: return "小红书"
        case .weibo: return "微博"
        }
    }

    var color: Color {
        switch self {
        case .wechat: return Color(hex: "#1AAD19")
        case .toutiao: return Color(hex: "#F04142")
        case .baijiahao: return Color(hex: "#2B63F0")
        case .zhihu: return Color(hex: "#0066FF")
        case .xiaohongshu: return Color(hex: "#FF2442")
        case .weibo: return Color(hex: "#E6162D")
        }
    }

    /// 长文平台：正文沿用主稿，只换标题、开头和标签
    var isLongForm: Bool { self == .toutiao || self == .baijiahao || self == .zhihu }

    /// 能在 app 里打开发文页自动填入
    var fillable: Bool { self != .wechat && self != .weibo }

    var publishURL: URL {
        switch self {
        case .wechat: return URL(string: "https://mp.weixin.qq.com")!
        case .toutiao: return URL(string: "https://mp.toutiao.com/profile_v4/graphic/publish")!
        case .baijiahao: return URL(string: "https://baijiahao.baidu.com/builder/rc/edit?type=news")!
        case .zhihu: return URL(string: "https://zhuanlan.zhihu.com/write")!
        case .xiaohongshu: return URL(string: "https://creator.xiaohongshu.com/publish/publish?target=image")!
        case .weibo: return URL(string: "https://weibo.com")!
        }
    }

    /// 写版本时给模型的规则
    var rule: String {
        switch self {
        case .wechat: return ""
        case .toutiao: return "头条号：标题 20 到 30 字，口语、有具体信息或数字；开头一段两三句直接抛出读者关心的问题；标签 3 到 5 个。"
        case .baijiahao: return "百家号：标题规范克制，不夸张不标题党，不用感叹号和问号连用；开头一段交代清楚这篇讲什么；标签 3 到 5 个。"
        case .zhihu: return "知乎：标题像一个问题或一句明确的判断；开头一段先给结论，再说「下面展开」，少情绪多干货；标签 3 到 5 个话题。"
        case .xiaohongshu: return "小红书笔记：标题 20 字以内，带一个关键词和一点情绪；正文 300 到 600 字，口语、分点短句、每段一两句，可以用少量表情符号；结尾一句互动提问；标签 5 到 8 个。"
        case .weibo: return "微博：正文 140 到 300 字，一个清楚的观点加一两个支撑细节，口语；话题标签 2 到 3 个。不需要标题。"
        }
    }

    static func of(_ s: String) -> Platform? { Platform(rawValue: s) }

    @MainActor
    static func enabled(_ store: Store) -> [Platform] {
        let on = store.data.auto.platforms
        return allCases.filter { on.contains($0.rawValue) }
    }

    /// 除公众号外打开了的平台
    @MainActor
    static func others(_ store: Store) -> [Platform] { enabled(store).filter { $0 != .wechat } }
}

// MARK: - 热榜来源（今日热榜 tophub.today 的节点）

struct HotSource: Identifiable, Hashable {
    let key: String
    let name: String
    let node: String
    var id: String { key }

    static let all: [HotSource] = [
        .init(key: "toutiao", name: "头条", node: "x9ozB4KoXb"),
        .init(key: "baidu", name: "百度", node: "Jb0vmloB1G"),
        .init(key: "zhihu", name: "知乎", node: "mproPpoq6O"),
        .init(key: "weibo", name: "微博", node: "KqndgxeLl9"),
        .init(key: "douyin", name: "抖音", node: "K7GdaMgdQy"),
        .init(key: "xiaohongshu", name: "小红书", node: "L4MdA5ldxD"),
    ]

    var url: URL { URL(string: "https://tophub.today/n/\(node)")! }

    static func name(_ key: String) -> String {
        key == "wechat" ? "公众号" : (all.first { $0.key == key }?.name ?? key)
    }

    static func color(_ key: String) -> Color {
        switch key {
        case "wechat": return Color(hex: "#1AAD19")
        case "toutiao": return Color(hex: "#F04142")
        case "baidu": return Color(hex: "#2B63F0")
        case "zhihu": return Color(hex: "#0066FF")
        case "weibo": return Color(hex: "#E6162D")
        case "douyin": return Color(hex: "#161823")
        case "xiaohongshu": return Color(hex: "#FF2442")
        default: return Theme.sub
        }
    }
}

struct PlatformTag: View {
    let key: String
    var body: some View {
        let c = HotSource.color(key)
        Text(HotSource.name(key))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(c)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(c.opacity(0.1), in: Capsule())
    }
}

// MARK: - 用内置浏览器读网页

/// 普通请求读公众号文章会被重定向到验证页（wappoc_appmsgcaptcha），拿不到正文和公众号名。
/// 这里用一个看不见的浏览器窗口去读，和你自己用浏览器打开一样；真要人工验证时可以把窗口亮出来。
@MainActor
final class WebReader: NSObject, WKNavigationDelegate {
    static let shared = WebReader()

    struct Page { let title: String; let text: String; let name: String; let url: String }

    private let web: WKWebView
    private let window: NSWindow
    private var busy = false
    private(set) var lastWasCaptcha = false

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 900), configuration: cfg)
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 900, height: 900),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle]
        super.init()
        web.navigationDelegate = self
    }

    private static let js = """
    (function() {
      var n = document.querySelector('#js_name') || document.querySelector('.wx_follow_nickname') || document.querySelector('#profileBt a');
      var name = n ? n.innerText.trim() : '';
      if (!name && typeof window.nickname === 'string') name = window.nickname;
      var c = document.querySelector('#js_content');
      var og = document.querySelector('meta[property="og:title"]');
      var h = document.querySelector('#activity-name');
      var title = (og && og.content) || (h && h.innerText.trim()) || document.title;
      var text = c ? c.innerText : (document.body ? document.body.innerText : '');
      return JSON.stringify({ name: name, title: title, text: text, url: location.href,
                              hasContent: !!c, state: document.readyState });
    })()
    """

    private func snapshot() async -> [String: Any]? {
        guard let s = try? await web.evaluateJavaScript(Self.js) as? String,
              let d = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    /// 读一页。interactive 为真时，碰到验证会把窗口亮出来等你过（最多 2 分钟）。
    func read(_ link: String, timeout: Double = 15, interactive: Bool = false) async -> Page? {
        guard let u = URL(string: link) else { return nil }
        while busy { try? await Task.sleep(nanoseconds: 300_000_000) }
        busy = true
        defer { busy = false; hide() }
        lastWasCaptcha = false
        window.orderFrontRegardless()
        web.load(URLRequest(url: u))
        let isWechat = u.host?.contains("mp.weixin.qq.com") == true

        func done(_ o: [String: Any]) -> Page? {
            let text = (o["text"] as? String) ?? ""
            let has = (o["hasContent"] as? Bool) ?? false
            let ready = (o["state"] as? String) == "complete"
            if isWechat ? (has && text.count > 30) : (ready && text.count > 200) {
                return Page(title: (o["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                            text: text, name: (o["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                            url: o["url"] as? String ?? link)
            }
            return nil
        }

        let steps = Int(timeout * 2)
        var captcha = false
        for _ in 0..<steps {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let o = await snapshot() else { continue }
            if let p = done(o) { return p }
            let url = o["url"] as? String ?? ""
            if url.contains("captcha") || url.contains("verify") { captcha = true }
        }
        lastWasCaptcha = captcha
        guard interactive else { return nil }

        // 亮出窗口让作者过验证
        show(title: "需要验证一下（过完会自动关闭）")
        for _ in 0..<240 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !window.isVisible { break }
            if let o = await snapshot(), let p = done(o) { return p }
        }
        return nil
    }

    private func show(title: String) {
        window.title = title
        window.alphaValue = 1
        window.ignoresMouseEvents = false
        window.setFrame(NSRect(x: 0, y: 0, width: 900, height: 760), display: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func hide() {
        window.orderOut(nil)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
    }
}

// MARK: - 合规检查（任意文字）

extension Compliance {
    static func scanText(_ text: String) -> [Hit] {
        var out: [Hit] = []
        var seen = Set<String>()
        let ns = text as NSString
        for r in rules {
            guard let re = try? NSRegularExpression(pattern: r.pattern) else { continue }
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let word = ns.substring(with: m.range)
                guard seen.insert(word).inserted else { continue }
                out.append(Hit(category: r.category, word: word, section: 0, snippet: "", tip: r.tip))
            }
        }
        return out
    }
}
