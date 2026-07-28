import Foundation
import CryptoKit
import Observation
import OSLog

/// Per-ride status used by `SavedRidesView` to decorate each row with an icon.
/// "Synced" means "not in the unsynced queue right now" — which, for users who have
/// never paired, also means "no syncing has been attempted".  The view layer is
/// responsible for hiding the icon entirely when the user isn't connected.
enum RideSyncStatus: Equatable {
    case synced
    case queued
    case uploading
    case paused
    case waitingForAuth
}

/// Drives the upload of unsynced rides to bumpyride.me.  Owned by `ContentView` and
/// wired to:
///
///   - `RideStore.onRideSaved` → `enqueue(_:)` + `kick()`
///   - `RideStore.onRideDeleted` → `remove(_:)`
///   - `webAccount.isConnected` toggling true → `kick()`
///   - App launch (`ContentView.task`) → `kick()`
///
/// Serial: only one upload runs at a time.  `kick()` is idempotent — calling it while
/// a drain is already in flight is a no-op.  On transport / 5xx errors it backs off
/// (30 s → 2 min → 10 min → 1 h, capped) and schedules a retry timer; on 401 it
/// invalidates the account and waits for re-pairing; on 400 / 409 it logs and removes
/// the ride from the queue (these are non-retriable).
@Observable
@MainActor
final class SyncCoordinator {
    enum State: Equatable {
        case idle
        case syncing(remaining: Int)
        case waitingForAuth
        case paused(reason: String, retryAt: Date)
    }

    private(set) var state: State = .idle
    /// The ID of the ride currently being uploaded, or `nil` if nothing is in flight.
    /// Views observe this to mark the specific row with an "uploading right now"
    /// indicator instead of the generic "queued" one.
    private(set) var currentUploadingId: UUID?

    /// Snapshot of how many rides are pending upload.  Exposed for tab-badge binding
    /// since `SyncQueue.ids` already changes are observable through this class.
    var unsyncedCount: Int { queue.count }

    /// Whether a given ride is in the queue.  Useful for per-row UI checks.
    func isQueued(_ id: UUID) -> Bool { queue.contains(id) }

    /// Per-ride status used by row UI in `SavedRidesView`.
    func status(forRide id: UUID) -> RideSyncStatus {
        if currentUploadingId == id { return .uploading }
        guard queue.contains(id) else { return .synced }
        switch state {
        case .paused: return .paused
        case .waitingForAuth: return .waitingForAuth
        case .syncing, .idle: return .queued
        }
    }

    let queue: SyncQueue
    private let client: WebSyncClient
    private let storage: TokenStorage
    private weak var rideStore: RideStore?
    private weak var webAccount: WebAccount?

    /// Fires when a user-initiated ride uploads successfully — i.e.
    /// the upload of a freshly-saved ride completes, not a backfill
    /// ride.  ContentView wires this to `RideScoreCache.requestScoreWithRetry`
    /// so the per-ride score lands in cache while the user is still
    /// looking at the app, and the v1.7 level-up celebration can fire
    /// (H3) when the score crosses a threshold.
    ///
    /// Backfill uploads do NOT fire this callback — they don't need
    /// per-ride score auto-fetch (the user can lazy-fetch when they
    /// open them) and they don't trigger level-up celebrations.
    var onUserRideUploaded: ((UUID) -> Void)?

    /// v2.0 N1/N4 (ACHIEVEMENTS_IOS_HANDOFF): fired when an upload's
    /// sync response reports newly-earned achievements.  Only fired for
    /// fresh inserts (`updated != true`) per the handoff's dedupe
    /// guidance — re-uploads re-report their per-ride awards and would
    /// otherwise re-toast on every detector-revision backfill.
    /// ContentView presents the toast.
    var onAchievementsAwarded: (([WebSyncClient.AwardedAchievement]) -> Void)?

    private var drainTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var attempt: Int = 0
    private let log = Logger(subsystem: "com.herbertindustries.BumpyRide", category: "sync")

    /// Backoff schedule in seconds, indexed by attempt count.  Final entry is the cap.
    private let backoffSchedule: [TimeInterval] = [30, 120, 600, 3600]

    init(
        queue: SyncQueue,
        client: WebSyncClient = WebSyncClient(),
        storage: TokenStorage = TokenStorage(),
        rideStore: RideStore,
        webAccount: WebAccount
    ) {
        self.queue = queue
        self.client = client
        self.storage = storage
        self.rideStore = rideStore
        self.webAccount = webAccount
        if queue.isEmpty {
            self.state = .idle
        } else {
            self.state = .syncing(remaining: queue.count)
        }
    }

