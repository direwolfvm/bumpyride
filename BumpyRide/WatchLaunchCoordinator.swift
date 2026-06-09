import Foundation
import Observation
import OSLog
#if canImport(HealthKit)
import HealthKit
#endif

/// iOS side of the v1.7 watch HealthKit handoff.  When the user opts
/// in via Settings ("Open watch app with this app"), we call
/// `HKHealthStore.startWatchApp(toHandle:)` on iPhone-app foreground
/// to launch the BumpyRideWatchApp on the user's wrist and hand it
/// an `HKWorkoutConfiguration` — which the watch then uses to spin
/// up an `HKWorkoutSession` and start heart-rate monitoring.
///
/// Several gates must all be true before we actually call
/// startWatchApp.  Each fail mode lands us in
/// `.skipped(reason:)` instead of `.failed(...)` so the difference
/// between "user didn't want this" and "system rejected the call"
/// is visible in logs.  No user-visible UI for either branch in
/// Phase C — Phase G could optionally surface launch failures, but
/// for now we lean on the fact that startWatchApp is idempotent and
/// will be retried on the next foreground.
///
/// **Idempotency**: Apple documents `startWatchApp(toHandle:)` as
/// safe to call repeatedly within a session.  We call on every
/// scene `.active` transition in `ContentView`, which is the
/// simplest correct cadence — the system de-dupes if the watch app
/// is already running with the same configuration.
@Observable
@MainActor
final class WatchLaunchCoordinator {
    // DebugLog so each launch attempt's gate snapshot lands in the
    // sidecar file when the user has Diagnostics → Write Debug Log
    // toggled on.  Diagnosing "the watch app isn't launching" is
    // exactly the kind of thing Console.app can't see from a
    // wrist-bound device, so we want the trail in iCloud.
    nonisolated private static let log = DebugLog(category: "watch-launch")

    /// Result of the most recent `considerLaunchingWatchApp()` call.
    /// Mostly for OSLog / future debug UI; nothing currently binds to
    /// it for rendering.  `.idle` is the pre-first-call state.
    enum LaunchState: Equatable, Sendable {
        case idle
        case launching
        case launched
        /// One of the gates failed.  Distinct from `.failed` so logs
        /// can distinguish "user has the toggle off" from "system
        /// said no" without ambiguity.
        case skipped(reason: String)
        /// The system rejected the call — entitlement missing,
        /// HealthKit unavailable mid-call, etc.  Rare in normal use.
        case failed(message: String)
    }

    private(set) var state: LaunchState = .idle

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let watchCoordinator: WatchCoordinator
    @ObservationIgnored private let healthKitAuth: HealthKitAuthManager

    init(
        settings: AppSettings,
        watchCoordinator: WatchCoordinator,
        healthKitAuth: HealthKitAuthManager
    ) {
        self.settings = settings
        self.watchCoordinator = watchCoordinator
        self.healthKitAuth = healthKitAuth
    }

    /// Evaluate all gates and, if they pass, call
    /// `HKHealthStore.startWatchApp(toHandle:)` with a cycling/
    /// outdoor workout configuration.  Updates `state` based on the
    /// outcome.  Safe to call repeatedly; the system de-dupes when
    /// the watch is already running with the same configuration.
    func considerLaunchingWatchApp() async {
        // Snapshot every gate value up front so the sidecar log line
        // shows the full decision context in one place.  Easier to
        // diagnose "why didn't the watch app launch" when you can
        // see all five booleans together rather than chasing the
        // first guard that fired.
        let toggleOn = settings.openWatchAppOnLaunch
        let paired = watchCoordinator.isPaired
        let installed = watchCoordinator.isWatchAppInstalled
        let hkAvailable = healthKitAuth.isAvailable
        let hkCanWrite = healthKitAuth.canWrite
        Self.log.info("considerLaunchingWatchApp gates: toggle=\(toggleOn) paired=\(paired) installed=\(installed) hkAvailable=\(hkAvailable) hkCanWrite=\(hkCanWrite)")

        // Gate 1: user opted in.  Default state — most users will
        // land here.
        guard toggleOn else {
            state = .skipped(reason: "openWatchAppOnLaunch is off")
            Self.log.info("Skipped: openWatchAppOnLaunch is off")
            return
        }

        // Gate 2: watch is paired and our companion is installed.
        // WatchCoordinator's published booleans reflect the latest
        // WCSession state — they're updated via the
        // sessionWatchStateDidChange delegate callback.  If the user
        // sees the watch app on their wrist but `installed` is false
        // here, that's the classic signing-chain mismatch (the watch
        // app present is from a different Xcode session / cert).
        guard paired else {
            state = .skipped(reason: "no paired Apple Watch")
            Self.log.info("Skipped: no paired Apple Watch")
            return
        }
        guard installed else {
            state = .skipped(reason: "BumpyRide watch app not installed")
            Self.log.info("Skipped: WCSession reports watch app not installed (signing chain mismatch is most common cause when icon is visible on wrist)")
            return
        }

        // Gate 3: HealthKit is available and we have auth.
        // `canWrite` requires that the user has been through the
        // v1.5 HealthKit auth sheet at least once — the same prompt
        // they granted for the Apple Health integration.  Without
        // it, startWatchApp's call would error anyway, so we
        // short-circuit gracefully.
        #if canImport(HealthKit)
        guard let store = healthKitAuth.store else {
            state = .skipped(reason: "HealthKit unavailable")
            Self.log.info("Skipped: HealthKit store unavailable")
            return
        }
        guard hkCanWrite else {
            state = .skipped(reason: "HealthKit auth not granted")
            Self.log.info("Skipped: HealthKit canWrite is false (user hasn't completed the Apple Health auth sheet)")
            return
        }

        // Build the workout configuration.  Cycling + outdoor
        // matches what our v1.5 Apple Health exporter writes for
        // saved rides, so the auto-launched watch session
        // describes the same activity the iPhone will eventually
        // persist a workout for.
        let config = HKWorkoutConfiguration()
        config.activityType = .cycling
        config.locationType = .outdoor

        state = .launching
        Self.log.info("Calling startWatchApp(toHandle: cycling/outdoor)")
        do {
            try await store.startWatchApp(toHandle: config)
            state = .launched
            Self.log.info("startWatchApp returned without throwing — watch app should be launching")
        } catch {
            let message = String(describing: error)
            Self.log.error("startWatchApp failed: \(message)")
            state = .failed(message: message)
        }
        #else
        state = .skipped(reason: "HealthKit not built in")
        Self.log.info("Skipped: HealthKit not built in")
        #endif
    }
}
