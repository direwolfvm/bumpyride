import SwiftUI

struct EditRideView: View {
    let original: Ride
    let settings: AppSettings
    var onCommit: (_ updated: Ride, _ newSecondRide: Ride?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var startIdx: Int = 0
    @State private var endIdx: Int = 0
    @State private var scrubIdx: Int = 0
    @State private var zoom: Double = 1.0

    private var maxIndex: Int { max(0, original.points.count - 1) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                SessionBumpinessChart(
                    points: original.points,
                    scrubIndex: scrubIdx,
                    zoom: zoom,
                    settings: settings
                )
                .frame(height: 140)

                trimPreview
                    .frame(height: 18)

                scrubControls

                Divider()

                actionButtons

                Spacer()
            }
            .padding(16)
            .navigationTitle("Edit Ride")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply Trim") { applyTrim() }
                        .disabled(startIdx == 0 && endIdx == maxIndex)
                }
            }
            .onAppear {
                endIdx = maxIndex
                scrubIdx = 0
            }
        }
    }

    private var trimPreview: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                if maxIndex > 0 {
                    let startFrac = CGFloat(startIdx) / CGFloat(maxIndex)
                    let endFrac = CGFloat(endIdx) / CGFloat(maxIndex)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(2, (endFrac - startFrac) * geo.size.width))
                        .offset(x: startFrac * geo.size.width)
                }
            }
        }
    }

    private var scrubControls: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Position")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(timeLabel(for: scrubIdx))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(scrubIdx) },
                    set: { scrubIdx = Int($0.rounded()) }
                ),
                in: 0...Double(maxIndex),
                step: 1
            )

            HStack {
                Text("Zoom")
                    .font(.caption).foregroundStyle(.secondary)
                Slider(value: $zoom, in: 0.05...1.0)
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    startIdx = min(scrubIdx, endIdx)
                } label: {
                    Label("Trim Before", systemImage: "arrow.left.to.line")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    endIdx = max(scrubIdx, startIdx)
                } label: {
                    Label("Trim After", systemImage: "arrow.right.to.line")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Button {
                resetTrim()
            } label: {
                Label("Reset Trim", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(startIdx == 0 && endIdx == maxIndex)

            Button {
                splitHere()
            } label: {
                Label("Split at Position", systemImage: "scissors")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(scrubIdx <= 0 || scrubIdx >= maxIndex)
        }
    }

    private func resetTrim() {
        startIdx = 0
        endIdx = maxIndex
    }

    private func applyTrim() {
        let updated = original.trimmed(startIndex: startIdx, endIndex: endIdx)
        onCommit(updated, nil)
        dismiss()
    }

    private func splitHere() {
        guard let (first, second) = original.split(at: scrubIdx) else { return }
        onCommit(first, second)
        dismiss()
    }

    private func timeLabel(for idx: Int) -> String {
        guard original.points.indices.contains(idx) else { return "—" }
        let t = original.points[idx].timestamp.timeIntervalSince(original.startedAt)
        return "\(Formatters.duration(max(0, t))) / \(Formatters.duration(original.duration))"
    }
}
