import Foundation
import Observation
import OSLog

/// Orchestrates the download half of the server-side restore flow:
/// given a list of `RideManifest`s the caller has already fetched (and
/// the user has confirmed), iterates through them, downloads each full
/// payload, and persists via `RideStore.save(_:)` with server-wins
/// dedup.
///
/// The listing step (fetching pages from `/api/sync/rides`) is the
/// caller's responsibility — settings UI does it for the confirmation
/// preview ("X rides will be restored, ~Y MB").  This class focuses
/// only on what happens after the user taps Restore.
///
/// **Failure handling per ride** is independent — one bad ride doesn't
/// abort the whole restore:
///
/// - 404 (server doesn't have the ride): skip, count as skipped.
///   Shouldn't happen given a fresh manifest, but defended against.
/// - 429 (rate-limited): back off `backoffSeconds` and retry the same
///   ride, up to `maxRateLimitRetries` times.
/// - Decode error: skip.  Treated as a bad payload from the server.
/// - Transport error: retry once after a 1 s pause, then skip.
/// - 401 (token revoked): fatal.  The whole restore stops; caller
///   handles via the same WebAccount-invalidated flow used elsewhere.
///
/// **Cancellation** is cooperative via `Task.isCancelled`, checked
/// before each ride and after each backoff.  Cancelling mid-restore
/// preserves whatever was already saved — `RideStore.save` is atomic
/// per ride, so partial state is always coherent.
///
/// **Pacing**: 100 ms between rides per the contract in
/// `docs/SERVER_RESTORE_WEB_HANDOFF.md`.  Adjustable via
/// `pacingNanos` if the server side later signals it can handle more.
@Observable
@MainActor
final class RestoreCoordinator {
    /// State machine driving the progress UI.  `.idle` until `start` is
    /// called; transitions to `.downloading` for each ride; settles into
    /// one of the three terminal states (succeeded / cancelled / failed)
    /// when done.  All states are `Equatable` so the progress sheet can
    /// use `.onChange(of: coordinator.phase)`.
    enum Phase: Equatable, Sendable {
        case idle
        case downloading(currentIndex: Int, total: Int, currentTitle: String)
        case succeeded(restoredCount: Int, skippedCount: Int)
        case cancelled(restoredCount: Int)
        case failed(message: String, restoredCount: Int)
    }

    private static let log = Logger(subsystem: "com.herbertindustries.BumpyRide", category: "restore")

    private(set) var phase: Phase = .idle

    private let account: WebAccount
    private let store: RideStore

    /// In-flight task, kept so `cancel()` can target it.  Cleared when
    /// the task completes (success / cancelled / failed alike).
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Pace between rides, in nanoseconds.  100 ms = 10 req/s upper
    /// bound, matching the contract recommendation in the handoff doc.
    private static let pacingNanos: UInt64 = 100_000_000

    /// Backoff applied on a 429 before retrying the same ride.
    private static let backoffSeconds: UInt64 = 5

    /// Max number of 429 retries per ride before giving up and counting
    /// it as skipped.  Caps worst-case stalling on a single bad ride at
    /// `maxRateLimitRetries * backoffSeconds`.
    private static let maxRateLimitRetries: Int = 3

    /// Number of transport-error retries per ride.  Just one — we'd
    /// rather move on to the next ride than burn time on a flapping
    /// network for one.  The whole flow will be re-runnable later by
    /// the user.
    private static let transportRetriesPerRide: Int = 1

    init(account: WebAccount, store: RideStore) {
        self.account = account
        self.store = store
    }

    /// Begin downloading the supplied manifests.  Caller provides the
    /// already-listed and user-confirmed list; this class doesn't touch
    /// `/api/sync/rides`.  Server-wins on conflicts (each download
    /// overwrites any local copy with the same id via the standard
    /// `RideStore.save(_:)` upsert).
    ///
    /// Idempotent re-entry: if already downloading, this is a no-op.
    /// To start a new restore after a terminal phase (succeeded /
    /// cancelled / failed), `reset()` first then `start`.
    func start(restoring manifests: [WebSyncClient.RideManifest]) {
        if case .downloading = phase { return }
        let total = manifests.count
        // Show progress on the first ride immediately so the sheet's
        // first frame after the user taps Restore isn't a stale
        // "Ready" state.
        phase = .downloading(
            currentIndex: 0,
            total: total,
            currentTitle: manifests.first?.title ?? ""
        )
        task = Task { @MainActor [weak self] in
            await self?.runDownloads(manifests)
            self?.task = nil
        }
    }

