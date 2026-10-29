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

    /// Speaker labels: muted hues from the same pearl family, legible in
    /// both themes. Repeats after six speakers.
    static let speakerColors: [Color] = [
        dynamic(light: 0x33506B, dark: 0x9DB8D3),
        dynamic(light: 0x8A4B63, dark: 0xE0A9BE),
        dynamic(light: 0x2F6B66, dark: 0x8FCFC8),
        dynamic(light: 0x7A5A1F, dark: 0xE2C287),
        dynamic(light: 0x5B4A8A, dark: 0xBDB0EA),
        dynamic(light: 0x6B5B4B, dark: 0xC9B8A6),
    ]
    static func speakerColor(_ index: Int) -> Color { speakerColors[((index % speakerColors.count) + speakerColors.count) % speakerColors.count] }

    static let radius: CGFloat = 14
    static let controlRadius: CGFloat = 10

    /// Interface text: Onest — a contemporary grotesque drawn for Cyrillic.
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        AppFont.font(AppFont.text, size: size, weight: weight)
    }
    /// Titles and the wordmark: Unbounded — wide, a little spacey. Optically
    /// larger than Onest, so it is drawn a bit smaller.
    static func display(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        AppFont.font(AppFont.display, size: size * 0.86, weight: weight)
    }
    static let mono = ui(12).monospacedDigit()
    static let numbers = ui(12.5).monospacedDigit()
}

/// Bundled variable fonts (registered by ATSApplicationFontsPath). Falls
/// back to the system font if a family is missing.
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
        if let ns = nsFont(family, size: size, weight: weight) {
            f = Font(ns as CTFont)
        } else {
            f = .system(size: size, weight: weight)
        }
        cache[key] = f
        return f
    }

    static func nsFont(_ family: String, size: CGFloat, weight: Font.Weight) -> NSFont? {
        let variation = [NSNumber(value: wghtTag): NSNumber(value: Double(weightValue(weight)))]
        let desc = NSFontDescriptor(fontAttributes: [.family: family])
            .addingAttributes([NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): variation])
        guard let f = NSFont(descriptor: desc, size: size), f.familyName == family else { return nil }
        return f
    }
}

/// Russian plural forms: ru(1, "фраза", "фразы", "фраз") → "1 фраза".
func ru(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let m10 = n % 10, m100 = n % 100
    let w = (m10 == 1 && m100 != 11) ? one : (2 ... 4).contains(m10) && !(12 ... 14).contains(m100) ? few : many
    return "\(n) \(w)"
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
    /// Titles: Unbounded from 18 pt, Onest below.
    func titleStyle(_ size: CGFloat, weight: Font.Weight = .semibold) -> some View {
        font(size >= 18 ? Theme.display(size, weight: weight == .semibold ? .medium : weight) : Theme.ui(size, weight: weight))
            .tracking(size >= 18 ? -0.01 * size : -0.1)
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

/// The one strong action: a softly lit accent capsule. A thin highlight on
/// the top edge and a faint glow make it read as glass, not a flat block.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        HoverReader { hover in
            let shape = RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
            configuration.label
                .font(Theme.ui(13, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 16)
                .frame(minHeight: 32)
                .frame(maxWidth: .infinity)
                .background(shape.fill(LinearGradient(
                    colors: configuration.isPressed ? [Theme.accentPressed, Theme.accentPressed]
                        : [hover ? Theme.accentHover : Theme.accent, Theme.accentPressed],
                    startPoint: .top, endPoint: .bottom)))
                .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.02)],
                                                           startPoint: .top, endPoint: .bottom), lineWidth: 1))
                .shadow(color: Theme.accent.opacity(hover && isEnabled ? 0.38 : 0), radius: 9, y: 2)
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
                .font(Theme.ui(13, weight: .medium))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 14)
                .frame(minHeight: 32)
                .frame(maxWidth: fill ? .infinity : nil)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .fill(configuration.isPressed ? Theme.surfaceSunken : Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .strokeBorder(hover ? Theme.accent.opacity(0.45) : Theme.hairline))
                .shadow(color: hover ? Theme.accent.opacity(0.18) : .black.opacity(0.05), radius: hover ? 7 : 2, y: 1)
                .animation(.easeOut(duration: 0.12), value: hover)
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
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
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
                    .shadow(color: (onStage ? Theme.stageAccent : Theme.accent).opacity(active ? 0.55 : 0), radius: 5)
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

// MARK: - Back control

/// «‹ Все записи»: a quiet accent pill, visible without shouting.
struct BackPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverReader { hover in
            configuration.label
                .font(Theme.ui(12.5, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .padding(.leading, 9)
                .padding(.trailing, 12)
                .frame(height: 26)
                .background(Capsule().fill(hover ? Theme.accentSoft : Theme.accentSoft.opacity(0.7)))
                .overlay(Capsule().strokeBorder(Theme.accent.opacity(hover ? 0.35 : 0.18)))
                .shadow(color: Theme.accent.opacity(hover ? 0.25 : 0), radius: 8)
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(Capsule())
                .animation(.easeOut(duration: 0.14), value: hover)
        }
    }
}

