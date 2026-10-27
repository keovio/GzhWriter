import SwiftUI

// MARK: 模型与分工

struct ModelsView: View {
    @EnvironmentObject var store: Store
    @State private var selected: UUID?

    /// 嵌进设置页右栏时为 true：不自己包 Page（避免嵌套滚动）
    var embedded = false

    var body: some View {
        Group {
            if embedded { inner } else { Page(maxWidth: 960) { inner } }
        }
        .onAppear { if selected == nil { selected = store.data.connections.first?.id } }
    }

    @ViewBuilder var inner: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "模型与分工", subtitle: "每个连接是一个服务商加一个 Key，Key 只存在本机钥匙串。再到下面安排谁选题、谁写、谁审。", compact: embedded) {
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
            SettingRow(label: "名称") { TextField("", text: field(\.name)).fieldBox().frame(minWidth: 200, maxWidth: 380) }
            Divider()
            SettingRow(label: "接口地址", hint: "Base URL") { TextField("", text: field(\.baseURL)).fieldBox().frame(minWidth: 200, maxWidth: 380) }
            Divider()
            SettingRow(label: "API Key", hint: "保存在钥匙串") {
                SecureField("sk-…", text: $key)
                    .fieldBox().frame(minWidth: 200, maxWidth: 380)
                    .onSubmit { Keychain.set(key, for: connId.uuidString) }
                    .onChange(of: key) { v in
                        // 粘贴后不按回车直接离开也要存上
                        if v != (Keychain.get(connId.uuidString) ?? "") { Keychain.set(v, for: connId.uuidString) }
                    }
            }
            Divider()
            SettingRow(label: "默认模型", hint: "每一步用哪个，在下面「角色分工」里换") {
                HStack(spacing: 8) {
                    TextField("模型名", text: field(\.model)).fieldBox()
                    if !models.isEmpty {
                        Menu("选") {
                            ForEach(models, id: \.self) { m in Button(m) { setModel(m) } }
                        }
                        .fixedSize()
                    }
                }
                .frame(minWidth: 200, maxWidth: 380)
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
    @State private var lists: [UUID: [String]] = [:]

    var single: Bool { store.data.connections.count == 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: "角色分工", hint: single ? "同一个平台，每一步可以用不同的模型" : "每一步选平台和模型；排第一的出错（限流、余额不足）自动换下一个")
                .padding(.bottom, 6)
            ForEach(Array(Role.allCases.enumerated()), id: \.element) { n, role in
                if n > 0 { Divider() }
                let ids = picked(role)
                SettingRow(label: role.title, hint: "用于：" + role.uses) {
                    HStack(spacing: 6) {
                        ForEach(Array(ids.enumerated()), id: \.element) { i, id in
                            if let c = store.data.connections.first(where: { $0.id == id }) {
                                chip(role, c, i, ids.count)
                            }
                        }
                        let rest = store.data.connections.filter { !ids.contains($0.id) }
                        if !rest.isEmpty {
                            Menu {
                                ForEach(rest) { c in Button("备用：\(c.name)") { addTo(role, c.id) } }
                            } label: { Image(systemName: "plus") }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }
                }
            }
        }
        .card()
        .task {
            for c in store.data.connections where lists[c.id] == nil {
                let key = Keychain.get(c.id.uuidString) ?? ""
                if let l = try? await LLM.listModels(baseURL: c.baseURL, key: key) { lists[c.id] = l }
            }
        }
    }

    func chip(_ role: Role, _ c: ModelConnection, _ i: Int, _ count: Int) -> some View {
        let k = "\(role.rawValue).\(c.id.uuidString)"
        let current = store.data.roleModels[k].flatMap { $0.isEmpty ? nil : $0 } ?? c.model
        var options = lists[c.id] ?? []
        if !options.contains(c.model) { options.insert(c.model, at: 0) }
        if !options.contains(current) { options.insert(current, at: 0) }
        return HStack(spacing: 6) {
            if count > 1 { Text("\(i + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.blue) }
            Text(c.name).font(.system(size: 12)).foregroundStyle(Theme.sub)
            Menu {
                ForEach(options, id: \.self) { m in
                    Button(m == current ? "✓ \(m)" : m) { store.data.roleModels[k] = m; store.save() }
                }
            } label: {
                Text(current).font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.borderlessButton).fixedSize()
            if count > 1 {
                if i > 0 {
                    Button { move(role, i, -1) } label: { Image(systemName: "arrow.left").font(.system(size: 9)) }
                        .buttonStyle(RowButton())
                }
                Button { remove(role, c.id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                    .buttonStyle(RowButton())
            }
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Theme.blueBg, in: Capsule())
    }

    /// 没手动排过的角色，按连接顺序全部用上
    func picked(_ r: Role) -> [UUID] {
        let ids = (store.data.roles[r.rawValue] ?? []).filter { id in store.data.connections.contains { $0.id == id } }
        return ids.isEmpty ? store.data.connections.map(\.id) : ids
    }
    func addTo(_ r: Role, _ id: UUID) { store.data.roles[r.rawValue] = picked(r) + [id]; store.save() }
    func remove(_ r: Role, _ id: UUID) { store.data.roles[r.rawValue] = picked(r).filter { $0 != id }; store.save() }
    func move(_ r: Role, _ i: Int, _ d: Int) {
        var list = picked(r)
        guard i + d >= 0, i + d < list.count else { return }
        list.swapAt(i, i + d)
        store.data.roles[r.rawValue] = list; store.save()
    }
}

// MARK: 设置页外壳（左 200 四类 + 高级折叠 / 右内容区，§4）

enum SettingsCategory: String, CaseIterable, Identifiable {
    case account = "公众号"
    case style = "文风"
    case model = "模型"
    case publish = "发布"
    case advanced = "高级"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .account: return "at"
        case .style: return "text.quote"
        case .model: return "cpu"
        case .publish: return "paperplane"
        case .advanced: return "slider.horizontal.3"
        }
    }
}

struct SettingsShell: View {
    @EnvironmentObject var store: Store
    @State private var category: SettingsCategory = SettingsShell.startCategory
    @State private var advancedOpen = SettingsShell.startCategory == .advanced

    /// GZH_PANE 环境变量直接打开对应的设置页（截图用）
    static var startCategory: SettingsCategory {
        switch ProcessInfo.processInfo.environment["GZH_PANE"] ?? "" {
        case "models": return .model
        case "styles": return .style
        case "publish": return .publish
        case "auto", "materials": return .advanced
        default: return .account
        }
    }

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 20) {
                column.frame(width: 160, alignment: .leading)
                content.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            // 以前限宽 800，右边内容装不下就整体往右溢出、被窗口切掉
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
    }

    // 左列：四类常显 + 高级（默认折叠，§4.1）
    var column: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsCategory.allCases) { c in
                if c == .advanced {
                    Button { advancedOpen.toggle(); if advancedOpen { category = .advanced } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .rotationEffect(.degrees(advancedOpen ? 90 : 0))
                                .foregroundStyle(Theme.faint)
                            Text(c.rawValue)
                                .font(.system(size: 13, weight: category == .advanced ? .medium : .regular))
                                .foregroundStyle(category == .advanced ? Theme.blue : Theme.sub)
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(category == .advanced ? Theme.blueBg : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .leading) {
                            if category == .advanced {
                                RoundedRectangle(cornerRadius: 2).fill(Theme.blue).frame(width: 3).padding(.vertical, 4)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RowButton())
                    .padding(.top, 6)
                    .onChange(of: advancedOpen) { open in
                        // 收起时若正停在高级，回到公众号
                        if !open && category == .advanced { category = .account }
                    }
                } else {
                    item(c)
                }
            }
        }
    }

    func item(_ c: SettingsCategory) -> some View {
        Button { category = c } label: {
            HStack(spacing: 6) {
                Text(c.rawValue)
                    .font(.system(size: 13, weight: category == c ? .medium : .regular))
                    .foregroundStyle(category == c ? Theme.blue : Theme.sub)
                Spacer()
                if c == .model && store.data.connections.isEmpty {
                    Circle().fill(Theme.orange).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(category == c ? Theme.blueBg : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .leading) {
                if category == c {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.blue).frame(width: 3).padding(.vertical, 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButton())
    }

    // 右栏内容
    @ViewBuilder var content: some View {
        switch category {
        case .account: AccountsView(embedded: true)
        case .style: StylesView(embedded: true)
        case .model: modelPane
        case .publish: publishPane
        case .advanced: AdvancedPane()
        }
    }

    var modelPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            if store.data.connections.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.orange)
                    Text("还没接模型，现在只能看不能写").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Theme.orangeBg, in: RoundedRectangle(cornerRadius: 8))
            }
            ModelsView(embedded: true)
        }
    }

    var publishPane: some View {
        PublishPane()
    }
}