    /// Cancel the in-flight restore (if any).  Cooperative — the loop
    /// checks `Task.isCancelled` at safe boundaries.  Rides already
    /// downloaded and saved are preserved; the next-up ride does not
    /// start.  Phase transitions to `.cancelled(restoredCount:)`.
    func cancel() {
        task?.cancel()
    }

    /// Reset to `.idle` so a new restore can begin.  Safe to call from
    /// any state; cancels any in-flight task first.
    func reset() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    // MARK: - Internal

    private func runDownloads(_ manifests: [WebSyncClient.RideManifest]) async {
        var restored = 0
        var skipped = 0
        let total = manifests.count

        for (index, manifest) in manifests.enumerated() {
            if Task.isCancelled {
                phase = .cancelled(restoredCount: restored)
                return
            }

            phase = .downloading(
                currentIndex: index,
                total: total,
                currentTitle: manifest.title
            )

            let outcome = await downloadOne(manifest)
            switch outcome {
            case .saved:
                restored += 1
            case .skipped:
                skipped += 1
            case .cancelled:
                phase = .cancelled(restoredCount: restored)
                return
            case .fatal(let message):
                phase = .failed(message: message, restoredCount: restored)
                return
            }

            // Pacing — wait briefly before the next request.  Skip the
            // delay after the last ride to avoid a useless final
            // sleep.
            if index < total - 1 {
                try? await Task.sleep(nanoseconds: Self.pacingNanos)
            }
        }

        phase = .succeeded(restoredCount: restored, skippedCount: skipped)
    }

    /// Result of attempting to download + save one ride.  Distinguishes
    /// the four outcomes the orchestrator needs to act on differently.
    private enum DownloadOutcome {
        case saved
        case skipped
        case cancelled
        case fatal(message: String)
    }

    private func downloadOne(_ manifest: WebSyncClient.RideManifest) async -> DownloadOutcome {
        var rateLimitRetriesLeft = Self.maxRateLimitRetries
        var transportRetriesLeft = Self.transportRetriesPerRide

        while true {
            do {
                let ride = try await account.downloadRide(rideId: manifest.id)
                store.save(ride)
                return .saved
            } catch WebSyncClient.ClientError.unauthorized {
                // Token died.  WebAccount has already invalidated;
                // the whole restore can't continue.
                Self.log.error("Restore stopped: unauthorized")
                return .fatal(message: "Your sign-in expired. Sign in again and try restoring.")
            } catch WebSyncClient.ClientError.http(status: 404) {
                Self.log.notice("Skip \(manifest.id, privacy: .public): 404")
                return .skipped
            } catch WebSyncClient.ClientError.http(status: 429) {
                if rateLimitRetriesLeft <= 0 {
                    Self.log.notice("Skip \(manifest.id, privacy: .public): rate-limit retries exhausted")
                    return .skipped
                }
                rateLimitRetriesLeft -= 1
                Self.log.notice("Rate-limited; backing off \(Self.backoffSeconds, privacy: .public)s")
                try? await Task.sleep(nanoseconds: Self.backoffSeconds * 1_000_000_000)
                if Task.isCancelled { return .cancelled }
                continue
            } catch WebSyncClient.ClientError.decoding {
                Self.log.error("Skip \(manifest.id, privacy: .public): decode failure")
                return .skipped
            } catch WebSyncClient.ClientError.transport {
                if transportRetriesLeft <= 0 {
                    Self.log.error("Skip \(manifest.id, privacy: .public): transport, no retries left")
                    return .skipped
                }
                transportRetriesLeft -= 1
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return .cancelled }
                continue
            } catch {
                // Anything else (validationFailed, unexpected http codes):
                // skip the ride.  Don't abort the whole batch on one
                // unexpected error.
                Self.log.error("Skip \(manifest.id, privacy: .public): \(String(describing: error), privacy: .public)")
                return .skipped
            }
        }
    }
}
