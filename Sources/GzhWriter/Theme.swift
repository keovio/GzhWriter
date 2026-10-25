import SwiftUI

/// 全局视觉：浅灰底 + 白卡片 + 深蓝主色
enum Theme {
    static let bg = Color(hex: "#F4F5F8")
    static let sheet = Color.white
    static let sidebar = Color(hex: "#FAFBFC")
    static let rule = Color(hex: "#E5E7EC")
    static let ink = Color(hex: "#1C2333")
    static let sub = Color(hex: "#6B7280")
    static let faint = Color(hex: "#9CA3AF")
    static let navy = Color(hex: "#1F2B47")
    static let blue = Color(hex: "#2F6FEB")
    static let blueBg = Color(hex: "#E9F0FD")
    static let green = Color(hex: "#2F7D5B")
    static let greenBg = Color(hex: "#E4F2EA")
    static let orange = Color(hex: "#D9822B")
    static let orangeBg = Color(hex: "#FDF1E4")
    static let red = Color(hex: "#B23A2A")

    static func scoreColor(_ s: Int) -> Color { s >= 80 ? green : (s >= 60 ? orange : red) }
    static func scoreBg(_ s: Int) -> Color { s >= 80 ? greenBg : orangeBg }
}

// MARK: 卡片

struct SheetCard: ViewModifier {
    var padding: CGFloat = 20
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.sheet, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.rule))
            .shadow(color: Color.black.opacity(0.03), radius: 6, y: 2)
    }
}

extension View {
    func card(padding: CGFloat = 20) -> some View { modifier(SheetCard(padding: padding)) }
}

// MARK: 按钮

struct PrimaryButton: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 15 : 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, large ? 22 : 14)
            .padding(.vertical, large ? 11 : 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(enabled ? (configuration.isPressed ? Theme.navy.opacity(0.85) : Theme.navy) : Theme.faint))
            .contentShape(Rectangle())
    }
}

struct GhostButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(configuration.isPressed ? Theme.rule : Theme.sheet))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.rule))
            .contentShape(Rectangle())
    }
}

struct LinkButton: ButtonStyle {
    var color: Color = Theme.blue
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(color.opacity(configuration.isPressed ? 0.6 : 1))
            .contentShape(Rectangle())
    }
}

// MARK: 小组件

struct Chip: View {
    let text: String
    var fg: Color = Theme.sub
    var bg: Color = Color(hex: "#F1F2F5")
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(fg)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(bg, in: Capsule())
    }
}

struct ScoreBadge: View {
    let score: Int
    var body: some View { Chip(text: "\(score) 分", fg: Theme.scoreColor(score), bg: Theme.scoreBg(score)) }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String = ""
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.ink)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.sub)
                }
            }
            Spacer()
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String = "") {
        self.title = title; self.subtitle = subtitle; self.trailing = EmptyView()
    }
}

/// 页面容器：浅灰底、居中、可滚动
struct Page<Content: View>: View {
    var maxWidth: CGFloat = 1040
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) { content }
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: maxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
    }
}

/// 白底输入框
struct FieldBox: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Theme.sheet, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.rule))
    }
}

extension View {
    func fieldBox() -> some View { modifier(FieldBox()) }
}

struct SectionTitle: View {
    let text: String
    var hint: String = ""
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
            if !hint.isEmpty { Text(hint).font(.system(size: 12)).foregroundStyle(Theme.faint) }
        }
    }
}

/// 设置页里的一行：左标签，右控件
struct SettingRow<Control: View>: View {
    let label: String
    var hint: String = ""
    @ViewBuilder var control: Control
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                if !hint.isEmpty { Text(hint).font(.system(size: 12)).foregroundStyle(Theme.sub).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 20)
            control
        }
        .padding(.vertical, 10)
    }
}

/// 五步进度
struct StepBar: View {
    let current: Stage
    let done: (Stage) -> Bool
    let select: (Stage) -> Void
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Stage.allCases) { s in
                Button { select(s) } label: {
                    HStack(spacing: 6) {
                        ZStack {
                            Circle().fill(s == current ? Theme.navy : (done(s) ? Theme.green : Theme.rule))
                                .frame(width: 22, height: 22)
                            if done(s) && s != current {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            } else {
                                Text("\(s.rawValue + 1)").font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(s == current ? .white : Theme.sub)
                            }
                        }
                        Text(s.name).font(.system(size: 13, weight: s == current ? .semibold : .regular))
                            .foregroundStyle(s == current ? Theme.ink : Theme.sub)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if s != Stage.allCases.last {
                    Rectangle().fill(done(s) ? Theme.green.opacity(0.5) : Theme.rule).frame(height: 2).frame(minWidth: 16, maxWidth: 48)
                        .padding(.horizontal, 8)
                }
            }
        }
    }
}

extension Stage {
    var name: String {
        switch self {
        case .topic: return "选题"
        case .outline: return "大纲"
        case .draft: return "正文"
        case .review: return "审稿"
        case .layout: return "排版"
        }
    }
}
