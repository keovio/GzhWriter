import Foundation
import Security

/// 密钥存放：~/Library/Application Support/GzhWriter/secrets.json（权限 600，只有本机当前用户能读）。
/// 以前存在钥匙串里，但 app 没有开发者签名，每次更新都会弹授权；第一次读到旧钥匙串项时搬过来并删掉。
enum Keychain {
    static let service = "com.keovi.GzhWriter.apikey"
    private static let lock = NSLock()
    private static var cache: [String: String]?

    private static var file: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("GzhWriter", isDirectory: true).appendingPathComponent("secrets.json")
    }

    private static func loadLocked() -> [String: String] {
        if let c = cache { return c }
        var d: [String: String] = [:]
        if let data = try? Data(contentsOf: file),
           let v = try? JSONDecoder().decode([String: String].self, from: data) { d = v }
        cache = d
        return d
    }

    private static func writeLocked(_ d: [String: String]) {
        cache = d
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(d) else { return }
        try? data.write(to: file, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func get(_ account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        var d = loadLocked()
        if let v = d[account] { return v.isEmpty ? nil : v }
        // 旧版本存在钥匙串里：读一次，搬到文件，删掉钥匙串项
        let migratedKey = "_migrated." + account
        if d[migratedKey] == nil {
            d[migratedKey] = "1"
            if let old = legacyGet(account), !old.isEmpty {
                d[account] = old
                legacyDelete(account)
            }
            writeLocked(d)
            return d[account]
        }
        return nil
    }

    static func set(_ value: String, for account: String) {
        lock.lock(); defer { lock.unlock() }
        var d = loadLocked()
        d[account] = value
        d["_migrated." + account] = "1"
        writeLocked(d)
    }

    private static func legacyGet(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func legacyDelete(_ account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

struct ChatMessage: Codable {
    let role: String
    let content: String
    static func system(_ s: String) -> ChatMessage { .init(role: "system", content: s) }
    static func user(_ s: String) -> ChatMessage { .init(role: "user", content: s) }
}

enum LLMError: LocalizedError {
    case noConnection
    case noKey(String)
    case badURL(String)
    case readFail(String)
    case http(Int, String)
    case empty
    case badJSON(String)
    case allFailed([String])

    var errorDescription: String? {
        switch self {
        case .noConnection: return "还没有可用的模型。先到「模型设置」添加一个，并给这个步骤选上。"
        case .noKey(let n): return "「\(n)」还没填 API Key。"
        case .badURL(let u): return "接口地址不对：\(u)"
        case .readFail(let m): return m
        case .http(let code, let body): return "接口返回 \(code)：\(body.prefix(300))"
        case .empty: return "模型没有返回内容。"
        case .badJSON(let raw): return "模型返回的格式没法解析，可以再试一次。\n\(raw.prefix(200))"
        case .allFailed(let errs): return "所有模型都失败了：\n" + errs.joined(separator: "\n")
        }
    }
}

/// OpenAI 兼容的 /chat/completions 客户端。DeepSeek、GLM、Kimi、通义、豆包、各类中转站都走这个。
enum LLM {
    static func endpoint(_ base: String, _ path: String) throws -> URL {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        if b.hasSuffix("/chat/completions") { b = String(b.dropLast("/chat/completions".count)) }
        guard let url = URL(string: b + path), url.scheme?.hasPrefix("http") == true else {
            throw LLMError.badURL(base)
        }
        return url
    }

    static func chat(_ conn: ModelConnection, messages: [ChatMessage], temperature: Double = 0.7) async throws -> String {
        guard let key = Keychain.get(conn.id.uuidString), !key.isEmpty else { throw LLMError.noKey(conn.name) }
        var req = URLRequest(url: try endpoint(conn.baseURL, "/chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": conn.model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "temperature": temperature,
            "stream": false,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw LLMError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.empty
        }
        return stripThinking(content)
    }

    /// 拉取模型列表（不是所有服务都支持，失败就手动填）
    static func listModels(baseURL: String, key: String) async throws -> [String] {
        var req = URLRequest(url: try endpoint(baseURL, "/models"))
        req.timeoutInterval = 30
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw LLMError.http(code, String(data: data, encoding: .utf8) ?? "") }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let list = (obj?["data"] as? [[String: Any]]) ?? []
        return list.compactMap { $0["id"] as? String }.sorted()
    }

    /// 有些推理模型会把思考过程放在 <think> 里，去掉
    static func stripThinking(_ s: String) -> String {
        var t = s
        if let r = t.range(of: "</think>") { t = String(t[r.upperBound...]) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 从模型回复里抠出 JSON 对象并解码（兼容 ```json 代码块和前后多余文字）
    static func decodeJSON<T: Decodable>(_ type: T.Type, from raw: String) throws -> T {
        var s = raw
        if let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b {
            s = String(s[a...b])
        }
        guard let data = s.data(using: .utf8) else { throw LLMError.badJSON(raw) }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw LLMError.badJSON(raw) }
    }
}

/// 读取网页正文作参考素材（简单去标签，不做采集）
enum PageReader {
    static func read(_ urlString: String) async throws -> (title: String, text: String) {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw LLMError.badURL(urlString)
        }
        // 公众号文章直接请求会被重定向到验证页，用内置浏览器读
        if url.host?.contains("mp.weixin.qq.com") == true {
            if let p = await WebReader.shared.read(url.absoluteString, timeout: 15, interactive: true) {
                var t = p.text
                if t.count > 6000 { t = String(t.prefix(6000)) + "…" }
                return (p.title, t)
            }
            throw LLMError.readFail("公众号文章没读到（可能需要验证），先点「打开原文」看一眼再试")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        var html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        var title = ""
        if let m = html.range(of: #"<meta property="og:title" content="([^"]*)""#, options: .regularExpression) {
            title = String(html[m]).replacingOccurrences(of: #"^.*content=""#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "\"", with: "")
        } else if let m = html.range(of: #"<title[^>]*>[^<]*</title>"#, options: .regularExpression) {
            title = String(html[m]).replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        }
        // 公众号文章只取正文区
        if let r = html.range(of: #"id="js_content""#) { html = String(html[r.lowerBound...]) }
        for pat in [#"(?s)<script.*?</script>"#, #"(?s)<style.*?</style>"#] {
            html = html.replacingOccurrences(of: pat, with: " ", options: .regularExpression)
        }
        html = html.replacingOccurrences(of: #"(?i)<br\s*/?>|</p>|</section>|</h\d>|</li>"#, with: "\n", options: .regularExpression)
        var text = html.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (a, b) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
            text = text.replacingOccurrences(of: a, with: b)
        }
        text = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n\s*\n+"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 6000 { text = String(text.prefix(6000)) + "…" }
        return (title.trimmingCharacters(in: .whitespacesAndNewlines), text)
    }
}
