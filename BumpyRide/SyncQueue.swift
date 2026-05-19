import Foundation
import Observation

/// Persistent record of which rides still need to be uploaded to bumpyride.me.
///
/// Kept deliberately small and orthogonal to the ride wire format: a pair of
/// `Ride.id` UUID sets in `<Documents>/Sync/queue.json`.  The contents of each
/// ride live in `RideStore`; this just remembers which ones haven't been
/// confirmed by the server yet, plus *why* each one is queued.
///
/// **Two categories**, both functionally equivalent to the drain loop:
///
/// - `userInitiatedIds`: a ride the user just saved (or one we couldn't
///   upload at the time and have been retrying).  These are the rides the
///   user *expects* to see backed up momentarily; the tab badge counts only
///   these so it represents real "you have work pending" attention.
/// - `backfillIds`: an existing ride being caught up after the user paired
///   their account, or one seeded on launch when we were already paired.
///   Functionally identical to `userInitiated` for uploading, but excluded
///   from the badge — pairing 50 historical rides shouldn't make the tab
///   feel like an unread-messages explosion.
///
/// A ride is in exactly one bucket.  `insert(_:isBackfill:)` enforces this:
/// user-initiated wins over backfill if both signals fire for the same ID.
///
/// Survives crashes, force-quits, and reboots.  Writes are atomic per
/// modification; volume is low enough (one write per ride save / successful
/// upload) that we don't need to debounce.
@Observable
final class SyncQueue {
    /// Rides queued as a result of a user save.  These count toward the tab badge.
    private(set) var userInitiatedIds: Set<UUID> = []

    /// Rides queued as backfill — existing rides being caught up after the
    /// user paired their account, or seeded on launch.  Excluded from the
    /// tab badge.
    private(set) var backfillIds: Set<UUID> = []

    private let fileURL: URL

    init(directory: URL = SyncQueue.defaultDirectory) {
        let dir = directory.appendingPathComponent("Sync", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("queue.json")
        load()
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    /// Union of both buckets.  Used by the drain loop and by the in-detail
    /// "Syncing N rides" status text — everywhere we care about *any* pending
    /// work, regardless of why it's pending.
    var ids: Set<UUID> { userInitiatedIds.union(backfillIds) }
    var isEmpty: Bool { userInitiatedIds.isEmpty && backfillIds.isEmpty }
    var count: Int { userInitiatedIds.count + backfillIds.count }

    /// Count for the tab badge — only newly-saved rides, never the backfill
    /// catch-up after pairing.
    var userInitiatedCount: Int { userInitiatedIds.count }

    func contains(_ id: UUID) -> Bool {
        userInitiatedIds.contains(id) || backfillIds.contains(id)
    }

    /// Add a ride to the queue.  If `isBackfill` is true and the ride is
    /// already user-initiated, the user-initiated marking is preserved — we
    /// never downgrade.  If `isBackfill` is false and the ride is currently
    /// in backfill, it gets promoted to user-initiated (the user just saved
    /// or re-saved it; that's a stronger signal than "from pairing").
    func insert(_ id: UUID, isBackfill: Bool = false) {
        if isBackfill {
            // Skip if the ride is already either kind of queued.  Backfill is
            // best-effort seeding; it doesn't override a user signal.
            guard !userInitiatedIds.contains(id), !backfillIds.contains(id) else { return }
            backfillIds.insert(id)
        } else {
            guard !userInitiatedIds.contains(id) else { return }
            // Promote out of backfill if necessary.
            backfillIds.remove(id)
            userInitiatedIds.insert(id)
        }
        persist()
    }

    /// Remove a ride from whichever bucket holds it.  No-op if it's not queued.
    func remove(_ id: UUID) {
        let wasUser = userInitiatedIds.remove(id) != nil
        let wasBackfill = backfillIds.remove(id) != nil
        if wasUser || wasBackfill { persist() }
    }

    /// Snapshot of the queued IDs as an array, in arbitrary order.  Callers
    /// that want chronological ordering should look the rides up in
    /// `RideStore` and sort by `startedAt`.
    func all() -> [UUID] { Array(ids) }

    // MARK: - Persistence

    /// Wire format.  Stored fields are explicit (not optionals) so the JSON
    /// is human-inspectable.  Pre-v1.2 builds wrote a flat `[UUID]` array;
    /// see `load()` for the backward-compat path.
    private struct PersistentForm: Codable {
        let userInitiated: [UUID]
        let backfill: [UUID]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        // Try the new structured format first; fall back to the legacy flat
        // array.  Legacy entries get classified as user-initiated — that's
        // the safer side of the badge (they appear) and matches what the
        // user has been seeing all along.  After the first persist() we'll
        // be in the new format permanently.
        if let decoded = try? decoder.decode(PersistentForm.self, from: data) {
            userInitiatedIds = Set(decoded.userInitiated)
            backfillIds = Set(decoded.backfill)
        } else if let legacy = try? decoder.decode([UUID].self, from: data) {
            userInitiatedIds = Set(legacy)
            backfillIds = []
        }
    }

    private func persist() {
        let payload = PersistentForm(
            userInitiated: Array(userInitiatedIds).sorted(by: { $0.uuidString < $1.uuidString }),
            backfill: Array(backfillIds).sorted(by: { $0.uuidString < $1.uuidString })
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
