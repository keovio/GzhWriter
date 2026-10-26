import AppKit
import SwiftUI

/// 编辑器排版页下方：配图、推草稿箱、头条号/百家号版本
struct DistributeCard: View {
    @EnvironmentObject var store: Store
    let articleId: UUID
    var only: Platform? = nil          // 直接写的小红书/微博：只显示这一个平台
    @StateObject private var busy = Busy()
    @State private var platform = ""
    @State private var copiedKey = ""
    @State private var drafting: String?      // 正在存草稿的平台
    @State private var draftNote: [String: String] = [:]

    var a: Article { store.article(articleId) ?? Article() }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SectionTitle(text: only.map { "\($0.name)正文" } ?? "配图与多平台分发", hint: only == nil ? "都只是准备好，发不发由你" : "改好了复制或打开平台，发布你自己点")
                Spacer()
            }
            BusyBar(busy: busy)

            if only == nil {
            // 配图
            HStack(spacing: 12) {
                coverThumb
                VStack(alignment: .leading, spacing: 4) {
                    Text("配图").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(imageStatus).font(.system(size: 12)).foregroundStyle(Theme.sub)
                    HStack(spacing: 8) {
                        Button(a.cover.isEmpty ? "生成配图" : "重新配图") { runImages() }
                            .buttonStyle(GhostButton()).disabled(busy.label != nil)
                        if !a.cover.isEmpty {
                            Button("在访达中显示") { ImageStore.reveal(articleId) }.buttonStyle(LinkButton())
                            Button("去掉配图") {
                                store.update(articleId) { art in
                                    art.cover = ""
                                    for k in art.sections.indices { art.sections[k].image = "" }
                                }
                            }
                            .buttonStyle(LinkButton(color: Theme.sub))
                        }
                    }
                    .padding(.top, 2)
                }
                Spacer()
            }
            .padding(14)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))

            // 公众号草稿箱
            HStack(spacing: 12) {
                Image(systemName: a.wechatDraft.isEmpty ? "tray.and.arrow.up" : "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(a.wechatDraft.isEmpty ? Theme.blue : Theme.green)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("公众号草稿箱").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(wechatStatus).font(.system(size: 12)).foregroundStyle(Theme.sub)
                }
                Spacer()
                Button(a.wechatDraft.isEmpty ? "推到草稿箱" : "再推一份") { push() }
                    .buttonStyle(PrimaryButton())
                    .disabled(busy.label != nil || store.wechatAccount(for: a) == nil)
            }
            .padding(14)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
            }

            // 其他平台
            VStack(alignment: .leading, spacing: 10) {
                if only == nil {
                HStack(spacing: 6) {
                    ForEach(tabs) { p in platformChip(p) }
                    Spacer()
                    if !Platform.others(store).isEmpty {
                        Button(a.variants.isEmpty ? "一键生成全部平台版本" : "全部重新生成") { runVariants([]) }
                            .buttonStyle(LinkButton()).disabled(busy.label != nil)
                    }
                }
                }
                if let p = current {
                    if let v = a.variants[p.rawValue] {
                        variantView(p, v)
                    } else {
                        HStack {
                            Text("\(p.name)版本还没生成。一键成稿会自动出，手动写的点这里。")
                                .font(.system(size: 12)).foregroundStyle(Theme.sub)
                            Spacer()
                            Button("生成\(p.name)版本") { runVariants([p]) }
                                .buttonStyle(GhostButton()).disabled(busy.label != nil)
                        }
                        .padding(.vertical, 6)
                    }
                } else {
                    Text("到「我的账号」里添加你在做的平台账号。").font(.system(size: 12)).foregroundStyle(Theme.sub)
                }
            }
            .padding(14)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
        }
        .card()
    }

    // MARK: 子视图

    @ViewBuilder var coverThumb: some View {
        if let u = ImageStore.url(articleId, a.cover), let img = NSImage(contentsOf: u) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 104, height: 52).clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6).fill(Theme.rule).frame(width: 104, height: 52)
                .overlay(Image(systemName: "photo").foregroundStyle(Theme.faint))
        }
    }

    var current: Platform? {
        if let only { return only }
        let list = tabs
        if let p = Platform.of(platform), list.contains(p) { return p }
        return list.first
    }

    /// 这篇的主平台排第一，再加上设置里开着的平台
    var tabs: [Platform] {
        var list = Platform.others(store)
        if let main = store.article(articleId)?.primary, main != "wechat", let p = Platform.of(main) {
            list.removeAll { $0 == p }; list.insert(p, at: 0)
        }
        return list
    }

    func platformChip(_ p: Platform) -> some View {
        let on = current == p
        let v = a.variants[p.rawValue]
        let dot: Color = v == nil ? Theme.rule : (v!.posted ? Theme.green : p.color)
        return Button { platform = p.rawValue } label: {
            HStack(spacing: 5) {
                Circle().fill(dot).frame(width: 6, height: 6)
                Text(p.name)
            }
            .font(.system(size: 12, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? Theme.blue : Theme.sub)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(on ? Theme.blueBg : Color.clear, in: Capsule())
        }
        .buttonStyle(RowButton())
        .help(v == nil ? "还没生成" : (v!.posted ? "已发" : "已生成，未发"))
    }

    func vb(_ p: Platform, _ kp: WritableKeyPath<PlatformVariant, String>) -> Binding<String> {
        Binding(get: { a.variants[p.rawValue]?[keyPath: kp] ?? "" },
                set: { nv in store.update(articleId) { $0.variants[p.rawValue, default: PlatformVariant()][keyPath: kp] = nv } })
    }

    func tagsBinding(_ p: Platform) -> Binding<String> {
        Binding(get: { (a.variants[p.rawValue]?.tags ?? []).joined(separator: " ") },
                set: { nv in
                    let tags = nv.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "，" || $0 == "#" }).map(String.init)
                    store.update(articleId) { $0.variants[p.rawValue, default: PlatformVariant()].tags = tags }
                })
    }

    func variantView(_ p: Platform, _ v: PlatformVariant) -> some View {
        let hits = Compliance.scanText(v.title + "\n" + v.intro + "\n" + v.body)
        return VStack(alignment: .leading, spacing: 8) {
            if p != .weibo {
                HStack(spacing: 8) {
                    Text("标题").font(.system(size: 12)).foregroundStyle(Theme.sub).frame(width: 52, alignment: .leading)
                    TextField("", text: vb(p, \.title)).fieldBox()
                    Text("\(v.title.count) 字").font(.system(size: 11)).foregroundStyle(v.title.count > (p == .xiaohongshu ? 20 : 30) ? Theme.orange : Theme.faint)
                }
            }
            if p.isLongForm {
                HStack(alignment: .top, spacing: 8) {
                    Text("开头").font(.system(size: 12)).foregroundStyle(Theme.sub).frame(width: 52, alignment: .leading)
                    TextEditor(text: vb(p, \.intro)).font(.system(size: 13)).frame(height: 66)
                        .padding(4).background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                }
                Text("正文其余部分沿用主稿，去掉了公众号的引导语。").font(.system(size: 11)).foregroundStyle(Theme.faint).padding(.leading, 60)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Text("正文").font(.system(size: 12)).foregroundStyle(Theme.sub).frame(width: 52, alignment: .leading)
                    TextEditor(text: vb(p, \.body)).font(.system(size: 13)).frame(height: 220)
                        .padding(4).background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                }
                Text("\(v.body.filter { !$0.isWhitespace }.count) 字").font(.system(size: 11)).foregroundStyle(Theme.faint).padding(.leading, 60)
            }
            HStack(spacing: 8) {
                Text("标签").font(.system(size: 12)).foregroundStyle(Theme.sub).frame(width: 52, alignment: .leading)
                TextField("空格分开", text: tagsBinding(p)).fieldBox()
            }
            if !hits.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange).font(.system(size: 11))
                    Text("可能不合规：" + hits.map { "「\($0.word)」\($0.category)" }.joined(separator: "、"))
                        .font(.system(size: 11)).foregroundStyle(Theme.orange).lineLimit(2)
                }
                .padding(.leading, 60)
            }
            HStack(spacing: 10) {
                if p != .weibo { copyButton("复制标题", key: "t") { Publisher.copyText(v.title) } }
                copyButton("复制正文", key: "b") {
                    if p.isLongForm { Publisher.copyPlatform(a, v) } else { Publisher.copyText(Publisher.platformFull(a, v)) }
                }
                if p.isLongForm && !v.tags.isEmpty { copyButton("复制标签", key: "g") { Publisher.copyText(v.tags.joined(separator: " ")) } }
                if !a.cover.isEmpty { Button("封面图") { ImageStore.reveal(articleId) }.buttonStyle(GhostButton()) }
                Button("重写") { runVariants([p]) }.buttonStyle(LinkButton()).disabled(busy.label != nil)
                Spacer()
                PostedToggle(articleId: articleId, platform: p.rawValue) {
                    HStack(spacing: 4) {
                        Image(systemName: v.posted ? "checkmark.circle.fill" : "circle")
                        Text(postedText(p))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(v.posted ? Theme.green : Theme.ink)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Theme.sheet, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.rule))
                }
                if PlatformFill.draftable(p) {
                    draftButton(p)
                }
                if p.fillable {
                    let accs = store.accounts(on: p.rawValue)
                    if accs.count > 1 {
                        Menu {
                            ForEach(accs) { acc in
                                Button("填到「\(acc.name)」") { PlatformFill.open(store: store, articleId: articleId, platform: p.rawValue, account: acc) }
                            }
                        } label: {
                            HStack(spacing: 4) { Image(systemName: "square.and.pencil"); Text("打开\(p.name)并自动填入") }
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                        .buttonStyle(PrimaryButton())
                    } else {
                        Button {
                            PlatformFill.open(store: store, articleId: articleId, platform: p.rawValue, account: accs.first)
                        } label: {
                            HStack(spacing: 4) { Image(systemName: "square.and.pencil"); Text("打开\(p.name)并自动填入") }
                        }
                        .buttonStyle(PrimaryButton())
                        .help("在 app 里打开发文页，自动填标题和正文；发布按钮你自己点")
                    }
                } else {
                    Button {
                        Publisher.copyText(Publisher.platformFull(a, v))
                        NSWorkspace.shared.open(p.publishURL)
                        flash(platform + "w")
                    } label: {
                        HStack(spacing: 4) { Image(systemName: "arrow.up.forward.app"); Text(copiedKey == platform + "w" ? "已复制，去粘贴" : "复制并打开\(p.name)") }
                    }
                    .buttonStyle(PrimaryButton())
                }
            }
            .padding(.top, 2)
            if let n = draftNote[p.rawValue] {
                Text(n).font(.system(size: 11))
                    .foregroundStyle(n.hasPrefix("✓") ? Theme.green : Theme.orange)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    @ViewBuilder func draftButton(_ p: Platform) -> some View {
        let accs = store.accounts(on: p.rawValue)
        let label = HStack(spacing: 4) {
            if drafting == p.rawValue { ProgressView().controlSize(.small) } else { Image(systemName: "tray.and.arrow.down") }
            Text(drafting == p.rawValue ? "存草稿中…" : "存草稿")
        }
        if accs.count > 1 {
            Menu {
                ForEach(accs) { acc in Button("存到「\(acc.name)」草稿箱") { saveDraft(p, acc) } }
            } label: { label }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(drafting != nil)
        } else if let acc = accs.first {
            Button { saveDraft(p, acc) } label: { label }
                .buttonStyle(GhostButton())
                .disabled(drafting != nil)
                .help("后台填好后存到\(p.name)草稿箱，发布你去后台点")
        }
    }

    func saveDraft(_ p: Platform, _ acc: Account) {
        drafting = p.rawValue
        draftNote[p.rawValue] = nil
        Task {
            do {
                let m = try await PlatformFill.saveDraft(store: store, articleId: articleId, account: acc)
                draftNote[p.rawValue] = "✓ \(m)：去\(p.name)「\(acc.name)」的草稿箱点发布"
            } catch {
                draftNote[p.rawValue] = error.localizedDescription
            }
            drafting = nil
        }
    }

    func copyButton(_ title: String, key: String, primary: Bool = false, _ action: @escaping () -> Void) -> some View {
        let k = platform + key
        return Group {
            if primary {
                Button(copiedKey == k ? "已复制" : title) { action(); flash(k) }.buttonStyle(PrimaryButton())
            } else {
                Button(copiedKey == k ? "已复制" : title) { action(); flash(k) }.buttonStyle(GhostButton())
            }
        }
    }

    func flash(_ k: String) {
        copiedKey = k
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copiedKey == k { copiedKey = "" } }
    }

    // MARK: 状态

    var imageStatus: String {
        let n = a.sections.filter { !$0.image.isEmpty }.count
        if a.cover.isEmpty { return ImageGen.connection(store) == nil ? "没接智谱，只能生成文字封面" : "还没配图" }
        return n == 0 ? "有封面，正文没配图" : "封面 + 正文 \(n) 张"
    }

    func postedText(_ p: Platform) -> String {
        let accs = store.accounts(on: p.rawValue)
        guard accs.count > 1 else { return a.variants[p.rawValue]?.posted == true ? "已发" : "我发了" }
        let n = accs.filter { store.isPosted(a, $0) }.count
        return n == 0 ? "我发了" : "已发 \(n)/\(accs.count) 个号"
    }

    var wechatStatus: String {
        guard let acc = store.wechatAccount(for: a) else { return "先到「我的账号」给公众号填 AppID 和 AppSecret" }
        return a.wechatDraft.isEmpty ? "存进「\(acc.name)」草稿箱，发表要你在后台或手机上点" : "已在「\(acc.name)」草稿箱，去看一眼再发表"
    }

    // MARK: 动作

    func runImages() {
        busy.run("正在配图…") {
            try await Publisher.makeImages(store, articleId) { msg in busy.label = msg }
        }
    }

    func runVariants(_ only: [Platform]) {
        let names = (only.isEmpty ? Platform.others(store) : only).map(\.name).joined(separator: "、")
        if a.isShort, let p = Platform.of(a.primary) {
            let style = store.style(a.styleId)
            busy.run("正在重写\(p.name)…") { try await Publisher.makeShort(store, articleId, p, style: style) }
            return
        }
        busy.run("正在改写\(names)版本…") {
            try await Publisher.makeVariants(store, articleId, only: only)
        }
    }

    func push() {
        busy.run("正在推到草稿箱…") {
            try await Publisher.pushDraft(store, articleId) { msg in busy.label = msg }
        }
    }
}