    // MARK: - Public API

    /// User just saved a ride — mark it for upload as user-initiated work
    /// (counts toward the tab badge).
    func enqueue(_ rideId: UUID) {
        queue.insert(rideId, isBackfill: false)
    }

    func remove(_ rideId: UUID) {
        queue.remove(rideId)
    }

    /// Mark every ride ID as unsynced *as backfill*.  Called when the user
    /// first pairs a web account so their existing local rides back up, and
    /// on launch when we were already paired.  Backfill rides upload the
    /// same way user-initiated ones do, but they're excluded from the tab
    /// badge — a freshly paired user with 50 historical rides shouldn't see
    /// the tab look like an unread-messages explosion.
    ///
    /// Already-queued rides are no-ops; if a ride is currently in the
    /// user-initiated bucket, backfill seeding leaves it there.  Server-side
    /// upsert is idempotent on `Ride.id`, so this is safe to call on every
    /// re-pair.
    func backfillAll(rideIds: some Sequence<UUID>) {
        for id in rideIds { queue.insert(id, isBackfill: true) }
    }

    /// Try to drain the queue if conditions are right.  Idempotent — safe to call
    /// from many event handlers.  Cancels any pending backoff timer so the user's
    /// implicit "do this now" intent (e.g. re-pairing) takes effect immediately.
    func kick() {
        retryTask?.cancel()
        retryTask = nil

        if queue.isEmpty {
            state = .idle
            return
        }
        if drainTask != nil { return }
        guard storage.load() != nil else {
            state = .waitingForAuth
            return
        }
        attempt = 0
        drainTask = Task { [weak self] in
            await self?.drain()
            self?.drainTask = nil
        }
    }

    // MARK: - Drain loop

