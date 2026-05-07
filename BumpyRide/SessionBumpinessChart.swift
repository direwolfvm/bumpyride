import SwiftUI

/// Static bumpiness-vs-position chart shown in the Ride tab during playback of a
/// saved ride.  Honors a zoom level (1.0 = whole ride, smaller = a tighter window
/// centered on the scrubber) so the user can inspect a specific segment closely.
struct SessionBumpinessChart: View {
    var points: [RidePoint]
    var scrubIndex: Int
    var zoom: Double
    var settings: AppSettings

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.85))

                gridLines(in: geo.size)

                Canvas { ctx, size in
                    guard !points.isEmpty else { return }
                    let window = visibleWindow()
                    let visibleCount = window.upperBound - window.lowerBound
                    guard visibleCount > 0 else { return }

                    let barWidth = size.width / CGFloat(visibleCount)
                    let topG = max(0.5, settings.topG)

                    for i in window {
                        let p = points[i]
                        let x = CGFloat(i - window.lowerBound) * barWidth
                        let norm = min(1.0, p.bumpiness / topG)
                        let h = CGFloat(norm) * (size.height - 16)
                        let rect = CGRect(x: x + 0.5, y: size.height - h, width: max(1, barWidth - 1), height: h)
                        ctx.fill(Path(rect), with: .color(settings.color(for: p.bumpiness)))
                    }

                    if window.contains(scrubIndex) {
                        let x = (CGFloat(scrubIndex - window.lowerBound) + 0.5) * barWidth
                        let line = Path { p in
                            p.move(to: CGPoint(x: x, y: 0))
                            p.addLine(to: CGPoint(x: x, y: size.height))
                        }
                        ctx.stroke(line, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
                    }
                }
                .padding(.top, 28)
                .padding(.horizontal, 4)
                .padding(.bottom, 4)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("BUMPINESS")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.6))
                            HStack(spacing: 6) {
                                if let p = currentPoint() {
                                    Text(String(format: "%.2f g", p.bumpiness))
                                        .font(.title3.monospacedDigit().weight(.semibold))
                                        .foregroundStyle(settings.color(for: p.bumpiness))
                                } else {
                                    Text("—")
                                        .font(.title3.monospacedDigit())
                                        .foregroundStyle(.white)
                                }
                                Spacer()
                                Text(String(format: "top %.1fg", max(0.5, settings.topG)))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
        }
    }

    private func currentPoint() -> RidePoint? {
        guard points.indices.contains(scrubIndex) else { return nil }
        return points[scrubIndex]
    }

    private func visibleWindow() -> Range<Int> {
        let n = points.count
        guard n > 0 else { return 0..<0 }
        let z = min(1.0, max(0.05, zoom))
        let visibleCount = max(4, Int((Double(n) * z).rounded()))
        if visibleCount >= n { return 0..<n }
        let half = visibleCount / 2
        var lower = scrubIndex - half
        var upper = lower + visibleCount
        if lower < 0 { lower = 0; upper = visibleCount }
        if upper > n { upper = n; lower = n - visibleCount }
        return lower..<upper
    }

    private func gridLines(in size: CGSize) -> some View {
        Path { path in
            for i in 1..<4 {
                let y = size.height * CGFloat(i) / 4
                path.move(to: CGPoint(x: 8, y: y))
                path.addLine(to: CGPoint(x: size.width - 8, y: y))
            }
        }
        .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
    }
}
