import AppKit
import SwiftUI

/// 编辑器排版页下方：配图、推草稿箱、头条号/百家号版本
struct DistributeCard: View {
    @EnvironmentObject var store: Store
    let articleId: UUID
    var only: Platform? = nil          // 直接写的小红书/微博：只显示这一个平台
    @StateObject private var busy = Busy()
    @State private var platform = "toutiao"
    @State private var copiedKey = ""

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
                    .disabled(busy.label != nil || store.data.wechat.appId.isEmpty)
            }
            .padding(14)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
            }

            // 其他平台
            VStack(alignment: .leading, spacing: 10) {
                if only == nil {
                HStack(spacing: 6) {
                    ForEach(Platform.others(store)) { p in platformChip(p) }
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
                    Text("到「发布与分发」里勾选你在做的平台。").font(.system(size: 12)).foregroundStyle(Theme.sub)
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
        let list = Platform.others(store)
        if let p = Platform.of(platform), list.contains(p) { return p }
        return list.first
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
                Button {
                    store.update(articleId) {
                        let now = !($0.variants[p.rawValue]?.posted ?? false)
                        $0.variants[p.rawValue, default: PlatformVariant()].posted = now
                        $0.variants[p.rawValue, default: PlatformVariant()].postedAt = now ? Date() : nil
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: v.posted ? "checkmark.circle.fill" : "circle")
                        Text(v.posted ? "已发" : "我发了")
                    }
                }
                .buttonStyle(GhostButton())
                if p.fillable {
                    Button {
                        PlatformFill.open(store: store, articleId: articleId, platform: p.rawValue)
                    } label: {
                        HStack(spacing: 4) { Image(systemName: "square.and.pencil"); Text("打开\(p.name)并自动填入") }
                    }
                    .buttonStyle(PrimaryButton())
                    .help("在 app 里打开发文页，自动填标题和正文；发布按钮你自己点")
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

    var wechatStatus: String {
        if store.data.wechat.appId.isEmpty { return "先到「发布与分发」填 AppID 和 AppSecret" }
        return a.wechatDraft.isEmpty ? "推过去只是存草稿，发表要你在后台或手机上点" : "已在草稿箱，去看一眼再发表"
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

// MARK: 发布与分发设置

struct PublishSettingsView: View {
    @EnvironmentObject var store: Store
    @StateObject private var busy = Busy()
    @State private var secret = ""
    @State private var ip = ""
    @State private var testResult = ""

    func w<T>(_ kp: WritableKeyPath<WechatSettings, T>) -> Binding<T> {
        Binding(get: { store.data.wechat[keyPath: kp] }, set: { store.data.wechat[keyPath: kp] = $0; store.save() })
    }
    func au<T>(_ kp: WritableKeyPath<AutoSettings, T>) -> Binding<T> {
        Binding(get: { store.data.auto[keyPath: kp] }, set: { store.data.auto[keyPath: kp] = $0; store.save() })
    }

    var body: some View {
        Page(maxWidth: 840) {
            PageHeader(title: "发布与分发", subtitle: "选你在做的平台。写完自动配图、推公众号草稿箱、出各平台版本。不会替你点发布。")

            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(text: "公众号草稿箱").padding(.bottom, 6)
                SettingRow(label: "AppID", hint: "公众号后台「设置与开发 → 开发接口管理」") {
                    TextField("wx…", text: w(\.appId)).fieldBox().frame(width: 340)
                }
                Divider()
                SettingRow(label: "AppSecret", hint: "同一页生成，存在钥匙串") {
                    SecureField("", text: $secret).fieldBox().frame(width: 340)
                        .onSubmit { saveSecret() }
                }
                Divider()
                SettingRow(label: "IP 白名单", hint: "把本机公网 IP 加到同一页的白名单里，换网络后要重新加") {
                    HStack(spacing: 8) {
                        Text(ip.isEmpty ? "获取中…" : ip).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.ink)
                        Button("复制") { Publisher.copyText(ip) }.buttonStyle(GhostButton()).disabled(ip.isEmpty)
                    }
                }
                Divider()
                SettingRow(label: "写完自动推到草稿箱", hint: "一键成稿完成后自动推，只存草稿") {
                    Toggle("", isOn: w(\.autoPush)).toggleStyle(.switch).labelsHidden()
                }
                Divider()
                SettingRow(label: "开启留言") {
                    Toggle("", isOn: w(\.openComment)).toggleStyle(.switch).labelsHidden()
                }
                HStack(spacing: 10) {
                    Button("保存并测试") { saveSecret(); test() }.buttonStyle(PrimaryButton()).disabled(busy.label != nil)
                    if !testResult.isEmpty { Text(testResult).font(.system(size: 12)).foregroundStyle(Theme.green) }
                    Spacer()
                }
                .padding(.top, 12)
                BusyBar(busy: busy).padding(.top, 4)
            }
            .card()

            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(text: "自动配图").padding(.bottom, 6)
                SettingRow(label: "写完自动配图", hint: ImageGen.connection(store) == nil
                           ? "画图用智谱 GLM-Image（0.1 元一张，没开通会自动换 CogView-4）。到「模型与分工」添加智谱并填 Key；没接时只生成文字封面。"
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

            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(text: "我的平台", hint: "勾上的平台会自动出对应版本，雷达和日历也按这个显示").padding(.bottom, 6)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                    ForEach(Platform.allCases) { p in platformToggle(p) }
                }
                .padding(.bottom, 10)
                Divider()
                SettingRow(label: "写完自动出各平台版本", hint: "头条/百家/知乎改标题、开头和标签；小红书、微博整篇重写成短内容。都去掉公众号引导语。") {
                    Toggle("", isOn: au(\.variants)).toggleStyle(.switch).labelsHidden()
                }
            }
            .card()
        }
        .task {
            secret = Keychain.get(Wechat.secretKey) ?? ""
            ip = await Wechat.publicIP() ?? "获取失败"
        }
    }

    func platformToggle(_ p: Platform) -> some View {
        let on = store.data.auto.platforms.contains(p.rawValue)
        return Button {
            if on { store.data.auto.platforms.removeAll { $0 == p.rawValue } } else { store.data.auto.platforms.append(p.rawValue) }
            store.save()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                Text(p.name)
            }
            .font(.system(size: 12, weight: on ? .semibold : .regular))
            .frame(maxWidth: .infinity).padding(.vertical, 7)
            .foregroundStyle(on ? p.color : Theme.sub)
            .background(on ? p.color.opacity(0.1) : Theme.bg, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(RowButton())
    }

    func saveSecret() {
        Keychain.set(secret.trimmingCharacters(in: .whitespacesAndNewlines), for: Wechat.secretKey)
        Wechat.shared.reset()
    }

    func test() {
        let id = store.data.wechat.appId.trimmingCharacters(in: .whitespacesAndNewlines)
        testResult = ""
        busy.run("正在连接公众号…") {
            try await Wechat.shared.test(appId: id)
            testResult = "✓ 连上了，可以推草稿"
        }
    }
}
