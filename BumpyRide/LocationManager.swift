import Foundation
import CoreLocation
import Observation
import OSLog

/// Wraps `CLLocationManager` for ride recording.  Configured for cycling-grade GPS
/// (`kCLLocationAccuracyBestForNavigation`, 3 m distance filter, `.fitness` activity)
/// and toggles `allowsBackgroundLocationUpdates` so location continues delivering
/// while the screen is locked or the app is backgrounded — which also keeps the
/// process alive long enough for `MotionManager` to keep producing samples.
///
/// **The mid-ride dropout story.**  Field testing surfaced occasional multi-minute
/// gaps where the app process stayed alive (accelerometer data kept flowing) but
/// location delivery stopped, sometimes for 20+ minutes.  We've iterated on the
/// mitigation:
///
/// - First fix: auto-resume on `didPauseLocationUpdates`.  Looped 24,001 times
///   in a single ride at unlimited rate, hit the CL API rate limit, quarantined
///   our OSLog subsystem.  Reverted.
/// - Second fix: switch `activityType` to `.otherNavigation` (which docs say
///   prevents auto-pause).  Empirically *worse* — possibly because when iOS
///   pauses us anyway under this activity type, it doesn't fire the pause
///   callback (since it "shouldn't" be happening), so our handler never runs.
///   Reverted to `.fitness`.
/// - Current fix: `.fitness` (so pause callbacks reliably fire) + auto-resume
///   with a 30 s minimum interval (well under the rate limit even worst-case)
///   + an unbounded attempt count + a 30 s watchdog Timer that detects silent
///   failures (case where iOS stops delivering without firing the pause
///   callback) and triggers resume from the side.
///
/// The watchdog is the defense-in-depth that covers the case where our
/// callback-driven resume can't run because no callback fires.
///
/// **Instrumentation note**: only *event-driven* CoreLocation callbacks emit
/// OSLog lines under subsystem `com.herbertindustries.BumpyRide` /
/// category `location` (start, stop, auth change, error, pause, resume).  The
/// 30 s rate limit on resume attempts keeps OSLog volume well below
/// quarantine thresholds even if the watchdog and the pause callback both
/// keep firing.  Never log on the hot per-fix path.
///
/// View live in Console.app (device must be plugged in or sharing via wifi):
///   `subsystem:com.herbertindustries.BumpyRide category:location`
@Observable
final class LocationManager: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    private static let log = Logger(subsystem: "com.herbertindustries.BumpyRide", category: "location")

    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    private(set) var lastLocation: CLLocation?
    var onLocationUpdate: ((CLLocation) -> Void)?

    /// When we last *received* a `didUpdateLocations` callback.  Read by the
    /// watchdog to decide whether delivery has gone silent.  Updated on the
    /// main actor as part of every location delivery.
    @ObservationIgnored private var lastLocationReceivedAt: Date?

    /// When we last *attempted* a resume (via `attemptResume`).  Pairs with
    /// `minResumeIntervalSeconds` to prevent a tight loop.
    @ObservationIgnored private var lastResumeAttemptAt: Date?

    /// Watchdog Timer that polls on the main RunLoop to detect silent
    /// dropouts — periods where `didUpdateLocations` simply stops firing
    /// without a corresponding `didPauseLocationUpdates`.  Without this,
    /// the callback-driven resume path is unreachable for the scenarios
    /// where iOS quietly stops delivering.
    @ObservationIgnored private var watchdogTimer: Timer?

    /// Minimum seconds between successive `startUpdatingLocation()` calls.
    /// Either source of resume (pause callback or watchdog) routes through
    /// `attemptResume`, which enforces this interval.  Caps the worst-case
    /// CL-API call rate at 2/min regardless of how aggressively iOS keeps
    /// pausing us.
    private static let minResumeIntervalSeconds: TimeInterval = 30

    /// Watchdog poll cadence.  Every `watchdogIntervalSeconds`, we check
    /// `Date().timeIntervalSince(lastLocationReceivedAt) >
    /// watchdogStalenessThresholdSeconds`.  Cadence + threshold tuned to
    /// detect a real dropout within ~1 minute without false-positive
    /// triggering on normal between-fix gaps.
    private static let watchdogIntervalSeconds: TimeInterval = 30

    /// Staleness threshold for the watchdog.  At cycling speed + 3 m
    /// distanceFilter we typically get a fix every 1–3 s; a 60 s gap is
    /// well outside normal even on a slow ride.
    private static let watchdogStalenessThresholdSeconds: TimeInterval = 60

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 3.0
        // `.fitness`, not `.otherNavigation`.  Both have failure modes;
        // `.fitness` is documented as pausable but at least fires the
        // pause callback reliably so our handler gets a chance to resume.
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        authorizationStatus = manager.authorizationStatus
    }

    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func startUpdating() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        // Enable background delivery before starting updates.  Together with the
        // `UIBackgroundModes = location` Info.plist key, this lets a "When In Use"-
        // authorized app keep receiving location callbacks after the user locks the
        // screen or switches apps — and as long as location is running the app process
        // stays alive, so CoreMotion callbacks keep firing too.  The indicator shows the
        // user a green/blue pill at the top of the screen so they know location is active.
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        // Reset per-ride bookkeeping; start the watchdog.
        lastResumeAttemptAt = nil
        lastLocationReceivedAt = Date()
        startWatchdog()
        Self.log.info("startUpdating(): allowsBackground=true authStatus=\(self.manager.authorizationStatus.rawValue, privacy: .public)")
    }

    func stopUpdating() {
        manager.stopUpdatingLocation()
        // Drop the background-mode opt-in when not recording so the app doesn't show the
        // indicator unnecessarily and iOS isn't asked to keep us alive.
        manager.allowsBackgroundLocationUpdates = false
        stopWatchdog()
        Self.log.info("stopUpdating()")
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // NO LOGGING IN THIS METHOD.  This is the hot path — at 3 m
        // distanceFilter and cycling speed it fires ~2–3 times/sec for the
        // length of a ride, which got the subsystem quarantined.  See the
        // file-level comment for the policy.
        let received = locations
        Task { @MainActor in
            guard let loc = received.last else { return }
            self.lastLocation = loc
            self.lastLocationReceivedAt = Date()
            self.onLocationUpdate?(loc)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            Self.log.info("didChangeAuthorization → \(status.rawValue, privacy: .public)")
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        Task { @MainActor in
            Self.log.error("didFailWithError: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Called when iOS auto-pauses updates despite our
    /// `pausesLocationUpdatesAutomatically = false` hint.  We route through
    /// the rate-limited `attemptResume` path — no per-ride attempt cap,
    /// just a 30 s minimum interval.
    nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor in
            Self.log.notice("didPauseLocationUpdates — iOS auto-paused")
            self.attemptResume(reason: "pauseCallback")
        }
    }

    nonisolated func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor in
            Self.log.notice("didResumeLocationUpdates")
        }
    }

    // MARK: - Resume + watchdog

    /// Single entry point for both resume sources (pause callback + watchdog).
    /// Skips if we've attempted within the last `minResumeIntervalSeconds`.
    /// No per-ride attempt cap: at 30 s minimum interval, the worst-case API
    /// volume is 2 calls/minute even if every restart immediately fails,
    /// which is well under any rate limit.
    private func attemptResume(reason: String) {
        if let last = lastResumeAttemptAt,
           Date().timeIntervalSince(last) < Self.minResumeIntervalSeconds {
            return  // Silent skip — too soon.  No log to avoid quarantine risk.
        }
        lastResumeAttemptAt = Date()
        Self.log.notice("Attempting resume (reason=\(reason, privacy: .public))")
        manager.startUpdatingLocation()
    }

    /// Start the watchdog Timer on the main RunLoop.  Fires every
    /// `watchdogIntervalSeconds`; checks for staleness on each fire and
    /// calls `attemptResume` if delivery has gone silent for longer than
    /// `watchdogStalenessThresholdSeconds`.  Invalidated on `stopUpdating`.
    private func startWatchdog() {
        stopWatchdog()  // idempotent
        let timer = Timer(timeInterval: Self.watchdogIntervalSeconds, repeats: true) { [weak self] _ in
            // Bind self before crossing into the Task so Swift 6 strict
            // concurrency is happy — capturing `self?` inside a Task body
            // is a warning today and an error under Swift 6.
            guard let self else { return }
            Task { @MainActor in self.watchdogTick() }
        }
        // Schedule on the common runloop modes so it fires even during
        // UI tracking modes (scroll, etc.).
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    private func watchdogTick() {
        guard let last = lastLocationReceivedAt else { return }
        let staleness = Date().timeIntervalSince(last)
        if staleness > Self.watchdogStalenessThresholdSeconds {
            Self.log.notice("Watchdog: \(staleness, privacy: .public)s since last fix; attempting resume")
            attemptResume(reason: "watchdog")
        }
    }
}
