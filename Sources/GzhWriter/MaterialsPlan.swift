import AppKit
import SwiftUI

// MARK: - 素材匹配

enum MaterialPicker {
    /// 按选题挑最相关的几条素材
    @MainActor
    static func pick(_ store: Store, for text: String, limit: Int = 4) -> [Material] {
        var scored: [(Material, Double)] = []
        for m in store.data.materials {
            var score = 0.0
            for tag in m.tags where !tag.isEmpty && text.contains(tag) { score = max(score, 1.0) }
            let head = String(m.text.prefix(80))
            let sim = Dedupe.similarity(text, head)
            score = max(score, sim)
            if score >= 0.35 { scored.append((m, score)) }
        }
        scored.sort { $0.1 > $1.1 }
        var out: [Material] = []
        for item in scored.prefix(limit) { out.append(item.0) }
        return out
    }

    @MainActor
    static func materials(_ store: Store, _ ids: [UUID]) -> [Material] {
        var out: [Material] = []
        for id in ids {
            if let m = store.data.materials.first(where: { $0.id == id }) { out.append(m) }
        }
        return out
    }

    /// 给稿件挑素材并记下用了几次
    @MainActor
    static func attach(_ store: Store, _ id: UUID) -> [Material] {
        guard let a = store.article(id) else { return [] }
        let mats = pick(store, for: a.topic + " " + a.viewpoint)
        let ids = mats.map(\.id)
        store.update(id) { $0.materialIds = ids }
        for mid in ids {
            if let k = store.data.materials.firstIndex(where: { $0.id == mid }) { store.data.materials[k].uses += 1 }
        }
        store.save()
        return mats
    }
}

// MARK: - 发布排期

enum PublishPlan {
    @MainActor
    static func nextSlot(_ store: Store, after: Date = Date()) -> Date? {
        let s = store.data.auto
        let cal = Calendar.current
        let start = cal.startOfDay(for: after)
        for offset in 0..<90 {
            guard let day = cal.date(byAdding: .day, value: offset, to: start) else { continue }
            let wd = cal.component(.weekday, from: day)
            if !s.publishDays.isEmpty && !s.publishDays.contains(wd) { continue }
            guard let slot = cal.date(bySettingHour: s.publishHour, minute: s.publishMinute, second: 0, of: day) else { continue }
            if slot <= after { continue }
            let taken = store.data.articles.contains { a in
                guard let d = a.scheduled, !a.published else { return false }
                return cal.isDate(d, inSameDayAs: day)
            }
            if !taken { return slot }
        }
        return nil
    }

    @MainActor
    static func schedule(_ store: Store, _ id: UUID) -> Date? {
        guard let slot = nextSlot(store) else { return nil }
        store.update(id) { $0.scheduled = slot; $0.reminded = false }
        return slot
    }

    static func label(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEE HH:mm"
        return f.string(from: d)
    }

    static let weekdayNames = ["日", "一", "二", "三", "四", "五", "六"]
}

// MARK: - 素材库页

struct MaterialsView: View {
    @EnvironmentObject var store: Store
    @State private var kind = "经历"
    @State private var text = ""
    @State private var tags = ""
    @State private var query = ""
    @State private var bulk = false

