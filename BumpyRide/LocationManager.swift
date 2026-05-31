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

    /// One-shot guard: have we already issued a `requestAlwaysAuthorization`
    /// call?  iOS only honors the prompt once per app launch — subsequent
    /// calls are silent no-ops.  We track it ourselves so we don't keep
    /// re-asking each time `didChangeAuthorization` fires.
    @ObservationIgnored private var hasRequestedAlways: Bool = false

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
        // `kCLLocationAccuracyBest`, NOT `kCLLocationAccuracyBestForNavigation`.
        // Apple documents the latter as "intended for use when the device is
        // plugged in" — meant for cars / dashboard navigation, not pocket
        // cycling on battery.  When the device isn't plugged in, iOS can
        // quietly demote or suspend us, which produced the multi-minute
        // mid-ride dropouts we kept chasing.  `.Best` is the same accuracy
        // tier most cycling apps use (Strava, etc.) and trades a small bit
        // of theoretical precision for substantially better resilience in
        // sustained-background scenarios.  User decision after rev 18:
        // they'd rather have continuous tracking than picking up the rare
        // sub-meter detail BestForNavigation might catch.
        manager.desiredAccuracy = kCLLocationAccuracyBest
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

    /// Two-step incremental authorization upgrade — the iOS-blessed way to
    /// get `.authorizedAlways`.  You can't ask for Always directly; you have
    /// to first hold `.authorizedWhenInUse` and then request the upgrade.
    /// Apple shows a separate system prompt for the upgrade step.
    ///
    /// We need `.authorizedAlways` for one specific reason: Significant
    /// Location Change service only delivers events to backgrounded apps if
    /// they hold Always.  Without it, SLC effectively doesn't exist for our
    /// background-suspension recovery scenario — which is what made the
    /// otherwise-correct build 18 wiring useless in practice.
    private func requestAlwaysIfNeeded() {
        guard !hasRequestedAlways else { return }
        guard manager.authorizationStatus == .authorizedWhenInUse else { return }
        hasRequestedAlways = true
        manager.requestAlwaysAuthorization()
    }

    func startUpdating() {
        // Three branches for the authorization state at start time:
        //  - notDetermined: ask for When In Use; the upgrade to Always
        //    fires from `didChangeAuthorization` once the user grants.
        //  - authorizedWhenInUse: already have base authorization but not
        //    the background-eligible Always tier; request the upgrade now.
        //  - authorizedAlways: nothing to do.  (denied / restricted are
        //    handled by the calling UI gating the Start button.)
        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if status == .authorizedWhenInUse {
            requestAlwaysIfNeeded()
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
        // Also register for Significant Location Change service.  SLC is the
        // *only* CoreLocation service that iOS will wake a suspended (or
        // even terminated) app for — fires when the device has moved by
        // roughly 500 m.  Continuous updates can stop entirely if iOS
        // decides to suspend us during a long ride (the watchdog Timer
        // can't fire from a suspended process — it's run-loop-driven),
        // and SLC is our only path back from that state.  When SLC
        // delivers a callback, our `didUpdateLocations` handler restarts
        // continuous tracking via `attemptResume`.
        manager.startMonitoringSignificantLocationChanges()
        // Reset per-ride bookkeeping; start the watchdog.
        lastResumeAttemptAt = nil
        lastLocationReceivedAt = Date()
        startWatchdog()
        Self.log.info("startUpdating(): allowsBackground=true authStatus=\(self.manager.authorizationStatus.rawValue, privacy: .public)")
    }

    func stopUpdating() {
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
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
            guard !received.isEmpty else { return }
            // Wake-from-silence path.  If this delivery follows a long quiet
            // period, the most likely source is either SLC (iOS just woke
            // us from suspension because the device moved 500+ m) or a
            // delayed delivery after iOS-side throttling.  Either way, we
            // need continuous updates flowing again — attemptResume hits
            // startUpdatingLocation() idempotently, and the 30 s rate limit
            // prevents any pathological feedback.  Checked once per
            // delivery before we update `lastLocationReceivedAt`.
            if let last = self.lastLocationReceivedAt,
               Date().timeIntervalSince(last) > Self.watchdogStalenessThresholdSeconds {
                self.attemptResume(reason: "delivery-after-silence")
            }
            // Process every CLLocation in the bundle, not just `.last`.
            // When the app is backgrounded, iOS often batches several
            // fixes into one callback delivery — taking only `.last`
            // discarded the rest and produced a misleadingly low sample
            // rate.  RideRecorder's freshness filter (30 s) keeps any
            // genuinely-stale entries out, but normal bundled deliveries
            // pass cleanly.
            for loc in received {
                self.lastLocation = loc
                self.onLocationUpdate?(loc)
            }
            self.lastLocationReceivedAt = Date()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            Self.log.info("didChangeAuthorization → \(status.rawValue, privacy: .public)")
            // Chain the Always upgrade onto the When-In-Use grant.  This is
            // what makes the incremental authorization flow work — the
            // request to upgrade has to be issued *after* the user has
            // already granted the base level.
            if status == .authorizedWhenInUse {
                self.requestAlwaysIfNeeded()
            }
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
