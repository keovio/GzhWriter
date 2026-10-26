import AppKit
import SwiftUI
import WebKit

/// 在 app 内打开头条号 / 百家号的发文页，自动填标题和正文。
/// 只填不发：「发布」按钮必须作者自己点。登录状态保存在本机。
@MainActor
enum PlatformFill {
    static var windows: [NSWindow] = []

    static func url(_ platform: String) -> URL {
        (Platform.of(platform) ?? .toutiao).publishURL
    }

    /// 每个账号单独的登录状态。每个平台的第一个号沿用原来的登录（老版本登过的不用重登）。
    static func dataStore(_ acc: Account?) -> WKWebsiteDataStore {
        guard let acc, let store = Store.shared else { return .default() }
        if store.accounts(on: acc.platform).first?.id == acc.id { return .default() }
        if #available(macOS 14.0, *) { return WKWebsiteDataStore(forIdentifier: acc.id) }
        return .default()
    }

    static func open(store: Store, articleId: UUID, platform: String, account: Account? = nil) {
        guard let a = store.article(articleId), let v = a.variants[platform] else { return }
        let model = FillModel(article: a, variant: v, platform: platform)
        model.dataStore = dataStore(account)
        let host = NSHostingView(rootView: FillView(model: model))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = (account.map { "\(Platform.of(platform)?.name ?? platform)「\($0.name)」" } ?? (Platform.of(platform)?.name ?? platform)) + " · " + (v.title.isEmpty ? a.displayTitle : v.title)
        w.contentView = host
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        windows.append(w)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            Task { @MainActor in windows.removeAll { $0 === w } }
        }
    }

    /// 只打开平台去登录（登录状态会记住，之后填稿、存草稿不用再登）
    static func login(_ acc: Account) {
        guard let p = Platform.of(acc.platform) else { return }
        let model = LoginModel(account: acc, store: dataStore(acc))
        let host = NSHostingView(rootView: LoginView(model: model))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "登录\(p.name)「\(acc.name)」"
        w.contentView = host
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        model.window = w
        windows.append(w)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            Task { @MainActor in
                windows.removeAll { $0 === w }
                NotificationCenter.default.post(name: .gzhLoginChanged, object: nil)
            }
        }
    }

    /// 平台登录后才会有的 cookie
    static func sessionCookies(_ p: Platform) -> (domain: String, names: [String]) {
        switch p {
        case .toutiao: return ("toutiao.com", ["sessionid", "sessionid_ss", "sid_tt"])
        case .baijiahao: return ("baidu.com", ["BDUSS", "BDUSS_BFESS"])
        case .zhihu: return ("zhihu.com", ["z_c0"])
        case .xiaohongshu: return ("xiaohongshu.com", ["galaxy_creator_session_id", "web_session", "access-token-creator.xiaohongshu.com"])
        case .weibo: return ("weibo.com", ["SUB"])
        case .wechat: return ("qq.com", ["slave_sid"])
        }
    }

    static func isLoggedIn(_ store: WKWebsiteDataStore, _ p: Platform) async -> Bool {
        let (domain, names) = sessionCookies(p)
        let cookies: [HTTPCookie] = await withCheckedContinuation { c in
            store.httpCookieStore.getAllCookies { c.resume(returning: $0) }
        }
        let now = Date()
        return cookies.contains { ck in
            ck.domain.hasSuffix(domain) && names.contains(ck.name) && !ck.value.isEmpty
                && (ck.expiresDate.map { $0 > now } ?? true)
        }
    }

    static func isLoggedIn(_ acc: Account) async -> Bool {
        guard let p = Platform.of(acc.platform) else { return false }
        return await isLoggedIn(dataStore(acc), p)
    }

    /// 能后台存草稿的平台（小红书要先传图、微博没有草稿箱）
    static func draftable(_ p: Platform) -> Bool { p == .toutiao || p == .baijiahao || p == .zhihu }

    /// 打开发文页（看得见的窗口），填好后点存草稿。发布永远是作者自己点。
    /// closeWhenDone：批量时存好自动关窗口接着下一篇；单篇存好后窗口留着，可以直接检查、发布。
    static func saveDraft(store: Store, articleId: UUID, account acc: Account, closeWhenDone: Bool = false) async throws -> String {
        guard let p = Platform.of(acc.platform), draftable(p) else { throw DraftError.msg("这个平台不支持存草稿") }
        guard await isLoggedIn(acc) else { throw DraftError.msg("「\(acc.name)」还没登录\(p.name)，先在「我的账号」点登录") }
        if store.article(articleId)?.variants[p.rawValue] == nil {
            try await Publisher.makeVariants(store, articleId, only: [p])
        }
        guard let a = store.article(articleId), let v = a.variants[p.rawValue] else { throw DraftError.msg("没有\(p.name)版本") }
        let model = FillModel(article: a, variant: v, platform: p.rawValue)
        model.dataStore = dataStore(acc)
        model.autoDraft = true
        model.status = "正在打开\(p.name)「\(acc.name)」的发文页，自动填好后存草稿…"
        let host = NSHostingView(rootView: FillView(model: model))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "存草稿 · \(p.name)「\(acc.name)」 · " + (v.title.isEmpty ? a.displayTitle : v.title)
        w.contentView = host
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        windows.append(w)
        let flag = CloseFlag()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            flag.closed = true
            Task { @MainActor in
                windows.removeAll { $0 === w }
                model.onDone?(.failure(DraftError.msg("窗口被关掉了，没存上")))
            }
        }
        let result: Result<String, Error> = await withCheckedContinuation { c in
            var resumed = false
            model.onDone = { r in
                guard !resumed else { return }
                resumed = true
                c.resume(returning: r)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 90_000_000_000)
                model.onDone?(.failure(DraftError.msg(model.filled ? "填好了但没找到存草稿按钮，可以在窗口里自己点" : "90 秒没打开编辑器，可能登录过期了")))
            }
        }
        let closedByUser = flag.closed
        switch result {
        case .success(let m):
            store.markDrafted(articleId, acc)
            model.done = true
            model.status = "✓ \(m)。可以在这里检查、设封面，满意了自己点「发布」；不发就直接关掉。"
            Theme.tap()
            if closeWhenDone && !closedByUser {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                w.close()
            }
            return m
        case .failure(let e):
            if !closedByUser { model.status = "没存上：\(e.localizedDescription)" }
            throw e
        }
    }

    /// 点「存草稿」一类的按钮；没有按钮的平台（头条、知乎）会自动保存
    static let draftScript = """
    (function() {
      var docs = [document];
      document.querySelectorAll('iframe').forEach(function(f) { try { if (f.contentDocument) docs.push(f.contentDocument); } catch (e) {} });
      var re = /^(存草稿|保存草稿|存为草稿|保存为草稿|暂存离开|保存)$/;
      for (var i = 0; i < docs.length; i++) {
        var els = docs[i].querySelectorAll('button, [role="button"], a, span, div');
        for (var j = 0; j < els.length; j++) {
          var e = els[j];
          var t = (e.innerText || '').replace(/\\s+/g, '');
          if (!re.test(t) || e.children.length > 2) continue;
          var r = e.getBoundingClientRect();
          if (r.width < 4 || r.height < 4) continue;
          e.click();
          return 'clicked';
        }
      }
      var txt = document.body ? document.body.innerText : '';
      if (/(草稿已保存|已保存|保存成功|自动保存)/.test(txt)) return 'saved';
      return 'none';
    })()
    """

    /// 读当前登录号的昵称：先试平台自己的接口，再从页面上找。读不到返回空
    static let nicknameScript = """
    const prefer = ['screen_name', 'media_name', 'nickname', 'nick_name', 'uname', 'user_name', 'name'];
    function pick(o, depth) {
      if (!o || typeof o !== 'object' || depth > 5) return '';
      for (const k of prefer) {
        const v = o[k];
        if (typeof v === 'string' && v.trim() && v.length <= 30) return v.trim();
      }
      for (const k in o) { const r = pick(o[k], depth + 1); if (r) return r; }
      return '';
    }
    const h = location.hostname;
    let urls = [];
    if (h.includes('toutiao.com')) urls = ['/mp/agw/media/get_media_info', '/passport/account/info/v2/'];
    else if (h.includes('baidu.com')) urls = ['/builder/app/appinfo'];
    else if (h.includes('zhihu.com')) urls = ['/api/v4/me', 'https://www.zhihu.com/api/v4/me'];
    else if (h.includes('xiaohongshu.com')) urls = ['/api/galaxy/user/info', '/api/sns/web/v2/user/me'];
    else if (h.includes('weibo.com')) urls = ['/ajax/side/cards?count=1'];
    for (const u of urls) {
      try {
        const r = await fetch(u, { credentials: 'include' });
        if (!r.ok) continue;
        const j = await r.json();
        const d = j.data || j.user || j;
        const n = pick(d.user || d.media || d.user_info || d, 0);
        if (n) return n;
      } catch (e) {}
    }
    const sel = '[class*="user-name"],[class*="userName"],[class*="nickname"],[class*="nick-name"],[class*="media-name"],[class*="account-name"]';
    for (const e of document.querySelectorAll(sel)) {
      const t = (e.innerText || '').trim();
      if (t && t.length <= 30 && !/登录|注册/.test(t)) return t;
    }
    return '';
    """

    /// 正文 HTML：配图转成 data URI 内嵌
    static func bodyHTML(_ a: Article, _ v: PlatformVariant) -> String {
        if !v.body.isEmpty {
            return Layout.paragraphs(Publisher.platformFull(a, v)).map { "<p>\(Layout.esc($0))</p>" }.joined()
        }
        var out = ""
        let intro = v.intro.trimmingCharacters(in: .whitespacesAndNewlines)
        let showH = ArticleKind.of(a.kind).showsHeadings
        for (i, sec) in a.sections.enumerated() {
            if !sec.heading.isEmpty && showH { out += "<h2>\(Layout.esc(sec.heading))</h2>" }
            if !sec.image.isEmpty, let uri = ImageStore.dataURI(a.id, sec.image) {
                out += "<p><img src=\"\(uri)\"></p>"
            }
            var paras = Layout.paragraphs(sec.body)
            if i == 0 && !intro.isEmpty && !paras.isEmpty { paras[0] = intro }
            for p in paras {
                let t = p.hasPrefix(">") ? String(p.drop(while: { $0 == ">" || $0 == " " })) : p
                out += "<p>\(Layout.esc(t).replacingOccurrences(of: "**", with: ""))</p>"
            }
        }
        return out
    }

    static func json(_ s: String) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        let arr = String(data: d, encoding: .utf8) ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }

    /// 找到标题框和正文编辑区，填进去。返回 wait / ok / err:…
    static func script(title: String, html: String, plain: String) -> String {
        """
        (function(T, H, P) {
          function setVal(el, v) {
            var proto = Object.getPrototypeOf(el);
            var desc = Object.getOwnPropertyDescriptor(proto, 'value');
            if (desc && desc.set) { desc.set.call(el, v); } else { el.value = v; }
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          }
          function docs() {
            var out = [document];
            document.querySelectorAll('iframe').forEach(function(f) {
              try { if (f.contentDocument) out.push(f.contentDocument); } catch (e) {}
            });
            return out;
          }
          var title = null, body = null, bodyDoc = null, area = 0;
          docs().forEach(function(d) {
            if (!title) {
              var fields = Array.prototype.slice.call(d.querySelectorAll('textarea, input'));
              title = fields.find(function(e) { return /标题/.test(e.placeholder || ''); }) || null;
            }
            var eds = Array.prototype.slice.call(d.querySelectorAll('[contenteditable="true"], .ProseMirror'));
            eds.forEach(function(e) {
              if (e === title) return;
              var ph = (e.getAttribute('placeholder') || e.getAttribute('data-placeholder') || '');
              if (/标题/.test(ph) && !title) { title = e; return; }
              var r = e.getBoundingClientRect();
              var s = r.width * Math.max(r.height, 60);
              if (s > area) { area = s; body = e; bodyDoc = d; }
            });
            if (!body && d.body && d.body.isContentEditable) { body = d.body; bodyDoc = d; }
          });
          if (!title || !body) return 'wait';
          if (title.tagName === 'TEXTAREA' || title.tagName === 'INPUT') { setVal(title, T); }
          else { title.focus(); title.textContent = T; title.dispatchEvent(new InputEvent('input', { bubbles: true })); }
          body.focus();
          var done = false;
          try {
            var dt = new DataTransfer();
            dt.setData('text/html', H);
            dt.setData('text/plain', P);
            var ev = new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true });
            body.dispatchEvent(ev);
            done = ev.defaultPrevented;
          } catch (e) {}
          if (!done) {
            try { done = bodyDoc.execCommand('insertHTML', false, H); } catch (e) {}
          }
          if (!done) { body.innerHTML = H; body.dispatchEvent(new InputEvent('input', { bubbles: true })); }
          return 'ok';
        })(\(json(title)), \(json(html)), \(json(plain)))
        """
    }

    static func copyCover(_ a: Article) -> Bool {
        guard let u = ImageStore.url(a.id, a.cover), let img = NSImage(contentsOf: u) else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.writeObjects([img])
    }
}

