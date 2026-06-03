import Foundation
import Observation
import OSLog
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// Watch-side owner of the WatchConnectivity session.  Mirror of the
/// iOS `WatchCoordinator` shape, adapted to the watchOS WCSession
/// surface (no `isPaired` / `isWatchAppInstalled` — those exist only
/// on the iOS side; watchOS infers paired-ness from the fact that the
/// app is running at all).
///
/// **Phase B** establishes the session, publishes connectivity state,
/// and implements `send(_:)` for outgoing commands.  Phase C adds the
/// snapshot-receive path that updates the UI from incoming
/// `applicationContext` payloads.  Phases D-F use `send(_:)` for the
/// real Pause/Resume/Stop/CloseCall buttons.
@Observable
@MainActor
final class WatchSessionManager: NSObject {
    // Nonisolated so the WCSessionDelegate callbacks (which arrive on
    // a background queue) can log directly.
    nonisolated private static let log = Logger(subsystem: "com.herbertindustries.BumpyRide.watchkitapp", category: "watch")

    /// Lifecycle of the WC session from the watch's perspective.
    /// Mirrors `WCSessionActivationState` with an `unavailable` case
    /// for devices that can't support WatchConnectivity at all (a
    /// theoretical future watchOS that drops the framework, or a
    /// configuration where the OS refuses to activate).
    enum SessionState: Equatable, Sendable {
        case unavailable
        case notActivated
        case activating
        case activated
        case failed(message: String)
    }

    private(set) var sessionState: SessionState

    /// True when the iPhone counterpart app is reachable RIGHT NOW.
    /// Drives the watch UI's "Phone connected" indicator and the
    /// `send(_:)` transport branch (sendMessage if reachable, else
    /// transferUserInfo for queued delivery).
    private(set) var isReachable: Bool = false

    /// Latest snapshot received from iOS via `applicationContext`.
    /// Updated by Phase C's delegate handler; Phase B leaves this at
    /// `.idle`.  Watch UI binds to this for state display.
    private(set) var lastSnapshot: WatchSnapshot = .idle

    /// Last error encountered (activation failure, send failure, etc.).
    /// Cleared on next successful operation of that kind.
    private(set) var lastError: String?

    /// Result of the most recent `ping(...)` attempt — `.none` if never
    /// pinged, `.success` on confirmed round-trip, `.failure(...)` on
    /// timeout / transport error / unreachable.  Used by the Phase B
    /// "Ping iPhone" button to give the user explicit verification of
    /// the connectivity round-trip, separate from the framework's
    /// passive `isReachable` flag.
    enum PingResult: Equatable, Sendable {
        case none
        case pending
        case success
        case failure(message: String)
    }
    private(set) var pingResult: PingResult = .none

    #if canImport(WatchConnectivity)
    private let session: WCSession?
    #endif

    override init() {
        #if canImport(WatchConnectivity)
        if WCSession.isSupported() {
            self.session = WCSession.default
            self.sessionState = .notActivated
        } else {
            self.session = nil
            self.sessionState = .unavailable
        }
        #else
        self.sessionState = .unavailable
        #endif
        super.init()
    }

    /// Begin session activation.  Idempotent — calling repeatedly while
    /// already activating or activated is a no-op.  Called by the watch
    /// app's `@main` on launch.
    func activate() {
        #if canImport(WatchConnectivity)
        guard let session else {
            sessionState = .unavailable
            return
        }
        switch sessionState {
        case .activating, .activated:
            return
        case .unavailable, .notActivated, .failed:
            break
        }
        sessionState = .activating
        session.delegate = self
        session.activate()
        Self.log.info("WCSession.activate() called")
        #endif
    }

    /// Send a `.ping` to iOS and wait for the `["pong": true]` reply.
    /// Updates `pingResult` so the UI can show "✓ Round-trip OK" or
    /// the failure reason.  Used by the Phase B verification button to
    /// give the user proof the WCSession transport is working end-to-end,
    /// not just that `isReachable` happens to be true.
    func ping() {
        #if canImport(WatchConnectivity)
        guard let session, case .activated = sessionState else {
            pingResult = .failure(message: "Session not activated")
            return
        }
        guard session.isReachable else {
            pingResult = .failure(message: "iPhone not reachable")
            return
        }
        pingResult = .pending
        let payload: [String: Any]
        do {
            payload = try WatchPayload.encode(WatchCommand.ping)
        } catch {
            pingResult = .failure(message: "Encode failed")
            return
        }
        session.sendMessage(payload, replyHandler: { reply in
            let ok = (reply["pong"] as? Bool) == true
            Task { @MainActor in
                self.pingResult = ok ? .success : .failure(message: "Unexpected reply")
            }
        }, errorHandler: { error in
            Task { @MainActor in
                self.pingResult = .failure(message: String(describing: error))
            }
        })
        #else
        pingResult = .failure(message: "WatchConnectivity unavailable")
        #endif
    }

