import SwiftUI

struct SeismographView: View {
    var samples: [Float]
    var bumpiness: Double
    var capacity: Int
    var settings: AppSettings

    private let verticalScale: Double = 1.5

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.85))

                gridLines(in: geo.size)

                waveform(in: geo.size)
                    .stroke(settings.color(for: bumpiness), lineWidth: 1.5)

                VStack {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("BUMPINESS")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.6))
                            Text(String(format: "%.2f g", bumpiness))
                                .font(.title2.monospacedDigit().weight(.semibold))
                                .foregroundStyle(settings.color(for: bumpiness))
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    Spacer()
                }
            }
        }
    }

    private func gridLines(in size: CGSize) -> some View {
        Path { path in
            let midY = size.height / 2
            path.move(to: CGPoint(x: 0, y: midY))
            path.addLine(to: CGPoint(x: size.width, y: midY))
        }
        .stroke(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
    }

    private func waveform(in size: CGSize) -> Path {
        Path { path in
            guard capacity > 1 else { return }
            let midY = size.height / 2
            let half = size.height / 2 - 8
            let step = size.width / CGFloat(capacity - 1)

            let offset = capacity - samples.count
            var started = false
            for (i, s) in samples.enumerated() {
                let x = CGFloat(offset + i) * step
                let clamped = max(-verticalScale, min(verticalScale, Double(s)))
                let y = midY - CGFloat(clamped / verticalScale) * half
                let p = CGPoint(x: x, y: y)
                if !started {
                    path.move(to: p)
                    started = true
                } else {
                    path.addLine(to: p)
                }
            }
        }
    }
}
