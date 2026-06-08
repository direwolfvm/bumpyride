import Foundation
import Observation
import OSLog

/// Watches for user-level level-ups after a freshly-saved ride
/// uploads, and emits a `pendingCelebration` value the UI binds to
/// for the level-up sheet (v1.7 H3).
///
/// **Flow**: SyncCoordinator's `onUserRideUploaded` fires →
/// ContentView calls `checkAfterRideUpload()` → monitor fetches
/// `/api/me/score` with retry/backoff (same shape as
/// `RideScoreCache.requestScoreWithRetry` — server may need a
/// moment to update lifetime totals) → compares the returned
/// `level.index` against `lastSeenLevelIndex` persisted in
/// UserDefaults.  If it's higher (and we have a previously-seen
/// value to compare against), `pendingCelebration` is set and the
/// sheet binding observes the change.
///
/// **First-run semantics**: `lastSeenLevelIndex` defaults to `-1`
/// when uninitialized.  On first run we just *seed* the stored
/// value without celebrating — wouldn't want to congratulate the
/// user for the level they were already at before installing
/// v1.7.
///
/// **Retry rationale**: the server processes ride uploads
/// asynchronously.  At the moment `onUserRideUploaded` fires, the
/// ride payload is in the database but the score events and user
/// totals may not yet be computed.  We retry through 17 s of
/// backoff watching for the level number to change; if it doesn't,
/// the new ride simply didn't push the user across a threshold.
@Observable
@MainActor
final class LevelProgressionMonitor {
    nonisolated private static let log = Logger(
        subsystem: "com.herbertindustries.BumpyRide",
        category: "score"
    )

    /// Payload for the celebration sheet.  Set by
    /// `checkAfterRideUpload()` when a level-up is detected;
    /// cleared by `acknowledgeCelebration()` when the user
    /// dismisses the sheet.  `Identifiable` so SwiftUI's
    /// `.sheet(item:)` can present it directly.
    struct PendingCelebration: Identifiable, Equatable, Sendable {
        let id: UUID
        let previousLevelName: String
        let newLevel: WebSyncClient.CurrentLevel
    }

    private(set) var pendingCelebration: PendingCelebration?

    @ObservationIgnored private let account: WebAccount

    /// UserDefaults key for the index of the level the user last
    /// saw a confirmation of.  -1 = unset (first-run path).
    private static let key = "lastSeenLevelIndex"

    init(account: WebAccount) {
        self.account = account
    }

    /// Fetch user score with retry/backoff and emit a
    /// `pendingCelebration` if `level.index` increased over what
    /// we last stored.  Safe to call concurrently — the
    /// pendingCelebration property is the only mutable shared
    /// state, and SwiftUI will pick up the latest value either way.
    func checkAfterRideUpload() async {
        let defaults = UserDefaults.standard
        let lastSeen = (defaults.object(forKey: Self.key) as? Int) ?? -1

        let backoffsNs: [UInt64] = [0, 2_000_000_000, 5_000_000_000, 10_000_000_000]
        for (i, backoff) in backoffsNs.enumerated() {
            if backoff > 0 {
                try? await Task.sleep(nanoseconds: backoff)
            }
            do {
                let data = try await account.fetchScore()
                let currentIndex = data.level.index

                // First-run seed.  Just stamp the stored value so
                // the next ride upload has a baseline to compare
                // against.
                if lastSeen == -1 {
                    defaults.set(currentIndex, forKey: Self.key)
                    Self.log.info("Seeded lastSeenLevelIndex=\(currentIndex, privacy: .public) on first run")
                    return
                }

                if currentIndex > lastSeen {
                    let previousName = data.levels.first(where: { $0.index == lastSeen })?.name
                        ?? "Previous level"
                    pendingCelebration = PendingCelebration(
                        id: UUID(),
                        previousLevelName: previousName,
                        newLevel: data.level
                    )
                    defaults.set(currentIndex, forKey: Self.key)
                    Self.log.info("Level up detected: \(lastSeen, privacy: .public) → \(currentIndex, privacy: .public) (\(data.level.name, privacy: .public))")
                    return
                }

                if currentIndex < lastSeen {
                    // Backslide — rare; could be a data correction
                    // server-side (e.g. user cleared their data and
                    // re-restored partial).  Don't celebrate going
                    // backwards; quietly update the stamp.
                    defaults.set(currentIndex, forKey: Self.key)
                    Self.log.notice("Level backslide: \(lastSeen, privacy: .public) → \(currentIndex, privacy: .public); stamp updated")
                    return
                }

                // Same level as before — possibly the server is
                // still computing.  Retry unless exhausted.
                if i == backoffsNs.count - 1 {
                    Self.log.info("Level check exhausted at index \(currentIndex, privacy: .public); no level-up this ride")
                    return
                }
            } catch {
                Self.log.notice("Level fetch failed (attempt \(i + 1, privacy: .public)): \(String(describing: error), privacy: .public)")
                // Network / auth error — don't burn through the
                // entire backoff loop on a permanently-broken
                // connection.  Stop here.
                return
            }
        }
    }

    /// Clear the pending celebration after the sheet's user-
    /// initiated dismissal.  The sheet binding writes nil on
    /// dismiss, which calls this via the binding's setter.
    func acknowledgeCelebration() {
        pendingCelebration = nil
    }
}
