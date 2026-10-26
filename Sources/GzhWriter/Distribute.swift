import AppKit
import SwiftUI

/// 编辑器排版页下方：配图、推草稿箱、头条号/百家号版本
struct DistributeCard: View {
    @EnvironmentObject var store: Store
    let articleId: UUID
    @StateObject private var busy = Busy()
    @State private var platform = "toutiao"
    @State private var copiedKey = ""

    var a: Article { store.article(articleId) ?? Article() }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SectionTitle(text: "配图与分发", hint: "都只是准备好，发不发由你")
                Spacer()
            }
            BusyBar(busy: busy)

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

            // 其他平台
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    ForEach([("toutiao", "头条号"), ("baijiahao", "百家号")], id: \.0) { key, name in
                        Button(name) { platform = key }
                            .buttonStyle(RowButton())
                            .font(.system(size: 12, weight: platform == key ? .semibold : .regular))
                            .foregroundStyle(platform == key ? Theme.blue : Theme.sub)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(platform == key ? Theme.blueBg : Color.clear, in: Capsule())
                    }
                    Spacer()
                    Button(a.variants.isEmpty ? "生成平台版本" : "重新生成") { runVariants() }
                        .buttonStyle(LinkButton()).disabled(busy.label != nil)
                }
                if let v = a.variants[platform] {
                    variantView(v)
                } else {
                    Text("还没生成。一键成稿会自动出；手动写的点右上角生成。")
                        .font(.system(size: 12)).foregroundStyle(Theme.sub).padding(.vertical, 6)
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

    func variantView(_ v: PlatformVariant) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(v.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink).textSelection(.enabled)
                Spacer()
                copyButton("标题", key: "t") { Publisher.copyText(v.title) }
            }
            if !v.intro.isEmpty {
                Text(v.intro).font(.system(size: 12)).foregroundStyle(Theme.sub).lineLimit(3)
            }
            HStack(spacing: 6) {
                ForEach(v.tags, id: \.self) { Chip(text: "#\($0)") }
            }
            HStack(spacing: 10) {
                copyButton("复制正文", key: "b") { Publisher.copyPlatform(a, v) }
                if !v.tags.isEmpty { copyButton("复制标签", key: "g") { Publisher.copyText(v.tags.joined(separator: " ")) } }
                if !a.cover.isEmpty { Button("封面图") { ImageStore.reveal(articleId) }.buttonStyle(GhostButton()) }
                Spacer()
                Button {
                    PlatformFill.open(store: store, articleId: articleId, platform: platform)
                } label: {
                    HStack(spacing: 4) { Image(systemName: "square.and.pencil"); Text("打开\(platform == "toutiao" ? "头条号" : "百家号")并自动填入") }
                }
                .buttonStyle(PrimaryButton())
                .help("在 app 里打开发文页，自动填标题和正文；发布按钮你自己点")
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

    func runVariants() {
        busy.run("正在改写头条号、百家号版本…") {
            try await Publisher.makeVariants(store, articleId)
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
            PageHeader(title: "发布与分发", subtitle: "写完自动配图、推到公众号草稿箱、出头条号和百家号版本。不会替你点发表。")

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
                SectionTitle(text: "其他平台").padding(.bottom, 6)
                SettingRow(label: "自动出头条号、百家号版本", hint: "改标题、开头和标签，去掉公众号引导语。到稿件里一键复制，再到对应后台粘贴发布。") {
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
