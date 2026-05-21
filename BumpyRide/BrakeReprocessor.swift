import Foundation
import OSLog

/// One-shot launch-time pass that runs `BrakeEventDetector` on every saved
/// ride with `brakeEvents == nil` — i.e., rides recorded before the brake
/// feature existed, or rides synced down from another device on a fresh
/// install.
///
/// **Idempotent + resumable.**  The predicate is `brakeEvents == nil` and
/// we flip rides to either `[]` (detected, no events) or `[...]` (detected,
/// events found) on success.  Re-running after a crash mid-pass skips
/// already-processed rides naturally — no separate "done" flag needed.
///
/// **Quiet saves.**  Writes go through `RideStore.updateBrakeEvents(_:forRideId:)`
/// instead of `save(_:)`, so the per-ride callbacks (sync enqueue,
/// calibration recompute) don't fire.  The call site (`ContentView`)
/// orchestrates sync explicitly *after* the batch by enqueueing touched
/// IDs as `backfill` — that way the Saved-tab badge isn't inflated by
/// the historical catch-up.
///
/// **Throttled.**  `await Task.yield()` between rides keeps the UI thread
/// responsive even if the user is mid-scroll on the Saved tab when launch
/// fires.  Detection on a typical ride (hundreds to low-thousands of
/// points) is fast enough to run on main without splitting to a background
/// queue; if profiling later shows otherwise, the detector call itself can
/// move to `Task.detached`.
enum BrakeReprocessor {
    private static let log = Logger(subsystem: "com.herbertindustries.BumpyRide", category: "brakereprocessor")

    /// Scan the store for rides needing brake detection and persist
    /// results.  Returns the IDs of rides that were successfully updated,
    /// so the caller can enqueue them as backfill on the sync coordinator
    /// (the server needs the updated payload, but it's not user-initiated
    /// work).
    ///
    /// Two modes:
    /// - `forceReDetect = false` (default): only rides with `brakeEvents == nil`
    ///   are touched.  This is the steady-state path — legacy rides
    ///   recorded before the feature existed get backfilled once and
    ///   stay that way.
    /// - `forceReDetect = true`: every saved ride is re-analyzed,
    ///   regardless of its current `brakeEvents` value.  Used by the
    ///   one-shot migration that follows a `BrakeEventDetector.revision`
    ///   bump (see `ContentView.task`) — the new detector tuning is
    ///   meaningfully different, so previously-empty results need to be
    ///   recomputed against the new algorithm.
    @MainActor
    static func reprocessLegacyRides(in store: RideStore, forceReDetect: Bool = false) async -> [UUID] {
        // Snapshot the candidate IDs.  We re-look-up each ride inside the
        // loop because the user might delete or edit a ride between this
        // snapshot and our turn to process it.
        let candidateIds: [UUID]
        if forceReDetect {
            candidateIds = store.rides.map(\.id)
        } else {
            candidateIds = store.rides
                .filter { $0.brakeEvents == nil }
                .map(\.id)
        }

        guard !candidateIds.isEmpty else { return [] }

        var updated: [UUID] = []
        var withEvents = 0

        for id in candidateIds {
            // Re-look-up; ride may have been deleted or edited.
            guard let ride = store.rides.first(where: { $0.id == id }) else { continue }
            // In force-re-detect mode we process unconditionally.  In the
            // default mode we still respect the "nil means needs work"
            // predicate so a ride that got processed by another concurrent
            // path (the edit-save hook) doesn't get a redundant detection
            // pass here.
            if !forceReDetect && ride.brakeEvents != nil { continue }

            let detected = BrakeEventDetector.detect(in: ride)

            if store.updateBrakeEvents(detected, forRideId: id) {
                updated.append(id)
                if !detected.isEmpty { withEvents += 1 }
            }

            // Cooperative checkpoint.  If the parent `.task` has been
            // cancelled (e.g., user backgrounded the app), bail out
            // cleanly — already-processed rides keep their results.
            if Task.isCancelled { break }
            await Task.yield()
        }

        if !updated.isEmpty {
            let mode = forceReDetect ? "re-detected" : "reprocessed"
            log.notice("\(mode, privacy: .public) \(updated.count, privacy: .public) rides; \(withEvents, privacy: .public) had brake events")
        }
        return updated
    }
}
