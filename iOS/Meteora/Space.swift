import SwiftUI
import UIKit

// The Mac app's sky (Theme.swift there), for iPhone: nebula glow, stars,
// and a meteor every 30–40 seconds.

enum AppearanceSettings {
    static let meteorsKey = "ui.meteors"
    static let skyKey = "ui.animatedSky"
}

/// Slow, very soft glows drifting behind the interface — a nebula seen
/// through frosted pearl. Never competes with content: low opacity, huge
/// blur radius, a full drift cycle takes about a minute. Static under
/// Reduce Motion.
struct NebulaBackground: View {
    /// 0…1: how present the glow is (start screen 1, working view less).
    var intensity: Double = 1
    var stars = true
    /// The slow drift. Off behind the working view: the background is
    /// mostly covered there, and every redraw costs GPU and battery.
    var animated = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Settings → Оформление.
    @AppStorage(AppearanceSettings.meteorsKey) private var meteorsOn = true
    @AppStorage(AppearanceSettings.skyKey) private var skyOn = true

    var body: some View {
        ZStack {
            Theme.background
            if scheme == .light {
                // Daylight sky: the pearl ground cools toward a pale steel
                // blue at the top, so faint stars still have something to
                // glow against.
                LinearGradient(colors: [Color(uiColor: UIColor(hex: 0xDDE3EC)).opacity(0.9 * intensity), .clear],
                               startPoint: .top, endPoint: .center)
            }
            if reduceMotion || !animated || !skyOn {
                glows(t: 0)
            } else {
                // Drift cycles take about a minute: 6 frames a second is smooth.
                TimelineView(.animation(minimumInterval: 1 / 6)) { ctx in
                    glows(t: ctx.date.timeIntervalSinceReferenceDate)
                }
            }
            if stars {
                Starfield(animated: !reduceMotion && animated && skyOn, light: scheme == .light).opacity(intensity)
                if !reduceMotion && meteorsOn { MeteorShower(light: scheme == .light).opacity(min(1, intensity * 1.4)) }
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
            TimelineView(.animation(minimumInterval: 1 / 4)) { ctx in canvas(t: ctx.date.timeIntervalSinceReferenceDate) }
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
                    let color = i % 3 == 0 ? Color(uiColor: UIColor(hex: 0x8C7FB8)) : Color(uiColor: UIColor(hex: 0x5F7FA3))
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
        TimelineView(.animation(minimumInterval: 1 / 12, paused: reduceMotion)) { ctx in
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
        // .task lives exactly as long as the view and restarts with it, so
        // the shower never quietly stops.
        .task {
            var rng = SplitMix(seed: UInt64(Date().timeIntervalSince1970 * 1000) & 0xFFFF_FFFF)
            try? await Task.sleep(nanoseconds: UInt64((5 + rng.unit() * 7) * 1e9))
            while !Task.isCancelled {
                let count = rng.unit() < 0.2 ? (rng.unit() < 0.3 ? 3 : 2) : 1
                for k in 0..<count {
                    let leftToRight = rng.unit() < 0.5
                    let m = Meteor(start: CGPoint(x: 0.12 + rng.unit() * 0.76, y: 0.05 + rng.unit() * 0.45),
                                   angle: (leftToRight ? 0.34 : .pi - 0.34) + (rng.unit() - 0.5) * 0.3,
                                   length: 110 + CGFloat(rng.unit()) * 120,
                                   travel: 300 + CGFloat(rng.unit()) * 260,
                                   duration: 1.0 + rng.unit() * 0.5)
                    meteors.append(m)
                    if k < count - 1 { try? await Task.sleep(nanoseconds: UInt64((0.25 + rng.unit() * 0.6) * 1e9)) }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                meteors.removeAll()
                // Next one in 30–40 seconds.
                try? await Task.sleep(nanoseconds: UInt64((28 + rng.unit() * 10) * 1e9))
            }
        }
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
        let core: Color = light ? Color(uiColor: UIColor(hex: 0x4E6E93)) : .white
        let glow: Color = light ? Color(uiColor: UIColor(hex: 0x9C8CD0)) : Theme.nacre[0]
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
                        style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            Circle().fill(core).frame(width: 2.4, height: 2.4).position(head)
                .shadow(color: glow, radius: 4)
        }
        .opacity(alpha * (light ? 0.85 : 1.0))
    }
}
