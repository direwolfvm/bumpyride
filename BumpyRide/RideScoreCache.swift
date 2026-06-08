import Foundation
import Observation

/// Lazy cache of per-ride score data fetched from `/api/rides/{id}/score`.
///
/// Holds a reference to `WebAccount` so callers (typically `RideView`) can
/// just ask `requestScore(for: rideId)` without threading the account
/// through every call site.  Entries persist for the app's lifetime by
/// default — scrubber moves, mode toggles, and tab switches within the
/// same playback session re-read the same `Entry` without re-fetching.
///
/// Invalidation:
/// - `invalidate(_ rideId:)` on ride delete, so a re-restored ride with
///   the same id doesn't return stale data.
/// - `invalidateAll()` on web account disconnect, since the new (or
///   absent) token can't read these rides' scores anymore.
@Observable
@MainActor
final class RideScoreCache {
    /// Per-ride cache state.  Four states, distinguishing the cases the
    /// playback view needs to render distinctly:
    ///
    /// - `.loading`: fetch in flight, hide the row briefly rather than
    ///   flashing a "0 points" placeholder.
    /// - `.loaded(data)`: ride is eligible AND scored — show the row with
    ///   `data.totalPoints`.
    /// - `.ineligible`: covers both the 200-with-`eligible: false`
    ///   server response (pocket-mode or sharing-off-at-sync) AND a 404
    ///   (ride doesn't exist on the server, e.g., never synced).  The
    ///   playback UX is identical: hide the row.
    /// - `.failed`: network or decode error.  Also hide the row; the user
    ///   may not have a working connection.
    enum Entry: Equatable, Sendable {
        case loading
        case loaded(WebSyncClient.RideScoreData)
        case ineligible
        case failed
    }

    let account: WebAccount
    private(set) var entries: [UUID: Entry] = [:]

    init(account: WebAccount) {
        self.account = account
    }

    /// Current cache entry for a ride, or `nil` if we haven't requested
    /// it yet.  Reading does not trigger a fetch — call `requestScore`
    /// for that.
    func entry(for rideId: UUID) -> Entry? {
        entries[rideId]
    }

    /// Kick off a fetch for this ride's score if we don't have one in
    /// flight already.  Safe to call from `.task` or `.onAppear`.
    /// Idempotent — repeated calls while loading or after success are
    /// no-ops, so views can re-issue freely without worry about
    /// duplicate requests.
    func requestScore(for rideId: UUID) {
        // Skip when we already have an entry (loading, loaded,
        // ineligible, or failed).  A `failed` entry doesn't auto-retry
        // — user has to do something explicit (re-open the ride).
        guard entries[rideId] == nil else { return }
        entries[rideId] = .loading
        Task {
            do {
                let data = try await account.fetchRideScore(rideId: rideId)
                entries[rideId] = data.eligible ? .loaded(data) : .ineligible
            } catch WebSyncClient.ClientError.http(status: 404) {
                // Ride doesn't exist server-side.  Treated as ineligible
                // for display purposes — there's no score to show.
                entries[rideId] = .ineligible
            } catch {
                entries[rideId] = .failed
            }
        }
    }

    /// Fetch a ride's score with retry/backoff.  Used after a
    /// user-initiated ride uploads successfully — the server has the
    /// ride payload but the score-events computation happens
    /// asynchronously, and `GET /api/rides/{id}/score` returns 404
    /// for a brief window after upload while the score lands.
    ///
    /// Retry schedule: immediately, then after 2 s, 5 s, 10 s.  Total
    /// wall-clock cap ~17 s; typical server compute is sub-second so
    /// the first or second attempt usually succeeds.  On final
    /// exhaustion the entry resolves to `.ineligible` (the same UX
    /// as "ride never qualified"), which is the right fallback —
    /// the user can re-open the ride later to retry via the lazy
    /// `requestScore` path.
    ///
    /// Unlike `requestScore`, this OVERWRITES any existing entry.
    /// That's intentional: a previous `.ineligible` cached during
    /// the upload-pending window should get replaced once the
    /// server actually has the score.
    func requestScoreWithRetry(for rideId: UUID) {
        entries[rideId] = .loading
        Task {
            await fetchScoreWithRetry(for: rideId)
        }
    }

    private func fetchScoreWithRetry(for rideId: UUID) async {
        // Index 0 fires immediately; indices 1..3 sleep first.
        let backoffsNs: [UInt64] = [0, 2_000_000_000, 5_000_000_000, 10_000_000_000]
        for (i, backoff) in backoffsNs.enumerated() {
            if backoff > 0 {
                try? await Task.sleep(nanoseconds: backoff)
            }
            do {
                let data = try await account.fetchRideScore(rideId: rideId)
                entries[rideId] = data.eligible ? .loaded(data) : .ineligible
                return
            } catch WebSyncClient.ClientError.http(status: 404) {
                // Score events not yet written.  Continue to next
                // backoff.  On the final attempt this falls through
                // to the post-loop ineligible assignment.
                if i == backoffsNs.count - 1 {
                    entries[rideId] = .ineligible
                }
            } catch {
                entries[rideId] = .failed
                return
            }
        }
    }

    /// Drop a specific ride's entry.  Call when a ride is deleted so a
    /// future re-restore of the same UUID doesn't surface stale cached
    /// data.
    func invalidate(_ rideId: UUID) {
        entries.removeValue(forKey: rideId)
    }

    /// Drop everything.  Use on web-account disconnect: the new (or
    /// absent) token can't read any of these rides' scores, and an old
    /// `.loaded` entry would surface stale data on top of a different
    /// account if the user re-pairs.
    func invalidateAll() {
        entries.removeAll()
    }
}
