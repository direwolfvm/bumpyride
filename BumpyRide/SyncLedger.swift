import Foundation
import Observation

/// v2.1 U1: what we have already successfully uploaded, and in what form.
///
/// `SyncQueue` records what still *needs* uploading.  This records the
/// opposite: for each ride, the SHA-256 of the exact wire body the server
/// last accepted.  A ride whose current body hashes to the same value is
/// already on the server, byte for byte, and needs neither an upload nor a
/// round-trip to ask.
///
/// **Why this exists.**  `ContentView` re-seeds every local ride into the
/// backfill queue on each launch (it has to — the queue can't otherwise
/// tell "already synced" from "never tried"), and the drain then leaned
/// entirely on server-side checks to prune it back down.  Any hiccup in
/// those checks — a flaky cellular link mid-ride, a slow endpoint, a hash
/// the server disagrees with — degraded straight into re-uploading the
/// whole library.  MetricKit caught it doing exactly that: 873 MB of
/// cellular upload in a single day against a 688 MB library.
///
/// With the ledger the prune happens locally and for free, so a steady-state
/// launch costs zero requests instead of one per ride.  The server checks
/// remain as the fallback for anything the ledger has no answer for.
///
/// Stored next to the queue in `<Documents>/Sync/ledger.json`.  Losing it is
/// harmless — it degrades to the old server-check behaviour.
@Observable
final class SyncLedger {
    private(set) var hashes: [UUID: String] = [:]
    private let fileURL: URL

    init(directory: URL = SyncQueue.defaultDirectory) {
        let dir = directory.appendingPathComponent("Sync", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("ledger.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([UUID: String].self, from: data) {
            hashes = decoded
        }
    }

    /// Hash of the body the server last accepted for this ride, if any.
    func hash(for id: UUID) -> String? { hashes[id] }

    /// True when `hash` is exactly what we last uploaded for this ride.
    func isCurrent(id: UUID, hash: String) -> Bool { hashes[id] == hash }

    func record(id: UUID, hash: String) {
        guard hashes[id] != hash else { return }
        hashes[id] = hash
        persist()
    }

    /// Drop one ride — on local delete, so a re-restored ride with the same
    /// id re-verifies rather than trusting a stale entry.
    func forget(_ id: UUID) {
        guard hashes.removeValue(forKey: id) != nil else { return }
        persist()
    }

    /// Drop everything — on account disconnect, since a different account's
    /// server has none of these.
    func clear() {
        guard !hashes.isEmpty else { return }
        hashes.removeAll()
        persist()
    }

    /// Forget rides that no longer exist locally, so the file can't grow
    /// without bound across years of deletes.
    func prune(keeping liveIds: Set<UUID>) {
        let before = hashes.count
        hashes = hashes.filter { liveIds.contains($0.key) }
        if hashes.count != before { persist() }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(hashes) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
