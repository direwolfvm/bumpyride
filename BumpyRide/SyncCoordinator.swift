import Foundation
import Observation
import OSLog

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

    private let queue: SyncQueue
    private let client: WebSyncClient
    private let storage: TokenStorage
    private weak var rideStore: RideStore?
    private weak var webAccount: WebAccount?

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

    func enqueue(_ rideId: UUID) {
        queue.insert(rideId)
    }

    func remove(_ rideId: UUID) {
        queue.remove(rideId)
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
        log.info("Starting drain — queued: \(self.queue.count, privacy: .public)")
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

            // Pick the oldest queued ride that still exists locally.
            let queuedIds = queue.all()
            let queuedRides = queuedIds.compactMap { id in
                store.rides.first(where: { $0.id == id })
            }.sorted { $0.startedAt < $1.startedAt }

            // Remove any queued IDs whose ride is no longer present (deleted locally).
            for id in queuedIds where !queuedRides.contains(where: { $0.id == id }) {
                queue.remove(id)
            }

            guard let next = queuedRides.first else {
                state = .idle
                return
            }

            state = .syncing(remaining: queue.count)

            // Encode the Ride here on the MainActor — `Ride.Encodable` is MainActor-
            // isolated (project default), so it can't be called from inside the
            // WebSyncClient actor.  We hand the actor raw bytes instead.
            let body: Data
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                body = try encoder.encode(next)
            } catch {
                log.error("Failed to encode ride \(next.id, privacy: .public) — dropping from queue")
                queue.remove(next.id)
                continue
            }

            do {
                try await client.uploadRide(jsonBody: body, token: stored.token)
                queue.remove(next.id)
                attempt = 0  // reset backoff on success
                log.info("Uploaded ride \(next.id, privacy: .public); remaining \(self.queue.count, privacy: .public)")
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