// MARK: 发布设置（账号相关的都在「我的账号」）

struct PublishSettingsView: View {
    @EnvironmentObject var store: Store
    @State private var ip = ""

    func w<T>(_ kp: WritableKeyPath<WechatSettings, T>) -> Binding<T> {
        Binding(get: { store.data.wechat[keyPath: kp] }, set: { store.data.wechat[keyPath: kp] = $0; store.save() })
    }
    func au<T>(_ kp: WritableKeyPath<AutoSettings, T>) -> Binding<T> {
        Binding(get: { store.data.auto[keyPath: kp] }, set: { store.data.auto[keyPath: kp] = $0; store.save() })
    }

    var body: some View {
        Page(maxWidth: 840) {
            PageHeader(title: "发布", subtitle: "写完之后做什么。每个平台都只帮你准备好，发布按钮你自己点。")

            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(text: "写完之后").padding(.bottom, 6)
                SettingRow(label: "顺带出其他平台版本", hint: "写公众号长文时，给你其他账号的平台各出一版") {
                    Toggle("", isOn: au(\.variants)).toggleStyle(.switch).labelsHidden()
                }
                Divider()
                SettingRow(label: "自动存进公众号草稿箱", hint: "只存草稿，不发表") {
                    Toggle("", isOn: w(\.autoPush)).toggleStyle(.switch).labelsHidden()
                }
                Divider()
                SettingRow(label: "公众号文章开启留言") {
                    Toggle("", isOn: w(\.openComment)).toggleStyle(.switch).labelsHidden()
                }
                Divider()
                SettingRow(label: "本机 IP", hint: "公众号后台「开发接口管理」的 IP 白名单要加这个，换网络后要重新加") {
                    HStack(spacing: 8) {
                        Text(ip.isEmpty ? "获取中…" : ip).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.ink)
                        Button("复制") { Publisher.copyText(ip) }.buttonStyle(GhostButton()).disabled(ip.isEmpty)
                    }
                }
            }
            .card()

            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(text: "自动配图").padding(.bottom, 6)
                SettingRow(label: "写完自动配图", hint: ImageGen.connection(store) == nil
                           ? "画图用智谱 GLM-Image（0.1 元一张，没开通会自动换 CogView-4）。到「设置 → 模型」添加智谱并填 Key；没接时只生成文字封面。"
                           : "已接智谱，封面加正文配图") {
                    Toggle("", isOn: au(\.images)).toggleStyle(.switch).labelsHidden()
                }
                Divider()
                SettingRow(label: "正文配图频率") {
                    Picker("", selection: au(\.imageEvery)) {
                        Text("每个小标题一张").tag(1)
                        Text("隔一个小标题一张").tag(2)
                        Text("隔两个小标题一张").tag(3)
                        Text("只要封面").tag(99)
                    }
                    .labelsHidden().frame(width: 160)
                }
                Divider()
                SettingRow(label: "画风") {
                    Picker("", selection: au(\.imageStyle)) {
                        ForEach(["扁平插画", "温暖水彩", "写实摄影", "极简线条", "3D 卡通"], id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 160)
                }
            }
            .card()
        }
        .task { ip = await Wechat.publicIP() ?? "获取失败" }
    }
}