    private func drain() async {
        // v2.0 O1: never drain against a store that hasn't finished its
        // async initial load — the loop below treats "queued id not in
        // store.rides" as locally-deleted and would remove the whole
        // queue.  ContentView's startup task kicks again right after
        // the load completes, so a deferred drain is only postponed.
        if let store = rideStore, !store.initialLoadComplete {
            log.info("Drain deferred — ride library still loading")
            state = .idle
            return
        }
        log.info("Starting drain — queued: \(self.queue.count, privacy: .public)")

        // v1.8 L1: prune the backfill queue with ONE batch check
        // round-trip instead of a per-ride check inside the loop.
        // With ~75 queued rides and nothing changed, the old path made
        // 75 sequential HTTP checks before concluding there was
        // nothing to do; the batch endpoint answers all of them at
        // once.  Encoding+hashing here is the same work the per-ride
        // path did — just front-loaded.
        //
        // On success, remaining queued backfill rides genuinely need
        // upload, so the in-loop per-ride check is skipped for this
        // drain (`batchPruned`).  On any failure — including 404 from
        // a server that hasn't deployed the endpoint yet — we fall
        // back silently to the per-ride path.  User-initiated rides
        // are excluded: they always upload (local copy is truth).
        var batchPruned = false
        if let stored = storage.load(), let store = rideStore {
            let backfillIds = queue.all().filter { !queue.userInitiatedIds.contains($0) }
            if backfillIds.count >= 2 {
                // v2.0 O2/P1: encode + hash streamed off-main, one ride
                // at a time from disk — the store only holds summaries
                // now, and nothing here needs the rides retained.
                let entries = await store.contentHashes(ids: backfillIds)
                if !entries.isEmpty {
                    do {
                        let needed = try await client.checkRidesBatch(entries: entries, token: stored.token)
                        for entry in entries where !needed.contains(entry.id) {
                            queue.remove(entry.id)
                        }
                        batchPruned = true
                        log.info("Batch check pruned \(entries.count - needed.count, privacy: .public)/\(entries.count, privacy: .public) backfill ride(s); \(self.queue.count, privacy: .public) still queued")
                    } catch WebSyncClient.ClientError.unauthorized {
                        log.error("401 from /api/sync/ride/check-batch — invalidating account")
                        webAccount?.invalidate()
                        state = .waitingForAuth
                        return
                    } catch {
                        log.debug("Batch check unavailable, falling back to per-ride checks: \(String(describing: error), privacy: .public)")
                    }
                }
            }
        }

        while !queue.isEmpty {
            guard let stored = storage.load() else {
                state = .waitingForAuth
                log.info("Drain stopped — no token in Keychain")
                return
            }
            guard let store = rideStore else {
                state = .idle
                return
            }

            // Pick the next queued ride that still exists locally.
            // User-initiated rides drain first; backfill fills the gaps
            // when no user-initiated work is queued.  Within each
            // bucket: oldest startedAt first.
            //
            // Why prioritize: a freshly-saved ride that lands during a
            // long backfill drain (e.g. just after pairing with the
            // web app and the catch-up upload of 50 historical rides
            // is mid-stream) used to wait behind every backfill ride
            // for upload.  That delayed score availability and the
            // level-up celebration by potentially 10+ minutes.
            // User-first ordering gets a new ride to the server in
            // seconds even when there's backlog work in flight.
            let queuedIds = queue.all()
            let queuedRides = queuedIds.compactMap { id in
                store.rides.first(where: { $0.id == id })
            }.sorted { $0.startedAt < $1.startedAt }

            // Remove any queued IDs whose ride is no longer present (deleted locally).
            for id in queuedIds where !queuedRides.contains(where: { $0.id == id }) {
                queue.remove(id)
            }

            let userInitiated = queuedRides.first { queue.userInitiatedIds.contains($0.id) }
            guard let next = userInitiated ?? queuedRides.first else {
                state = .idle
                return
            }

            state = .syncing(remaining: queue.count)

            // v2.0 O2/P1: the wire body is produced off-main from disk
            // on demand (`next` is only a summary now).  nil means the
            // ride file is gone — the user deleted it after enqueue —
            // so drop it from the queue, same as the old missing-ride
            // prune.
            guard let body = await store.encodedBody(id: next.id) else {
                log.error("Ride \(next.id, privacy: .public) missing or unreadable on disk — dropping from queue")
                queue.remove(next.id)
                continue
            }

            currentUploadingId = next.id
            // Capture the bucket BEFORE the upload because queue.remove
            // erases the membership info; the post-success callback fires
            // for user-initiated rides only (see onUserRideUploaded).
            let isUserInitiated = queue.userInitiatedIds.contains(next.id)
            defer { currentUploadingId = nil }

            // v1.7 H5: checksum-skip for backfill rides only.  A
            // freshly-paired user who's about to upload 50 historical
            // rides can skip any ride the server already has stored
            // with a matching content hash — saving multi-MB upload
            // per skip.  User-initiated rides ALWAYS upload: the
            // local copy is the source of truth, and a 50 ms check
            // round-trip would just delay the H1+H2+H3 fast-path.
            //
            // Check failures (transport, 5xx) silently fall through
            // to the upload path — never the wrong-answer scenario.
            //
            // v1.8 L1: skipped entirely when the batch check already
            // pruned this drain's backfill set — whatever survived
            // the prune genuinely needs upload.
            if !isUserInitiated && !batchPruned {
                let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
                do {
                    let result = try await client.checkRide(id: next.id, hash: hash, token: stored.token)
                    if result.exists && result.hashMatches {
                        log.debug("Backfill ride \(next.id, privacy: .public) already on server with matching hash — skipping upload")
                        queue.remove(next.id)
                        attempt = 0
                        continue
                    }
                } catch WebSyncClient.ClientError.unauthorized {
                    log.error("401 from /api/sync/ride/check — invalidating account")
                    webAccount?.invalidate()
                    state = .waitingForAuth
                    return
                } catch {
                    // Any other error from the check endpoint just
                    // falls through to the upload path — the worst
                    // case is we upload a ride the server already
                    // has, which is harmless (the upload endpoint is
                    // idempotent on ride id).
                    log.debug("checkRide error for \(next.id, privacy: .public), proceeding with upload: \(String(describing: error), privacy: .public)")
                }
            }

            do {
                // v1.8 L2: uploads go through the background URLSession
                // so a drain keeps advancing after the user locks the
                // screen or backgrounds the app.  Same status-code →
                // ClientError mapping as uploadRide, so the catch
                // clauses below are unchanged.
                let syncResponse = try await uploadViaBackgroundSession(body: body, rideId: next.id, token: stored.token)
                queue.remove(next.id)
                // v2.0 N1/N4: surface newly-earned achievements.  Fresh
                // inserts only (updated != true) — see the callback doc.
                if let awards = syncResponse?.achievementsAwarded,
                   !awards.isEmpty,
                   syncResponse?.updated != true {
                    onAchievementsAwarded?(awards)
                }
                attempt = 0  // reset backoff on success
                // .debug per upload — see WebSyncClient.uploadRide comment.
                // The "Drain complete" .info at the end still gives one
                // summary line per drain pass, which is the useful signal.
                log.debug("Uploaded ride \(next.id, privacy: .public); remaining \(self.queue.count, privacy: .public)")
                if isUserInitiated {
                    onUserRideUploaded?(next.id)
                }
            } catch WebSyncClient.ClientError.unauthorized {
                log.error("401 from /api/sync/ride — invalidating account")
                webAccount?.invalidate()
                state = .waitingForAuth
                return
            } catch WebSyncClient.ClientError.validationFailed {
                // Our payload doesn't match SCHEMA.md.  This is an iOS bug — the user
                // can't fix it.  Drop from queue so we don't loop forever; log loudly.
                log.error("400 from /api/sync/ride for \(next.id, privacy: .public) — dropping from queue")
                queue.remove(next.id)
            } catch WebSyncClient.ClientError.conflict {
                // Ride UUID is already owned by a different user account on the
                // server.  Can't be resolved without manual intervention; drop and
                // continue with the rest.
                log.error("409 from /api/sync/ride for \(next.id, privacy: .public) — dropping from queue")
                queue.remove(next.id)
            } catch WebSyncClient.ClientError.transport {
                schedulePause(reason: "Couldn't reach bumpyride.me")
                return
            } catch WebSyncClient.ClientError.http(let status) where (500...599).contains(status) {
                schedulePause(reason: "Server returned \(status)")
                return
            } catch WebSyncClient.ClientError.http(let status) {
                log.error("Unexpected status \(status) for \(next.id, privacy: .public) — dropping")
                queue.remove(next.id)
            } catch {
                log.error("Unexpected error \(error.localizedDescription, privacy: .public) — pausing")
                schedulePause(reason: "Unexpected error")
                return
            }
        }
        state = .idle
        log.info("Drain complete")
    }