    /// Send a command to iOS.  Uses real-time `sendMessage` when the
    /// counterpart is reachable; falls back to `transferUserInfo` for
    /// queued delivery when not.  Per the v1.6 offline-behavior design:
    /// the close-call safety affordance never silently fails — taps
    /// during a disconnect get queued for replay when the iPhone comes
    /// back into range.
    ///
    /// Phase B includes this so Phase D's button taps have a working
    /// transport.  Phase B itself doesn't surface any UI that calls
    /// it — the user can verify connectivity by observing `isReachable`
    /// flip when the simulator pairs come up.
    func send(_ command: WatchCommand) {
        #if canImport(WatchConnectivity)
        guard let session else { return }
        guard case .activated = sessionState else {
            Self.log.notice("send(\(String(describing: command), privacy: .public)) ignored: session not activated")
            return
        }
        let payload: [String: Any]
        do {
            payload = try WatchPayload.encode(command)
        } catch {
            Self.log.error("Failed to encode command \(String(describing: command), privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }
        if session.isReachable {
            // Real-time path.  Fast (sub-100ms typical) but requires
            // both apps reachable.  Fallback to queued transport if
            // sendMessage errors out (e.g., reachability just dropped
            // between our check and the send).
            session.sendMessage(payload, replyHandler: nil) { error in
                Self.log.notice("sendMessage failed, queuing via transferUserInfo: \(String(describing: error), privacy: .public)")
                session.transferUserInfo(payload)
            }
        } else {
            // Queued path.  Survives backgrounding on either side and
            // replays when both apps + reachability come back.  This is
            // what makes the close-call safety affordance reliable.
            session.transferUserInfo(payload)
        }
        #endif
    }
}

#if canImport(WatchConnectivity)
extension WatchSessionManager: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let reachableNow = session.isReachable
        let errorMessage = error.map { String(describing: $0) }
        Self.log.info("WCSession activation completed: state=\(activationState.rawValue, privacy: .public) reachable=\(reachableNow, privacy: .public)")
        Task { @MainActor in
            self.isReachable = reachableNow
            if let errorMessage {
                self.sessionState = .failed(message: errorMessage)
                self.lastError = errorMessage
            } else if activationState == .activated {
                self.sessionState = .activated
                self.lastError = nil
            } else {
                self.sessionState = .notActivated
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachableNow = session.isReachable
        Self.log.info("Reachability changed: \(reachableNow, privacy: .public)")
        Task { @MainActor in
            self.isReachable = reachableNow
        }
    }

    // Note: WCSessionDelegate's `sessionDidBecomeInactive` and
    // `sessionDidDeactivate` are explicitly marked
    // `@available(watchOS, unavailable)` in the framework headers —
    // those concepts only apply on iOS where the user can re-pair
    // their phone with a different watch.  We must NOT declare them
    // here on watchOS; the iOS `WatchCoordinator` is where they live.

    /// Receive the latest snapshot iOS has pushed via
    /// `updateApplicationContext`.  Decode and publish to `lastSnapshot`
    /// — the UI binds to that and re-renders.  Apple delivers the
    /// *latest* context on app launch as well, so the watch UI shows
    /// the iPhone's last-known state immediately on resume.
    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        guard let snapshot = WatchPayload.decodeSnapshot(from: applicationContext) else {
            Self.log.notice("Received unrecognized applicationContext")
            return
        }
        Self.log.info("Received snapshot: state=\(snapshot.state.rawValue, privacy: .public) elapsed=\(snapshot.elapsedSeconds, format: .fixed(precision: 1), privacy: .public)")
        Task { @MainActor in
            self.lastSnapshot = snapshot
        }
    }
}
#endif
