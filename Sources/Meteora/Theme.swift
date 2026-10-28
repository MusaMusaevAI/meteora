import SwiftUI
import AppKit

/// Meteora's visual language: a pearl work surface and gunmetal in the dark,
/// a dusty steel-blue accent (Amouage Portrayal's box and crystal) and a
/// mother-of-pearl sheen (Portrayal, Reflection 45) that appears only in the
/// mark and while something is being processed.
enum Theme {
    static func dynamic(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: dynamicNS(light: light, dark: dark, alpha: alpha))
    }
    static func dynamicNS(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: alpha)
        }
    }

    // Grounds
    static let windowNS = dynamicNS(light: 0xF3F2EF, dark: 0x141619)
    static let background = Color(nsColor: windowNS)
    /// Second neutral layer for the inspector: a touch cooler than the ground.
    static let inspector = dynamic(light: 0xEDEDEB, dark: 0x181A1E)
    static let surface = dynamic(light: 0xFBFBFA, dark: 0x1D2024)
    static let surfaceSunken = dynamic(light: 0xE6E6E3, dark: 0x101215)
    static let hairline = dynamic(light: 0xDAD9D5, dark: 0x2A2E34)
    static let border = hairline

    // Ink
    static let text = dynamic(light: 0x16181B, dark: 0xECEDEF)
    static let secondary = dynamic(light: 0x5B6068, dark: 0x9BA2AB)
    static let tertiary = dynamic(light: 0x8A9098, dark: 0x6A717A)

    // Accent: dusty steel blue
    static let accent = dynamic(light: 0x33506B, dark: 0x9DB8D3)
    static let accentHover = dynamic(light: 0x3B5C7B, dark: 0xADC5DD)
    static let accentPressed = dynamic(light: 0x283F55, dark: 0x89A6C3)
    static let accentSoft = dynamic(light: 0xE1E8EF, dark: 0x1E2A36)
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x0F1720)
    static let danger = dynamic(light: 0xA6432F, dark: 0xE38C76)

    // The stage: dark metal around the media in both appearances.
    static let stage = dynamic(light: 0x1B1E22, dark: 0x0C0E11)
    static let stageRaised = dynamic(light: 0x24282D, dark: 0x16191D)
    static let stageText = Color(nsColor: NSColor(hex: 0xE9EBEE))
    static let stageSecondary = Color(nsColor: NSColor(hex: 0x8F97A1))
    static let stageAccent = Color(nsColor: NSColor(hex: 0x9DB8D3))

    /// Mother-of-pearl: blue, lilac, rose, champagne.
    static let nacre: [Color] = ([0xBCD4EC, 0xD6CDEE, 0xEBC6D6, 0xF1E2CC, 0xC9E3E4] as [UInt32]).map { Color(nsColor: NSColor(hex: $0)) }

    static let radius: CGFloat = 12
    static let controlRadius: CGFloat = 7

    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    /// Kept for call sites that want a larger title; same family, no serif.
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight)
    }
    static let mono = Font.system(size: 12, weight: .regular).monospacedDigit()
    static let numbers = Font.system(size: 12.5).monospacedDigit()
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension View {
    /// Large titles get negative tracking, as SF Pro Display does natively.
    func titleStyle(_ size: CGFloat, weight: Font.Weight = .semibold) -> some View {
        font(.system(size: size, weight: weight)).tracking(size >= 20 ? -0.022 * size : -0.1)
    }
}

// MARK: - Inspector building blocks

/// One section of the inspector. Sections are separated by hairlines and
/// space, not boxed into cards.
struct InspectorSection<Content: View>: View {
    var title: String?
    var trailing: AnyView?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(Theme.ui(13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Spacer(minLength: 8)
                    if let trailing { trailing }
                }
            }
            content
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.hairline).frame(height: 1) }
}

// MARK: - Buttons

private struct HoverReader<Content: View>: View {
    @State private var hover = false
    var content: (Bool) -> Content
    var body: some View { content(hover).onHover { hover = $0 } }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        HoverReader { hover in
            configuration.label
                .font(Theme.ui(13, weight: .medium))
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 14)
                .frame(minHeight: 30)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .fill(configuration.isPressed ? Theme.accentPressed : hover ? Theme.accentHover : Theme.accent))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .animation(.easeOut(duration: 0.12), value: hover)
        }
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var fill = true
    func makeBody(configuration: Configuration) -> some View {
        HoverReader { hover in
            configuration.label
                .font(Theme.ui(13, weight: .regular))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 12)
                .frame(minHeight: 30)
                .frame(maxWidth: fill ? .infinity : nil)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .fill(configuration.isPressed ? Theme.surfaceSunken : Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .strokeBorder(hover ? Theme.tertiary.opacity(0.7) : Theme.hairline))
                .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
        }
    }
}

