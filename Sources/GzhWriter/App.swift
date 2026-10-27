import AppKit
import SwiftUI
import WebKit

@main
struct GzhWriterApp: App {
    @StateObject private var store: Store
    @StateObject private var pipeline: Pipeline
    @StateObject private var radar: HotRadar
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        let s = Store()
        _store = StateObject(wrappedValue: s)
        _pipeline = StateObject(wrappedValue: Pipeline(store: s))
        _radar = StateObject(wrappedValue: HotRadar(store: s))
    }

    var body: some Scene {
        WindowGroup("公众号写稿助手") {
            ContentView()
                .environmentObject(store)
                .environmentObject(pipeline)
                .environmentObject(radar)
                .frame(minWidth: 1081, minHeight: 740)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建稿件") {
                    NotificationCenter.default.post(name: .newArticle, object: nil)
                }
                .keyboardShortcut("n")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        Store.shared?.flush()
    }
}

extension Notification.Name {
    static let newArticle = Notification.Name("GzhWriter.newArticle")
}

/// 手机宽度的预览
struct WebPreview: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var last = "" }

    func makeNSView(context: Context) -> WKWebView {
        let v = WKWebView()
        v.setValue(false, forKey: "drawsBackground")
        return v
    }

    func updateNSView(_ v: WKWebView, context: Context) {
        guard context.coordinator.last != html else { return }
        context.coordinator.last = html
        v.loadHTMLString(html, baseURL: nil)
    }
}

/// 通用的「正在调用模型」状态
@MainActor
final class Busy: ObservableObject {
    @Published var label: String?
    @Published var error: String?

    func run(_ label: String, _ work: @escaping @MainActor () async throws -> Void) {
        guard self.label == nil else { return }
        self.label = label
        error = nil
        Task { @MainActor in
            do { try await work() } catch { self.error = error.localizedDescription }
            self.label = nil
        }
    }
}

struct BusyBar: View {
    @ObservedObject var busy: Busy
    @EnvironmentObject var store: Store
    var body: some View {
        if let l = busy.label {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(l).foregroundStyle(.secondary)
                if let m = store.calling { ModelTag(text: m) }
            }
            .padding(.vertical, 4)
        }
        if let e = busy.error {
            HStack(alignment: .top) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(e).textSelection(.enabled).font(.callout)
                Spacer()
                Button("关闭") { busy.error = nil }.buttonStyle(.borderless)
            }
            .padding(8)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}


/// 小标签：显示用的是哪个模型
struct ModelTag: View {
    var text: String
    var prefix = "模型"
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "cpu").font(.system(size: 10))
            Text("\(prefix)：\(text)").font(.system(size: 11)).lineLimit(1)
        }
        .foregroundStyle(Theme.sub)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Theme.bg, in: Capsule())
        .fixedSize()
    }
}

/// 显示某个用途会用哪个模型
struct RoleModelTag: View {
    @EnvironmentObject var store: Store
    let role: Role
    var body: some View { ModelTag(text: store.modelLabel(role), prefix: role.title + "用") }
}