@MainActor
final class FillModel: ObservableObject {
    let article: Article
    let variant: PlatformVariant
    let platform: String
    @Published var status = "正在打开…第一次用要先登录，登录一次之后会记住。"
    var firstHint: String {
        platform == "xiaohongshu" ? "小红书要先上传图片才会出现标题和正文框：点「复制封面」粘进去，或上传你自己的图。" : ""
    }
    @Published var filled = false
    @Published var done = false
    var dataStore: WKWebsiteDataStore = .default()
    var autoDraft = false
    var onDone: ((Result<String, Error>) -> Void)?
    private var draftTries = 0
    weak var web: WKWebView?
    private var tries = 0
    private var timer: Timer?

    init(article: Article, variant: PlatformVariant, platform: String) {
        self.article = article; self.variant = variant; self.platform = platform
    }

    /// 页面加载后每 2 秒找一次编辑器，找到就自动填一次
    func startWatching() {
        timer?.invalidate()
        tries = 0
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard !filled else { timer?.invalidate(); return }
        tries += 1
        if tries > 150 { timer?.invalidate(); status = "没找到编辑器。登录后进入发文页，再点「填入」。"; return }
        fill(auto: true)
    }

    func fill(auto: Bool = false) {
        guard let web else { return }
        let js = PlatformFill.script(title: variant.title,
                                     html: PlatformFill.bodyHTML(article, variant),
                                     plain: variant.body.isEmpty ? Publisher.platformPlain(article, variant) : Publisher.platformFull(article, variant))
        web.evaluateJavaScript(js) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                let r = result as? String ?? ""
                if r == "ok" {
                    self.filled = true
                    self.timer?.invalidate()
                    if self.autoDraft {
                        self.status = "已填好标题和正文，正在存草稿…"
                        self.saveDraftSoon()
                    } else {
                        self.status = "已填好标题和正文。检查一遍、设封面和标签，再自己点「发布」。"
                        Theme.tap()
                    }
                } else if !auto {
                    self.status = error != nil ? "填入出错：\(error!.localizedDescription)" : "还没找到编辑器，先登录并进入发文页。"
                }
            }
        }
    }
}