/// Text-only action in the accent colour ("Отменить", "Расшифровать заново").
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverReader { hover in
            configuration.label
                .font(Theme.ui(12, weight: .medium))
                .foregroundStyle(Theme.accent)
                .underline(hover, color: Theme.accent.opacity(0.5))
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
        }
    }
}

/// Round icon button; `onStage` for use on the dark media frame.
struct IconButtonStyle: ButtonStyle {
    var onStage = false
    func makeBody(configuration: Configuration) -> some View {
        HoverReader { hover in
            configuration.label
                .font(Theme.ui(14, weight: .semibold))
                .foregroundStyle(onStage ? Theme.stageText : Theme.text)
                .frame(width: 32, height: 32)
                .background(Circle().fill(
                    (onStage ? Color.white : Color.black).opacity(configuration.isPressed ? 0.16 : hover ? 0.08 : 0)))
                .contentShape(Circle())
        }
    }
}

/// Segmented control in the app's style.
struct PillPicker<Value: Hashable & Identifiable>: View {
    var options: [Value]
    @Binding var selection: Value
    var label: (Value) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let selected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(Theme.ui(12.5, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? Theme.text : Theme.secondary)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(selected ? Theme.surface : Color.clear)
                            .shadow(color: .black.opacity(selected ? 0.10 : 0), radius: 1.5, y: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.surfaceSunken))
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

// MARK: - Progress with the nacre sheen (signature)

/// Thin progress track. While work is running a mother-of-pearl highlight
/// drifts across the filled part — the one place the interface shimmers.
struct ThinProgress: View {
    var value: Double
    var active: Bool = true
    var onStage = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { g in
            let w = max(4, g.size.width * min(1, max(0, value)))
            ZStack(alignment: .leading) {
                Capsule().fill(onStage ? Color.white.opacity(0.14) : Theme.surfaceSunken)
                Capsule().fill(onStage ? Theme.stageAccent : Theme.accent).frame(width: w)
                if active {
                    NacreSheen(animated: !reduceMotion)
                        .frame(width: w)
                        .clipShape(Capsule())
                        .blendMode(.screen)
                }
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.25), value: value)
        .accessibilityElement()
        .accessibilityLabel("Прогресс")
        .accessibilityValue("\(Int(value * 100)) %")
    }
}

/// A band of mother-of-pearl colour sliding slowly through its container.
struct NacreSheen: View {
    var animated = true
    var body: some View {
        if animated {
            TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                band(phase: ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.8) / 2.8)
            }
        } else {
            band(phase: 0.5)
        }
    }

    private func band(phase: Double) -> some View {
        GeometryReader { g in
            let bw = max(60, g.size.width * 0.45)
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: Theme.nacre[0].opacity(0.9), location: 0.25),
                .init(color: Theme.nacre[1], location: 0.45),
                .init(color: Theme.nacre[2], location: 0.6),
                .init(color: Theme.nacre[3].opacity(0.9), location: 0.78),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
            .frame(width: bw)
            .offset(x: -bw + (g.size.width + bw) * phase)
        }
    }
}

/// A static mother-of-pearl gradient, for strokes and small fills.
enum Nacre {
    static func gradient(_ start: UnitPoint = .topLeading, _ end: UnitPoint = .bottomTrailing) -> LinearGradient {
        LinearGradient(colors: Theme.nacre, startPoint: start, endPoint: end)
    }
}

// MARK: - Rows

struct KeyValueRow: View {
    var key: String
    var value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).foregroundStyle(Theme.secondary)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(Theme.text).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(Theme.numbers)
    }
}

/// Status line under a progress bar: text on the left, an action on the right.
struct ProgressStatus: View {
    var text: String
    var action: String?
    var perform: (() -> Void)?
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(Theme.ui(11.5).monospacedDigit()).foregroundStyle(Theme.secondary)
            Spacer(minLength: 8)
            if let action, let perform {
                Button(action, action: perform).buttonStyle(LinkButtonStyle())
            }
        }
    }
}