    var filtered: [Material] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return store.data.materials }
        return store.data.materials.filter { m in
            m.text.contains(q) || m.tags.contains { $0.contains(q) } || m.kind == q
        }
    }

    var body: some View {
        Page {
            PageHeader(title: "素材库", subtitle: "存你自己的经历、观点、金句、数据。写稿时自动挑相关的用上，文章更像你本人写的。") {
                Toggle("写稿自动用素材", isOn: Binding(get: { store.data.auto.useMaterials },
                                                  set: { store.data.auto.useMaterials = $0; store.save() }))
                    .toggleStyle(.switch).font(.system(size: 12))
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("", selection: $kind) {
                        ForEach(Material.kinds, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 300)
                    Spacer()
                    Toggle("批量（一行一条）", isOn: $bulk).toggleStyle(.checkbox).font(.system(size: 12))
                }
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: bulk ? 160 : 90)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(placeholder).font(.system(size: 13)).foregroundStyle(Theme.faint)
                                .padding(.horizontal, 13).padding(.vertical, 8).allowsHitTesting(false)
                        }
                    }
                HStack(spacing: 10) {
                    TextField("标签，用逗号隔开，比如：备考,时间管理（写稿时按标签匹配）", text: $tags).fieldBox()
                    Button { add() } label: { HStack(spacing: 4) { Image(systemName: "plus"); Text("存进素材库") } }
                        .buttonStyle(PrimaryButton())
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .card()

            HStack {
                SectionTitle(text: "全部素材", hint: "\(store.data.materials.count) 条")
                Spacer()
                TextField("搜索", text: $query).fieldBox().frame(width: 200)
            }
            if filtered.isEmpty {
                Text(store.data.materials.isEmpty ? "还没有素材。先存几条你自己的真实经历试试。" : "没有匹配的素材。")
                    .font(.system(size: 13)).foregroundStyle(Theme.sub)
            }
            ForEach(filtered) { m in row(m) }
        }
    }

    var placeholder: String {
        switch kind {
        case "经历": return "比如：我在职备考那年，每天 6 点起床刷 40 分钟行测，三个月正确率从 55% 到 72%。"
        case "观点": return "比如：备考最怕的不是时间少，是每天都在换资料。"
        case "金句": return "一句你常说、想反复用的话"
        case "数据": return "一个你确认过的数字，最好带出处"
        default: return "一个你亲眼见过的真实例子"
        }
    }

    func row(_ m: Material) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Chip(text: m.kind, fg: color(m.kind), bg: color(m.kind).opacity(0.12))
            VStack(alignment: .leading, spacing: 6) {
                Text(m.text).font(.system(size: 13)).foregroundStyle(Theme.ink).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    ForEach(m.tags, id: \.self) { Chip(text: "#\($0)") }
                    if m.uses > 0 { Text("用过 \(m.uses) 次").font(.system(size: 11)).foregroundStyle(Theme.faint) }
                }
            }
            Spacer()
            Button("删除") {
                store.data.materials.removeAll { $0.id == m.id }
                store.save()
            }
            .buttonStyle(LinkButton(color: Theme.red))
        }
        .card(padding: 14)
    }

    func color(_ k: String) -> Color {
        switch k {
        case "经历": return Theme.navy
        case "观点": return Theme.violet
        case "金句": return Theme.pink
        case "数据": return Theme.teal
        default: return Theme.orange
        }
    }

    func add() {
        let tagList = tags.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == " " }).map { String($0) }
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines: [String] = bulk ? raw.components(separatedBy: "\n") : [raw]
        var added: [Material] = []
        for l in lines {
            let t = l.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { added.append(Material(kind: kind, text: t, tags: tagList)) }
        }
        store.data.materials.insert(contentsOf: added, at: 0)
        store.save()
        text = ""
    }
}

// MARK: - 发布日历页

struct PlanView: View {
    @EnvironmentObject var store: Store
    var open: (UUID) -> Void

