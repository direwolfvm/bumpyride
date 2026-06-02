import SwiftUI

/// Modal flow for the Apple Health backfill feature.  Two visual halves:
///
/// 1. **Setup**: count the local rides without a HealthKit stamp, show
///    the user a confirmation preview (X rides will be added).  If
///    auth hasn't been granted yet, the Sync button drives that flow.
/// 2. **Run**: instantiate a `HealthKitBackfillCoordinator`, kick it
///    off, and render based on its `phase` (running / succeeded /
///    cancelled / failed).
///
/// Mirrors the visual language and state-machine style of
/// `RestoreRidesSheet`, adapted to a local-only flow (no network
/// listing step — counting unsynced rides is instant).
struct HealthKitBackfillSheet: View {
    @Bindable var healthKitAuth: HealthKitAuthManager
    let healthKitExporter: HealthKitExporter
    @Bindable var store: RideStore

    @Environment(\.dismiss) private var dismiss

    /// State machine for the setup half.  Once the user confirms in
    /// `.ready` and auth is in hand, we transition to `.running` and
    /// the body delegates to `coordinator.phase` for the rest of the
    /// flow.
    enum SheetPhase: Equatable {
        case ready(unsyncedRides: [Ride])
        case nothingToSync
        case authDenied
        case running
    }

    @State private var sheetPhase: SheetPhase
    @State private var coordinator: HealthKitBackfillCoordinator?

    init(healthKitAuth: HealthKitAuthManager, healthKitExporter: HealthKitExporter, store: RideStore) {
        self.healthKitAuth = healthKitAuth
        self.healthKitExporter = healthKitExporter
        self.store = store
        // Compute the initial phase eagerly — counting unsynced rides
        // is instant (no I/O), so there's no "Loading…" interstitial
        // to render.  Sheet opens directly into Ready or NothingToSync.
        let unsynced = store.rides.filter { $0.healthKitWorkoutUUID == nil }
        if unsynced.isEmpty {
            _sheetPhase = State(initialValue: .nothingToSync)
        } else {
            _sheetPhase = State(initialValue: .ready(unsyncedRides: unsynced))
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                switch sheetPhase {
                case .ready(let rides):
                    readyContent(rides: rides)
                case .nothingToSync:
                    nothingToSyncContent
                case .authDenied:
                    authDeniedContent
                case .running:
                    runningContent
                }
            }
            .navigationTitle("Sync to Apple Health")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if shouldShowToolbarCancel {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
            // Block swipe-to-dismiss only during the active sync so the
            // user can't accidentally orphan an in-flight Task by
            // pulling the sheet down.  They must use the explicit
            // Cancel button to abort.  Setup states and terminal states
            // are fine to dismiss freely.
            .interactiveDismissDisabled(blockInteractiveDismiss)
        }
    }

    // MARK: - Toolbar / dismiss gating

    /// Show the toolbar Cancel button while we're not in a terminal
    /// running state (terminal states already show a Done button in
    /// the body).
    private var shouldShowToolbarCancel: Bool {
        switch sheetPhase {
        case .ready, .nothingToSync, .authDenied:
            return true
        case .running:
            // Body's own Cancel/Done button handles it.
            return false
        }
    }

    /// Disable swipe-down only while the export is in flight.
    /// Cancellable, failed, and succeeded states leave the user free
    /// to dismiss with a swipe.
    private var blockInteractiveDismiss: Bool {
        guard case .running = sheetPhase else { return false }
        guard let c = coordinator else { return true }
        switch c.phase {
        case .running: return true
        case .idle, .succeeded, .cancelled, .failed: return false
        }
    }

    // MARK: - Setup phase content

