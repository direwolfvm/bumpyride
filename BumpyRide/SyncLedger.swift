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
/// **Scoped to an account.**  The entries record what a *particular* server
/// account accepted, so they are only valid for that account.  Earlier this was
/// handled by wiping the ledger whenever `isConnected` went false — which was
/// wrong twice over: `SyncCoordinator` calls `webAccount.invalidate()` on any
/// 401, so a single expired token silently discarded the whole ledger and the
/// next drain re-uploaded the entire library (453 MB in one pass on 15 Sep).
/// The ledger now remembers which account owns it and clears only on a genuine
/// switch, so a transient auth failure costs nothing.
///
/// Stored next to the queue in `<Documents>/Sync/ledger.json`.  Losing it is
/// harmless — it degrades to the old server-check behaviour.
@Observable
final class SyncLedger {
    private(set) var hashes: [UUID: String] = [:]
    /// Account these entries belong to (the email `TokenStorage` keys on).
    private(set) var owner: String?
    private let fileURL: URL
    nonisolated private static let debug = DebugLog(category: "sync")

    /// On-disk form.  v1 was a bare `[UUID: String]`; that shape is still read
    /// so an upgrade keeps its entries, adopting whatever account is current.
    private struct Persisted: Codable {
        var owner: String?
        var hashes: [UUID: String]
    }

    init(directory: URL = SyncQueue.defaultDirectory) {
        let dir = directory.appendingPathComponent("Sync", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("ledger.json")
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode(Persisted.self, from: data) {
            owner = decoded.owner
            hashes = decoded.hashes
        } else if let legacy = try? JSONDecoder().decode([UUID: String].self, from: data) {
            hashes = legacy          // pre-owner file; adopted by the next setOwner
        }
    }

    /// Point the ledger at the signed-in account.  Same account: entries stand.
    /// Different account: they are meaningless, so drop them.  Called whenever
    /// the account is known — **not** on disconnect, which is frequently just a
    /// recoverable 401.
    func setOwner(_ email: String) {
        if let owner, owner == email {
            return
        }
        if owner != nil, !hashes.isEmpty {
            Self.debug.info("ledger: account changed — discarding \(hashes.count) entrie(s)")
            hashes.removeAll()
        } else if owner == nil, !hashes.isEmpty {
            Self.debug.info("ledger: adopting \(hashes.count) pre-existing entrie(s) for this account")
        }
        owner = email
        persist()
    }

    /// How many rides the ledger vouches for.  Logged at drain start: if this
    /// is 0 after a drain that uploaded rides, the problem is persistence; if
    /// it is large while nothing prunes, the problem is hash stability.  That
    /// one number separates the two (v2.1 U10).
    var count: Int { hashes.count }

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

    /// Drop everything.  Reserved for an explicit user action (unpair / clear
    /// server data); a 401 must not reach this — see `setOwner`.
    func clear() {
        guard !hashes.isEmpty else { return }
        Self.debug.info("ledger: cleared \(hashes.count) entrie(s)")
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
        guard let data = try? JSONEncoder().encode(Persisted(owner: owner, hashes: hashes)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