// MARK: - Space: nebula glow and stars

/// Slow, very soft glows drifting behind the interface — a nebula seen
/// through frosted pearl. Never competes with content: low opacity, huge
/// blur radius, a full drift cycle takes about a minute. Static under
/// Reduce Motion.
struct NebulaBackground: View {
    /// 0…1: how present the glow is (start screen 1, working view less).
    var intensity: Double = 1
    var stars = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Theme.background
            if scheme == .light {
                // Daylight sky: the pearl ground cools toward a pale steel
                // blue at the top, so faint stars still have something to
                // glow against.
                LinearGradient(colors: [Color(nsColor: NSColor(hex: 0xDDE3EC)).opacity(0.9 * intensity), .clear],
                               startPoint: .top, endPoint: .center)
            }
            if reduceMotion {
                glows(t: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1 / 15)) { ctx in
                    glows(t: ctx.date.timeIntervalSinceReferenceDate)
                }
            }
            if stars {
                Starfield(animated: !reduceMotion, light: scheme == .light).opacity(intensity)
                if !reduceMotion { MeteorShower(light: scheme == .light).opacity(min(1, intensity * 1.4)) }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func glows(t: Double) -> some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let dark = scheme == .dark
            let k = intensity * (dark ? 1 : 0.75)
            // (colour, base position, drift radius, period, size, opacity)
            let blobs: [(Color, CGPoint, CGFloat, Double, CGFloat, Double)] = [
                (Theme.accent, CGPoint(x: 0.82, y: 0.12), 0.06, 61, 0.75, dark ? 0.28 : 0.16),
                (Theme.nacre[1], CGPoint(x: 0.12, y: 0.86), 0.07, 73, 0.70, dark ? 0.16 : 0.22),
                (Theme.nacre[2], CGPoint(x: 0.55, y: 0.98), 0.05, 89, 0.55, dark ? 0.10 : 0.14),
                (Theme.nacre[0], CGPoint(x: 0.05, y: 0.10), 0.05, 97, 0.50, dark ? 0.12 : 0.16),
            ]
            ZStack {
                ForEach(0..<blobs.count, id: \.self) { i in
                    let b = blobs[i]
                    let a = t / b.3 * 2 * .pi + Double(i)
                    let d = max(w, h) * b.4
                    Circle()
                        .fill(RadialGradient(colors: [b.0.opacity(b.5 * k), b.0.opacity(0)],
                                             center: .center, startRadius: 0, endRadius: d / 2))
                        .frame(width: d, height: d)
                        .position(x: w * (b.1.x + b.2 * CGFloat(cos(a))), y: h * (b.1.y + b.2 * CGFloat(sin(a * 0.8))))
                }
            }
            .blendMode(dark ? .screen : .normal)
        }
    }
}

/// Sparse, faint stars for the dark theme. Positions are fixed (seeded),
/// a few of them breathe slowly.
struct Starfield: View {
    var animated = true
    /// Daylight: stars are dusty blue and lilac specks with a few four-point
    /// glints, instead of white points.
    var light = false
    private static let stars: [(CGFloat, CGFloat, CGFloat, Double)] = {
        var rng = SplitMix(seed: 0x4D_65_74_65)
        return (0..<70).map { _ in
            (CGFloat(rng.unit()), CGFloat(rng.unit()), CGFloat(0.6 + rng.unit() * 1.1), rng.unit())
        }
    }()

    var body: some View {
        if animated {
            TimelineView(.animation(minimumInterval: 1 / 10)) { ctx in canvas(t: ctx.date.timeIntervalSinceReferenceDate) }
        } else {
            canvas(t: 0)
        }
    }

    private func canvas(t: Double) -> some View {
        Canvas { ctx, size in
            for (i, s) in Self.stars.enumerated() {
                let twinkle = i % 5 == 0 ? 0.5 + 0.5 * sin(t * 0.7 + s.3 * 20) : 1
                let r = s.2 * (light ? 1.25 : 1)
                let x = s.0 * size.width, y = s.1 * size.height
                let rect = CGRect(x: x - r / 2, y: y - r / 2, width: r, height: r)
                if light {
                    // Denser near the top, where the sky is bluest.
                    let fade = max(0, 1 - Double(s.1) * 1.1)
                    let color = i % 3 == 0 ? Color(nsColor: NSColor(hex: 0x8C7FB8)) : Color(nsColor: NSColor(hex: 0x5F7FA3))
                    let alpha = (0.22 + 0.38 * s.3) * twinkle * (0.35 + 0.65 * fade)
                    ctx.fill(Path(ellipseIn: rect), with: .color(color.opacity(alpha)))
                    if i % 9 == 0 {
                        // A four-point glint.
                        let g = 3.2 + 2.4 * s.3
                        var p = Path()
                        p.move(to: CGPoint(x: x - g, y: y)); p.addLine(to: CGPoint(x: x + g, y: y))
                        p.move(to: CGPoint(x: x, y: y - g)); p.addLine(to: CGPoint(x: x, y: y + g))
                        ctx.stroke(p, with: .color(color.opacity(alpha * 0.8)), lineWidth: 0.6)
                    }
                } else {
                    let alpha = (0.18 + 0.32 * s.3) * twinkle
                    ctx.fill(Path(ellipseIn: rect), with: .color(.white.opacity(alpha)))
                }
            }
        }
    }
}

