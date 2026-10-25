import SwiftUI

// MARK: 账号设定

struct StylesView: View {
    @EnvironmentObject var store: Store
    @State private var selected: UUID?

    var body: some View {
        Page(maxWidth: 900) {
            PageHeader(title: "账号设定", subtitle: "每个公众号一套设定。自动选题和写作都照这里来，填得越具体越像你。") {
                Button {
                    let s = StylePreset(name: "新账号")
                    store.data.styles.append(s); store.save(); selected = s.id
                } label: { Label("添加账号", systemImage: "plus") }
                .buttonStyle(GhostButton())
            }

            HStack(spacing: 8) {
                ForEach(store.data.styles) { s in
                    Button { selected = s.id } label: {
                        HStack(spacing: 6) {
                            Text(String(s.name.prefix(1))).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 20, height: 20).background(Theme.navy, in: Circle())
                            Text(s.name).font(.system(size: 13, weight: selected == s.id ? .semibold : .regular))
                        }
                        .foregroundStyle(selected == s.id ? Theme.blue : Theme.ink)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(selected == s.id ? Theme.blueBg : Theme.sheet, in: Capsule())
                        .overlay(Capsule().stroke(selected == s.id ? Theme.blue.opacity(0.3) : Theme.rule))
                    }
                    .buttonStyle(RowButton())
                }
            }

            if let i = store.data.styles.firstIndex(where: { $0.id == selected }) {
                let b = Binding(get: { store.data.styles[i] }, set: { store.data.styles[i] = $0; store.save() })
                VStack(alignment: .leading, spacing: 0) {
                    SectionTitle(text: "基本信息").padding(.bottom, 6)
                    SettingRow(label: "账号名称") { TextField("", text: b.name).fieldBox().frame(width: 360) }
                    Divider()
                    SettingRow(label: "赛道", hint: "写什么领域") {
                        TextField("比如：公考备考经验", text: b.track).fieldBox().frame(width: 360)
                    }
                    Divider()
                    SettingRow(label: "读者是谁", hint: "写给谁看") {
                        TextField("比如：在职备考的 25–35 岁上班族", text: b.audience).fieldBox().frame(width: 360)
                    }
                    Divider()
                    SettingRow(label: "不写的话题", hint: "选题和正文都会避开") {
                        TextField("比如：明星八卦、股票推荐", text: b.avoid).fieldBox().frame(width: 360)
                    }
                    Divider()
                    SettingRow(label: "作者名", hint: "推到草稿箱时填在作者栏") {
                        TextField("比如：小 K", text: b.author).fieldBox().frame(width: 360)
                    }
                    Divider()
                    SettingRow(label: "文末一句话", hint: "排版时放在文章末尾") {
                        TextField("比如：我是小 K，陪你上岸。", text: b.signature).fieldBox().frame(width: 360)
                    }
                }
                .card()

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(text: "范文", hint: "贴一两篇你最满意的文章，AI 学口吻和句式，不抄内容")
                    TextEditor(text: b.sample)
                        .font(.system(size: 13))
                        .lineSpacing(4)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 260)
                        .padding(10)
                        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
                    HStack {
                        Text("\(store.data.styles[i].sample.count) 字").font(.system(size: 11)).foregroundStyle(Theme.faint)
                        Spacer()
                        if store.data.styles.count > 1 {
                            Button("删除这个账号") {
                                let id = store.data.styles[i].id
                                store.data.styles.removeAll { $0.id == id }; store.save()
                                selected = store.data.styles.first?.id
                            }
                            .buttonStyle(LinkButton(color: Theme.red))
                        }
                    }
                }
                .card()
            }
        }
        .onAppear { if selected == nil { selected = store.data.styles.first?.id } }
    }
}

// MARK: 模型与分工

struct ModelsView: View {
    @EnvironmentObject var store: Store
    @State private var selected: UUID?

