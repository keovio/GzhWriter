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

    static func open(store: Store, articleId: UUID, platform: String) {
        guard let a = store.article(articleId), let v = a.variants[platform] else { return }
        let model = FillModel(article: a, variant: v, platform: platform)
        let host = NSHostingView(rootView: FillView(model: model))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = (Platform.of(platform)?.name ?? platform) + " · " + (v.title.isEmpty ? a.displayTitle : v.title)
        w.contentView = host
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        windows.append(w)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            Task { @MainActor in windows.removeAll { $0 === w } }
        }
    }

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
                    self.status = "已填好标题和正文。检查一遍、设封面和标签，再自己点「发布」。"
                    Theme.tap()
                } else if !auto {
                    self.status = error != nil ? "填入出错：\(error!.localizedDescription)" : "还没找到编辑器，先登录并进入发文页。"
                }
            }
        }
    }
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
        cfg.websiteDataStore = .default()
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
