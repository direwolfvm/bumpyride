import Foundation
import Observation
import OSLog

/// On-disk persistence for saved rides: one ISO-8601 JSON file per ride at
/// `<directoryURL>/<UUID>.json`.  The directory is supplied at init time by
/// `CloudStorage`, which picks iCloud Documents when available and falls back
/// to the local app sandbox's `Documents/Rides/` otherwise.  RideStore itself
/// is storage-mode-agnostic — it sees a URL and writes to it.
///
/// v2.0 O1: rides load **asynchronously off the main thread** via
/// `reload()` — the app renders immediately and the library fills in
/// when the decode finishes (`initialLoadComplete` tells the UI which
/// state it's in).  The original synchronous load-at-init design froze
/// startup for 10+ seconds once the corpus grew to hundreds of MB of
/// JSON.  ContentView's startup task owns the one `reload()` call,
/// sequenced after the iCloud migration so a single pass sees
/// everything.
///
/// Writes to iCloud Documents are wrapped in `NSFileCoordinator` because the
/// ubiquity container can be touched concurrently by the iCloud sync engine
/// or another instance of the app on a different device.  Reads are
/// intentionally *not* coordinated — reload() is best-effort, runs at
/// startup, and a torn read of a single ride just means that ride is
/// skipped this launch and reloaded next time.
@Observable
final class RideStore {
    private(set) var rides: [Ride] = []

    /// Fired after every successful `save(_:)` write — whether for a brand-new ride or
    /// an in-place update from rename / trim / split.  `ContentView` wires this to
    /// `SyncCoordinator.enqueue(_:)` + `kick()` so the upload path doesn't have to
    /// reach into `RideStore` itself.
    var onRideSaved: ((Ride) -> Void)?

    /// Fired after `delete(_:)` removes a ride from disk.  Wired to
    /// `SyncCoordinator.remove(_:)` so we don't waste a network round trip uploading
    /// something the user already deleted locally.
    var onRideDeleted: ((UUID) -> Void)?

    /// Fired when `save(_:)` fails to write the ride to disk.  Unwired by default —
    /// callers (typically the view that just initiated the save) can attach a
    /// handler to surface an alert.  Failure is rare (disk full, IO error, sandbox
    /// permission revoked) but historically silent; this hook makes it actionable.
    var onSaveFailed: ((Ride, any Error) -> Void)?

    private static let log = Logger(subsystem: "com.herbertindustries.BumpyRide", category: "ridestore")

