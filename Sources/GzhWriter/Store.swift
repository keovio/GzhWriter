import Foundation
import SwiftUI

/// 所有数据存在 ~/Library/Application Support/GzhWriter/data.json，只在本机
@MainActor
final class Store: ObservableObject {
    @Published var data = AppData()
    /// 正在调用的模型（界面上显示「正在用 xx」）
    @Published var calling: String?
    private var saveTask: Task<Void, Never>?

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("GzhWriter", isDirectory: true)
    }
    static var file: URL { folder.appendingPathComponent("data.json") }

    static weak var shared: Store?

    init() {
        load()
        Self.shared = self
        if data.styles.isEmpty {
            data.styles = [StylePreset(name: "我的公众号", sample: "", avoid: "")]
        }
        if ProcessInfo.processInfo.environment["GZH_DEMO"] != nil { demo() }
        migrateAccounts()
        renameStyleNamedAccounts()
    }

    /// 老版本拿风格名给账号起名，容易把账号和风格搞混：改成「我的头条号」，登录后再换成平台昵称
    func renameStyleNamedAccounts() {
        let key = "renamedStyleAccounts.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let styleNames = Set(data.styles.map(\.name))
        var seen: [String: Int] = [:]
        for i in data.accounts.indices {
            let p = data.accounts[i].platform
            seen[p, default: 0] += 1
            if styleNames.contains(data.accounts[i].name) || data.accounts[i].name.isEmpty {
                data.accounts[i].name = Account.defaultName(p, index: seen[p]!)
            }
        }
        save()
    }

    /// 记下「已存进某个号的草稿箱」
    func markDrafted(_ id: UUID, _ acc: Account) {
        update(id) { $0.drafts[acc.id.uuidString] = Date() }
    }

    /// 登录后读到平台昵称：只替换还是默认名的号，用户自己改过的不动
    func adoptNickname(_ accId: UUID, _ nick: String) {
        let n = nick.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n.count <= 30, let i = data.accounts.firstIndex(where: { $0.id == accId }),
              data.accounts[i].isDefaultName else { return }
        data.accounts[i].name = n
        save()
    }

    /// CI 截图用的示例数据（只在设置了 GZH_DEMO 时）
    private func demo() {
        guard data.articles.isEmpty else { return }
        data.connections = [ModelConnection(name: "DeepSeek", baseURL: "https://api.deepseek.com", model: "deepseek-chat")]
        data.styles[0].name = "考公小助手"
        data.auto.platforms = ["wechat", "toutiao", "xiaohongshu"]
        let titles = ["在职备考公务员，每天两小时怎么安排", "申论大作文，开头三句话定生死", "行测刷题十年，我只信这三个方法"]
        for (i, t) in titles.enumerated() {
            var a = Article()
            a.title = t; a.topic = t; a.stage = .layout
            a.styleId = data.styles[0].id
            a.sections = [ArticleSection(heading: "先说结论", body: String(repeating: "备考最怕的不是时间少，而是没有节奏。", count: 20))]
            a.created = Date().addingTimeInterval(Double(-i) * 3600 * 20)
            data.articles.append(a)
        }
        var x = Article()
        x.primary = "xiaohongshu"; x.topic = "上岸学姐的申论笔记本"; x.stage = .layout
        x.variants["xiaohongshu"] = PlatformVariant(title: "上岸学姐的申论笔记本", tags: ["考公", "申论"], body: "三个月从 52 到 71 分，我只做了这几件事……")
        data.articles.append(x)
    }

    /// 老版本没有账号：按原来的风格和打开的平台各建一个号，公众号沿用原来的 AppID / AppSecret
    func migrateAccounts() {
        guard data.accounts.isEmpty else { return }
        let style = data.styles.first
        var wx = Account(platform: "wechat", name: Account.defaultName("wechat", index: 1), styleId: style?.id, appId: data.wechat.appId)
        if let old = Keychain.get(Wechat.secretKey), !old.isEmpty { Keychain.set(old, for: wx.secretKey) }
        wx.appId = data.wechat.appId
        data.accounts = [wx]
        for p in data.auto.platforms where p != "wechat" && Platform.of(p) != nil {
            data.accounts.append(Account(platform: p, name: Account.defaultName(p, index: 1), styleId: style?.id))
        }
        save()
    }

    /// 某个号发没发。只有一个号的平台沿用老的「我发了」
    func isPosted(_ a: Article, _ acc: Account) -> Bool {
        if a.posts[acc.id.uuidString] != nil { return true }
        return accounts(on: acc.platform).count == 1 && (a.variants[acc.platform]?.posted ?? false)
    }

    /// 切换「我发了」：acc 为空时按平台记
    func togglePosted(_ id: UUID, _ platform: String, _ acc: Account?) {
        update(id) { a in
            if let acc {
                let wasOn = a.posts[acc.id.uuidString] != nil
                    || (self.accounts(on: platform).count == 1 && (a.variants[platform]?.posted ?? false))
                a.posts[acc.id.uuidString] = wasOn ? nil : Date()
                let any = self.accounts(on: platform).contains { a.posts[$0.id.uuidString] != nil }
                a.variants[platform, default: PlatformVariant()].posted = any
                a.variants[platform, default: PlatformVariant()].postedAt = any ? Date() : nil
            } else {
                let now = !(a.variants[platform]?.posted ?? false)
                a.variants[platform, default: PlatformVariant()].posted = now
                a.variants[platform, default: PlatformVariant()].postedAt = now ? Date() : nil
            }
        }
    }

    func account(_ id: UUID?) -> Account? {
        guard let id else { return nil }
        return data.accounts.first { $0.id == id }
    }

    func accounts(on platform: String) -> [Account] {
        data.accounts.filter { $0.platform == platform }
    }

    /// 推草稿箱用哪个公众号：稿件自己的号 → 同风格的公众号 → 第一个配好了的公众号
    func wechatAccount(for a: Article) -> Account? {
        let wx = accounts(on: "wechat").filter { !$0.appId.isEmpty }
        if let acc = account(a.accountId), acc.platform == "wechat", !acc.appId.isEmpty { return acc }
        return wx.first { $0.styleId == a.styleId } ?? wx.first
    }

    func load() {
        guard let d = try? Data(contentsOf: Self.file) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let v = try? dec.decode(AppData.self, from: d) { data = v; data.hot.removeAll { $0.platform == "douyin" } }
    }

    /// 改动后 0.5 秒落盘（合并连续输入）；写之前留一份 .bak
    func save() {
        saveTask?.cancel()
        let snapshot = data
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, self != nil else { return }
            Self.write(snapshot)
        }
    }

    static func write(_ d: AppData) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let out = try? enc.encode(d) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if fm.fileExists(atPath: file.path) {
            let bak = folder.appendingPathComponent("data.bak.json")
            try? fm.removeItem(at: bak)
            try? fm.copyItem(at: file, to: bak)
        }
        try? out.write(to: file, options: .atomic)
    }

    // MARK: 稿件

    func newArticle(topic: String = "", angle: String = "") -> UUID {
        var a = Article()
        a.topic = topic
        if !angle.isEmpty { a.material = "选题角度：\(angle)" }
        a.styleId = data.styles.first?.id
        data.articles.insert(a, at: 0)
        save()
        return a.id
    }

    func binding(for id: UUID) -> Binding<Article>? {
        guard data.articles.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.data.articles.first(where: { $0.id == id }) ?? Article() },
            set: { new in
                if let i = self.data.articles.firstIndex(where: { $0.id == id }) {
                    var v = new
                    v.updated = Date()
                    self.data.articles[i] = v
                    self.save()
                }
            })
    }

    func article(_ id: UUID) -> Article? { data.articles.first { $0.id == id } }

    func update(_ id: UUID, _ change: (inout Article) -> Void) {
        guard let i = data.articles.firstIndex(where: { $0.id == id }) else { return }
        change(&data.articles[i])
        data.articles[i].updated = Date()
        save()
    }

    func deleteArticle(_ id: UUID) {
        data.articles.removeAll { $0.id == id }
        ImageStore.remove(id)
        save()
    }

    func style(_ id: UUID?) -> StylePreset? {
        guard let id else { return data.styles.first }
        return data.styles.first { $0.id == id } ?? data.styles.first
    }

    // MARK: 模型调用（按角色的顺序依次尝试，失败自动换下一个）

    /// 这个用途现在会用哪个模型（排第一的那个）
    func modelLabel(_ role: Role) -> String {
        guard let c = connections(for: role).first else { return "还没配模型" }
        return "\(c.name)（\(c.model)）"
    }

    func connections(for role: Role) -> [ModelConnection] {
        let ids = data.roles[role.rawValue] ?? []
        let picked = ids.compactMap { id in data.connections.first { $0.id == id } }
        return (picked.isEmpty ? data.connections : picked).map { c in
            var c = c
            if let m = data.roleModels["\(role.rawValue).\(c.id.uuidString)"], !m.isEmpty { c.model = m }
            return c
        }
    }

    func run(_ role: Role, _ messages: [ChatMessage], temperature: Double = 0.7) async throws -> String {
        let conns = connections(for: role)
        guard !conns.isEmpty else { throw LLMError.noConnection }
        var errors: [String] = []
        for c in conns {
            calling = "\(c.name)（\(c.model)）"
            defer { calling = nil }
            do {
                return try await LLM.chat(c, messages: messages, temperature: temperature)
            } catch {
                errors.append("· \(c.name)：\(error.localizedDescription)")
            }
        }
        throw LLMError.allFailed(errors)
    }

    func runJSON<T: Decodable>(_ role: Role, _ type: T.Type, _ messages: [ChatMessage]) async throws -> T {
        // JSON 解析失败时再试一次
        var lastError: Error = LLMError.empty
        for _ in 0..<2 {
            let raw = try await run(role, messages, temperature: 0.6)
            do { return try LLM.decodeJSON(type, from: raw) } catch { lastError = error }
        }
        throw lastError
    }
}