extension FillModel {
    /// 填好后等编辑器反应过来，再点存草稿
    func saveDraftSoon() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            self?.tryDraft()
        }
    }

    private func tryDraft() {
        guard let web else { return }
        web.evaluateJavaScript(PlatformFill.draftScript) { [weak self] result, _ in
            Task { @MainActor in
                guard let self else { return }
                let r = result as? String ?? ""
                if r == "clicked" || r == "saved" {
                    // 给平台几秒把草稿存下来
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    self.onDone?(.success(r == "clicked" ? "已存草稿" : "平台已自动存草稿"))
                } else {
                    self.retryDraft()
                }
            }
        }
    }

    private func retryDraft() {
        draftTries += 1
        if draftTries >= 5 {
            // 头条、知乎编辑器会自动保存草稿，等够时间就算存好
            if platform == "toutiao" || platform == "zhihu" {
                onDone?(.success("平台自动存草稿"))
            } else {
                onDone?(.failure(DraftError.msg("填好了但没找到存草稿按钮")))
            }
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.tryDraft()
        }
    }
}

final class CloseFlag: @unchecked Sendable { var closed = false }

enum DraftError: LocalizedError {
    case msg(String)
    var errorDescription: String? { if case .msg(let s) = self { return s }; return nil }
}

extension Notification.Name {
    static let gzhLoginChanged = Notification.Name("gzhLoginChanged")
}