    private let directoryURL: URL
    private let encoder: JSONEncoder
    /// v2.0 O1: `false` until the first `reload()` publishes.  UI uses
    /// this to distinguish "library is empty" from "library hasn't
    /// loaded yet"; SyncCoordinator uses it to defer drains (its
    /// missing-ride-means-deleted heuristic would wipe the queue
    /// against an unloaded store).
    private(set) var initialLoadComplete: Bool = false

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
        // CloudStorage already ensured the directory exists; doing it again is
        // a cheap idempotent operation that protects against any caller that
        // hands us a URL without preparing it.
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // v2.0 O1: no load here — ContentView's startup task calls
        // reload() (after the iCloud migration).  A synchronous load at
        // init blocked the first frame behind hundreds of MB of JSON.
    }

    /// v2.0 O1: read + decode the whole library on a detached
    /// background task, then publish on the main actor.  Callable
    /// repeatedly (each call is a full rescan).
    func reload() async {
        let dir = directoryURL
        let loaded = await Task.detached(priority: .userInitiated) {
            Self.readAllRides(in: dir)
        }.value
        rides = loaded.sorted { $0.startedAt > $1.startedAt }
        initialLoadComplete = true
        Self.log.info("Loaded \(self.rides.count, privacy: .public) ride(s)")
    }

    /// The heavy part, deliberately `nonisolated` so it runs off-main
    /// (model Codable is nonisolated as of O1).
    nonisolated private static func readAllRides(in directoryURL: URL) -> [Ride] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil))
            ?? []
        var loaded: [Ride] = []
        for url in files where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               let ride = try? decoder.decode(Ride.self, from: data) {
                loaded.append(ride)
            }
        }
        return loaded
    }

    func save(_ ride: Ride) {
        let url = directoryURL.appendingPathComponent("\(ride.id.uuidString).json")
        do {
            let data = try encoder.encode(ride)
            try coordinatedWrite(data, to: url)
            if let idx = rides.firstIndex(where: { $0.id == ride.id }) {
                rides[idx] = ride
            } else {
                rides.insert(ride, at: 0)
                rides.sort { $0.startedAt > $1.startedAt }
            }
            onRideSaved?(ride)
        } catch {
            // Silent save failure has historically been the worst failure mode of
            // this app — the ride looks saved but isn't on disk.  Log loudly via
            // OSLog (visible in Console.app) and surface to whoever wired up
            // onSaveFailed, so future versions can show a banner.  The in-memory
            // rides array is left unchanged so the rest of the app behaves
            // consistently with disk state.
            Self.log.error("Failed to save ride \(ride.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            onSaveFailed?(ride, error)
        }
    }

    func delete(_ ride: Ride) {
        let url = directoryURL.appendingPathComponent("\(ride.id.uuidString).json")
        coordinatedRemove(at: url)
        rides.removeAll { $0.id == ride.id }
        onRideDeleted?(ride.id)
    }

    /// Remove every ride from disk and from the in-memory list.  Fires
    /// `onRideDeleted` once per ride so the sync queue and the calibration
    /// store both follow.  Used by the "Clear my data" and "Delete account"
    /// flows in `WebAccountView`, where the user has explicitly asked for
    /// a clean slate.
    ///
    /// Iterates over a *snapshot* of the IDs rather than `rides` directly
    /// so the in-loop mutation of `rides` (via the onRideDeleted handler's
    /// access chain through `store.rides`) can't index-shift mid-iteration.
    ///
    /// File removals go through the coordinated path for the same reason
    /// `delete(_:)` does — the ubiquity container may have concurrent
    /// readers (Files app, another device) that benefit from coordination.
    func removeAll() {
        let snapshot = rides.map(\.id)
        for id in snapshot {
            let url = directoryURL.appendingPathComponent("\(id.uuidString).json")
            coordinatedRemove(at: url)
        }
        rides = []
        for id in snapshot {
            onRideDeleted?(id)
        }
    }

    /// Update only the `brakeEvents` field of an existing ride in place,
    /// without firing `onRideSaved`.
    ///
    /// Used by the launch-time brake reprocessor (`BrakeReprocessor`) where
    /// going through `save(_:)` would inflate the Saved-tab badge (every
    /// backfilled ride would land in the sync queue as user-initiated) and
    /// recompute calibration N times unnecessarily.  Reprocessor saves are
    /// effectively backfill — the call site is responsible for enqueueing
    /// touched IDs as backfill on the sync coordinator after the batch.
    ///
    /// Returns `true` on successful persist.  Does nothing and returns
    /// `false` if the ride isn't in the store (e.g., user deleted it
    /// between the reprocessor reading the ride and persisting the result).
    @discardableResult
    func updateBrakeEvents(_ events: [BrakeEvent], forRideId id: UUID) -> Bool {
        guard let idx = rides.firstIndex(where: { $0.id == id }) else { return false }
        var ride = rides[idx]
        ride.brakeEvents = events
        let url = directoryURL.appendingPathComponent("\(ride.id.uuidString).json")
        do {
            let data = try encoder.encode(ride)
            try coordinatedWrite(data, to: url)
            rides[idx] = ride
            return true
        } catch {
            Self.log.error("Failed to update brakeEvents for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Update only the `healthKitWorkoutUUID` field of an existing ride
    /// in place, without firing `onRideSaved`.
    ///
    /// Used by all three HealthKit write paths (auto-export in
    /// `ContentView.onRideSaved`, manual button in `RideView`, backfill
    /// coordinator) after a successful export to stamp the local Ride
    /// with the resulting HKWorkout UUID.  Going through `save(_:)`
    /// here would cascade — every stamp would re-enqueue the ride for
    /// upload to bumpyride.me (re-sending the full multi-MB payload to
    /// land a device-local 36-byte field the server doesn't interpret)
    /// and re-recompute calibration unnecessarily.  Worst case on a
    /// 50-ride backfill: 50 spurious POSTs and 50 spurious calibration
    /// PUTs, observed in field testing to hit timeouts and the OSLog
    /// quarantine on the device.
    ///
    /// Returns `true` on successful persist.  Does nothing and returns
    /// `false` if the ride isn't in the store (e.g., user deleted it
    /// between the exporter's call and persistence).
    @discardableResult
    func updateHealthKitWorkoutUUID(_ uuid: UUID, forRideId id: UUID) -> Bool {
        guard let idx = rides.firstIndex(where: { $0.id == id }) else { return false }
        var ride = rides[idx]
        ride.healthKitWorkoutUUID = uuid
        let url = directoryURL.appendingPathComponent("\(ride.id.uuidString).json")
        do {
            let data = try encoder.encode(ride)
            try coordinatedWrite(data, to: url)
            rides[idx] = ride
            return true
        } catch {
            Self.log.error("Failed to update healthKitWorkoutUUID for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Atomic write wrapped in `NSFileCoordinator` so the iCloud sync engine
    /// (or another device touching the same file) sees a consistent snapshot.
    /// For local-only storage this adds negligible overhead and the
    /// coordinator simply gates the inner block.
    ///
    /// The coordinator's API is a little awkward: it takes an in-out NSError
    /// for *scheduling* errors and runs the closure synchronously.  Any IO
    /// error thrown from inside the closure is captured separately and
    /// re-thrown.
    private func coordinatedWrite(_ data: Data, to url: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var writeError: Error?
        coordinator.coordinate(writingItemAt: url, options: [.forReplacing], error: &coordinationError) { writeURL in
            do {
                try data.write(to: writeURL, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    /// Coordinated delete — same rationale as `coordinatedWrite`.  Failures
    /// are swallowed because the prior behavior was `try?` and the worst case
    /// (file leaks on disk) is recoverable.
    private func coordinatedRemove(at url: URL) {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        coordinator.coordinate(writingItemAt: url, options: [.forDeleting], error: &coordinationError) { deleteURL in
            try? FileManager.default.removeItem(at: deleteURL)
        }
    }

    func rename(_ ride: Ride, to title: String) {
        var updated = ride
        updated.title = title
        save(updated)
    }
}