/// 发布：三个开关，就这三个（§4.2）
struct PublishPane: View {
    @EnvironmentObject var store: Store

    func w<T>(_ kp: WritableKeyPath<WechatSettings, T>) -> Binding<T> {
        Binding(get: { store.data.wechat[keyPath: kp] }, set: { store.data.wechat[keyPath: kp] = $0; store.save() })
    }
    func au<T>(_ kp: WritableKeyPath<AutoSettings, T>) -> Binding<T> {
        Binding(get: { store.data.auto[keyPath: kp] }, set: { store.data.auto[keyPath: kp] = $0; store.save() })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "发布", subtitle: "写完之后做什么。发布按钮永远由你自己点。", compact: true)
                .padding(.bottom, 12)
            SettingRow(label: "出多平台版本", hint: "写公众号长文时，顺带给其他平台各出一版") {
                Toggle("", isOn: au(\.variants)).toggleStyle(.switch).labelsHidden()
            }
            Divider()
            SettingRow(label: "写完自动推公众号草稿箱", hint: "推草稿箱只是存进草稿箱，不会发表。发表永远要你自己点。") {
                Toggle("", isOn: w(\.autoPush)).toggleStyle(.switch).labelsHidden()
            }
            Divider()
            SettingRow(label: "自动配图", hint: "按小标题配图，画风和间隔在高级里调") {
                Toggle("", isOn: au(\.images)).toggleStyle(.switch).labelsHidden()
            }
        }
        .card()
    }
}