// MARK: - 登录窗口：顶部显示是否已登录

@MainActor
final class LoginModel: ObservableObject {
    let account: Account
    let dataStore: WKWebsiteDataStore
    weak var window: NSWindow?
    weak var web: WKWebView?
    @Published var loggedIn = false
    @Published var nickname = ""
    private var nickTries = 0
    private var timer: Timer?

    init(account: Account, store: WKWebsiteDataStore) {
        self.account = account
        self.dataStore = store
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        Task { await check() }
    }

    func check() async {
        guard let p = Platform.of(account.platform) else { return }
        let ok = await PlatformFill.isLoggedIn(dataStore, p)
        if ok && !loggedIn {
            loggedIn = true
            Theme.tap()
            NotificationCenter.default.post(name: .gzhLoginChanged, object: nil)
        } else if !ok { loggedIn = false }
        if loggedIn && nickname.isEmpty && nickTries < 8 { await readNickname() }
    }

    /// 登录后读平台上的昵称，拿来当账号名（只替换默认名）
    func readNickname() async {
        guard let web else { return }
        nickTries += 1
        let r = try? await web.callAsyncJavaScript(PlatformFill.nicknameScript, arguments: [:], in: nil, contentWorld: .page)
        let n = (r as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        nickname = n
        Store.shared?.adoptNickname(account.id, n)
        NotificationCenter.default.post(name: .gzhLoginChanged, object: nil)
    }

    func stop() { timer?.invalidate() }

    /// 退出登录：清掉这个号的 cookie
    func logout() async {
        guard let p = Platform.of(account.platform) else { return }
        let domain = PlatformFill.sessionCookies(p).domain
        let records = await dataStore.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let mine = records.filter { $0.displayName.hasSuffix(domain) }
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: mine)
        loggedIn = false
        NotificationCenter.default.post(name: .gzhLoginChanged, object: nil)
    }
}

