import Foundation
import Observation
import OSLog
import CryptoKit

/// On-disk persistence for saved rides: one ISO-8601 JSON file per ride at
/// `<directoryURL>/<UUID>.json`.  The directory is supplied at init time by
/// `CloudStorage`, which picks iCloud Documents when available and falls back
/// to the local app sandbox's `Documents/Rides/` otherwise.  RideStore itself
/// is storage-mode-agnostic — it sees a URL and writes to it.
///
/// v2.0 P1: **metadata-eager, points-lazy.**  `rides` is now
/// `[RideSummary]` — everything the list / score / map-event surfaces
/// need, without the `points` arrays that made a 168-ride library
/// occupy ~1 GB resident.  Full `Ride`s load on demand:
///
///   • `fullRide(id:)` — decode one ride off-main (small LRU cache for
///     the viewer/edit flows).
///   • `foldRides(ids:initial:_:)` — stream rides one at a time
///     through an accumulator off-main (bump-grid rebuilds,
///     calibration).  Peak memory: one ride.
///   • `encodedBody(id:)` / `contentHashes(ids:)` — sync-path
///     encode/hash without retaining anything.
///
/// Summaries are cached in a **local** (Caches, never iCloud) sidecar
/// keyed by ride-file size + mtime, so a relaunch skips full decodes
/// entirely; only new/changed files pay a one-ride decode.  The first
/// launch after this change performs one full background pass to seed
/// the cache.
///
/// Writes to iCloud Documents are wrapped in `NSFileCoordinator` because the
/// ubiquity container can be touched concurrently by the iCloud sync engine
/// or another instance of the app on a different device.  Reads are
/// intentionally *not* coordinated — reload() is best-effort, runs at
/// startup, and a torn read of a single ride just means that ride is
/// skipped this launch and reloaded next time.
@Observable
final class RideStore {
    /// v2.0 P1: summaries, not full rides.  Sorted newest-first.
    private(set) var rides: [RideSummary] = []

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

    nonisolated private static let log = Logger(subsystem: "com.herbertindustries.BumpyRide", category: "ridestore")

    private let directoryURL: URL
    private let encoder: JSONEncoder

    /// v2.0 O1: `false` until the first `reload()` publishes.  UI uses
    /// this to distinguish "library is empty" from "library hasn't
    /// loaded yet"; SyncCoordinator uses it to defer drains (its
    /// missing-ride-means-deleted heuristic would wipe the queue
    /// against an unloaded store).
    private(set) var initialLoadComplete: Bool = false

    // MARK: - Summary cache (P1)

    /// One persisted cache row: the summary plus the file signature it
    /// was computed from.  mtime is stored as epoch seconds (not a
    /// Codable Date) so the ISO-8601 round-trip can't shave fractional
    /// seconds and silently invalidate every entry each launch.
    nonisolated private struct SummaryCacheEntry: Codable {
        let summary: RideSummary
        let fileSize: Int
        let fileModifiedEpoch: TimeInterval
    }