/// 高级（折叠）：生成偏好 + 角色分工（§4.3）
struct AdvancedPane: View {
    @EnvironmentObject var store: Store

    func b<T>(_ kp: WritableKeyPath<AutoSettings, T>) -> Binding<T> {
        Binding(get: { store.data.auto[keyPath: kp] }, set: { store.data.auto[keyPath: kp] = $0; store.save() })
    }
    func w<T>(_ kp: WritableKeyPath<WechatSettings, T>) -> Binding<T> {
        Binding(get: { store.data.wechat[keyPath: kp] }, set: { store.data.wechat[keyPath: kp] = $0; store.save() })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "高级", subtitle: "平时不用动，改坏了会影响生成效果。", compact: true)
                    .padding(.bottom, 12)
                SettingRow(label: "自动选标题", hint: "出 5 个标题打分，换上分数最高的；稿件里可以再换") {
                    Toggle("", isOn: b(\.autoTitle)).toggleStyle(.switch).labelsHidden()
                }
                Divider()
                SettingRow(label: "自动改敏感词", hint: "审完稿扫一遍极限词、收益承诺、诱导分享、站外引流，有就让 AI 改掉") {
                    Toggle("", isOn: b(\.autoCompliance)).toggleStyle(.switch).labelsHidden()
                }
                Divider()
                SettingRow(label: "生成时参考热榜", hint: "自动选题时参考头条、百度热榜，只选和赛道相关的") {
                    Toggle("", isOn: b(\.useHot)).toggleStyle(.switch).labelsHidden()
                }
                Divider()
                SettingRow(label: "热榜自动刷新", hint: "app 开着时每 10 分钟刷一次，超 6 小时提示过期") {
                    Toggle("", isOn: b(\.hotAuto)).toggleStyle(.switch).labelsHidden()
                }
                Divider()
                SettingRow(label: "写稿自动用素材", hint: "素材一期没有编辑界面，此开关控制生成时是否自动带已有素材") {
                    Toggle("", isOn: b(\.useMaterials)).toggleStyle(.switch).labelsHidden()
                }
                Divider()
                SettingRow(label: "公众号文章开启留言", hint: "推草稿箱时带的参数，日常不用改") {
                    Toggle("", isOn: w(\.openComment)).toggleStyle(.switch).labelsHidden()
                }
            }
            .card()

            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(text: "生成偏好").padding(.bottom, 6)
                SettingRow(label: "及格线", hint: "五个维度合计，低于这个分数自动返修") {
                    Stepper("\(store.data.auto.passScore) 分", value: b(\.passScore), in: 50...95, step: 5).fixedSize()
                }
                Divider()
                SettingRow(label: "目标字数", hint: "整篇大约多少字") {
                    Stepper("\(store.data.auto.targetWords) 字", value: b(\.targetWords), in: 600...4000, step: 100).fixedSize()
                }
                Divider()
                SettingRow(label: "最多返修", hint: "一直不及格就用分数最高的那版") {
                    Stepper("\(store.data.auto.maxRounds) 轮", value: b(\.maxRounds), in: 0...4).fixedSize()
                }
                Divider()
                SettingRow(label: "图文间隔", hint: "每隔几个小标题配一张图") {
                    Picker("", selection: b(\.imageEvery)) {
                        Text("每个小标题一张").tag(1)
                        Text("隔一个小标题一张").tag(2)
                        Text("隔两个小标题一张").tag(3)
                        Text("只要封面").tag(99)
                    }
                    .labelsHidden().frame(width: 160)
                }
                Divider()
                SettingRow(label: "图片风格") {
                    Picker("", selection: b(\.imageStyle)) {
                        ForEach(["扁平插画", "温暖水彩", "写实摄影", "极简线条", "3D 卡通"], id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 160)
                }
            }
            .card()

            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "热榜领域", hint: "每 10 分钟刷一次，超 6 小时提示过期").padding(.bottom, 2)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                    ForEach(HotCategory.all, id: \.0) { item in chip(item.0) }
                }
                HStack {
                    Button("全选") { store.data.auto.hotCategories = HotCategory.all.map(\.0); store.save() }
                        .buttonStyle(LinkButton())
                    Button("只留综合") { store.data.auto.hotCategories = ["综合"]; store.save() }
                        .buttonStyle(LinkButton(color: Theme.sub))
                    Text("领域越多刷新越慢").font(.system(size: 11)).foregroundStyle(Theme.faint)
                    Spacer()
                }
            }
            .card()

            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "角色分工", hint: "谁选题、谁写、谁审").padding(.bottom, 2)
                RolesEditor()
            }
            .card()
        }
    }

    func chip(_ name: String) -> some View {
        let on = store.data.auto.hotCategories.contains(name)
        return Button {
            if on { store.data.auto.hotCategories.removeAll { $0 == name } }
            else { store.data.auto.hotCategories.append(name) }
            store.save()
        } label: {
            Text(name).font(.system(size: 12, weight: on ? .semibold : .regular))
                .frame(maxWidth: .infinity).padding(.vertical, 5)
                .foregroundStyle(on ? Color.white : Theme.sub)
                .background(on ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.bg), in: Capsule())
        }
        .buttonStyle(RowButton())
    }
}
