import SwiftUI
import UIKit

/// The Mac app's design tokens (DESIGN.md), for iPhone.
enum Theme {
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }

    static let background = dynamic(light: 0xF3F2EF, dark: 0x141619)
    static let inspector = dynamic(light: 0xEDEDEB, dark: 0x181A1E)
    static let surface = dynamic(light: 0xFBFBFA, dark: 0x1D2024)
    static let surfaceSunken = dynamic(light: 0xE6E6E3, dark: 0x101215)
    static let hairline = dynamic(light: 0xDAD9D5, dark: 0x2A2E34)
    static let text = dynamic(light: 0x16181B, dark: 0xECEDEF)
    static let secondary = dynamic(light: 0x5B6068, dark: 0x9BA2AB)
    static let tertiary = dynamic(light: 0x8A9098, dark: 0x6A717A)
    static let accent = dynamic(light: 0x33506B, dark: 0x9DB8D3)
    static let accentSoft = dynamic(light: 0xE1E8EF, dark: 0x1E2A36)
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x0F1720)
    static let danger = dynamic(light: 0xA6432F, dark: 0xE38C76)
    static let record = Color(uiColor: UIColor(hex: 0xD9533F))
    static let stage = dynamic(light: 0x1B1E22, dark: 0x0C0E11)
    static let stageText = Color(uiColor: UIColor(hex: 0xE9EBEE))
    static let nacre: [Color] = ([0xBCD4EC, 0xD6CDEE, 0xEBC6D6, 0xF1E2CC, 0xC9E3E4] as [UInt32]).map { Color(uiColor: UIColor(hex: $0)) }
    static let speakerColors: [Color] = [
        dynamic(light: 0x33506B, dark: 0x9DB8D3), dynamic(light: 0x7A4E6E, dark: 0xD3A6C6),
        dynamic(light: 0x4E6E5A, dark: 0xA6CDB2), dynamic(light: 0x8A5A2E, dark: 0xE0B98E),
        dynamic(light: 0x5A4E8A, dark: 0xB8AEE6), dynamic(light: 0x2E6E7A, dark: 0x8ECFD9),
        dynamic(light: 0x7A2E3A, dark: 0xE09AA6), dynamic(light: 0x6B5B4B, dark: 0xC9B8A6),
    ]
    static func speakerColor(_ i: Int) -> Color { speakerColors[((i % speakerColors.count) + speakerColors.count) % speakerColors.count] }

    static let radius: CGFloat = 18

    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        AppFont.font(AppFont.text, size: size, weight: weight)
    }
    static func display(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        AppFont.font(AppFont.display, size: size * 0.86, weight: weight)
    }
    static let mono = ui(13).monospacedDigit()
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Bundled variable fonts (UIAppFonts). Falls back to the system font.
enum AppFont {
    static let text = "Onest"
    static let display = "Unbounded"
    private static let wghtTag = 0x7767_6874 // 'wght'
    private static var cache: [String: Font] = [:]
    private static let lock = NSLock()

    static func weightValue(_ w: Font.Weight) -> CGFloat {
        switch w {
        case .ultraLight: return 200
        case .thin: return 250
        case .light: return 300
        case .regular: return 400
        case .medium: return 500
        case .semibold: return 600
        case .bold: return 700
        case .heavy: return 800
        case .black: return 900
        default: return 400
        }
    }

    static func font(_ family: String, size: CGFloat, weight: Font.Weight) -> Font {
        let key = "\(family)|\(size)|\(weightValue(weight))"
        lock.lock(); defer { lock.unlock() }
        if let f = cache[key] { return f }
        let f: Font
        if let ui = uiFont(family, size: size, weight: weight) {
            f = Font(ui as CTFont)
        } else {
            f = .system(size: size, weight: weight)
        }
        cache[key] = f
        return f
    }

    static func uiFont(_ family: String, size: CGFloat, weight: Font.Weight) -> UIFont? {
        let variation = [NSNumber(value: wghtTag): NSNumber(value: Double(weightValue(weight)))]
        let desc = UIFontDescriptor(fontAttributes: [.family: family])
            .addingAttributes([UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): variation])
        let f = UIFont(descriptor: desc, size: size)
        return f.familyName == family ? f : nil
    }
}

extension View {
    /// Display face with the tight tracking of the Mac titles.
    func titleStyle(_ size: CGFloat) -> some View {
        font(Theme.display(size, weight: .medium)).tracking(-size * 0.012)
    }
}

/// Russian plural forms: ru(1, "фраза", "фразы", "фраз") → "1 фраза".
func ru(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let m10 = n % 10, m100 = n % 100
    let w = (m10 == 1 && m100 != 11) ? one : (2 ... 4).contains(m10) && !(12 ... 14).contains(m100) ? few : many
    return "\(n) \(w)"
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.ui(16, weight: .semibold))
            .foregroundStyle(Theme.onAccent)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.accent.opacity(0.92), Theme.accent], startPoint: .top, endPoint: .bottom))
            )
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.16)))
            .shadow(color: Theme.accent.opacity(0.35), radius: configuration.isPressed ? 4 : 12, y: 4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.ui(15, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// A rounded card on a translucent surface.
struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title).font(Theme.ui(13, weight: .semibold)).foregroundStyle(Theme.secondary)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.surface.opacity(0.86)))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairline.opacity(0.8)))
    }
}

/// Thin progress track with the pearl shimmer (DESIGN.md).
struct ThinProgress: View {
    var value: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceSunken)
                Capsule().fill(Theme.accent).frame(width: max(4, g.size.width * min(1, max(0, value))))
                    .overlay {
                        if !reduceMotion {
                            TimelineView(.animation(minimumInterval: 1 / 20)) { ctx in
                                let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                                LinearGradient(colors: [Color.clear] + Array(Theme.nacre.prefix(3)) + [Color.clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: 60)
                                    .offset(x: CGFloat(t) * g.size.width - 30)
                                    .opacity(0.7)
                            }
                            .mask(Capsule())
                        }
                    }
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.2), value: value)
    }
}

/// «Расшифровка · 42 %» row with a cancel link.
struct ProgressRow: View {
    var text: String
    var value: Double?
    var cancel: (() -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(text).font(Theme.ui(14)).foregroundStyle(Theme.text)
                Spacer()
                if let value { Text("\(Int(value * 100)) %").font(Theme.mono).foregroundStyle(Theme.secondary) }
                if let cancel {
                    Button("Отменить", action: cancel).font(Theme.ui(14, weight: .medium)).foregroundStyle(Theme.accent)
                }
            }
            ThinProgress(value: value ?? 0.05)
        }
    }
}
