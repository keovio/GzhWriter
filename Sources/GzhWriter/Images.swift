import AppKit
import SwiftUI

/// 稿件图片：存在 ~/Library/Application Support/GzhWriter/images/<稿件id>/
enum ImageStore {
    static func dir(_ articleId: UUID) -> URL {
        let d = Store.folder.appendingPathComponent("images/\(articleId.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func url(_ articleId: UUID, _ name: String) -> URL? {
        guard !name.isEmpty else { return nil }
        let u = dir(articleId).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    static func save(_ data: Data, _ articleId: UUID, ext: String = "png") -> String {
        let name = "\(UUID().uuidString.prefix(8)).\(ext)"
        try? data.write(to: dir(articleId).appendingPathComponent(name))
        return name
    }

    /// 预览用：转成 data URI
    static func dataURI(_ articleId: UUID, _ name: String) -> String? {
        guard let u = url(articleId, name), let d = try? Data(contentsOf: u) else { return nil }
        let mime = u.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
        return "data:\(mime);base64,\(d.base64EncodedString())"
    }

    static func reveal(_ articleId: UUID) {
        NSWorkspace.shared.activateFileViewerSelecting([dir(articleId)])
    }

    static func remove(_ articleId: UUID) {
        try? FileManager.default.removeItem(at: dir(articleId))
    }
}

/// 文生图：智谱 GLM-Image / CogView-4（/images/generations）
enum ImageGen {
    /// 找一个能画图的连接（目前认智谱）
    @MainActor static func connection(_ store: Store) -> ModelConnection? {
        store.data.connections.first {
            $0.baseURL.contains("bigmodel.cn") && !(Keychain.get($0.id.uuidString) ?? "").isEmpty
        }
    }

    enum Size { case wide, section }

    /// 先用 GLM-Image（0.1 元/张），账号没开通时退回 CogView-4（0.06 元/张）
    static let models: [(String, wide: String, section: String)] = [
        ("glm-image", "1728x960", "1472x1088"),
        ("cogView-4-250304", "1440x720", "1344x768"),
    ]

    static func generate(_ conn: ModelConnection, prompt: String, size: Size) async throws -> Data {
        var last: Error = LLMError.empty
        for m in models {
            do {
                return try await generate(conn, model: m.0, prompt: prompt, size: size == .wide ? m.wide : m.section)
            } catch LLMError.http(let code, let body) where code == 400 || code == 404 || body.contains("模型") {
                last = LLMError.http(code, body)    // 模型不可用，换下一个
            }
        }
        throw last
    }

    static func generate(_ conn: ModelConnection, model: String, prompt: String, size: String) async throws -> Data {
        guard let key = Keychain.get(conn.id.uuidString), !key.isEmpty else { throw LLMError.noKey(conn.name) }
        var base = conn.baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard let u = URL(string: base + "/images/generations") else { throw LLMError.badURL(base) }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "prompt": String(prompt.prefix(900)),
            "size": size,
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw LLMError.http(code, String(data: data, encoding: .utf8) ?? "") }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let first = (obj?["data"] as? [[String: Any]])?.first else { throw LLMError.empty }
        if let b64 = first["b64_json"] as? String, let d = Data(base64Encoded: b64) { return d }
        guard let s = first["url"] as? String, let iu = URL(string: s) else { throw LLMError.empty }
        let (img, _) = try await URLSession.shared.data(from: iu)
        return img
    }
}

/// 没有画图模型时，本地画一张干净的文字封面（2.35:1）
enum LocalCover {
    static let palettes: [(String, String)] = [
        ("#1F2B47", "#3F68A8"), ("#2F4F4F", "#5B8C7A"), ("#4A2C2A", "#B5654B"),
        ("#2D2A4A", "#6C5B9E"), ("#1E3A5F", "#2F80B7"),
    ]

    @MainActor static func render(title: String, account: String, seed: Int) -> Data? {
        let p = palettes[abs(seed) % palettes.count]
        let view = ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [Color(hex: p.0), Color(hex: p.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color.white.opacity(0.06)).frame(width: 520, height: 520).offset(x: 820, y: -260)
            Circle().fill(Color.white.opacity(0.05)).frame(width: 300, height: 300).offset(x: 1020, y: 40)
            VStack(alignment: .leading, spacing: 22) {
                Rectangle().fill(Color.white.opacity(0.85)).frame(width: 64, height: 6)
                Text(title)
                    .font(.system(size: 64, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineSpacing(10)
                    .lineLimit(2)
                    .frame(maxWidth: 1040, alignment: .leading)
                if !account.isEmpty {
                    Text(account).font(.system(size: 28, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                }
            }
            .padding(.leading, 80)
            .padding(.bottom, 90)
        }
        .frame(width: 1410, height: 600)
        .clipped()

        let r = ImageRenderer(content: view)
        r.scale = 1
        guard let cg = r.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }
}