    @ViewBuilder
    private func readyContent(rides: [Ride]) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text("\(rides.count) ride\(rides.count == 1 ? "" : "s") not yet in Apple Health")
                        .font(.body.weight(.semibold))
                } icon: {
                    Image(systemName: "heart.text.square.fill")
                        .foregroundStyle(.pink)
                }
                let totalDistance = rides.reduce(0) { $0 + $1.distanceMeters }
                Text("\(Formatters.distance(totalDistance)) total")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Summary")
        } footer: {
            Text("Already-exported rides are skipped automatically. Each ride becomes a cycling workout with its route, distance, and estimated active energy.")
        }

        Section {
            Button {
                startBackfill(rides: rides)
            } label: {
                Text("Sync \(rides.count) ride\(rides.count == 1 ? "" : "s")")
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var nothingToSyncContent: some View {
        Section {
            Label("All rides are already in Apple Health.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } footer: {
            Text("New rides you record from here will be added automatically if the toggle above is on.")
        }
        Section {
            Button("Done") { dismiss() }
        }
    }

    @ViewBuilder
    private var authDeniedContent: some View {
        Section {
            Label("Apple Health access wasn't granted.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } footer: {
            Text("Open Settings → Privacy & Security → Health → BumpyRide to grant access, then try again.")
        }
        Section {
            Button("Try again") {
                Task { await requestAuthThenContinue() }
            }
            Button("Cancel") { dismiss() }
        }
    }

    // MARK: - Running phase content

    @ViewBuilder
    private var runningContent: some View {
        if let c = coordinator {
            switch c.phase {
            case .idle:
                // Brief; we transition from .idle → .running
                // synchronously in start().  Shown only if SwiftUI
                // happens to render between phases.
                Section {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Preparing…").foregroundStyle(.secondary)
                    }
                }
            case .running(let idx, let total, let title):
                runningProgressContent(idx: idx, total: total, title: title, coordinator: c)
            case .succeeded(let exported, let alreadyPresent, let failed):
                succeededContent(exported: exported, alreadyPresent: alreadyPresent, failed: failed)
            case .cancelled(let exported):
                cancelledContent(exported: exported)
            case .failed(let message, let exported):
                failedContent(message: message, exported: exported)
            }
        }
    }

    @ViewBuilder
    private func runningProgressContent(idx: Int, total: Int, title: String, coordinator: HealthKitBackfillCoordinator) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                // "N of M" with +1 offset since idx is 0-based but
                // humans count from 1.
                Text("Syncing \(idx + 1) of \(total)")
                    .font(.callout.weight(.semibold))
                ProgressView(value: Double(idx), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
                    .tint(.pink)
                Text(title.isEmpty ? " " : title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.vertical, 4)
        }
        Section {
            Button(role: .destructive) {
                coordinator.cancel()
            } label: {
                Text("Cancel sync")
                    .frame(maxWidth: .infinity)
            }
        } footer: {
            Text("Already-synced rides will be kept. Cancelling stops the queue.")
        }
    }

    @ViewBuilder
    private func succeededContent(exported: Int, alreadyPresent: Int, failed: Int) -> some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Done.")
                        .font(.headline)
                    Text(succeededDescription(exported: exported, alreadyPresent: alreadyPresent))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if failed > 0 {
                        Text("\(failed) couldn't be synced and were skipped.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        Section {
            Button("Done") { dismiss() }
        }
    }

    /// Combined exported/alreadyPresent count phrasing — we don't
    /// surface "alreadyPresent" separately in the success message
    /// because from the user's POV they're identical outcomes ("rides
    /// are now reflected in Apple Health").  The split is only for
    /// internal counting; we report total added or refreshed.
    private func succeededDescription(exported: Int, alreadyPresent: Int) -> String {
        let total = exported + alreadyPresent
        if total == 0 {
            return "No rides were added."
        }
        return "\(total) ride\(total == 1 ? "" : "s") now reflected in Apple Health."
    }

    @ViewBuilder
    private func cancelledContent(exported: Int) -> some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sync cancelled.")
                        .font(.headline)
                    Text("Synced \(exported) ride\(exported == 1 ? "" : "s") before stopping.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "stop.circle.fill")
                    .foregroundStyle(.orange)
            }
        }
        Section {
            Button("Done") { dismiss() }
        }
    }

    @ViewBuilder
    private func failedContent(message: String, exported: Int) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            if exported > 0 {
                Text("Synced \(exported) ride\(exported == 1 ? "" : "s") before the failure.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        Section {
            Button("Done") { dismiss() }
        }
    }

    // MARK: - Actions

    /// Tap of the Sync button in `.ready`.  Auth-on-demand: if the
    /// user already opted in via the Settings toggle, this path skips
    /// the prompt entirely.
    private func startBackfill(rides: [Ride]) {
        Task {
            if !healthKitAuth.canWrite {
                let granted = await healthKitAuth.requestAuthorization()
                guard granted else {
                    sheetPhase = .authDenied
                    return
                }
            }
            let c = HealthKitBackfillCoordinator(exporter: healthKitExporter, store: store)
            coordinator = c
            sheetPhase = .running
            c.start(exporting: rides)
        }
    }

    /// Retry path from `.authDenied`.  Re-prompts; on success drops
    /// straight into `.running` with the still-current snapshot of
    /// unsynced rides; on continued denial keeps the user on
    /// `.authDenied`.
    private func requestAuthThenContinue() async {
        let granted = await healthKitAuth.requestAuthorization()
        guard granted else { return }
        // Recompute unsynced set in case rides were exported by other
        // paths (Phase E button) while the sheet was open.
        let unsynced = store.rides.filter { $0.healthKitWorkoutUUID == nil }
        if unsynced.isEmpty {
            sheetPhase = .nothingToSync
            return
        }
        let c = HealthKitBackfillCoordinator(exporter: healthKitExporter, store: store)
        coordinator = c
        sheetPhase = .running
        c.start(exporting: unsynced)
    }

}
