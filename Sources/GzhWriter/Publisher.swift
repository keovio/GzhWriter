import AppKit
import Foundation

/// 写完之后的事：配图、各平台版本、推公众号草稿箱。都不发表。
@MainActor
enum Publisher {

    // MARK: 配图

    struct ImagePlan: Decodable {
        struct Item: Decodable { let section: Int; let prompt: String }
        let cover: String
        let images: [Item]?
    }

    static func makeImages(_ store: Store, _ id: UUID, log: (String) -> Void) async throws {
        guard let a = store.article(id) else { return }
        let style = store.style(a.styleId)
        let every = max(1, store.data.auto.imageEvery)
        let picks = every >= 99 ? [] : Array(stride(from: 0, to: a.sections.count, by: every))

        guard let conn = ImageGen.connection(store) else {
            // 没有画图模型：本地文字封面
            if let d = LocalCover.render(title: a.displayTitle, account: style?.name ?? "", seed: a.displayTitle.count) {
                let name = ImageStore.save(d, id, ext: "jpg")
                store.update(id) { $0.cover = name }
                log("生成本地封面（没接智谱，正文不配图）")
            }
            return
        }

        log("构思配图")
        let list = picks.map { i in "第\(i + 1)节「\(a.sections[i].heading)」：\(a.sections[i].body.prefix(160))" }.joined(separator: "\n")
        let msg: [ChatMessage] = [
            .system("你是公众号美编，给文章写文生图提示词。画面风格统一为：\(store.data.auto.imageStyle)。提示词用中文，具体描述画面主体、场景、构图、色调，60 到 120 字。不要出现文字、logo、水印、真实人物姓名。只输出 JSON。"),
            .user("""
            文章标题：\(a.displayTitle)
            需要配图的小节（没有就只写封面，images 给空数组）：
            \(list)

            输出 JSON：{"cover":"封面提示词，横版，主题明确，画面留出简洁背景","images":[{"section":小节序号,"prompt":"提示词"}]}
            """),
        ]
        let plan = try await store.runJSON(.topic, ImagePlan.self, msg)

        log("画封面")
        do {
            let d = try await ImageGen.generate(conn, prompt: plan.cover + "，\(store.data.auto.imageStyle)，横版构图，无文字", size: .wide)
            let name = ImageStore.save(d, id)
            store.update(id) { $0.cover = name }
        } catch {
            log("封面失败：\(error.localizedDescription)，改用本地封面")
            if let d = LocalCover.render(title: a.displayTitle, account: style?.name ?? "", seed: a.displayTitle.count) {
                let name = ImageStore.save(d, id, ext: "jpg")
                store.update(id) { $0.cover = name }
            }
        }

        for item in plan.images ?? [] {
            let idx = item.section - 1
            guard idx >= 0, idx < a.sections.count else { continue }
            log("画第 \(item.section) 部分的配图")
            do {
                let d = try await ImageGen.generate(conn, prompt: item.prompt + "，\(store.data.auto.imageStyle)，无文字", size: .section)
                let name = ImageStore.save(d, id)
                let secId = a.sections[idx].id
                store.update(id) { art in
                    if let k = art.sections.firstIndex(where: { $0.id == secId }) { art.sections[k].image = name }
                }
            } catch {
                log("第 \(item.section) 部分配图失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: 头条号、百家号版本

    struct VariantReply: Decodable {
        let digest: String?
        let toutiao: PlatformVariant
        let baijiahao: PlatformVariant
    }

    static func makeVariants(_ store: Store, _ id: UUID) async throws {
        guard let a = store.article(id) else { return }
        let firstPara = Layout.paragraphs(a.sections.first?.body ?? "").first ?? ""
        let msg: [ChatMessage] = [
            .system("""
            你帮作者把一篇公众号文章改成头条号和百家号版本。正文主体不变，只改标题、开头一段和标签。
            头条号：标题 20 到 30 字，口语、有具体信息或数字，开头一段两三句直接抛出读者关心的问题。
            百家号：标题规范克制，不夸张不标题党，不用感叹号和问号连用，开头一段交代清楚这篇讲什么。
            两个平台都不能出现「公众号」「关注我」「点击在看」「微信」等站外引导。
            不使用「不是……而是……」句式，不用破折号。只输出 JSON。
            """),
            .user("""
            原标题：\(a.displayTitle)
            原开头：\(firstPara)
            全文：
            \(a.plainText.prefix(3500))

            输出 JSON：{"digest":"公众号摘要，40 字内","toutiao":{"title":"","intro":"","tags":["",""]},"baijiahao":{"title":"","intro":"","tags":["",""]}}
            """),
        ]
        let r = try await store.runJSON(.draft, VariantReply.self, msg)
        store.update(id) {
            $0.variants["toutiao"] = r.toutiao
            $0.variants["baijiahao"] = r.baijiahao
            if let d = r.digest, !d.isEmpty { $0.digest = d }
        }
    }

    /// 平台版纯净 HTML（不带公众号的花哨样式和站外引导）
    static func platformHTML(_ a: Article, _ v: PlatformVariant) -> String {
        var out = ""
        let intro = v.intro.trimmingCharacters(in: .whitespacesAndNewlines)
        for (i, sec) in a.sections.enumerated() {
            if !sec.heading.isEmpty, ArticleKind.of(a.kind).showsHeadings { out += "<h2>\(Layout.esc(sec.heading))</h2>" }
            var paras = Layout.paragraphs(sec.body)
            if i == 0, !intro.isEmpty, !paras.isEmpty { paras[0] = intro }
            for p in paras {
                let t = p.hasPrefix(">") ? String(p.drop(while: { $0 == ">" || $0 == " " })) : p
                out += "<p>\(Layout.esc(t).replacingOccurrences(of: "**", with: ""))</p>"
            }
        }
        return out
    }

    static func platformPlain(_ a: Article, _ v: PlatformVariant) -> String {
        var out: [String] = []
        let intro = v.intro.trimmingCharacters(in: .whitespacesAndNewlines)
        for (i, sec) in a.sections.enumerated() {
            if !sec.heading.isEmpty, ArticleKind.of(a.kind).showsHeadings { out.append(sec.heading) }
            var paras = Layout.paragraphs(sec.body)
            if i == 0, !intro.isEmpty, !paras.isEmpty { paras[0] = intro }
            out += paras.map { $0.replacingOccurrences(of: "**", with: "") }
        }
        return out.joined(separator: "\n\n")
    }

    static func copyPlatform(_ a: Article, _ v: PlatformVariant) {
        let html = platformHTML(a, v)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(html, forType: .html)
        pb.setString(platformPlain(a, v), forType: .string)
    }

    static func copyText(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    // MARK: 公众号草稿箱

    static func pushDraft(_ store: Store, _ id: UUID, log: (String) -> Void) async throws {
        let w = store.data.wechat
        guard !w.appId.isEmpty, !(Keychain.get(Wechat.secretKey) ?? "").isEmpty else { throw WechatError.notConfigured }
        guard let a = store.article(id) else { return }
        let style = store.style(a.styleId)
        let api = Wechat.shared

        // 封面（没有就本地画一张）
        var coverData: Data?
        if let u = ImageStore.url(id, a.cover) { coverData = try? Data(contentsOf: u) }
        if coverData == nil, let d = LocalCover.render(title: a.displayTitle, account: style?.name ?? "", seed: a.displayTitle.count) {
            coverData = d
            let name = ImageStore.save(d, id, ext: "jpg")
            store.update(id) { $0.cover = name }
        }
        guard let cd = coverData else { throw WechatError.api(-1, "封面生成失败") }
        log("上传封面")
        let thumb = try await api.uploadCover(cd, appId: w.appId)

        // 正文图片
        var urls: [String: String] = [:]
        for sec in a.sections where !sec.image.isEmpty {
            guard let u = ImageStore.url(id, sec.image), let d = try? Data(contentsOf: u) else { continue }
            log("上传正文图片")
            urls[sec.image] = try await api.uploadBodyImage(d, appId: w.appId)
        }

        let html = Layout.html(a, signature: style?.signature ?? "", img: { urls[$0] })
        let digest = a.digest.isEmpty ? String(a.plainText.replacingOccurrences(of: "\n", with: " ").prefix(54)) : a.digest
        log("新建草稿")
        let mid = try await api.addDraft(title: a.displayTitle, author: style?.author ?? "", digest: digest, html: html,
                                         thumbId: thumb, openComment: w.openComment, appId: w.appId)
        store.update(id) { $0.wechatDraft = mid }
        log("已推到公众号草稿箱，去手机上看一眼再发")
    }
}
