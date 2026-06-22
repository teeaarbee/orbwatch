import SwiftUI

/// A tiny filled line chart of recent CPU samples, auto-scaled to its own peak
/// (min ceiling so idle workloads stay flat, not noisy).
struct Sparkline: View {
    let values: [Double]
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let peak = max(values.max() ?? 1, 10)
            let pts = points(in: CGSize(width: w, height: h), peak: peak)

            ZStack {
                if pts.count > 1 {
                    // Soft fill under the line.
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: h))
                        for pt in pts { p.addLine(to: pt) }
                        p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: h))
                        p.closeSubpath()
                    }
                    .fill(tint.opacity(0.18))

                    Path { p in
                        p.move(to: pts[0])
                        for pt in pts.dropFirst() { p.addLine(to: pt) }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.5,
                                                     lineJoin: .round))
                }
            }
        }
        .frame(minWidth: 60, minHeight: 18)
    }

    private func points(in size: CGSize, peak: Double) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let stepX = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { i, v in
            let y = size.height - CGFloat(min(v, peak) / peak) * size.height
            return CGPoint(x: CGFloat(i) * stepX, y: y)
        }
    }
}
