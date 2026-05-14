import SwiftUI

/// Inspector for the opportunistic pocket-mode calibration.  Surfaces the math
/// behind the single `pocketGain` number — distribution of per-cell ratios, top
/// contributing cells, recent rides' detector results, algorithm constants in
/// effect.  Lets the user export the full diagnostic as JSON for offline review.
///
/// Recomputes the diagnostics on appear (cheap; sub-millisecond).  Doesn't touch
/// the persisted `CalibrationStore.calibration` — that only updates on save /
/// delete via the existing `recompute(from:)` path.
struct CalibrationInspectorView: View {
    @Bindable var calibration: CalibrationStore
    @Bindable var store: RideStore

    @State private var diagnostics: CalibrationDiagnostics?
    @State private var exportFileURL: URL?

    var body: some View {
        Form {
            if let d = diagnostics {
                summarySection(d)
                distributionSection(d)
                coverageSection(d)
                topCellsSection(d)
                recentDetectionsSection(d)
                thresholdsSection(d)
                exportSection
            } else {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Computing diagnostics…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Calibration Inspector")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Run on a Task to avoid blocking view appearance on large ride sets.
            // The compute is still on MainActor (CalibrationStore is MainActor),
            // but wrapping in a Task lets SwiftUI render the loading state first.
            let d = calibration.computeDiagnostics(from: store.rides)
            diagnostics = d
            writeExportFile(d)
        }
    }

    // MARK: - Sections

    private func summarySection(_ d: CalibrationDiagnostics) -> some View {
        Section {
            row("Current gain", value: String(format: "%.3f×", d.currentGain))
            row("Confidence", value: "\(d.currentConfidence) cells")
            if let m = d.unclampedMedian {
                row("Unclamped median", value: String(format: "%.3f×", m))
                if abs(m - d.currentGain) > 0.0005 {
                    row("Clamped by", value: clampDirection(median: m, gain: d.currentGain))
                }
            }
            if let date = d.lastPersistedAt {
                row("Last persisted", value: Self.relativeFormatter.localizedString(for: date, relativeTo: Date()))
            } else {
                row("Last persisted", value: "Never")
            }
        } header: {
            Text("Summary")
        } footer: {
            Text("Gain is applied to pocket-mode samples in the Bump Map and on the server when confidence ≥ \(d.thresholds.minOverlappingCells). Below that, no correction is applied.")
        }
    }

    private func distributionSection(_ d: CalibrationDiagnostics) -> some View {
        Section {
            if let min = d.minRatio, let max = d.maxRatio, let mean = d.meanRatio, let std = d.stdDev {
                row("Min ratio", value: String(format: "%.3f", min))
                row("Median (clamped → gain)", value: String(format: "%.3f", d.currentGain))
                row("Max ratio", value: String(format: "%.3f", max))
                row("Mean", value: String(format: "%.3f", mean))
                row("Std dev", value: String(format: "%.3f", std))
            } else {
                Text("No qualifying cells yet.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Per-cell ratio distribution")
        } footer: {
            Text("Each qualifying cell contributes one ratio (mounted avg ÷ pocket avg). The gain is the median, clamped to [\(String(format: "%.1f", d.thresholds.minGain)), \(String(format: "%.1f", d.thresholds.maxGain))].")
        }
    }

    private func coverageSection(_ d: CalibrationDiagnostics) -> some View {
        Section {
            row("Mounted samples", value: Self.numberFormatter.string(from: NSNumber(value: d.totalMountedSamples)) ?? "0")
            row("Pocket samples", value: Self.numberFormatter.string(from: NSNumber(value: d.totalPocketSamples)) ?? "0")
            row("Cells touched", value: Self.numberFormatter.string(from: NSNumber(value: d.totalCellsTouched)) ?? "0")
            row("Cells with both modes", value: Self.numberFormatter.string(from: NSNumber(value: d.cellsWithBothModes)) ?? "0")
            row("Qualifying cells", value: Self.numberFormatter.string(from: NSNumber(value: d.qualifyingCells)) ?? "0")
        } header: {
            Text("Coverage")
        } footer: {
            Text("\"Qualifying\" means ≥ \(d.thresholds.minSamplesPerMode) samples in each mode and a pocket average above \(String(format: "%.3f", d.thresholds.minPocketAvg)) g.")
        }
    }

    @ViewBuilder
    private func topCellsSection(_ d: CalibrationDiagnostics) -> some View {
        if !d.topCells.isEmpty {
            Section {
                ForEach(Array(d.topCells.prefix(15).enumerated()), id: \.offset) { _, cell in
                    cellRow(cell)
                }
                if d.topCells.count > 15 {
                    Text("+\(d.topCells.count - 15) more in the JSON export")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Top cells by sample count")
            } footer: {
                Text("Cells where you've ridden in both modes, sorted by total sample count. The most reliable contributions to the median.")
            }
        }
    }

    @ViewBuilder
    private func recentDetectionsSection(_ d: CalibrationDiagnostics) -> some View {
        if !d.recentDetections.isEmpty {
            Section {
                ForEach(d.recentDetections, id: \.rideId) { snapshot in
                    detectionRow(snapshot)
                }
            } header: {
                Text("Recent rides — auto-detect")
            } footer: {
                Text("`MountStyleDetector` ratio (cadence-band RMS ÷ bump-band RMS) for your most recent rides. > \(String(format: "%.1f", MountStyleDetector.likelyPocketThreshold)) → likely pocket; < \(String(format: "%.1f", MountStyleDetector.likelyMountedThreshold)) → likely mounted.")
            }
        }
    }

    private func thresholdsSection(_ d: CalibrationDiagnostics) -> some View {
        Section {
            row("minSamplesPerMode", value: "\(d.thresholds.minSamplesPerMode)")
            row("minOverlappingCells", value: "\(d.thresholds.minOverlappingCells)")
            row("minPocketAvg", value: String(format: "%.3f g", d.thresholds.minPocketAvg))
            row("Gain clamp", value: "[\(String(format: "%.1f", d.thresholds.minGain)), \(String(format: "%.1f", d.thresholds.maxGain))]")
            row("Detector pocket threshold", value: String(format: "%.2f", MountStyleDetector.likelyPocketThreshold))
            row("Detector mounted threshold", value: String(format: "%.2f", MountStyleDetector.likelyMountedThreshold))
        } header: {
            Text("Algorithm constants")
        } footer: {
            Text("Hard-coded in the iOS app. Changing them requires a build update.")
        }
    }

    private var exportSection: some View {
        Section {
            if let url = exportFileURL {
                ShareLink(item: url, preview: SharePreview("Calibration diagnostics", icon: Image(systemName: "doc.text"))) {
                    Label("Export full diagnostics", systemImage: "square.and.arrow.up")
                }
            } else {
                Text("Preparing export…")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Export")
        } footer: {
            Text("Pretty-printed JSON containing everything above plus cell centroids and per-ride detector breakdowns. Useful for offline analysis or sharing for debugging. Includes location data from your rides — review before sharing.")
        }
    }

    // MARK: - Row builders

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.callout)
            Spacer()
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func cellRow(_ cell: CalibrationDiagnostics.CellEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(String(format: "%.5f, %.5f", cell.latitude, cell.longitude))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if let r = cell.ratio {
                    Text(String(format: "%.3f×", r))
                        .font(.callout.monospacedDigit().weight(.medium))
                        .foregroundStyle(cell.qualifies ? .primary : .secondary)
                } else {
                    Text("—")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 12) {
                Text("M: \(cell.mountedCount) · \(String(format: "%.2fg", cell.mountedAverage))")
                Text("P: \(cell.pocketCount) · \(String(format: "%.2fg", cell.pocketAverage))")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func detectionRow(_ snapshot: CalibrationDiagnostics.RideDetectionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(snapshot.rideTitle)
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                if let verdict = snapshot.detectorVerdict {
                    Text(verdictLabel(verdict))
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(verdictColor(verdict).opacity(0.2))
                        .clipShape(Capsule())
                        .foregroundStyle(verdictColor(verdict))
                } else {
                    Text("—")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 10) {
                Text(snapshot.pocketMode == true ? "Tagged: pocket"
                     : snapshot.pocketMode == false ? "Tagged: mounted"
                     : "Tagged: —")
                if let ratio = snapshot.detectorRatio {
                    Text(String(format: "ratio %.2f", ratio))
                }
                if let c = snapshot.cadenceRMS, let b = snapshot.bumpRMS {
                    Text(String(format: "c %.3f / b %.3f", c, b))
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func verdictLabel(_ v: MountStyleDetector.Verdict) -> String {
        switch v {
        case .likelyPocket: return "Pocket"
        case .likelyMounted: return "Mounted"
        case .ambiguous: return "Ambiguous"
        }
    }

    private func verdictColor(_ v: MountStyleDetector.Verdict) -> Color {
        switch v {
        case .likelyPocket: return .orange
        case .likelyMounted: return .blue
        case .ambiguous: return .secondary
        }
    }

    private func clampDirection(median: Double, gain: Double) -> String {
        if median < gain { return "lower bound (\(String(format: "%.1f", median)) → \(String(format: "%.1f", gain)))" }
        if median > gain { return "upper bound (\(String(format: "%.1f", median)) → \(String(format: "%.1f", gain)))" }
        return "—"
    }

    // MARK: - Export

    private func writeExportFile(_ d: CalibrationDiagnostics) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(d) else { return }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        let stamp = formatter.string(from: d.computedAt).replacingOccurrences(of: ":", with: "")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bumpyride-calibration-\(stamp).json")
        if (try? data.write(to: url, options: .atomic)) != nil {
            exportFileURL = url
        }
    }

    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()
}
