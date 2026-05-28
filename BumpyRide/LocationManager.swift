import Foundation
import CoreLocation
import Observation
import OSLog

/// Wraps `CLLocationManager` for ride recording.  Configured for cycling-grade GPS
/// (`kCLLocationAccuracyBestForNavigation`, 3 m distance filter, `.otherNavigation`
/// activity) and toggles `allowsBackgroundLocationUpdates` so location continues
/// delivering while the screen is locked or the app is backgrounded — which also
/// keeps the process alive long enough for `MotionManager` to keep producing samples.
///
/// **Why `.otherNavigation` and not `.fitness`?**  Per Apple's documentation, the
/// `.fitness` activity type is *explicitly designed to be pausable* — iOS will
/// auto-pause location delivery when its classifier decides the user has stopped.
/// The navigation activity types (`.automotiveNavigation`, `.otherNavigation`)
/// disable auto-pause entirely.  A bike app that needs continuous tracking is
/// closer to "vehicle navigation" than "fitness coach" in this respect; the
/// small battery cost (no smart pausing at long red lights) is worth it to
/// avoid the multi-minute mid-ride dropouts we saw in field testing.
///
/// **Instrumentation note**: only *event-driven* CoreLocation callbacks emit
/// OSLog lines under subsystem `com.herbertindustries.BumpyRide` /
/// category `location` (start, stop, auth change, error, pause, resume).
/// Two rules learned the hard way:
///
/// 1. **Never log on the hot per-fix path.**  At cycling speed + 3 m
///    distanceFilter that's ~2–3 callbacks/sec sustained for a whole ride,
///    which trips iOS's OSLog rate limiter and gets the subsystem quarantined.
///    For per-fix visibility during debugging, attach Xcode + breakpoint.
///
/// 2. **Auto-resume on `didPauseLocationUpdates` MUST be rate-limited.**  An
///    early version restarted with no throttling; iOS pause → restart →
///    immediate pause → restart looped 24,001 times in a single ride,
///    hitting the CL API rate limit and quarantining our subsystem.  Current
///    version uses a 30 s minimum interval + 5 attempts-per-ride cap.  See
///    `attemptResumeFromPause` for the math.
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

    /// Auto-resume bookkeeping for `didPauseLocationUpdates`.  See
    /// `attemptResumeFromPause` for usage.  Untracked since they don't
    /// drive any UI.
    @ObservationIgnored private var lastResumeAttemptAt: Date?
    @ObservationIgnored private var resumeAttemptsThisRide: Int = 0

    /// Minimum seconds between successive `startUpdatingLocation()` calls
    /// in response to a `didPauseLocationUpdates`.  Caps the CL-API rate
    /// well below the limit even worst-case (5 attempts × 30 s = at most
    /// one restart every 30 s, vs. the rate limit being measured in
    /// thousands of calls).
    private static let minResumeIntervalSeconds: TimeInterval = 30

    /// Max number of auto-resume attempts per `startUpdating()` cycle.
    /// At 5 we'll try for ~2.5 min before giving up — long enough to
    /// recover from a transient cause (cellular dropout, low-power
    /// triggers), short enough that a fundamental issue (e.g., iOS
    /// hard-decided to stop us) doesn't waste forever.
    private static let maxResumeAttemptsPerRide: Int = 5

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 3.0
        // `.otherNavigation` rather than `.fitness` — see file-level comment.
        // Tells iOS "don't auto-pause regardless of the activity classifier's
        // opinion about whether the user has stopped."
        manager.activityType = .otherNavigation
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
        // Reset auto-resume bookkeeping at the start of each ride so the
        // attempt budget is per-ride, not per-app-launch.
        lastResumeAttemptAt = nil
        resumeAttemptsThisRide = 0
        Self.log.info("startUpdating(): allowsBackground=true authStatus=\(self.manager.authorizationStatus.rawValue, privacy: .public)")
    }

    func stopUpdating() {
        manager.stopUpdatingLocation()
        // Drop the background-mode opt-in when not recording so the app doesn't show the
        // indicator unnecessarily and iOS isn't asked to keep us alive.
        manager.allowsBackgroundLocationUpdates = false
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
        // Historically swallowed silently, which was the worst possible default
        // for diagnosing GPS dropouts.  CoreLocation routinely emits transient
        // `kCLErrorLocationUnknown` while it warms up — those are normal and
        // self-recover.  But sustained errors (or `denied`) are the kind of
        // thing we want to see in Console.app immediately.
        Task { @MainActor in
            Self.log.error("didFailWithError: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Called when iOS auto-pauses updates despite our
    /// `pausesLocationUpdatesAutomatically = false` hint AND the
    /// `.otherNavigation` activity type that's supposed to disable
    /// auto-pause entirely.  In field testing this still fires occasionally
    /// — mid-ride dropouts of 5–10 minutes were observed before the
    /// resume logic was added.
    ///
    /// **Rate-limited restart strategy** to avoid the feedback-loop disaster
    /// of an earlier version (see file-level comment, point 2):
    ///   - At most one restart attempt every `minResumeIntervalSeconds`
    ///   - At most `maxResumeAttemptsPerRide` attempts per ride
    /// Together that bounds API call volume well below CoreLocation's rate
    /// limit even if iOS keeps re-pausing us.
    nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor in
            Self.log.notice("didPauseLocationUpdates — iOS auto-paused")
            self.attemptResumeFromPause()
        }
    }

    /// Restart updates if our rate-limit + circuit-breaker budget allows.
    /// Skips quietly otherwise so we don't pile up restarts that iOS
    /// would just pause again.
    private func attemptResumeFromPause() {
        if resumeAttemptsThisRide >= Self.maxResumeAttemptsPerRide {
            Self.log.notice("Skip resume: budget exhausted (\(self.resumeAttemptsThisRide, privacy: .public) attempts this ride)")
            return
        }
        if let last = lastResumeAttemptAt,
           Date().timeIntervalSince(last) < Self.minResumeIntervalSeconds {
            Self.log.notice("Skip resume: too soon since last attempt (\(Date().timeIntervalSince(last), privacy: .public)s)")
            return
        }
        lastResumeAttemptAt = Date()
        resumeAttemptsThisRide += 1
        Self.log.notice("Attempting resume (#\(self.resumeAttemptsThisRide, privacy: .public)/\(Self.maxResumeAttemptsPerRide, privacy: .public))")
        manager.startUpdatingLocation()
    }

    /// Logged for symmetry with `didPauseLocationUpdates`.  iOS calls this
    /// when location delivery resumes naturally on its own.  No action
    /// needed beyond the log line — `didUpdateLocations` will start
    /// firing again of its own accord.
    nonisolated func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor in
            Self.log.notice("didResumeLocationUpdates")
        }
    }
}