struct LoginView: View {
    @ObservedObject var model: LoginModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: model.loggedIn ? "checkmark.circle.fill" : "person.crop.circle.badge.questionmark")
                    .foregroundStyle(model.loggedIn ? Theme.green : Theme.navy)
                Text(model.loggedIn ? (model.nickname.isEmpty ? "已登录" : "已登录「\(model.nickname)」") + "，会一直记住。以后填稿、存草稿都不用再登。" : "在下面登录（扫码或密码都行），登录成功这里会变绿。")
                    .font(.system(size: 12)).foregroundStyle(Theme.ink)
                Spacer()
                if model.loggedIn {
                    Button("关闭") { model.stop(); model.window?.close() }.buttonStyle(PrimaryButton())
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(model.loggedIn ? Theme.greenBg : Theme.blueBg)
            Rectangle().fill(Theme.rule).frame(height: 1)
            LoginWeb(model: model)
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

struct LoginWeb: NSViewRepresentable {
    let model: LoginModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let model: LoginModel
        init(model: LoginModel) { self.model = model }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in await model.check() }
        }
        // 扫码、第三方登录的弹窗在同一个窗口里打开
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }
    }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = model.dataStore
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        v.navigationDelegate = context.coordinator
        v.uiDelegate = context.coordinator
        v.allowsBackForwardNavigationGestures = true
        model.web = v
        let p = Platform.of(model.account.platform) ?? .toutiao
        v.load(URLRequest(url: p == .weibo ? URL(string: "https://weibo.com/login.php")! : p.publishURL))
        return v
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct FillView: View {
    @ObservedObject var model: FillModel
    @State private var copied = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: model.filled ? "checkmark.circle.fill" : "hourglass")
                    .foregroundStyle(model.filled ? Theme.green : Theme.navy)
                Text(model.filled || model.firstHint.isEmpty ? model.status : model.status + " " + model.firstHint).font(.system(size: 12)).foregroundStyle(Theme.ink).lineLimit(2)
                Spacer()
                Button(model.filled ? "重新填入" : "填入") { model.fill() }.buttonStyle(PrimaryButton())
                Button(copied == "c" ? "已复制" : "复制封面") {
                    if PlatformFill.copyCover(model.article) { flash("c") }
                }
                .buttonStyle(GhostButton())
                .disabled(model.article.cover.isEmpty)
                if !model.variant.tags.isEmpty {
                    Button(copied == "t" ? "已复制" : "复制标签") {
                        Publisher.copyText(model.variant.tags.joined(separator: " ")); flash("t")
                    }
                    .buttonStyle(GhostButton())
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(model.filled ? Theme.greenBg : Theme.blueBg)
            Rectangle().fill(Theme.rule).frame(height: 1)
            FillWeb(model: model)
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    func flash(_ k: String) {
        copied = k
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == k { copied = "" } }
    }
}

struct FillWeb: NSViewRepresentable {
    let model: FillModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let model: FillModel
        init(model: FillModel) { self.model = model }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in if !model.filled { model.startWatching() } }
        }
        // 弹窗登录（扫码、第三方）在同一个窗口里打开
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }
    }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = model.dataStore
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        v.navigationDelegate = context.coordinator
        v.uiDelegate = context.coordinator
        v.allowsBackForwardNavigationGestures = true
        model.web = v
        v.load(URLRequest(url: PlatformFill.url(model.platform)))
        return v
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
