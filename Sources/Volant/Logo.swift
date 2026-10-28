import SwiftUI

/// The Volant mark: a "V" whose right stroke is solid (what is written
/// remains) and whose left stroke breaks apart into flying fragments
/// (spoken words fly away) — "Verba volant, scripta manent".
///
/// Geometry is defined on a 1024×1024 canvas, identical to the app icon.
enum LogoGeometry {
    static let vertex = CGPoint(x: 512, y: 772)
    static let rightTop = CGPoint(x: 724, y: 268)
    static let leftTop = CGPoint(x: 300, y: 268)
    static let stroke: CGFloat = 92
    /// Left-arm fragments: (from t, to t, width, offset); t = 0 at the vertex.
    static let dashes: [(CGFloat, CGFloat, CGFloat, CGPoint)] = [
        (0, 0.40, 92, .zero), (0.53, 0.72, 76, CGPoint(x: -10, y: -6)),
    ]
    /// Words flying away: (t, radius, offset).
    static let dots: [(CGFloat, CGFloat, CGPoint)] = [
        (0.87, 32, CGPoint(x: -24, y: -14)), (1.05, 20, CGPoint(x: -44, y: -28)),
    ]

    static func point(_ t: CGFloat, _ o: CGPoint = .zero) -> CGPoint {
        CGPoint(x: vertex.x + (leftTop.x - vertex.x) * t + o.x, y: vertex.y + (leftTop.y - vertex.y) * t + o.y)
    }
}

struct LogoMark: View {
    var color: Color = Theme.accent

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 1024
            let ox = (size.width - 1024 * s) / 2, oy = (size.height - 1024 * s) / 2
            func p(_ q: CGPoint) -> CGPoint { CGPoint(x: ox + q.x * s, y: oy + q.y * s) }
            func line(_ a: CGPoint, _ b: CGPoint, _ w: CGFloat) {
                var path = Path()
                path.move(to: p(a))
                path.addLine(to: p(b))
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: w * s, lineCap: .round))
            }
            line(LogoGeometry.vertex, LogoGeometry.rightTop, LogoGeometry.stroke)
            for (a, b, w, o) in LogoGeometry.dashes {
                line(LogoGeometry.point(a, o), LogoGeometry.point(b, o), w)
            }
            for (t, r0, o) in LogoGeometry.dots {
                let c = p(LogoGeometry.point(t, o)), r = r0 * s
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(color))
            }
        }
        .accessibilityHidden(true)
    }
}
