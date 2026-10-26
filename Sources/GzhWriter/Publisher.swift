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

    // MARK: 各平台版本

    struct LongReply: Decodable {
        let digest: String?
        let toutiao: PlatformVariant?
        let baijiahao: PlatformVariant?
        let zhihu: PlatformVariant?
    }

    struct ShortReply: Decodable {
        let xiaohongshu: PlatformVariant?
        let weibo: PlatformVariant?
    }

    static let platformRules = """
    所有平台版本都不能出现「公众号」「关注我」「点击在看」「微信」「加我」等站外引导。
    不使用「不是……而是……」句式，不用破折号，不编造原文没有的数据和经历。只输出 JSON。
    """

    /// 按「我的平台」生成各平台版本。only 不为空时只重写这些平台。
    static func makeVariants(_ store: Store, _ id: UUID, only: [Platform] = []) async throws {
        guard let a = store.article(id) else { return }
        let targets = only.isEmpty ? Platform.others(store) : only
        let long = targets.filter(\.isLongForm)
        let short = targets.filter { !$0.isLongForm && $0 != .wechat }
        let firstPara = Layout.paragraphs(a.sections.first?.body ?? "").first ?? ""

        if !long.isEmpty || only.isEmpty {
            let rules = long.map(\.rule).joined(separator: "\n")
            let shape = long.map { "\"\($0.rawValue)\":{\"title\":\"\",\"intro\":\"\",\"tags\":[\"\"]}" }.joined(separator: ",")
            let msg: [ChatMessage] = [
                .system("""
                你帮作者把一篇公众号文章改成其他长文平台的版本。正文主体不变，只改标题、开头一段和标签。
                \(rules)
                \(platformRules)
                """),
                .user("""
                原标题：\(a.displayTitle)
                原开头：\(firstPara)
                全文：
                \(a.plainText.prefix(3500))

                输出 JSON：{"digest":"公众号摘要，40 字内"\(shape.isEmpty ? "" : "," + shape)}
                """),
            ]
            let r = try await store.runJSON(.draft, LongReply.self, msg)
            store.update(id) { art in
                for (p, v) in [(Platform.toutiao, r.toutiao), (.baijiahao, r.baijiahao), (.zhihu, r.zhihu)] {
                    guard long.contains(p), var v else { continue }
                    v.posted = art.variants[p.rawValue]?.posted ?? false
                    v.postedAt = art.variants[p.rawValue]?.postedAt
                    art.variants[p.rawValue] = v
                }
                if let d = r.digest, !d.isEmpty { art.digest = d }
            }
        }

        if !short.isEmpty {
            let rules = short.map(\.rule).joined(separator: "\n")
            let shape = short.map {
                $0 == .weibo ? "\"weibo\":{\"body\":\"\",\"tags\":[\"\"]}" : "\"\($0.rawValue)\":{\"title\":\"\",\"body\":\"\",\"tags\":[\"\"]}"
            }.joined(separator: ",")
            let msg: [ChatMessage] = [
                .system("""
                你帮作者把一篇公众号长文改写成短内容平台的版本。保留原文的核心观点和最有用的一两个细节，按平台习惯重写，不要缩写成摘要腔。
                \(rules)
                正文段落之间空一行；标签不带 # 号。
                \(platformRules)
                """),
                .user("""
                原标题：\(a.displayTitle)
                全文：
                \(a.plainText.prefix(4000))

                输出 JSON：{\(shape)}
                """),
            ]
            let r = try await store.runJSON(.draft, ShortReply.self, msg)
            store.update(id) { art in
                for (p, v) in [(Platform.xiaohongshu, r.xiaohongshu), (.weibo, r.weibo)] {
                    guard short.contains(p), var v else { continue }
                    v.posted = art.variants[p.rawValue]?.posted ?? false
                    v.postedAt = art.variants[p.rawValue]?.postedAt
                    art.variants[p.rawValue] = v
                }
            }
        }
    }

    /// 不写长文，直接按选题写一篇小红书 / 微博
    static func makeShort(_ store: Store, _ id: UUID, _ p: Platform, style: StylePreset?) async throws {
        guard let a = store.article(id) else { return }
        let shape = p == .weibo ? "{\"body\":\"\",\"tags\":[\"\"]}" : "{\"title\":\"\",\"body\":\"\",\"tags\":[\"\"]}"
        let msg: [ChatMessage] = [
            .system("""
            你帮作者写一篇\(p.name)内容，作者会自己改完再手动发。
            \(p.rule)
            正文段落之间空一行；标签不带 # 号。
            写作者本人的观点和经验口吻，具体、有信息量，不说空话套话，不编造数据和作者没提供的亲身经历。
            \(platformRules)
            \(Prompts.styleBlock(style))
            """),
            .user("""
            \(Prompts.profile(style))
            选题：\(a.topic)
            \(a.viewpoint.isEmpty ? "" : "作者观点：\(a.viewpoint)")
            \(a.material.isEmpty ? "" : a.material)

            输出 JSON：\(shape)
            """),
        ]
        var v = try await store.runJSON(.draft, PlatformVariant.self, msg)
        v.body = Humanize.clean(v.body)
        store.update(id) { $0.variants[p.rawValue] = v }
    }

    /// 平台版纯净 HTML（不带公众号的花哨样式和站外引导）
    static func platformHTML(_ a: Article, _ v: PlatformVariant) -> String {
        if !v.body.isEmpty {
            return Layout.paragraphs(v.body).map { "<p>\(Layout.esc($0))</p>" }.joined()
        }
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
        if !v.body.isEmpty { return v.body }
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

    /// 带标签的完整文字（小红书、微博直接贴这个）
    static func platformFull(_ a: Article, _ v: PlatformVariant) -> String {
        var s = platformPlain(a, v)
        if !v.tags.isEmpty { s += "\n\n" + v.tags.map { "#" + $0 }.joined(separator: " ") }
        return s
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
        guard let a = store.article(id) else { return }
        let w = store.data.wechat
        guard let acc = store.wechatAccount(for: a), !Wechat.secret(appId: acc.appId, store: store).isEmpty
        else { throw WechatError.notConfigured }
        let appId = acc.appId
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
        let thumb = try await api.uploadCover(cd, appId: appId)

        // 正文图片
        var urls: [String: String] = [:]
        for sec in a.sections where !sec.image.isEmpty {
            guard let u = ImageStore.url(id, sec.image), let d = try? Data(contentsOf: u) else { continue }
            log("上传正文图片")
            urls[sec.image] = try await api.uploadBodyImage(d, appId: appId)
        }

        let html = Layout.html(a, signature: style?.signature ?? "", img: { urls[$0] })
        let digest = a.digest.isEmpty ? String(a.plainText.replacingOccurrences(of: "\n", with: " ").prefix(54)) : a.digest
        log("新建草稿")
        let mid = try await api.addDraft(title: a.displayTitle, author: style?.author ?? "", digest: digest, html: html,
                                         thumbId: thumb, openComment: w.openComment, appId: appId)
        store.update(id) { $0.wechatDraft = mid }
        store.markDrafted(id, acc)
        log("已推到「\(acc.name)」草稿箱，去手机上看一眼再发")
    }
}
