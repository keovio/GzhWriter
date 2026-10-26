import AppKit
import Foundation

/// 公众号开发者接口：只做「上传图片 + 新建草稿」，不调用发表接口
enum WechatError: LocalizedError {
    case notConfigured
    case api(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "还没填公众号的 AppID 和 AppSecret（在「我的账号」里）。"
        case .api(let code, let msg):
            switch code {
            case 40164, 61004:
                if let ip = WechatError.ipIn(msg) {
                    return "微信看到你的 IP 是 \(ip)，它不在白名单里。把 \(ip) 加到公众号后台「设置与开发 → 开发接口管理 → IP 白名单」，等一两分钟再试。开着代理/VPN 或家里宽带换了 IP 都会变。（\(code)）"
                }
                return "这台电脑的 IP 不在公众号白名单里。到公众号后台「设置与开发 → 开发接口管理 → IP 白名单」把本机 IP 加进去。（\(code)）"
            case 40001, 40125, 40013:
                return "AppID 或 AppSecret 不对，重新复制一遍试试。（\(code)）"
            case 48001:
                return "这个公众号没有草稿箱接口权限（未认证的个人号可能没有）。可以先用「复制富文本」。（\(code)）"
            case 45009:
                return "今天接口调用次数用完了，明天再推。（\(code)）"
            default:
                return "公众号接口返回错误 \(code)：\(msg)"
            }
        }
    }
}

extension WechatError {
    /// 微信报错里带着它实际看到的 IP：invalid ip 1.2.3.4 ipv6 ...
    static func ipIn(_ msg: String) -> String? {
        guard let r = msg.range(of: #"\d{1,3}(\.\d{1,3}){3}"#, options: .regularExpression) else { return nil }
        return String(msg[r])
    }
}

@MainActor
final class Wechat {
    static let shared = Wechat()
    private var tokens: [String: (String, Date)] = [:]

    static let secretKey = "wechat.appsecret"

    /// 每个公众号的 AppSecret 单独存，按 AppID 找
    static func secret(appId: String, store: Store? = nil) -> String {
        let accs = (store ?? Store.shared)?.data.accounts ?? []
        if let a = accs.first(where: { $0.platform == "wechat" && $0.appId == appId }),
           let s = Keychain.get(a.secretKey), !s.isEmpty { return s }
        return Keychain.get(secretKey) ?? ""
    }

    func accessToken(appId: String) async throws -> String {
        if let (t, exp) = tokens[appId], Date() < exp { return t }
        let secret = Self.secret(appId: appId)
        guard !appId.isEmpty, !secret.isEmpty else { throw WechatError.notConfigured }
        let obj = try await post("https://api.weixin.qq.com/cgi-bin/stable_token",
                                 json: ["grant_type": "client_credential", "appid": appId, "secret": secret])
        guard let t = obj["access_token"] as? String else { throw WechatError.api(-1, "没拿到 access_token") }
        tokens[appId] = (t, Date().addingTimeInterval(Double((obj["expires_in"] as? Int) ?? 7200) - 300))
        return t
    }

    func reset() { tokens = [:] }

    /// 本机公网 IP，方便用户加白名单
    /// 查本机出口 IP。先用国内服务：开着代理时，访问微信一般走直连，国外查到的是代理的 IP，不准。
    static func publicIP() async -> String? {
        for s in ["https://4.ipw.cn", "https://myip.ipip.net", "https://api.ipify.org"] {
            guard let u = URL(string: s) else { continue }
            var req = URLRequest(url: u)
            req.timeoutInterval = 6
            guard let (d, _) = try? await URLSession.shared.data(for: req),
                  let t = String(data: d, encoding: .utf8),
                  let ip = WechatError.ipIn(t) else { continue }
            return ip
        }
        return nil
    }

    /// 测试：拿一次 token
    func test(appId: String) async throws {
        reset()
        _ = try await accessToken(appId: appId)
    }

    /// 封面：永久素材，返回 media_id
    func uploadCover(_ data: Data, appId: String) async throws -> String {
        let t = try await accessToken(appId: appId)
        let obj = try await upload("https://api.weixin.qq.com/cgi-bin/material/add_material?access_token=\(t)&type=image",
                                   data: Self.jpeg(data, maxBytes: 9_000_000), filename: "cover.jpg")
        guard let id = obj["media_id"] as? String else { throw WechatError.api(-1, "封面上传没返回 media_id") }
        return id
    }

    /// 正文图片：返回可以放进正文的 URL
    func uploadBodyImage(_ data: Data, appId: String) async throws -> String {
        let t = try await accessToken(appId: appId)
        let obj = try await upload("https://api.weixin.qq.com/cgi-bin/media/uploadimg?access_token=\(t)",
                                   data: Self.jpeg(data, maxBytes: 950_000), filename: "img.jpg")
        guard let u = obj["url"] as? String else { throw WechatError.api(-1, "图片上传没返回 url") }
        return u
    }

    /// 新建草稿，返回草稿 media_id
    func addDraft(title: String, author: String, digest: String, html: String,
                  thumbId: String, openComment: Bool, appId: String) async throws -> String {
        let t = try await accessToken(appId: appId)
        let article: [String: Any] = [
            "title": String(title.prefix(64)),
            "author": String(author.prefix(16)),
            "digest": String(digest.prefix(120)),
            "content": html,
            "thumb_media_id": thumbId,
            "need_open_comment": openComment ? 1 : 0,
            "only_fans_can_comment": 0,
        ]
        let obj = try await post("https://api.weixin.qq.com/cgi-bin/draft/add?access_token=\(t)", json: ["articles": [article]])
        guard let id = obj["media_id"] as? String else { throw WechatError.api(-1, "草稿没返回 media_id") }
        return id
    }

    // MARK: 网络

    private func check(_ data: Data) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WechatError.api(-1, String(data: data, encoding: .utf8) ?? "")
        }
        if let code = obj["errcode"] as? Int, code != 0 {
            if code == 40001 || code == 42001 { reset() }
            throw WechatError.api(code, obj["errmsg"] as? String ?? "")
        }
        return obj
    }

    private func post(_ url: String, json: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        // 微信要求中文不转义
        req.httpBody = try JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes])
        let (d, _) = try await URLSession.shared.data(for: req)
        return try check(d)
    }

    private func upload(_ url: String, data: Data, filename: String) async throws -> [String: Any] {
        let boundary = "gzh\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"media\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (d, _) = try await URLSession.shared.upload(for: req, from: body)
        return try check(d)
    }

    /// 转 JPEG 并压到限制以内
    static func jpeg(_ data: Data, maxBytes: Int) -> Data {
        guard let img = NSImage(data: data), let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return data }
        var q: Double = 0.9
        var out = rep.representation(using: .jpeg, properties: [.compressionFactor: q]) ?? data
        while out.count > maxBytes && q > 0.3 {
            q -= 0.15
            out = rep.representation(using: .jpeg, properties: [.compressionFactor: q]) ?? out
        }
        return out
    }
}