    /// v1.8 L2: write the ride body to a temp file and hand it to the
    /// background session (background configurations require file-based
    /// uploads).  Maps HTTP status onto the same `ClientError` cases
    /// `uploadRide` threw, so `drain`'s error handling is untouched.
    /// The temp file is deleted by `BackgroundUploadClient`'s
    /// completion delegate in all outcomes — including completions
    /// that arrive after a process relaunch.
    ///
    /// v2.0 N1: returns the decoded sync response on success (nil when
    /// the body doesn't parse — old servers, or a relaunch-orphaned
    /// completion with an empty buffer; never a failure, the upload
    /// itself succeeded).
    @discardableResult
    private func uploadViaBackgroundSession(body: Data, rideId: UUID, token: String) async throws -> WebSyncClient.RideSyncResponse? {
        let request = await client.rideUploadRequest(token: token)
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BumpyRideUploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("\(rideId.uuidString).json")
        do {
            try body.write(to: fileURL)
        } catch {
            // Local I/O failure — treat as retryable, same as a
            // transport blip (disk-full clears, etc.).
            log.error("Couldn't stage upload body for \(rideId, privacy: .public): \(String(describing: error), privacy: .public)")
            throw WebSyncClient.ClientError.transport
        }

        let (status, responseBody) = try await BackgroundUploadClient.shared.upload(request: request, bodyFile: fileURL)
        switch status {
        case 200..<300:
            return try? JSONDecoder().decode(WebSyncClient.RideSyncResponse.self, from: responseBody)
        case 400:
            throw WebSyncClient.ClientError.validationFailed
        case 401:
            throw WebSyncClient.ClientError.unauthorized
        case 409:
            throw WebSyncClient.ClientError.conflict
        default:
            throw WebSyncClient.ClientError.http(status: status)
        }
    }

    private func schedulePause(reason: String) {
        let delay = backoffSchedule[min(attempt, backoffSchedule.count - 1)]
        let retryAt = Date().addingTimeInterval(delay)
        state = .paused(reason: reason, retryAt: retryAt)
        attempt += 1
        log.info("Pausing — attempt \(self.attempt, privacy: .public), retry in \(delay, privacy: .public)s")

        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            // Re-enter the drain loop.  Don't call kick() (which resets attempt) —
            // we want the backoff to escalate if the next attempt also fails.
            if !self.queue.isEmpty, self.drainTask == nil {
                self.drainTask = Task { [weak self] in
                    await self?.drain()
                    self?.drainTask = nil
                }
            } else if self.queue.isEmpty {
                self.state = .idle
            }
        }
    }
}
