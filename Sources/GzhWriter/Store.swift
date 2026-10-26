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

    init() {
        load()
        if data.styles.isEmpty {
            data.styles = [StylePreset(name: "我的公众号", sample: "", avoid: "")]
        }
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
        return picked.isEmpty ? data.connections : picked
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
