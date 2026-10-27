import Foundation
import SwiftUI

/// 所有数据存在 ~/Library/Application Support/GzhWriter/data.json，只在本机
@MainActor
final class Store: ObservableObject {
    @Published var data = AppData()
    /// 正在调用的模型（界面上显示「正在用 xx」）
    @Published var calling: String?
    /// 数据文件读不出来时的提示。非 nil 表示本次启动是「空数据 + 不写盘」状态
    @Published var loadError: String?
    private var saveTask: Task<Void, Never>?

    /// 硬闸：解码失败的那次会话里一次都不许写盘，否则会把用户的坏文件顶成空数据。
    /// 这是第二层保险，第一层是 load() 里把原文件 move 走。
    static var writeBlocked = false

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("GzhWriter", isDirectory: true)
    }
    static var file: URL { folder.appendingPathComponent("data.json") }
    /// 「上次启动出过事」的持久化凭据。解码失败时把文案写进来，重启后靠它认出这次不是首次启动。
    /// 光放内存不行：move 走原文件后 data.json 位置是空的，下次启动会走「首次启动」分支静默吃空数据。
    static var loadErrorFile: URL { folder.appendingPathComponent("load-error.txt") }
    /// 第二凭据：上次损坏备份的文件名，用户在警示条上点过「我知道了」的记这里。
    /// 为什么需要：load-error.txt 本身可能写不进去（磁盘满/权限/同名目录占位），
    /// 那时靠扫 data.corrupt-*.json 兜底；但备份永不自动删除，若不加这个记录，
    /// 用户点过确认之后每次重启都会再被拦一次。
    static var loadAckFile: URL { folder.appendingPathComponent("load-acked.txt") }
    /// 本次会话的提示若来自某个损坏备份，记下文件名，点确认时写进 load-acked.txt
    static var pendingCorruptBackup: String?

    static weak var shared: Store?

    init() {
        load()
        Self.shared = self
        if data.styles.isEmpty {
            data.styles = [StylePreset(name: "我的公众号", sample: "", avoid: "")]
        }
        // 测试钩子：模拟用户点「我知道了，开始新文档」。无头环境点不了按钮，
        // 但按钮 action 调的就是这个函数，走的是同一条路径（删凭据 → 解闸 → 清提示）。
        // 放在 demo() 之前，这样配合 GZH_DEMO 就能验证「解除后能正常写盘」。
        // 只在 debug 构建生效：这是绕过按钮直接关掉数据保护的开关，正式包里不能留。
        #if DEBUG
        if ProcessInfo.processInfo.environment["GZH_ACK_LOAD_ERROR"] != nil { clearLoadError() }
        #endif
        // demo 数据只在 debug 构建里造，正式包启动就是用户的真实数据
        #if DEBUG
        if ProcessInfo.processInfo.environment["GZH_DEMO"] != nil { demo() }
        #endif
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

    /// 诊断日志：凭据类文件静默写失败，是出事故后最难查的东西——文件没了、日志也没有，
    /// 只能猜。所以这几处写失败一律留痕（走系统日志，用户看不到，管家和测试能查到）。
    /// 注意：留痕不等于改变行为，写失败该怎么降级还是怎么降级，方向只能是「多拦一次」。
    static func note(_ msg: String) {
        NSLog("[GzhWriter] %@", msg)
    }

    /// 目录里最新的一份损坏备份，但用户还没确认过的。没有就返回 nil。
    /// 已确认过的记在 load-acked.txt，备份文件本身永不自动删除（用户可能要手动找回原稿）。
    static func latestUnackedBackup() -> String? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return nil }
        let corrupt = names.filter { $0.hasPrefix("data.corrupt-") && $0.hasSuffix(".json") }
        guard !corrupt.isEmpty else { return nil }
        let acked = (try? String(contentsOf: loadAckFile, encoding: .utf8)) ?? ""
        let ackedSet = Set(acked.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        // 判据是「任何一份 corrupt 不在 ack 名单里就拦」，不是「最新那份在不在名单里」。
        // 只看最新一份会漏掉这种情况：旧备份 A 没确认过、新备份 B 确认过 → 最新是 B → 放行，
        // 可 A 里躺着的原稿就再也没人提起了（V34）。
        let unacked = corrupt.filter { !ackedSet.contains($0) }
        guard !unacked.isEmpty else { return nil }
        // 文案用 mtime 最新的那份未确认备份（用户最可能记得的是最近这次事故）
        return unacked.compactMap { n -> (String, Date)? in
            let p = folder.appendingPathComponent(n)
            guard let m = (try? fm.attributesOfItem(atPath: p.path))?[.modificationDate] as? Date else { return nil }
            return (n, m)
        }.max { $0.1 < $1.1 }?.0 ?? unacked.first
    }

    /// 从凭据文案里抠出备份文件名（文案形如「…原文件已备份为 data.corrupt-123.json，…」）。
    /// 只在扫目录拿不到时兜底：move 失败时文案里没有文件名，返回 nil。
    static func backupName(in text: String) -> String? {
        let marker = "data.corrupt-"
        guard let r = text.range(of: marker) else { return nil }
        let rest = text[r.lowerBound...]
        guard let end = rest.range(of: ".json") else { return nil }
        return String(rest[..<end.upperBound])
    }

    func load() {
        // 文件不存在 = 首次启动，正常以空数据开始。
        // 但先看一眼上次有没有出过事：解码失败时原文件被 move 走了，data.json 位置是空的，
        // 这一行会和首次启动长得一模一样。不读凭据的话，重启后就会静默吃空数据并且正常写盘。
        guard FileManager.default.fileExists(atPath: Self.file.path) else {
            if let prev = try? String(contentsOf: Self.loadErrorFile, encoding: .utf8),
               !prev.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Self.writeBlocked = true
                loadError = prev
                // 走 txt 分支也要记下是哪份备份：否则用户点确认时 ack 不落盘，
                // 删掉 data.json 重启又会被同一份备份拦住（V30）。
                // 优先扫目录拿最新的未确认备份；扫不到（move 失败、或 txt 是旧的）
                // 就从凭据文案里把文件名抠出来。
                Self.pendingCorruptBackup = Self.latestUnackedBackup() ?? Self.backupName(in: prev)
                return
            }
            // 凭据文件读不到，还有第二种可能：上次解码失败时 load-error.txt 根本写不进去
            // （磁盘满、权限、同名目录占位都等价）。这时 data.json 位置是空的、
            // 凭据也是空的，光看这两样和「首次启动」完全一样。
            // 兜底：扫目录里有没有损坏备份，有就说明确实出过事，照样拦。
            if let backup = Self.latestUnackedBackup() {
                Self.writeBlocked = true
                Self.pendingCorruptBackup = backup
                loadError = "发现上次数据损坏时留下的备份 \(backup)，本次仍以空数据启动、不会写盘。原稿在那份备份文件里，确认后可以手动恢复。"
            }
            return
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        do {
            let d = try Data(contentsOf: Self.file)
            var v = try dec.decode(AppData.self, from: d)
            v.hot.removeAll { $0.platform == "douyin" }
            data = v
        } catch {
            // 读盘或解码失败：第一层保险 —— 把原文件整个 move 走留档，
            // Self.file 位置空出来，后续 save() 写的是新文件，原数据一定还在。
            let stamp = Int(Date().timeIntervalSince1970)
            let keep = Self.folder.appendingPathComponent("data.corrupt-\(stamp).json")
            let moved = (try? FileManager.default.moveItem(at: Self.file, to: keep)) != nil
            // 第二层保险：本次会话一律不写盘
            Self.writeBlocked = true
            // move 成功时也记下备份名：万一凭据文件写不进去（磁盘满/权限），
            // 重启后靠第二凭据扫描能认出这次出过事；点确认时也能把「已确认」落盘，
            // 免得凭据没了、备份还在，导致用户点完确认重启又被拦一次。
            if moved { Self.pendingCorruptBackup = "data.corrupt-\(stamp).json" }
            let msg = moved
                ? "数据文件读不出来（\(error.localizedDescription)）。原文件已备份为 data.corrupt-\(stamp).json，本次以空数据启动，不会覆盖它。"
                : "数据文件读不出来（\(error.localizedDescription)），备份也失败了。为免覆盖原文件，本次启动不写入任何数据。"
            loadError = msg
            // 第三层：把「出过事」落盘。move 成功后 data.json 位置是空的，下次启动看起来和首次启动一样，
            // 只有这份凭据能让重启后的会话继续提示、继续不写盘。
            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            // 写失败不致命（拦截靠扫备份兜），但要留痕：静默失败的凭据是排查事故时最难看的东西
            do { try msg.write(to: Self.loadErrorFile, atomically: true, encoding: .utf8) }
            catch { Self.note("凭据 load-error.txt 写入失败：\(error.localizedDescription)（不影响拦截，靠扫 corrupt 备份兜）") }
        }
    }

    /// 用户在警示条上点「我知道了」：唯一解除写盘闸的方式，必须手动点。
    /// 删凭据 → 解除闸 → 清提示，此后正常保存（用户已知情并选择继续用）。
    func clearLoadError() {
        // 如果这次的提示来自某份损坏备份，先把「已确认过它」记下来，
        // 否则备份文件还在，下次启动会被第二凭据再拦一次，用户会以为永远解除不掉。
        if let backup = Self.pendingCorruptBackup {
            let old = (try? String(contentsOf: Self.loadAckFile, encoding: .utf8)) ?? ""
            var lines = old.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !lines.contains(backup) { lines.append(backup) }
            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            do { try lines.joined(separator: "\n").write(to: Self.loadAckFile, atomically: true, encoding: .utf8) }
            catch { Self.note("确认记录 load-acked.txt 写入失败：\(error.localizedDescription)（后果是下次启动多拦一次，不丢数据）") }
            Self.pendingCorruptBackup = nil
        }
        try? FileManager.default.removeItem(at: Self.loadErrorFile)
        Self.writeBlocked = false
        loadError = nil
    }

    /// 改动后 0.5 秒落盘（合并连续输入）；写之前留一份 .bak
    func save() {
        guard !Self.writeBlocked else { return }
        saveTask?.cancel()
        let snapshot = data
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, self != nil else { return }
            Self.write(snapshot)
        }
    }

    static func write(_ d: AppData) {
        // 硬闸：解码失败的那次会话，任何一次 save 都不许落到 data.json
        guard !writeBlocked else { return }
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