    /// Device-local on purpose: file mtimes differ across devices, so
    /// a cache that synced through iCloud would be wrong everywhere
    /// but its birthplace.
    nonisolated private static var summaryCacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ride-summaries.json")
    }

    /// In-memory mirror of the persisted cache, mutated on save/delete
    /// and flushed via `persistSummaryCacheSoon`.
    private var summaryCache: [UUID: SummaryCacheEntry] = [:]

    // MARK: - Full-ride LRU (P1)

    private var fullRideCache: [UUID: Ride] = [:]
    private var fullRideOrder: [UUID] = []
    private static let fullRideCacheCap = 3

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
        // CloudStorage already ensured the directory exists; doing it again is
        // a cheap idempotent operation that protects against any caller that
        // hands us a URL without preparing it.
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // v2.0 O1: no load here — ContentView's startup task calls
        // reload() (after the iCloud migration).
    }

    // MARK: - Loading

    /// v2.0 O1/P1: scan the directory off-main, serving summaries from
    /// the cache where the file signature matches and decoding only
    /// new/changed rides.  Publishes on the main actor.
    func reload() async {
        let dir = directoryURL
        let (summaries, cache, decoded) = await Task.detached(priority: .userInitiated) {
            Self.loadSummaries(in: dir)
        }.value
        rides = summaries.sorted { $0.startedAt > $1.startedAt }
        summaryCache = cache
        initialLoadComplete = true
        fullRideCache = [:]
        fullRideOrder = []
        Self.log.info("Loaded \(summaries.count, privacy: .public) ride summaries (\(decoded, privacy: .public) required full decode)")
    }

    nonisolated private static func loadSummaries(
        in dir: URL
    ) -> ([RideSummary], [UUID: SummaryCacheEntry], Int) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let priorCache: [UUID: SummaryCacheEntry] = {
            guard let data = try? Data(contentsOf: summaryCacheURL) else { return [:] }
            return (try? decoder.decode([UUID: SummaryCacheEntry].self, from: data)) ?? [:]
        }()

        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        )) ?? []

        var summaries: [RideSummary] = []
        var cache: [UUID: SummaryCacheEntry] = [:]
        var decodedCount = 0

        for url in files where url.pathExtension == "json" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? -1
            let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? -1

            if let hit = priorCache[id],
               hit.fileSize == size,
               abs(hit.fileModifiedEpoch - mtime) < 0.001 {
                summaries.append(hit.summary)
                cache[id] = hit
                continue
            }
            guard let data = try? Data(contentsOf: url),
                  let ride = try? decoder.decode(Ride.self, from: data) else { continue }
            let summary = ride.summary
            summaries.append(summary)
            cache[id] = SummaryCacheEntry(summary: summary, fileSize: size, fileModifiedEpoch: mtime)
            decodedCount += 1
        }

        persistSummaryCache(cache)
        return (summaries, cache, decodedCount)
    }

    nonisolated private static func persistSummaryCache(_ cache: [UUID: SummaryCacheEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(cache) else { return }
        try? data.write(to: summaryCacheURL, options: .atomic)
    }

    /// Flush the in-memory cache mirror to disk off-main.  Fire-and-
    /// forget; the cache is an optimization, and a lost write just
    /// means one extra decode next launch.
    private func persistSummaryCacheSoon() {
        let snapshot = summaryCache
        Task.detached(priority: .utility) {
            Self.persistSummaryCache(snapshot)
        }
    }

    // MARK: - On-demand full rides (P1)

    /// Load one full ride, decoding off-main.  Small LRU keeps the
    /// viewer/edit flows snappy without re-accumulating the library.
    func fullRide(id: UUID) async -> Ride? {
        if let cached = fullRideCache[id] {
            fullRideOrder.removeAll { $0 == id }
            fullRideOrder.append(id)
            return cached
        }
        let dir = directoryURL
        guard let ride = await Task.detached(priority: .userInitiated, operation: {
            Self.loadFullRide(id: id, in: dir)
        }).value else { return nil }
        cacheFullRide(ride)
        return ride
    }

    nonisolated private static func loadFullRide(id: UUID, in dir: URL) -> Ride? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let url = dir.appendingPathComponent("\(id.uuidString).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(Ride.self, from: data)
    }

    private func cacheFullRide(_ ride: Ride) {
        fullRideCache[ride.id] = ride
        fullRideOrder.removeAll { $0 == ride.id }
        fullRideOrder.append(ride.id)
        while fullRideOrder.count > Self.fullRideCacheCap {
            let evicted = fullRideOrder.removeFirst()
            fullRideCache.removeValue(forKey: evicted)
        }
    }

    private func invalidateFullRide(id: UUID) {
        fullRideCache.removeValue(forKey: id)
        fullRideOrder.removeAll { $0 == id }
    }

    /// Stream full rides one at a time through `body` off-main —
    /// the aggregator primitive (bump grid, calibration).  Peak
    /// memory is a single decoded ride.  Missing/undecodable ids are
    /// skipped, matching reload()'s tolerance.
    func foldRides<T: Sendable>(
        ids: [UUID],
        initial: T,
        _ body: @escaping @Sendable (inout T, Ride) -> Void
    ) async -> T {
        let dir = directoryURL
        return await Task.detached(priority: .utility) {
            var acc = initial
            for id in ids {
                guard let ride = Self.loadFullRide(id: id, in: dir) else { continue }
                body(&acc, ride)
            }
            return acc
        }.value
    }

    /// v2.0 P1: sync-path helper — the wire-format encode of one ride,
    /// produced off-main and not retained.  nil = ride file is gone
    /// (deleted) or undecodable.
    func encodedBody(id: UUID) async -> Data? {
        let dir = directoryURL
        return await Task.detached(priority: .userInitiated) { () -> Data? in
            guard let ride = Self.loadFullRide(id: id, in: dir) else { return nil }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return try? encoder.encode(ride)
        }.value
    }

    /// v2.0 P1: content hashes for the L1 batch check, streamed
    /// off-main one ride at a time.  Ids whose file is gone are
    /// omitted from the result.
    func contentHashes(ids: [UUID]) async -> [(id: UUID, hash: String)] {
        let dir = directoryURL
        return await Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var out: [(id: UUID, hash: String)] = []
            for id in ids {
                guard let ride = Self.loadFullRide(id: id, in: dir),
                      let body = try? encoder.encode(ride) else { continue }
                let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
                out.append((id: id, hash: hash))
            }
            return out
        }.value
    }

    // MARK: - Mutations

    func save(_ ride: Ride) {
        let url = directoryURL.appendingPathComponent("\(ride.id.uuidString).json")
        do {
            let data = try encoder.encode(ride)
            try coordinatedWrite(data, to: url)
            upsertSummary(for: ride, at: url)
            cacheFullRide(ride)
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

    /// Update the summaries array + persisted cache after a successful
    /// file write.
    private func upsertSummary(for ride: Ride, at url: URL) {
        let summary = ride.summary
        if let idx = rides.firstIndex(where: { $0.id == summary.id }) {
            rides[idx] = summary
        } else {
            rides.insert(summary, at: 0)
            rides.sort { $0.startedAt > $1.startedAt }
        }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        summaryCache[summary.id] = SummaryCacheEntry(
            summary: summary,
            fileSize: values?.fileSize ?? -1,
            fileModifiedEpoch: values?.contentModificationDate?.timeIntervalSince1970 ?? -1
        )
        persistSummaryCacheSoon()
    }

    func delete(_ summary: RideSummary) {
        delete(id: summary.id)
    }

    func delete(id: UUID) {
        let url = directoryURL.appendingPathComponent("\(id.uuidString).json")
        coordinatedRemove(at: url)
        rides.removeAll { $0.id == id }
        summaryCache.removeValue(forKey: id)
        invalidateFullRide(id: id)
        persistSummaryCacheSoon()
        onRideDeleted?(id)
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
        summaryCache = [:]
        fullRideCache = [:]
        fullRideOrder = []
        persistSummaryCacheSoon()
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
    /// v2.0 P1: async — loads the full ride on demand first.  Returns
    /// `false` when the ride file is gone (deleted between snapshot
    /// and processing) or the write fails.
    @discardableResult
    func updateBrakeEvents(_ events: [BrakeEvent], forRideId id: UUID) async -> Bool {
        guard var ride = await fullRide(id: id) else { return false }
        ride.brakeEvents = events
        return persistQuietly(ride)
    }

    /// Update only the `healthKitWorkoutUUID` field of an existing ride
    /// in place, without firing `onRideSaved` — see the pre-P1 doc
    /// history for why the quiet path exists (loud saves cascaded
    /// multi-MB POSTs + calibration PUTs per stamped ride).
    ///
    /// v2.0 P1: async — loads the full ride on demand first.
    @discardableResult
    func updateHealthKitWorkoutUUID(_ uuid: UUID, forRideId id: UUID) async -> Bool {
        guard var ride = await fullRide(id: id) else { return false }
        ride.healthKitWorkoutUUID = uuid
        return persistQuietly(ride)
    }

    /// Shared quiet-persist: write the file and refresh summary +
    /// caches WITHOUT firing onRideSaved.
    private func persistQuietly(_ ride: Ride) -> Bool {
        let url = directoryURL.appendingPathComponent("\(ride.id.uuidString).json")
        do {
            let data = try encoder.encode(ride)
            try coordinatedWrite(data, to: url)
            upsertSummary(for: ride, at: url)
            cacheFullRide(ride)
            return true
        } catch {
            Self.log.error("Quiet persist failed for \(ride.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func rename(_ ride: Ride, to title: String) {
        var updated = ride
        updated.title = title
        // v2.0 Q1: renames are user content edits — stamp editedAt so a
        // future web-side editor can order conflicting edits.
        updated.editedAt = Date()
        save(updated)
    }

    // MARK: - Coordinated IO

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
}
