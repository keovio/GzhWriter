import SwiftUI

// MARK: 口吻与范文

struct StylesView: View {
    @EnvironmentObject var store: Store
    @State private var selected: UUID?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading) {
                List(selection: $selected) {
                    ForEach(store.data.styles) { s in Text(s.name).tag(Optional(s.id)) }
                }
                HStack {
                    Button {
                        let s = StylePreset(name: "新账号")
                        store.data.styles.append(s); store.save(); selected = s.id
                    } label: { Image(systemName: "plus") }
                    Button {
                        guard let id = selected, store.data.styles.count > 1 else { return }
                        store.data.styles.removeAll { $0.id == id }; store.save(); selected = store.data.styles.first?.id
                    } label: { Image(systemName: "minus") }
                    .disabled(store.data.styles.count <= 1)
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 180, maxWidth: 240)

            if let i = store.data.styles.firstIndex(where: { $0.id == selected }) {
                let b = Binding(get: { store.data.styles[i] }, set: { store.data.styles[i] = $0; store.save() })
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("账号设定").font(.title2.bold())
                        Text("自动选题和写作都按这里来，填得越具体写得越像你。").font(.callout).foregroundStyle(.secondary)
                        TextField("账号名称", text: b.name).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                        Text("赛道").font(.headline)
                        TextField("比如：公考备考经验、职场成长、母婴好物", text: b.track).textFieldStyle(.roundedBorder)
                        Text("读者是谁").font(.headline)
                        TextField("比如：在职备考的 25–35 岁上班族", text: b.audience).textFieldStyle(.roundedBorder)
                        Text("范文").font(.headline)
                        Text("贴一两篇你自己写过、最满意的文章。AI 会模仿口吻和句式，不会照抄内容。")
                            .font(.callout).foregroundStyle(.secondary)
                        TextEditor(text: b.sample)
                            .font(.system(size: 13)).frame(minHeight: 280).padding(4)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                        Text("不写的话题").font(.headline)
                        TextField("用顿号或逗号分隔，比如：明星八卦、股票推荐", text: b.avoid)
                            .textFieldStyle(.roundedBorder)
                        Text("文末一句话").font(.headline)
                        TextField("比如：我是小 K，陪你上岸。", text: b.signature)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(20)
                }
            } else {
                Text("选一个账号编辑").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selected == nil { selected = store.data.styles.first?.id } }
    }
}

// MARK: 模型设置

struct ModelsView: View {
    @EnvironmentObject var store: Store
    @State private var selected: UUID?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading) {
                List(selection: $selected) {
                    Section("模型连接") {
                        ForEach(store.data.connections) { c in
                            VStack(alignment: .leading) {
                                Text(c.name)
                                Text(c.model.isEmpty ? "未选模型" : c.model).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(Optional(c.id))
                        }
                    }
                }
                HStack {
                    Menu {
                        ForEach(ProviderPreset.all) { p in
                            Button(p.name) { add(p) }
                        }
                    } label: { Label("添加", systemImage: "plus") }
                    .fixedSize()
                    Button {
                        guard let id = selected else { return }
                        Keychain.set("", for: id.uuidString)
                        store.data.connections.removeAll { $0.id == id }
                        for k in store.data.roles.keys { store.data.roles[k]?.removeAll { $0 == id } }
                        store.save(); selected = nil
                    } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless)
                    .disabled(selected == nil)
                }
                .padding(8)
            }
            .frame(minWidth: 200, maxWidth: 260)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let id = selected, store.data.connections.contains(where: { $0.id == id }) {
                        ConnectionEditor(connId: id).id(id)
                        Divider()
                    } else if store.data.connections.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("先添加一个模型").font(.title2.bold())
                            Text("点左下角「添加」，选 DeepSeek 或智谱 GLM，填上 API Key 就能用。所有兼容 OpenAI 接口的服务都能接，Key 只存在你 Mac 的钥匙串里。")
                                .foregroundStyle(.secondary)
                        }
                        Divider()
                    }
                    RolesEditor()
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 10) {
            Text("连接设置").font(.title2.bold())
            Form {
                TextField("名称", text: field(\.name))
                TextField("接口地址 Base URL", text: field(\.baseURL))
                SecureField("API Key", text: $key)
                    .onSubmit { Keychain.set(key, for: connId.uuidString) }
                HStack {
                    TextField("模型名", text: field(\.model))
                    if !models.isEmpty {
                        Menu("从列表选") {
                            ForEach(models, id: \.self) { m in Button(m) { setModel(m) } }
                        }
                        .fixedSize()
                    }
                }
            }
            .frame(maxWidth: 520)
            HStack {
                Button("保存 Key") { Keychain.set(key, for: connId.uuidString); testResult = "已保存到钥匙串" }
                Button("获取模型列表") { fetchModels() }.disabled(busy.label != nil)
                Button("测试一下") { test() }.disabled(busy.label != nil)
            }
            BusyBar(busy: busy)
            if let t = testResult { Text(t).foregroundStyle(.secondary).textSelection(.enabled) }
            Text("DeepSeek 常用模型 deepseek-chat；智谱 GLM 的模型名以开放平台当前列表为准，点「获取模型列表」最省事。")
                .font(.caption).foregroundStyle(.secondary)
        }
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
            testResult = models.isEmpty ? "这个服务没有返回模型列表，请手动填写模型名。" : "共 \(models.count) 个模型，可从列表选。"
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
        VStack(alignment: .leading, spacing: 12) {
            Text("分工").font(.title2.bold())
            Text("每个步骤可以选一个或多个模型，按顺序尝试，前一个失败自动换下一个。没选的步骤默认按连接列表顺序。")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(Role.allCases) { role in
                let ids = store.data.roles[role.rawValue] ?? []
                HStack(alignment: .center, spacing: 8) {
                    Text(role.title).frame(width: 90, alignment: .leading)
                    ForEach(Array(ids.enumerated()), id: \.element) { i, id in
                        if let c = store.data.connections.first(where: { $0.id == id }) {
                            HStack(spacing: 4) {
                                Text("\(i + 1). \(c.name)")
                                Button { move(role, i, -1) } label: { Image(systemName: "chevron.left") }
                                    .buttonStyle(.borderless).disabled(i == 0)
                                Button { remove(role, id) } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.borderless)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                        }
                    }
                    let rest = store.data.connections.filter { !ids.contains($0.id) }
                    if !rest.isEmpty {
                        Menu("添加") {
                            ForEach(rest) { c in Button(c.name) { addTo(role, c.id) } }
                        }
                        .fixedSize()
                    }
                }
            }
        }
    }

    func addTo(_ r: Role, _ id: UUID) {
        store.data.roles[r.rawValue, default: []].append(id); store.save()
    }
    func remove(_ r: Role, _ id: UUID) {
        store.data.roles[r.rawValue]?.removeAll { $0 == id }; store.save()
    }
    func move(_ r: Role, _ i: Int, _ d: Int) {
        guard var list = store.data.roles[r.rawValue], i + d >= 0, i + d < list.count else { return }
        list.swapAt(i, i + d)
        store.data.roles[r.rawValue] = list; store.save()
    }
}
