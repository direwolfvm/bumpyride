import SwiftUI
import CoreLocation

/// v2.0 Q2: dedicated full-screen ride editor — trim a ride down to a
/// slice, or split it into two rides at a chosen point.  Presented as a
/// `fullScreenCover` from the viewer's ellipsis menu ("Edit Ride…"),
/// keeping the ride summary itself uncluttered.
///
/// Layout: a live map preview of what the edit will keep, the bumpiness
/// chart with the kept range highlighted, a Trim/Split mode picker, and
/// per-mode controls with live distance/duration readouts so the rider
/// can see exactly what each half gets before committing.
///
/// Commit contract (unchanged from v1.x): `onCommit(updated, second)` —
/// `second` is non-nil only for splits.  The caller re-runs brake
/// detection on the new points, saves both, updates the viewer, and
/// invalidates the score cache (content changed → server re-scores on
/// re-upload).  The model layer (`Ride.trimmed` / `split`) partitions
/// user events by the new time bounds and stamps `editedAt`.
struct EditRideView: View {
    let original: Ride
    let settings: AppSettings
    var onCommit: (_ updated: Ride, _ newSecondRide: Ride?) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable {
        case trim = "Trim"
        case split = "Split"
    }

    @State private var mode: Mode = .trim
    @State private var startIdx: Int = 0
    @State private var endIdx: Int = 0
    @State private var splitIdx: Int = 0

    private var maxIndex: Int { max(0, original.points.count - 1) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    // Live preview of what the edit keeps: the trimmed
                    // slice, or (in split mode) the full route with the
                    // split point highlighted.
                    RouteMapView(
                        points: previewPoints,
                        followUser: false,
                        highlightIndex: mode == .split ? splitPreviewHighlight : nil,
                        settings: settings,
                        colorRoute: true
                    )
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    SessionBumpinessChart(
                        points: original.points,
                        scrubIndex: mode == .trim ? startIdx : splitIdx,
                        zoom: 1.0,
                        settings: settings
                    )
                    .frame(height: 110)

                    rangeBar
                        .frame(height: 14)

                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if maxIndex >= 2 {
                        switch mode {
                        case .trim: trimControls
                        case .split: splitControls
                        }
                    } else {
                        Text("This ride is too short to edit.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 12)
                    }

                    Text("Edits replace the synced copy on bumpyride.me — the ride re-uploads and is re-scored. Apple Health exports are not modified.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .navigationTitle("Edit Ride")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                endIdx = maxIndex
                splitIdx = maxIndex / 2
            }
        }
    }

    // MARK: - Preview helpers

    /// Trim mode previews the kept slice; split mode previews the whole
    /// route (both halves survive) with the boundary highlighted.
    private var previewPoints: [RidePoint] {
        switch mode {
        case .trim:
            guard maxIndex >= 1, startIdx <= endIdx else { return original.points }
            return Array(original.points[startIdx...endIdx])
        case .split:
            return original.points
        }
    }

    /// Highlight index into `previewPoints` for split mode (identical
    /// indexing since split previews the full array).
    private var splitPreviewHighlight: Int? {
        original.points.indices.contains(splitIdx) ? splitIdx : nil
    }

    /// Kept-range bar under the chart: full-width track, tinted span
    /// for the slice being kept (trim) or a boundary tick (split).
    private var rangeBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                if maxIndex > 0 {
                    switch mode {
                    case .trim:
                        let startFrac = CGFloat(startIdx) / CGFloat(maxIndex)
                        let endFrac = CGFloat(endIdx) / CGFloat(maxIndex)
                        Capsule()
                            .fill(Color.green)
                            .frame(width: max(3, (endFrac - startFrac) * geo.size.width))
                            .offset(x: startFrac * geo.size.width)
                    case .split:
                        let frac = CGFloat(splitIdx) / CGFloat(maxIndex)
                        Capsule().fill(Color.blue)
                            .frame(width: geo.size.width * frac)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.orange)
                            .frame(width: 3)
                            .offset(x: frac * geo.size.width - 1.5)
                    }
                }
            }
        }
    }

    // MARK: - Trim

    private var trimControls: some View {
        VStack(spacing: 12) {
            labeledSlider(
                label: "Start",
                time: timeLabel(startIdx),
                value: Binding(
                    get: { Double(startIdx) },
                    set: { startIdx = min(Int($0.rounded()), endIdx) }
                )
            )
            labeledSlider(
                label: "End",
                time: timeLabel(endIdx),
                value: Binding(
                    get: { Double(endIdx) },
                    set: { endIdx = max(Int($0.rounded()), startIdx) }
                )
            )

            Text("Keeping \(Formatters.distance(distanceMeters(from: startIdx, to: endIdx))) · \(durationLabel(from: startIdx, to: endIdx)) of \(Formatters.distance(original.distanceMeters)) · \(Formatters.duration(original.duration))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                onCommit(original.trimmed(startIndex: startIdx, endIndex: endIdx), nil)
                dismiss()
            } label: {
                Label("Apply Trim", systemImage: "crop")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(startIdx == 0 && endIdx == maxIndex)
        }
    }

    // MARK: - Split

    private var splitControls: some View {
        VStack(spacing: 12) {
            labeledSlider(
                label: "Split at",
                time: timeLabel(splitIdx),
                value: Binding(
                    get: { Double(splitIdx) },
                    set: { splitIdx = min(max(Int($0.rounded()), 1), max(1, maxIndex - 1)) }
                )
            )

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Part 1")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(Formatters.distance(distanceMeters(from: 0, to: max(0, splitIdx - 1)))) · \(durationLabel(from: 0, to: max(0, splitIdx - 1)))")
                        .font(.caption.monospacedDigit())
                }
                Divider().frame(height: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Part 2")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(Formatters.distance(distanceMeters(from: splitIdx, to: maxIndex))) · \(durationLabel(from: splitIdx, to: maxIndex))")
                        .font(.caption.monospacedDigit())
                }
                Spacer()
            }

            Button {
                guard let (first, second) = original.split(at: splitIdx) else { return }
                onCommit(first, second)
                dismiss()
            } label: {
                Label("Split into Two Rides", systemImage: "scissors")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(splitIdx <= 0 || splitIdx >= maxIndex)
        }
    }

    // MARK: - Shared controls

    private func labeledSlider(label: String, time: String, value: Binding<Double>) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...Double(max(1, maxIndex)), step: 1)
        }
    }

    // MARK: - Readout math

    /// Slice distance without materializing a points sub-array — this
    /// runs on every slider tick.
    private func distanceMeters(from lo: Int, to hi: Int) -> Double {
        let pts = original.points
        guard lo < hi, pts.indices.contains(lo), pts.indices.contains(hi) else { return 0 }
        var total: Double = 0
        for i in (lo + 1)...hi {
            let a = CLLocation(latitude: pts[i - 1].latitude, longitude: pts[i - 1].longitude)
            let b = CLLocation(latitude: pts[i].latitude, longitude: pts[i].longitude)
            total += b.distance(from: a)
        }
        return total
    }

    private func durationLabel(from lo: Int, to hi: Int) -> String {
        let pts = original.points
        guard pts.indices.contains(lo), pts.indices.contains(hi), lo <= hi else { return "—" }
        return Formatters.duration(max(0, pts[hi].timestamp.timeIntervalSince(pts[lo].timestamp)))
    }

    private func timeLabel(_ idx: Int) -> String {
        guard original.points.indices.contains(idx) else { return "—" }
        let t = original.points[idx].timestamp.timeIntervalSince(original.startedAt)
        return Formatters.duration(max(0, t))
    }
}