    var body: some View {
        Page(maxWidth: 960) {
            PageHeader(title: "模型与分工", subtitle: "每个连接是一个服务商加一个 Key，Key 只存在本机钥匙串。再到下面安排谁选题、谁写、谁审。") {
                Menu {
                    ForEach(ProviderPreset.all) { p in Button(p.name) { add(p) } }
                } label: { Label("添加连接", systemImage: "plus") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Theme.navy, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.white)
            }

            if store.data.connections.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "cpu").font(.system(size: 30)).foregroundStyle(Theme.faint)
                    Text("还没有模型连接").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text("点右上角「添加连接」，选 DeepSeek 或智谱 GLM，填上 API Key 就能用。兼容 OpenAI 接口的服务都能接。")
                        .font(.system(size: 12)).foregroundStyle(Theme.sub).multilineTextAlignment(.center)
                    HStack {
                        Button("添加 DeepSeek") { add(ProviderPreset.all[0]) }.buttonStyle(PrimaryButton())
                        Button("添加智谱 GLM") { add(ProviderPreset.all[1]) }.buttonStyle(GhostButton())
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 30)
                .card()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                    ForEach(store.data.connections) { c in
                        Button { selected = c.id } label: {
                            HStack(spacing: 10) {
                                Text(String(c.name.prefix(1))).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                    .frame(width: 30, height: 30).background(Theme.navy, in: RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                                    Text(c.model.isEmpty ? "未选模型" : c.model).font(.system(size: 11)).foregroundStyle(Theme.sub).lineLimit(1)
                                }
                                Spacer()
                                Circle().fill(Keychain.get(c.id.uuidString)?.isEmpty == false ? Theme.green : Theme.orange)
                                    .frame(width: 7, height: 7)
                            }
                            .padding(12)
                            .background(Theme.sheet, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected == c.id ? Theme.blue : Theme.rule, lineWidth: selected == c.id ? 1.5 : 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(RowButton())
                    }
                }
                if let id = selected, store.data.connections.contains(where: { $0.id == id }) {
                    ConnectionEditor(connId: id, onDelete: { selected = store.data.connections.first?.id }).id(id)
                }
                RolesEditor()
            }
        }
        .onAppear { if selected == nil { selected = store.data.connections.first?.id } }
    }

    func add(_ p: ProviderPreset) {
        let c = ModelConnection(name: p.name, baseURL: p.baseURL, model: p.model)
        store.data.connections.append(c)
        store.save()
        selected = c.id
    }
}

struct ConnectionEditor: View {
    @EnvironmentObject var store: Store
    let connId: UUID
    var onDelete: () -> Void = {}
    @StateObject private var busy = Busy()
    @State private var key = ""
    @State private var models: [String] = []
    @State private var testResult: String?

    var idx: Int? { store.data.connections.firstIndex { $0.id == connId } }

    func field(_ kp: WritableKeyPath<ModelConnection, String>) -> Binding<String> {
        Binding(get: { idx.map { store.data.connections[$0][keyPath: kp] } ?? "" },
                set: { v in if let i = idx { store.data.connections[i][keyPath: kp] = v; store.save() } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionTitle(text: "连接设置")
                Spacer()
                Button("删除连接") {
                    Keychain.set("", for: connId.uuidString)
                    store.data.connections.removeAll { $0.id == connId }
                    for k in store.data.roles.keys { store.data.roles[k]?.removeAll { $0 == connId } }
                    store.save(); onDelete()
                }
                .buttonStyle(LinkButton(color: Theme.red))
            }
            .padding(.bottom, 6)
            SettingRow(label: "名称") { TextField("", text: field(\.name)).fieldBox().frame(width: 380) }
            Divider()
            SettingRow(label: "接口地址", hint: "Base URL") { TextField("", text: field(\.baseURL)).fieldBox().frame(width: 380) }
            Divider()
            SettingRow(label: "API Key", hint: "保存在钥匙串") {
                SecureField("sk-…", text: $key)
                    .fieldBox().frame(width: 380)
                    .onSubmit { Keychain.set(key, for: connId.uuidString) }
            }
            Divider()
            SettingRow(label: "模型", hint: "点「获取列表」后可以直接选") {
                HStack(spacing: 8) {
                    TextField("模型名", text: field(\.model)).fieldBox()
                    if !models.isEmpty {
                        Menu("选") {
                            ForEach(models, id: \.self) { m in Button(m) { setModel(m) } }
                        }
                        .fixedSize()
                    }
                }
                .frame(width: 380)
            }
            HStack(spacing: 10) {
                Button("保存 Key") { Keychain.set(key, for: connId.uuidString); testResult = "已保存到钥匙串" }
                    .buttonStyle(PrimaryButton())
                Button("获取列表") { fetchModels() }.buttonStyle(GhostButton()).disabled(busy.label != nil)
                Button("测试一下") { test() }.buttonStyle(GhostButton()).disabled(busy.label != nil)
                Spacer()
            }
            .padding(.top, 12)
            BusyBar(busy: busy).padding(.top, 6)
            if let t = testResult {
                Text(t).font(.system(size: 12)).foregroundStyle(Theme.sub).textSelection(.enabled).padding(.top, 6)
            }
        }
        .card()
        .onAppear { key = Keychain.get(connId.uuidString) ?? "" }
    }