    var days: [Date] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        var out: [Date] = []
        for i in 0..<14 {
            if let d = cal.date(byAdding: .day, value: i, to: start) { out.append(d) }
        }
        return out
    }

    var unscheduled: [Article] {
        store.data.articles.filter { $0.stage == .layout && $0.scheduled == nil && !$0.published }
    }

    func au<T>(_ kp: WritableKeyPath<AutoSettings, T>) -> Binding<T> {
        Binding(get: { store.data.auto[keyPath: kp] }, set: { store.data.auto[keyPath: kp] = $0; store.save() })
    }

    var body: some View {
        Page {
            PageHeader(title: "发布日历", subtitle: "写好的稿子排到发布日，到点 Mac 提醒你去发。发表还是你自己点。")
            settingsCard
            if !unscheduled.isEmpty { unscheduledCard }
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: "未来两周")
                ForEach(days, id: \.self) { d in dayRow(d) }
            }
            .card()
        }
    }

    var settingsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(label: "写好自动排期", hint: "一键成稿完成后排进下一个空的发布日") {
                Toggle("", isOn: au(\.autoSchedule)).toggleStyle(.switch).labelsHidden()
            }
            Divider()
            SettingRow(label: "发布日") {
                HStack(spacing: 4) {
                    ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { wd in dayToggle(wd) }
                }
            }
            Divider()
            SettingRow(label: "提醒时间") {
                HStack(spacing: 6) {
                    Stepper("\(store.data.auto.publishHour) 点", value: au(\.publishHour), in: 0...23).fixedSize()
                    Picker("", selection: au(\.publishMinute)) {
                        ForEach([0, 15, 30, 45], id: \.self) { Text(String(format: "%02d 分", $0)).tag($0) }
                    }
                    .labelsHidden().frame(width: 80)
                }
            }
        }
        .card()
    }

    func dayToggle(_ wd: Int) -> some View {
        let on = store.data.auto.publishDays.contains(wd)
        return Button {
            if on { store.data.auto.publishDays.removeAll { $0 == wd } } else { store.data.auto.publishDays.append(wd) }
            store.save()
        } label: {
            Text(PublishPlan.weekdayNames[wd - 1])
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(on ? Color.white : Theme.sub)
                .background(on ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.bg), in: Circle())
        }
        .buttonStyle(RowButton())
    }

    var unscheduledCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(text: "待排期", hint: "\(unscheduled.count) 篇已排好版")
                Spacer()
                Button("全部排进日历") {
                    for a in unscheduled { _ = PublishPlan.schedule(store, a.id) }
                }
                .buttonStyle(PrimaryButton())
            }
            ForEach(unscheduled) { a in
                HStack {
                    Button(a.displayTitle) { open(a.id) }.buttonStyle(LinkButton(color: Theme.ink))
                    if let r = a.review { ScoreBadge(score: r.total) }
                    Spacer()
                    Button("排进下一个空位") { _ = PublishPlan.schedule(store, a.id) }.buttonStyle(GhostButton())
                }
            }
        }
        .card()
    }

    func dayRow(_ d: Date) -> some View {
        let cal = Calendar.current
        let wd = cal.component(.weekday, from: d)
        let isPub = store.data.auto.publishDays.contains(wd)
        let items = store.data.articles.filter { a in
            guard let s = a.scheduled else { return false }
            return cal.isDate(s, inSameDayAs: d)
        }
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(cal.isDateInToday(d) ? "今天" : "周" + PublishPlan.weekdayNames[wd - 1])
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(cal.isDateInToday(d) ? Theme.navy : Theme.ink)
                Text(f.string(from: d)).font(.system(size: 11)).foregroundStyle(Theme.faint)
            }
            .frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                if items.isEmpty {
                    Text(isPub ? "发布日 · 还空着" : "—").font(.system(size: 12))
                        .foregroundStyle(isPub ? Theme.orange : Theme.faint)
                }
                ForEach(items) { a in item(a) }
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(isPub ? Theme.blueBg.opacity(0.35) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
    }

    func item(_ a: Article) -> some View {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return HStack(spacing: 8) {
            Image(systemName: a.published ? "checkmark.circle.fill" : "clock")
                .foregroundStyle(a.published ? Theme.green : Theme.navy)
            Text(a.scheduled.map { f.string(from: $0) } ?? "").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.sub)
            Button(a.displayTitle) { open(a.id) }.buttonStyle(LinkButton(color: Theme.ink))
            if !a.wechatDraft.isEmpty { Chip(text: "已在草稿箱", fg: Theme.green, bg: Theme.greenBg) }
            Spacer()
            ForEach(Platform.others(store).filter { a.variants[$0.rawValue] != nil }) { p in
                let posted = a.variants[p.rawValue]?.posted ?? false
                PostedToggle(articleId: a.id, platform: p.rawValue) {
                    HStack(spacing: 3) {
                        Image(systemName: posted ? "checkmark" : "circle").font(.system(size: 8, weight: .bold))
                        Text(p.name)
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(posted ? Color.white : p.color)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(posted ? p.color : p.color.opacity(0.1), in: Capsule())
                }
                .help(posted ? "\(p.name)已发，点一下取消" : "发完\(p.name)点一下标记")
            }
            if !a.published {
                Button("公众号发了") { store.update(a.id) { $0.published = true } }.buttonStyle(GhostButton())
                Button("取消") { store.update(a.id) { $0.scheduled = nil } }.buttonStyle(LinkButton(color: Theme.sub))
            }
        }
    }
}
