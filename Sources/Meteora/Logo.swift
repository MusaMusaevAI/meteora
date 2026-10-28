import SwiftUI

/// The Meteora mark: an "M" whose first diagonal arrives as a meteor —
/// a tapering trail that fades from the accent into mother-of-pearl.
/// Words fly past; Meteora catches them and they become writing.
///
/// Geometry is defined on a 1024×1024 canvas, identical to the app icon
/// (scripts/make_icon.py).
enum LogoGeometry {
    static let a = CGPoint(x: 392, y: 802)   // left foot
    static let b = CGPoint(x: 392, y: 390)   // left peak — where the meteor lands
    static let c = CGPoint(x: 580, y: 620)   // middle valley
    static let d = CGPoint(x: 768, y: 390)   // right peak
    static let e = CGPoint(x: 768, y: 802)   // right foot
    static let stroke: CGFloat = 88
    static let tailLength: CGFloat = 380

    /// Unit vector from the left peak back along the meteor's path.
    static var tailDirection: CGVector {
        let dx = b.x - c.x, dy = b.y - c.y
        let n = (dx * dx + dy * dy).squareRoot()
        return CGVector(dx: dx / n, dy: dy / n)
    }
}

struct LogoMark: View {
    var color: Color = Theme.accent
    /// Draw the meteor trail (off for tiny sizes, where it turns to noise).
    var trail = true

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 1024
            let ox = (size.width - 1024 * s) / 2, oy = (size.height - 1024 * s) / 2
            func p(_ q: CGPoint) -> CGPoint { CGPoint(x: ox + q.x * s, y: oy + q.y * s) }
            let g = LogoGeometry.self

            if trail {
                let u = g.tailDirection
                let tip = CGPoint(x: g.b.x + u.dx * g.tailLength, y: g.b.y + u.dy * g.tailLength)
                let r = g.stroke / 2
                // Taper: a half circle around the peak narrowing to a point.
                let nx = -u.dy * r, ny = u.dx * r
                var tail = Path()
                tail.move(to: p(CGPoint(x: g.b.x + nx, y: g.b.y + ny)))
                tail.addQuadCurve(to: p(tip), control: p(CGPoint(x: g.b.x + nx * 0.5 + u.dx * g.tailLength * 0.55,
                                                                 y: g.b.y + ny * 0.5 + u.dy * g.tailLength * 0.55)))
                tail.addQuadCurve(to: p(CGPoint(x: g.b.x - nx, y: g.b.y - ny)),
                                  control: p(CGPoint(x: g.b.x - nx * 0.5 + u.dx * g.tailLength * 0.55,
                                                     y: g.b.y - ny * 0.5 + u.dy * g.tailLength * 0.55)))
                tail.addArc(center: p(g.b), radius: r * s,
                            startAngle: .radians(atan2(-ny, -nx)), endAngle: .radians(atan2(ny, nx)), clockwise: false)
                tail.closeSubpath()
                ctx.fill(tail, with: .linearGradient(
                    Gradient(stops: [
                        .init(color: color, location: 0),
                        .init(color: Theme.nacre[0].opacity(0.95), location: 0.30),
                        .init(color: Theme.nacre[1].opacity(0.75), location: 0.55),
                        .init(color: Theme.nacre[2].opacity(0.45), location: 0.78),
                        .init(color: Theme.nacre[3].opacity(0.0), location: 1),
                    ]),
                    startPoint: p(g.b), endPoint: p(tip)))
            }

            var m = Path()
            m.move(to: p(g.a)); m.addLine(to: p(g.b)); m.addLine(to: p(g.c)); m.addLine(to: p(g.d)); m.addLine(to: p(g.e))
            ctx.stroke(m, with: .color(color),
                       style: StrokeStyle(lineWidth: g.stroke * s, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