    func setModel(_ m: String) {
        if let i = idx { store.data.connections[i].model = m; store.save() }
    }

    func fetchModels() {
        Keychain.set(key, for: connId.uuidString)
        let base = field(\.baseURL).wrappedValue
        let k = key
        busy.run("正在获取模型列表…") {
            models = try await LLM.listModels(baseURL: base, key: k)
            testResult = models.isEmpty ? "这个服务没有返回模型列表，请手动填写模型名。" : "共 \(models.count) 个模型，点「选」挑一个。"
        }
    }

    func test() {
        Keychain.set(key, for: connId.uuidString)
        guard let i = idx else { return }
        let c = store.data.connections[i]
        busy.run("正在测试…") {
            let r = try await LLM.chat(c, messages: [.user("用一句话介绍你自己。")], temperature: 0.3)
            testResult = "✅ 连接成功：\(r.prefix(80))"
        }
    }
}

struct RolesEditor: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: "角色分工", hint: "按顺序用，第一个出错（限流、余额不足、宕机）自动换下一个")
                .padding(.bottom, 6)
            ForEach(Array(Role.allCases.enumerated()), id: \.element) { n, role in
                if n > 0 { Divider() }
                let ids = store.data.roles[role.rawValue] ?? []
                SettingRow(label: role.title, hint: ids.isEmpty ? "没选就按连接顺序" : "") {
                    HStack(spacing: 6) {
                        ForEach(Array(ids.enumerated()), id: \.element) { i, id in
                            if let c = store.data.connections.first(where: { $0.id == id }) {
                                HStack(spacing: 4) {
                                    Text("\(i + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.blue)
                                    Text(c.name).font(.system(size: 12))
                                    if i > 0 {
                                        Button { move(role, i, -1) } label: { Image(systemName: "arrow.left").font(.system(size: 9)) }
                                            .buttonStyle(RowButton())
                                    }
                                    Button { remove(role, id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                                        .buttonStyle(RowButton())
                                }
                                .foregroundStyle(Theme.ink)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Theme.blueBg, in: Capsule())
                            }
                        }
                        let rest = store.data.connections.filter { !ids.contains($0.id) }
                        if !rest.isEmpty {
                            Menu {
                                ForEach(rest) { c in Button(c.name) { addTo(role, c.id) } }
                            } label: { Image(systemName: "plus") }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }
                }
            }
        }
        .card()
    }

    func addTo(_ r: Role, _ id: UUID) { store.data.roles[r.rawValue, default: []].append(id); store.save() }
    func remove(_ r: Role, _ id: UUID) { store.data.roles[r.rawValue]?.removeAll { $0 == id }; store.save() }
    func move(_ r: Role, _ i: Int, _ d: Int) {
        guard var list = store.data.roles[r.rawValue], i + d >= 0, i + d < list.count else { return }
        list.swapAt(i, i + d)
        store.data.roles[r.rawValue] = list; store.save()
    }
}
