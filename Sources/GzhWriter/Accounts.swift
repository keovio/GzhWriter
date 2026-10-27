import SwiftUI

/// 我的账号：每个号 = 平台 + 名字 + 用哪套风格。登录各管各的。
struct AccountsView: View {
    @EnvironmentObject var store: Store
    @StateObject private var busy = Busy()
    @State private var secrets: [UUID: String] = [:]
    @State private var tested: [UUID: String] = [:]
    @State private var removing: Account?
    @State private var loggedIn: [UUID: Bool] = [:]

    func refreshLogin() async {
        for acc in store.data.accounts where acc.platform != "wechat" {
            loggedIn[acc.id] = await PlatformFill.isLoggedIn(acc)
        }
    }

    /// 嵌进设置页右栏时为 true：不自己包 Page（避免嵌套滚动）
    var embedded = false

    var body: some View {
        Group {
            if embedded { inner } else { Page(maxWidth: 900) { inner } }
        }
        .onAppear {
            for a in store.data.accounts where a.platform == "wechat" {
                secrets[a.id] = Keychain.get(a.secretKey) ?? ""
            }
        }
        .confirmationDialog("删除这个账号？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("删除", role: .destructive) {
                if let r = removing { store.data.accounts.removeAll { $0.id == r.id }; store.save() }
                removing = nil
            }
        } message: {
            Text("只删账号设置，写过的稿件不受影响。")
        }
    }

    @ViewBuilder var inner: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "我的账号", subtitle: "每个平台可以有几个号，每个号只登录一次，之后会一直记住。", compact: embedded) {
                Menu {
                    ForEach(Platform.allCases) { p in
                        Button(p.name) { add(p) }
                    }
                } label: { Label("添加账号", systemImage: "plus") }
                .menuStyle(.borderlessButton).fixedSize()
                .buttonStyle(GhostButton())
            }
            .task { await refreshLogin() }
            .onReceive(NotificationCenter.default.publisher(for: .gzhLoginChanged)) { _ in
                Task { await refreshLogin() }
            }

            ForEach(Platform.allCases) { p in
                let accs = store.accounts(on: p.rawValue)
                if !accs.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 8) {
                            PlatformTag(key: p.rawValue)
                            Text(p.howTo).font(.system(size: 12)).foregroundStyle(Theme.sub)
                            Spacer()
                        }
                        .padding(.bottom, 8)
                        ForEach(accs) { acc in
                            Divider()
                            row(acc)
                        }
                    }
                    .card()
                }
            }
            BusyBar(busy: busy)
        }
    }

    func bind<T>(_ id: UUID, _ kp: WritableKeyPath<Account, T>) -> Binding<T> {
        Binding(get: { store.account(id)?[keyPath: kp] ?? Account()[keyPath: kp] },
                set: { v in
                    if let i = store.data.accounts.firstIndex(where: { $0.id == id }) {
                        store.data.accounts[i][keyPath: kp] = v; store.save()
                    }
                })
    }

    func row(_ acc: Account) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text(String(acc.name.prefix(1)).isEmpty ? "?" : String(acc.name.prefix(1)))
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Platform.of(acc.platform)?.color ?? Theme.navy, in: Circle())
                TextField("平台上的昵称", text: bind(acc.id, \.name)).fieldBox().frame(width: 200)
                HStack(spacing: 6) {
                    Text("风格").font(.system(size: 12)).foregroundStyle(Theme.sub).fixedSize()
                    Picker("", selection: bind(acc.id, \.styleId)) {
                        ForEach(store.data.styles) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden().frame(width: 150)
                }
                Spacer()
                if acc.platform != "wechat" {
                    if loggedIn[acc.id] == true {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("已登录")
                        }
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.green)
                        Button("重新登录") { PlatformFill.login(acc) }.buttonStyle(LinkButton(color: Theme.sub))
                    } else {
                        Button("登录") { PlatformFill.login(acc) }.buttonStyle(PrimaryButton())
                    }
                }
                if store.data.accounts.count > 1 {
                    Button { removing = acc } label: { Image(systemName: "trash") }
                        .buttonStyle(LinkButton(color: Theme.sub))
                }
            }
            if acc.platform == "wechat" {
                HStack(spacing: 8) {
                    Text("草稿箱").font(.system(size: 12)).foregroundStyle(Theme.sub).fixedSize().frame(width: 40, alignment: .leading)
                    TextField("AppID  wx…", text: bind(acc.id, \.appId)).fieldBox().frame(width: 200)
                    SecureField("AppSecret", text: Binding(get: { secrets[acc.id] ?? "" }, set: { secrets[acc.id] = $0 }))
                        .fieldBox().frame(width: 220)
                    Button("保存并测试") { test(acc) }.buttonStyle(GhostButton()).disabled(busy.label != nil)
                    if let t = tested[acc.id] {
                        Text(t).font(.system(size: 12)).foregroundStyle(t.hasPrefix("✓") ? Theme.green : Theme.orange).lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.leading, 40)
            }
        }
        .padding(.vertical, 10)
    }

    func add(_ p: Platform) {
        let style = store.data.styles.first
        let same = store.accounts(on: p.rawValue).count
        let acc = Account(platform: p.rawValue, name: Account.defaultName(p.rawValue, index: same + 1), styleId: style?.id)
        store.data.accounts.append(acc)
        store.save()
    }

    func test(_ acc: Account) {
        let s = (secrets[acc.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.set(s, for: acc.secretKey)
        Wechat.shared.reset()
        let id = (store.account(acc.id)?.appId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        tested[acc.id] = nil
        busy.run("正在连接「\(acc.name)」…") {
            do {
                try await Wechat.shared.test(appId: id)
                tested[acc.id] = "✓ 连上了"
            } catch {
                tested[acc.id] = "没连上"
                throw error
            }
        }
    }
}
