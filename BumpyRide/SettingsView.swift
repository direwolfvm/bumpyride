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
    @Bindable var cloudStorage: CloudStorage
    @Bindable var healthKitAuth: HealthKitAuthManager
    /// Plain `let` (not `@Bindable`) — the exporter has no observable
    /// state; it's a stateless command service used by the backfill
    /// sheet.
    let healthKitExporter: HealthKitExporter
    /// Watch session owner.  Used here to gate the Apple Watch
    /// section on `isPaired` — no point surfacing watch settings to
    /// users without a paired Apple Watch.
    @Bindable var watchCoordinator: WatchCoordinator

    /// Surfaces an inline error if the HealthKit auth request itself
    /// errored (entitlement missing, OS state weird).  Different from
    /// a deny — a deny just leaves the toggle off silently.
    @State private var healthAuthErrored: Bool = false

    /// Drives the presentation of the Apple Health backfill sheet.
    @State private var showingHealthBackfillSheet: Bool = false

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
                    backupStatusRow
                } header: {
                    Text("Backup")
                } footer: {
                    Text(cloudStorage.isCloudAvailable
                        ? "Rides are stored in iCloud Drive under \"BumpyRide.\" They sync across your devices automatically and survive deleting the app — reinstalling re-attaches to the same data."
                        : "Rides are stored only on this device. Sign in to iCloud and turn on iCloud Drive in Settings to enable automatic backup and cross-device sync.")
                }

                Section {
                    NavigationLink {
                        WebAccountView(
                            account: webAccount,
                            syncCoordinator: syncCoordinator,
                            syncQueue: syncQueue,
                            store: store
                        )
                    } label: {
                        webAccountRow
                    }
                } header: {
                    Text("Web Account")
                } footer: {
                    Text("Connect a bumpyride.me account to back up rides off-device. Token-only — your password never leaves the web app.")
                }

                if healthKitAuth.isAvailable {
                    appleHealthSection
                }

                if watchCoordinator.isPaired {
                    appleWatchSection
                }

                Section {
                    Toggle(isOn: $settings.debugLogEnabled) {
                        Label("Write Debug Log", systemImage: "doc.text.magnifyingglass")
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text(cloudStorage.isCloudAvailable
                        ? "Writes a verbose log alongside each ride in iCloud Drive → BumpyRide → Rides. Per-ride file: \"<rideId>-debug.log\". Outside a ride: \"session-YYYY-MM-DD.log\". Helpful when troubleshooting a real-world ride. Files older than 14 days are cleaned up automatically."
                        : "Writes a verbose log alongside each ride in this device's Documents folder. Per-ride file: \"<rideId>-debug.log\". Outside a ride: \"session-YYYY-MM-DD.log\". Files older than 14 days are cleaned up automatically.")
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

    /// Read-only status row for ride backup.  Mirrors the style of
    /// `webAccountRow` (icon + title + secondary detail).  No action — the
    /// user enables iCloud at the OS level (Settings → Apple ID → iCloud),
    /// which is also where they'd go to fix any access issue.  We could deep-
    /// link there, but the path differs per iOS version and the system path
    /// from Settings → BumpyRide is usually faster anyway.
    private var backupStatusRow: some View {
        HStack(spacing: 12) {
            Image(systemName: cloudStorage.isCloudAvailable ? "icloud.fill" : "icloud.slash")
                .font(.title3)
                .foregroundStyle(cloudStorage.isCloudAvailable ? Color.blue : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(cloudStorage.isCloudAvailable ? "iCloud Drive" : "Local only")
                    .font(.body)
                Text(cloudStorage.isCloudAvailable
                     ? "\(store.rides.count) ride\(store.rides.count == 1 ? "" : "s") backed up"
                     : "\(store.rides.count) ride\(store.rides.count == 1 ? "" : "s") on device")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
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

    // MARK: - Apple Health

    /// "Apple Health" section.  Shown only when HealthKit is available on
    /// the device (`healthKitAuth.isAvailable`); the parent gates on that
    /// via `if`.  Internally we still need to handle three sub-states for
    /// the toggle copy:
    ///
    ///  - `.notRequested`: never asked.  Flipping on triggers the auth
    ///    sheet via the custom binding's setter.
    ///  - `.granted`: toggle behaves like any other persisted bool.
    ///  - `.denied`: the request itself errored (rare — usually a missing
    ///    entitlement).  Show an inline warning rather than retrying
    ///    silently.
    ///
    /// We deliberately do NOT detect "auth was revoked externally via
    /// Settings → Privacy & Security → Health" — Apple's HealthKit API
    /// hides that state.  The auto-export write will silently no-op if
    /// revoked; user fixes from iOS Settings.
    @ViewBuilder
    private var appleHealthSection: some View {
        Section {
            Toggle(isOn: appleHealthToggleBinding) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add new rides to Apple Health")
                        if case .requesting = healthKitAuth.state {
                            Text("Requesting access…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "heart.text.square.fill")
                        .foregroundStyle(.pink)
                }
            }
            .disabled({ if case .requesting = healthKitAuth.state { return true } else { return false } }())

            // Backfill row.  Tap opens the multi-phase sheet that adds
            // previously-recorded rides (those without
            // `healthKitWorkoutUUID`) to Apple Health.  Independent of
            // the auto-export toggle — a user can run a one-shot
            // backfill without turning auto-export on.
            Button {
                showingHealthBackfillSheet = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.up.heart.fill")
                        .font(.title3)
                        .foregroundStyle(.pink)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sync past rides to Apple Health")
                            .foregroundStyle(.primary)
                        Text(backfillRowDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if healthAuthErrored {
                Label("Couldn't enable Apple Health access. The app entitlement may be missing — try restarting BumpyRide.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        } header: {
            Text("Apple Health")
        } footer: {
            Text("""
            New rides will appear in the Fitness app as cycling workouts and count toward your activity rings. \
            BumpyRide writes the route, distance, and an estimated active-energy value based on your average speed and weight.

            If you also record rides with Apple Workout (e.g. on Apple Watch), you may want to leave this off to avoid duplicates.
            """)
        }
        .sheet(isPresented: $showingHealthBackfillSheet) {
            HealthKitBackfillSheet(
                healthKitAuth: healthKitAuth,
                healthKitExporter: healthKitExporter,
                store: store
            )
        }
    }

    // MARK: - Apple Watch

    /// "Apple Watch" section, surfaced only when a watch is paired.
    /// v1.7 Phase A: a single toggle for whether opening the iPhone
    /// app should also open the watch app and start a HealthKit
    /// workout session (the prerequisite for collecting heart rate
    /// during a ride).
    ///
    /// Phase A only stores the bit — phases C-G wire it into actual
    /// behavior (startWatchApp on the iOS side, HKWorkoutSession on
    /// the watch side, heart rate streaming back to iOS).  Until
    /// those land, toggling on/off changes nothing user-visible.
    @ViewBuilder
    private var appleWatchSection: some View {
        Section {
            Toggle(isOn: openWatchAppToggleBinding) {
                Label {
                    Text("Open watch app with this app")
                } icon: {
                    Image(systemName: "applewatch")
                        .foregroundStyle(.blue)
                }
            }
        } header: {
            Text("Apple Watch")
        } footer: {
            Text("""
            When on, opening BumpyRide on your iPhone also opens the BumpyRide watch app and starts heart-rate monitoring. \
            Heart rate is added to your ride's Apple Health workout.

            Off by default — flip on if you want auto-launch.
            """)
        }
    }

    /// Custom binding for the "Open watch app with this app" toggle.
    /// Off → on triggers `healthKitAuth.requestAuthorization()` so the
    /// user is prompted for the heart-rate read added in v1.7 (Phase F
    /// extended `HealthKitAuthManager.readTypes` to include it).  Users
    /// who granted v1.5's Apple Health auth see only the new heart-rate
    /// prompt; the others are silently kept as-is by HealthKit.
    ///
    /// The bit lands true even if the user dismisses the auth sheet
    /// without granting — the watch session will still launch, just
    /// without HR collection.  This matches the v1.7 design decision
    /// "watch session still runs, no HR collection" (Phase A
    /// confirmation question).
    private var openWatchAppToggleBinding: Binding<Bool> {
        Binding(
            get: { settings.openWatchAppOnLaunch },
            set: { newValue in
                if newValue {
                    Task {
                        await healthKitAuth.requestAuthorization()
                        settings.openWatchAppOnLaunch = true
                    }
                } else {
                    settings.openWatchAppOnLaunch = false
                }
            }
        )
    }

    /// Secondary line under "Sync past rides to Apple Health" — counts
    /// rides without a HealthKit stamp.  Computed live from the store
    /// so it always reflects the current state (Phase E per-ride
    /// exports and Phase D auto-exports both decrement this naturally
    /// as they patch the ride struct).
    private var backfillRowDetail: String {
        let unsyncedCount = store.rides.filter { $0.healthKitWorkoutUUID == nil }.count
        if unsyncedCount == 0 {
            return "All caught up"
        }
        return "\(unsyncedCount) ride\(unsyncedCount == 1 ? "" : "s") not yet in Apple Health"
    }

    /// Custom binding so the toggle's off → on transition can interpose
    /// an authorization request before persisting the bit.  Off → on is
    /// the only transition that needs special handling; on → off and the
    /// no-op cases pass through normally.
    private var appleHealthToggleBinding: Binding<Bool> {
        Binding(
            get: { settings.autoExportToAppleHealth },
            set: { newValue in
                if newValue {
                    // Off → on.
                    if healthKitAuth.canWrite {
                        // Already authorized — flip the bit immediately,
                        // no prompt.  Most subsequent toggles take this
                        // path (auth survives across toggle off/on).
                        settings.autoExportToAppleHealth = true
                        healthAuthErrored = false
                    } else {
                        // Never asked, or last attempt errored.  Fire
                        // the auth sheet and only land the bit if the
                        // user dismisses it (the user may have ticked
                        // none of the boxes, but we accept that — see
                        // HealthKitAuthManager for why we can't tell).
                        Task {
                            let granted = await healthKitAuth.requestAuthorization()
                            if granted {
                                settings.autoExportToAppleHealth = true
                                healthAuthErrored = false
                            } else {
                                // Toggle stays off — value already reflects that.
                                // Distinguish a hard error (.denied state) from a
                                // soft "user just dismissed without granting" so we
                                // can show the inline warning only when actionable.
                                if case .denied = healthKitAuth.state {
                                    healthAuthErrored = true
                                }
                            }
                        }
                    }
                } else {
                    // On → off.  Just persist.  We don't revoke
                    // HealthKit auth — user does that from iOS Settings
                    // if they want — so re-enabling later won't re-prompt.
                    settings.autoExportToAppleHealth = false
                }
            }
        )
    }
}
