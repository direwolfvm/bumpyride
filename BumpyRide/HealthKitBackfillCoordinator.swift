import Foundation
import Observation
import OSLog

/// Orchestrates the multi-ride Apple Health backfill.  Given a list of
/// rides the caller has already filtered (and the user has confirmed),
/// iterates through them, calls `HealthKitExporter.export(_:)` for
/// each, and patches each ride's `healthKitWorkoutUUID` via
/// `RideStore.save(_:)` on success.
///
/// Mirrors `RestoreCoordinator`'s shape — same Phase enum style, same
/// cooperative-cancellation pattern, same observable progress fields.
/// Sheet UI reads `phase` and renders accordingly.
///
/// **Per-ride failure handling**: independent.  One bad ride doesn't
/// abort the whole backfill.  HealthKit writes don't have a 429 / 5xx
/// to back off from — failures are usually permanent for that ride
/// (auth revoked, malformed data, OS pressure).  We log and skip.
///
/// **Cancellation**: cooperative via `Task.isCancelled`, checked
/// before each ride.  Already-exported rides are preserved; the next
/// ride doesn't start.  Each `RideStore.save(_:)` is atomic per ride,
/// so partial state is always coherent.
///
/// **Pacing**: HealthKit writes are local-only, no rate limit to
/// respect.  We `await Task.yield()` between rides to keep the UI
/// thread responsive on a large backfill.  A 100-ride backfill
/// typically completes in a few seconds.
@Observable
@MainActor
final class HealthKitBackfillCoordinator {
    /// State machine driving the progress UI.  `.idle` until `start` is
    /// called; transitions to `.running` for each ride; settles into one
    /// of the terminal states (succeeded / cancelled / failed) when
    /// done.  All states are `Equatable` so the sheet can use
    /// `.onChange(of: coordinator.phase)`.
    enum Phase: Equatable, Sendable {
        case idle
        case running(currentIndex: Int, total: Int, currentTitle: String)
        /// Terminal success.  Counts split by exporter outcome:
        ///  - `exported`: ride wasn't in HealthKit yet, we wrote it.
        ///  - `alreadyPresent`: ride was already there (orphan stamp on
        ///    a fresh local ride, or a duplicate run); we just
        ///    re-stamped locally.
        ///  - `failed`: ride hit an error; we skipped and moved on.
        case succeeded(exportedCount: Int, alreadyPresentCount: Int, failedCount: Int)
        case cancelled(exportedCount: Int)
        case failed(message: String, exportedCount: Int)
    }

    nonisolated private static let log = Logger(subsystem: "com.herbertindustries.BumpyRide", category: "healthkit")

    private(set) var phase: Phase = .idle

    private let exporter: HealthKitExporter
    private let store: RideStore

    /// In-flight task, kept so `cancel()` can target it.  Cleared when
    /// the task completes (success / cancelled / failed alike).
    @ObservationIgnored private var task: Task<Void, Never>?

    init(exporter: HealthKitExporter, store: RideStore) {
        self.exporter = exporter
        self.store = store
    }

    /// Begin backfilling the supplied rides.  Caller provides the
    /// already-filtered and user-confirmed list (typically rides where
    /// `healthKitWorkoutUUID == nil`); this class doesn't re-filter.
    ///
    /// Idempotent re-entry: if already running, this is a no-op.  To
    /// start a new backfill after a terminal phase, call `reset()`
    /// first then `start`.
    func start(exporting rides: [Ride]) {
        if case .running = phase { return }
        let total = rides.count
        // Show progress on the first ride immediately so the sheet's
        // first frame after the user taps Sync isn't a stale "Ready"
        // state.
        phase = .running(
            currentIndex: 0,
            total: total,
            currentTitle: rides.first?.title ?? ""
        )
        task = Task { @MainActor [weak self] in
            await self?.runExports(rides)
            self?.task = nil
        }
    }

    /// Cancel the in-flight backfill (if any).  Cooperative — the loop
    /// checks `Task.isCancelled` at safe boundaries.  Rides already
    /// exported and stamped are preserved.  Phase transitions to
    /// `.cancelled(exportedCount:)`.
    func cancel() {
        task?.cancel()
    }

    /// Reset to `.idle` so a new backfill can begin.  Safe to call
    /// from any state; cancels any in-flight task first.
    func reset() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    // MARK: - Internal

    private func runExports(_ rides: [Ride]) async {
        var exported = 0
        var alreadyPresent = 0
        var failed = 0
        let total = rides.count

        for (index, ride) in rides.enumerated() {
            if Task.isCancelled {
                phase = .cancelled(exportedCount: exported)
                return
            }

            phase = .running(
                currentIndex: index,
                total: total,
                currentTitle: ride.title
            )

            do {
                let result = try await exporter.export(ride)
                switch result {
                case .written(let uuid):
                    // Quiet save — see `RideStore.updateHealthKitWorkoutUUID`
                    // for the rationale.  A backfill of 50 rides is
                    // exactly the workload that made the cascading
                    // loud-save pattern visible in the field
                    // (multi-MB POST + calibration PUT per ride),
                    // hitting network timeouts and the OSLog quarantine.
                    store.updateHealthKitWorkoutUUID(uuid, forRideId: ride.id)
                    exported += 1
                case .alreadyPresent(let uuid):
                    store.updateHealthKitWorkoutUUID(uuid, forRideId: ride.id)
                    alreadyPresent += 1
                case .unavailable:
                    // HealthKit went away mid-backfill (extremely rare:
                    // user disabled HealthKit at the OS level while
                    // backfill was running).  Treat as fatal — no
                    // subsequent ride will succeed either.
                    phase = .failed(
                        message: "Apple Health is no longer available.",
                        exportedCount: exported
                    )
                    return
                }
            } catch {
                // Per-ride failure: log and continue.  The exporter
                // already logged the underlying cause.  Most likely
                // cause in practice: a single ride has data the
                // HealthKit builder didn't like (e.g. zero-duration).
                Self.log.notice("Backfill: skipping \(ride.id, privacy: .public) due to error")
                failed += 1
            }

            // Yield between rides to keep the UI thread responsive on
            // a large backfill.  No artificial sleep — HealthKit
            // writes don't need rate-limiting.
            await Task.yield()
        }

        phase = .succeeded(
            exportedCount: exported,
            alreadyPresentCount: alreadyPresent,
            failedCount: failed
        )
    }
}
