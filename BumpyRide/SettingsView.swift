import SwiftUI

/// The Settings tab.  Shows a live preview of the bumpiness color gradient, sliders
/// for the four threshold breakpoints (each constrained to stay ordered relative to
/// its neighbors), the Pocket Mode toggle, a Web Account row that pushes into the
/// `WebAccountView` pairing UI, and a reset-to-defaults button.
struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var webAccount: WebAccount
    @Bindable var syncCoordinator: SyncCoordinator
    @Bindable var syncQueue: SyncQueue
    @Bindable var calibration: CalibrationStore
    @Bindable var store: RideStore

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    preview
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                } header: {
                    Text("Color Scale Preview")
                } footer: {
                    Text("Map segments and bumpiness readouts use this scale. Thresholds are in g (1 g ≈ gravity).")
                }

                Section("Thresholds") {
                    thresholdRow(
                        label: "Yellow at",
                        color: settings.color(for: settings.yellowG),
                        value: $settings.yellowG,
                        range: 0.1...settings.orangeG - 0.05
                    )
                    thresholdRow(
                        label: "Orange at",
                        color: settings.color(for: settings.orangeG),
                        value: $settings.orangeG,
                        range: (settings.yellowG + 0.05)...(settings.redG - 0.05)
                    )
                    thresholdRow(
                        label: "Red at",
                        color: settings.color(for: settings.redG),
                        value: $settings.redG,
                        range: (settings.orangeG + 0.05)...(settings.purpleG - 0.05)
                    )
                    thresholdRow(
                        label: "Purple at",
                        color: settings.color(for: settings.purpleG),
                        value: $settings.purpleG,
                        range: (settings.redG + 0.05)...5.0
                    )
                }

                Section {
                    calibrationStatusRow
                    NavigationLink {
                        CalibrationInspectorView(calibration: calibration, store: store)
                    } label: {
                        Label("Calibration Inspector", systemImage: "chart.bar.doc.horizontal")
                    }
                } header: {
                    Text("Sensing")
                } footer: {
                    Text("Pocket mode applies a 3 Hz high-pass to the vertical-acceleration channel so the rider's pedaling cadence (≈1–2 Hz) doesn't register as bumpiness. Toggle it per ride from the Ride tab; auto-detect catches mistagged rides at save time.\n\nCalibration is opportunistic: every time you save a ride, the app looks for cells you've ridden in both modes and derives a per-rider correction. The Bump Map applies it automatically once enough overlap accumulates.")
                }

                Section {
                    NavigationLink {
                        WebAccountView(
                            account: webAccount,
                            syncCoordinator: syncCoordinator,
                            syncQueue: syncQueue
                        )
                    } label: {
                        webAccountRow
                    }
                } header: {
                    Text("Web Account")
                } footer: {
                    Text("Connect a bumpyride.me account to back up rides off-device. Token-only — your password never leaves the web app.")
                }

                Section {
                    Button(role: .destructive) {
                        settings.resetToDefaults()
                    } label: {
                        Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                Canvas { ctx, size in
                    let steps = 160
                    let maxG = max(0.5, settings.purpleG) * 1.05
                    for i in 0..<steps {
                        let t = Double(i) / Double(steps - 1)
                        let g = t * maxG
                        let x = CGFloat(t) * size.width
                        let w = size.width / CGFloat(steps) + 0.5
                        let rect = CGRect(x: x, y: 0, width: w, height: size.height)
                        ctx.fill(Path(rect), with: .color(settings.color(for: g)))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .frame(height: 22)

            HStack {
                Text("0 g")
                Spacer()
                Text(String(format: "%.1f g", max(0.5, settings.purpleG) * 1.05))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var calibrationStatusRow: some View {
        HStack(spacing: 12) {
            Image(systemName: calibration.hasCalibration ? "checkmark.seal.fill" : "hourglass")
                .font(.title3)
                .foregroundStyle(calibration.hasCalibration ? Color.green : Color.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pocket calibration")
                    .font(.body)
                Text(calibrationDetailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var calibrationDetailText: String {
        if calibration.hasCalibration {
            return String(
                format: "Pocket × %.2f · %d overlapping cells",
                calibration.calibration.pocketGain,
                calibration.calibration.confidence
            )
        }
        return "Not enough overlap yet — needs ≥ \(CalibrationStore.minOverlappingCells) cells ridden in both modes."
    }

    private var webAccountRow: some View {
        HStack(spacing: 12) {
            Image(systemName: webAccount.isConnected ? "person.crop.circle.fill.badge.checkmark" : "person.crop.circle.badge.plus")
                .font(.title3)
                .foregroundStyle(webAccount.isConnected ? Color.green : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(webAccount.isConnected ? "Connected" : "Not connected")
                    .font(.body)
                Text(webAccountRowDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// Secondary line in the Web Account row.  Prefers showing live sync state when
    /// there's something interesting to report; otherwise falls back to the user's
    /// email (when connected) or the brand name (when not).
    private var webAccountRowDetail: String {
        switch syncCoordinator.state {
        case .syncing(let remaining):
            return remaining == 1 ? "Syncing 1 ride" : "Syncing \(remaining) rides"
        case .paused:
            return "Sync paused — will retry"
        case .waitingForAuth:
            if syncQueue.count > 0 {
                return "\(syncQueue.count) ride\(syncQueue.count == 1 ? "" : "s") waiting to sync"
            }
            return "Sign in to sync"
        case .idle:
            if let email = webAccount.connectedEmail {
                return email
            }
            return "bumpyride.me"
        }
    }

    private func thresholdRow(label: String, color: Color, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 4).fill(color).frame(width: 22, height: 16)
                Text(label)
                Spacer()
                Text(String(format: "%.2f g", value.wrappedValue))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: safeRange(range), step: 0.05)
        }
    }

    private func safeRange(_ r: ClosedRange<Double>) -> ClosedRange<Double> {
        let lo = min(r.lowerBound, r.upperBound)
        let hi = max(r.lowerBound, r.upperBound)
        if lo == hi { return lo...(hi + 0.05) }
        return lo...hi
    }
}
