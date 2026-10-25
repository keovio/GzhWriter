import AppKit
import SwiftUI

/// 全局视觉：冷灰底 + 白卡片 + 靛蓝紫渐变主色，配几种辅助色
enum Theme {
    static let bg = Color(hex: "#F2F4FB")
    static let sheet = Color.white
    static let sidebar = Color(hex: "#EEF1FB")
    static let rule = Color(hex: "#DCE1EE")
    static let ink = Color(hex: "#151C2E")
    static let sub = Color(hex: "#566078")
    static let faint = Color(hex: "#7E879B")
    /// 主色（原深蓝改为更亮的靛蓝）
    static let navy = Color(hex: "#4361EE")
    static let navyDeep = Color(hex: "#3046C9")
    static let violet = Color(hex: "#7B5CF0")
    static let blue = Color(hex: "#3B5BDB")
    static let blueBg = Color(hex: "#E6EBFF")
    static let green = Color(hex: "#1F9D6B")
    static let greenBg = Color(hex: "#DFF5EA")
    static let orange = Color(hex: "#E8590C")
    static let orangeBg = Color(hex: "#FFEDDF")
    static let red = Color(hex: "#D63B3B")
    static let redBg = Color(hex: "#FDE7E7")
    static let teal = Color(hex: "#0CA5B0")
    static let pink = Color(hex: "#E64980")

    static let brand = LinearGradient(colors: [navy, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let brandPressed = LinearGradient(colors: [navyDeep, Color(hex: "#6342D8")], startPoint: .topLeading, endPoint: .bottomTrailing)

    static func scoreColor(_ s: Int) -> Color { s >= 80 ? green : (s >= 60 ? orange : red) }
    static func scoreBg(_ s: Int) -> Color { s >= 80 ? greenBg : (s >= 60 ? orangeBg : redBg) }

    /// 触控板轻震，让点击有手感
    static func tap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
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
            .shadow(color: Color(hex: "#1B2A6B").opacity(0.06), radius: 10, y: 3)
    }
}

extension View {
    func card(padding: CGFloat = 20) -> some View { modifier(SheetCard(padding: padding)) }
}

// MARK: 按钮（悬停变亮、按下缩小变深、触控板轻震）

struct PrimaryButton: ButtonStyle {
    var large = false
    func makeBody(configuration: Configuration) -> some View {
        PrimaryBody(configuration: configuration, large: large)
    }
    struct PrimaryBody: View {
        let configuration: Configuration
        let large: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false
        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .font(.system(size: large ? 15 : 13, weight: .semibold))
                .foregroundStyle(enabled ? Color.white : Theme.sub)
                .padding(.horizontal, large ? 22 : 14)
                .padding(.vertical, large ? 11 : 7)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(enabled ? (pressed ? Theme.brandPressed : Theme.brand)
                                      : LinearGradient(colors: [Theme.rule], startPoint: .top, endPoint: .bottom))
                }
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(enabled && hover && !pressed ? 0.12 : 0)))
                .shadow(color: Theme.navy.opacity(enabled ? (pressed ? 0.15 : (hover ? 0.45 : 0.3)) : 0),
                        radius: pressed ? 2 : (hover ? 10 : 6), y: pressed ? 1 : 3)
                .scaleEffect(pressed ? 0.95 : (hover && enabled ? 1.02 : 1))
                .animation(.spring(response: 0.22, dampingFraction: 0.6), value: pressed)
                .animation(.easeOut(duration: 0.15), value: hover)
                .contentShape(Rectangle())
                .onHover { hover = $0; if enabled { ($0 ? NSCursor.pointingHand : NSCursor.arrow).set() } }
                .onChange(of: pressed) { if $0 && enabled { Theme.tap() } }
        }
    }
}

struct GhostButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { GhostBody(configuration: configuration) }
    struct GhostBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false
        var body: some View {
            let pressed = configuration.isPressed
            let active = enabled && (hover || pressed)
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(enabled ? (active ? Theme.navyDeep : Theme.ink) : Theme.faint)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(pressed ? Theme.blueBg.opacity(1) : (hover && enabled ? Theme.blueBg.opacity(0.6) : Theme.sheet)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(active ? Theme.navy.opacity(0.7) : Color(hex: "#C6CDDD"), lineWidth: active ? 1.5 : 1))
                .shadow(color: Color.black.opacity(pressed ? 0 : 0.05), radius: 2, y: 1)
                .scaleEffect(pressed ? 0.95 : 1)
                .animation(.spring(response: 0.22, dampingFraction: 0.6), value: pressed)
                .animation(.easeOut(duration: 0.12), value: hover)
                .opacity(enabled ? 1 : 0.6)
                .contentShape(Rectangle())
                .onHover { hover = $0; if enabled { ($0 ? NSCursor.pointingHand : NSCursor.arrow).set() } }
                .onChange(of: pressed) { if $0 && enabled { Theme.tap() } }
        }
    }
}

struct LinkButton: ButtonStyle {
    var color: Color = Theme.blue
    func makeBody(configuration: Configuration) -> some View { LinkBody(configuration: configuration, color: color) }
    struct LinkBody: View {
        let configuration: Configuration
        let color: Color
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false
        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(enabled ? color : Theme.faint)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color.opacity(pressed ? 0.2 : (hover && enabled ? 0.1 : 0))))
                .scaleEffect(pressed ? 0.94 : 1)
                .animation(.spring(response: 0.2, dampingFraction: 0.6), value: pressed)
                .animation(.easeOut(duration: 0.12), value: hover)
                .contentShape(Rectangle())
                .onHover { hover = $0; if enabled { ($0 ? NSCursor.pointingHand : NSCursor.arrow).set() } }
                .onChange(of: pressed) { if $0 && enabled { Theme.tap() } }
        }
    }
}

/// 列表行、卡片式按钮：悬停浮起、按下缩小
struct RowButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { RowBody(configuration: configuration) }
    struct RowBody: View {
        let configuration: Configuration
        @State private var hover = false
        var body: some View {
            configuration.label
                .brightness(hover ? -0.02 : 0)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
                .onHover { hover = $0 }
                .onChange(of: configuration.isPressed) { if $0 { Theme.tap() } }
        }
    }
}

// MARK: 小组件

struct Chip: View {
    let text: String
    var fg: Color = Theme.sub
    var bg: Color = Color(hex: "#ECEFF7")
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
                            Circle().fill(s == current ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(done(s) ? Theme.green : Theme.rule))
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
                .buttonStyle(RowButton())
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
