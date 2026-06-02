import Foundation
import Observation
import OSLog
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// iOS-side owner of the WatchConnectivity session.  Mirrors the
/// shape of other root-level coordinators (`SyncCoordinator`,
/// `RestoreCoordinator`) — `@Observable @MainActor`, single instance
/// held by `ContentView`, with `nonisolated` log so callbacks coming
/// off the WCSession delegate thread can write to it freely.
///
/// **Phase A** wires up the basics: activate the session on launch,
/// publish reachability + installed-app status as observable values,
/// and surface activation errors via `lastError`.  Snapshot push and
/// command handling are stubs that Phase B fills in.
///
/// **Why a separate object instead of folding into one of the
/// existing coordinators**: the WC session has a strong NSObject
/// delegate requirement and an activation lifecycle that doesn't fit
/// the existing patterns; isolating it keeps the iOS app's state
/// model legible.
@Observable
@MainActor
final class WatchCoordinator: NSObject {
    // `Logger` is thread-safe; mark nonisolated so the WCSessionDelegate
    // callbacks (which arrive on a background queue) can write logs
    // without an actor hop.
    nonisolated private static let log = Logger(subsystem: "com.herbertindustries.BumpyRide", category: "watch")

    /// Lifecycle of the WCSession from this app's perspective.  Mirrors
    /// `WCSessionActivationState` but adds an `unavailable` case for
    /// devices that don't support WatchConnectivity at all (iPad without
    /// a paired watch, etc.) so the UI can hide watch-related affordances
    /// cleanly.
    enum SessionState: Equatable, Sendable {
        case unavailable
        case notActivated
        case activating
        case activated
        case failed(message: String)
    }

    private(set) var sessionState: SessionState

    /// True when the counterpart watch app is reachable RIGHT NOW (e.g.
    /// foregrounded or actively in our extended runtime window).  Drives
    /// the "send real-time message" vs "queue via transferUserInfo"
    /// branching in Phase D.
    private(set) var isReachable: Bool = false

    /// True when the user has paired an Apple Watch to this iPhone.
    /// False on a phone with no watch ever paired.
    private(set) var isPaired: Bool = false

    /// True when our specific companion app (BumpyRideWatchApp) is
    /// installed on the paired watch.  False if the user paired a watch
    /// but never installed our watch app from the iPhone Watch app.
    private(set) var isWatchAppInstalled: Bool = false

    /// Last error from session activation, if any.  Cleared on next
    /// successful activation.
    private(set) var lastError: String?

    #if canImport(WatchConnectivity)
    /// The shared WC session if WatchConnectivity is available on this
    /// device, nil otherwise.  Lazily resolved at init.
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
    /// already activating or activated is a no-op.  Called by
    /// `ContentView.task` once at launch.
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

    /// **Phase B will fill this in.**  Pushes the snapshot to the watch
    /// via `updateApplicationContext` (replaceable, queued, survives
    /// backgrounding).  Phase A: no-op.
    func sendSnapshot(_ snapshot: WatchSnapshot) {
        // Stub — implemented in Phase B.
    }

    /// **Phase D will fill this in.**  Routes a command received from
    /// the watch into `RideRecorder` (pause/resume/stop/closeCall).
    /// Phase A: no-op.
    fileprivate func handle(command: WatchCommand) {
        // Stub — implemented in Phase D.
    }
}

#if canImport(WatchConnectivity)
extension WatchCoordinator: WCSessionDelegate {
    // WCSessionDelegate callbacks arrive on a background dispatch queue,
    // so each delegate method is `nonisolated` and hops to the main
    // actor before touching our observable state.

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let reachableNow = session.isReachable
        let pairedNow = session.isPaired
        let installedNow = session.isWatchAppInstalled
        let errorMessage = error.map { String(describing: $0) }
        Self.log.info("WCSession activation completed: state=\(activationState.rawValue, privacy: .public) paired=\(pairedNow, privacy: .public) installed=\(installedNow, privacy: .public) reachable=\(reachableNow, privacy: .public)")
        Task { @MainActor in
            self.isReachable = reachableNow
            self.isPaired = pairedNow
            self.isWatchAppInstalled = installedNow
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

    // iOS-only delegate methods.  The watch counterpart doesn't have
    // these.  Apple requires both to be implemented even if empty —
    // they're called when the user pairs/unpairs a watch or switches
    // between paired watches.
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Self.log.notice("WCSession became inactive")
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Self.log.notice("WCSession deactivated — re-activating to attach to new watch if any")
        // Apple's documented re-activation flow: after deactivation
        // (e.g. user switched watches), call activate() again so the
        // session re-binds to the newly-active watch.
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachableNow = session.isReachable
        Self.log.info("WCSession reachability changed: \(reachableNow, privacy: .public)")
        Task { @MainActor in
            self.isReachable = reachableNow
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let pairedNow = session.isPaired
        let installedNow = session.isWatchAppInstalled
        Self.log.info("WCSession watch state changed: paired=\(pairedNow, privacy: .public) installed=\(installedNow, privacy: .public)")
        Task { @MainActor in
            self.isPaired = pairedNow
            self.isWatchAppInstalled = installedNow
        }
    }

    // Phase C will fill this in with applicationContext snapshot
    // push (iOS → Watch direction).  No incoming application
    // context expected from the watch side in our design.
    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Self.log.notice("Received applicationContext (unexpected — watch shouldn't push these)")
    }

    /// Sendable-payload no-reply variant.  Phase D will dispatch real
    /// commands here (pause / resume / stop / closeCall).  Phase B
    /// uses the reply variant below for the ping round-trip.
    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        if let command = WatchPayload.decodeCommand(from: message) {
            Self.log.notice("Received command (no reply): \(String(describing: command), privacy: .public)")
            Task { @MainActor in self.handle(command: command) }
        } else {
            Self.log.notice("Received unrecognized message (no reply)")
        }
    }

    /// Reply variant.  Phase B uses this for the `.ping` connectivity
    /// health check — watch sends `.ping`, iOS replies immediately
    /// with `["pong": true]` so the watch can confirm the round-trip.
    /// Phase D's commands that need acknowledgments (e.g. stop with
    /// save) will also use this path.
    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard let command = WatchPayload.decodeCommand(from: message) else {
            Self.log.notice("Received unrecognized message-with-reply")
            replyHandler([:])
            return
        }
        Self.log.notice("Received command (with reply): \(String(describing: command), privacy: .public)")
        switch command {
        case .ping:
            // Immediate pong — no main-actor hop needed.
            replyHandler(["pong": true])
        default:
            // Phase D will route these into RideRecorder.  For now
            // reply with a "received" ack so the watch isn't left
            // hanging on the reply handler.
            replyHandler(["received": true])
            Task { @MainActor in self.handle(command: command) }
        }
    }

    /// Queued (offline-replay) command path.  Used by the watch when
    /// the iPhone isn't reachable: command goes into the
    /// `transferUserInfo` queue and lands here when the apps reconnect.
    /// Same dispatch as the no-reply message variant.
    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        if let command = WatchPayload.decodeCommand(from: userInfo) {
            Self.log.notice("Received queued command: \(String(describing: command), privacy: .public)")
            Task { @MainActor in self.handle(command: command) }
        } else {
            Self.log.notice("Received unrecognized userInfo")
        }
    }
}
#endif
