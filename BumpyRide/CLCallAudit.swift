import Foundation

/// v2.1 U6: counts the CoreLocation API calls the app makes, by call site.
///
/// CoreLocation logs `"Supported CoreLocation API call rate exceeded,
/// behavior undefined."` once an app crosses ~24,000 calls, and takes the
/// app's OSLog subsystem down with it ("QUARANTINED DUE TO HIGH LOGGING
/// VOLUME") — which is exactly the state in which it is hardest to work out
/// what did it.  The count in that message is the threshold, not a
/// fingerprint of any particular bug, so two unrelated causes produce the
/// identical `24001`.
///
/// Auditing every call site we own turns the next occurrence into a fact
/// instead of a guess: the per-ride sidecar gets a breakdown, so we can see
/// whether the volume is ours at all, and if so which API is responsible.
/// Counters are process-lifetime and cheap — an `NSLock` around a small
/// dictionary, touched only at genuine CoreLocation call sites, never on the
/// per-fix delivery path.
///
/// Note this can only see calls *we* make.  MapKit runs its own
/// `CLLocationManager` behind `showsUserLocation` / `userTrackingMode`, and
/// those calls count against the same app-wide budget while being invisible
/// here.  A ride whose sidecar shows a low total is therefore evidence that
/// the volume is MapKit's, which is useful in itself.
enum CLCallAudit {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    nonisolated(unsafe) private static var lastReportedTotal = 0

    /// Record one CoreLocation API call from `site`.
    static func note(_ site: String) {
        lock.lock()
        counts[site, default: 0] += 1
        lock.unlock()
    }

    static var total: Int {
        lock.lock(); defer { lock.unlock() }
        return counts.values.reduce(0, +)
    }

    /// `"total=N site=a:3 site=b:1"`, ordered heaviest first.
    static func snapshot() -> String {
        lock.lock(); defer { lock.unlock() }
        let sum = counts.values.reduce(0, +)
        let parts = counts.sorted { $0.value > $1.value }.map { "\($0.key):\($0.value)" }
        return "total=\(sum) " + parts.joined(separator: " ")
    }

    /// Snapshot only if the total moved since the last call — keeps a periodic
    /// caller from writing an identical line every tick.
    static func snapshotIfChanged() -> String? {
        lock.lock()
        let sum = counts.values.reduce(0, +)
        let changed = sum != lastReportedTotal
        lastReportedTotal = sum
        let parts = counts.sorted { $0.value > $1.value }.map { "\($0.key):\($0.value)" }
        lock.unlock()
        guard changed else { return nil }
        return "total=\(sum) " + parts.joined(separator: " ")
    }
}