/// Tiny deterministic generator (stable star positions across launches).
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

/// A soft glow halo used behind the logo mark.
struct GlowHalo: View {
    var size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let angle = Angle.degrees(reduceMotion ? 0 : (t * 9).truncatingRemainder(dividingBy: 360))
            Circle()
                .fill(AngularGradient(colors: Theme.nacre + [Theme.nacre[0]], center: .center, angle: angle))
                .frame(width: size, height: size)
                .blur(radius: size * 0.34)
                .opacity(0.38)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}


// MARK: - Shooting stars

/// Now and then — every 15–40 seconds — one, sometimes two or three, thin
/// meteors cross the upper sky. An easter egg for the name; never more.
struct MeteorShower: View {
    var light = false
    @State private var meteors: [Meteor] = []
    @State private var task: Task<Void, Never>?

    struct Meteor: Identifiable {
        let id = UUID()
        var start: CGPoint   // unit coordinates
        var angle: Double    // radians, downward to the side
        var length: CGFloat  // points
        var travel: CGFloat  // points
        var duration: Double
    }

    var body: some View {
        GeometryReader { g in
            ZStack {
                ForEach(meteors) { m in
                    MeteorStreak(meteor: m, size: g.size, light: light)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            task?.cancel()
            task = Task { @MainActor in
                var rng = SplitMix(seed: UInt64(Date().timeIntervalSince1970 * 1000))
                try? await Task.sleep(nanoseconds: UInt64((6 + rng.unit() * 10) * 1e9))
                while !Task.isCancelled {
                    let count = rng.unit() < 0.18 ? (rng.unit() < 0.3 ? 3 : 2) : 1
                    for k in 0..<count {
                        let leftToRight = rng.unit() < 0.5
                        let m = Meteor(start: CGPoint(x: 0.15 + rng.unit() * 0.7, y: 0.04 + rng.unit() * 0.3),
                                       angle: (leftToRight ? 0.32 : .pi - 0.32) + (rng.unit() - 0.5) * 0.25,
                                       length: 90 + CGFloat(rng.unit()) * 110,
                                       travel: 260 + CGFloat(rng.unit()) * 220,
                                       duration: 0.9 + rng.unit() * 0.5)
                        meteors.append(m)
                        let id = m.id
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: UInt64((m.duration + 0.3) * 1e9))
                            meteors.removeAll { $0.id == id }
                        }
                        if k < count - 1 { try? await Task.sleep(nanoseconds: UInt64((0.25 + rng.unit() * 0.6) * 1e9)) }
                    }
                    try? await Task.sleep(nanoseconds: UInt64((15 + rng.unit() * 25) * 1e9))
                }
            }
        }
        .onDisappear { task?.cancel(); task = nil }
    }
}

private struct MeteorStreak: View {
    let meteor: MeteorShower.Meteor
    let size: CGSize
    let light: Bool
    @State private var born = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { ctx in
            let raw = min(1, max(0, ctx.date.timeIntervalSince(born) / meteor.duration))
            streak(CGFloat(raw * raw * 0.35 + raw * 0.65))  // gentle acceleration
        }
    }

    private func streak(_ p: CGFloat) -> some View {
        let dx = CGFloat(cos(meteor.angle)), dy = CGFloat(sin(meteor.angle))
        let head = CGPoint(x: meteor.start.x * size.width + dx * meteor.travel * p,
                           y: meteor.start.y * size.height + dy * meteor.travel * p)
        let tailLen = meteor.length * min(1, p * 2.2)
        let tail = CGPoint(x: head.x - dx * tailLen, y: head.y - dy * tailLen)
        let core: Color = light ? Color(nsColor: NSColor(hex: 0x4E6E93)) : .white
        let glow: Color = light ? Color(nsColor: NSColor(hex: 0x9C8CD0)) : Theme.nacre[0]
        // Fade in fast, burn out at the end.
        let alpha = Double(p < 0.15 ? p / 0.15 : max(0, 1 - (p - 0.55) / 0.45))
        let w = max(1, size.width), h = max(1, size.height)
        let from = UnitPoint(x: tail.x / w, y: tail.y / h), to = UnitPoint(x: head.x / w, y: head.y / h)
        return ZStack {
            Path { $0.move(to: tail); $0.addLine(to: head) }
                .stroke(LinearGradient(colors: [glow.opacity(0), glow.opacity(0.55)], startPoint: from, endPoint: to),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .blur(radius: 2)
            Path { $0.move(to: tail); $0.addLine(to: head) }
                .stroke(LinearGradient(colors: [core.opacity(0), core.opacity(0.95)], startPoint: from, endPoint: to),
                        style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
            Circle().fill(core).frame(width: 2.4, height: 2.4).position(head)
                .shadow(color: glow, radius: 4)
        }
        .opacity(alpha * (light ? 0.75 : 0.9))
    }
}
