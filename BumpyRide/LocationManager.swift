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
/// **Instrumentation note**: only *event-driven* CoreLocation callbacks emit
/// OSLog lines under subsystem `com.herbertindustries.BumpyRide` /
/// category `location` (start, stop, auth change, error, pause, resume).
/// Two related rules learned the hard way:
///
/// 1. **Never log on the hot per-fix path.**  At cycling speed + 3 m
///    distanceFilter that's ~2–3 callbacks/sec sustained for a whole ride,
///    which trips iOS's OSLog rate limiter and gets the subsystem quarantined.
///    For per-fix visibility during debugging, attach Xcode + breakpoint.
///
/// 2. **Never auto-call `startUpdatingLocation()` from
///    `didPauseLocationUpdates`.**  iOS pauses for reasons we can't change;
///    restarting just produces a feedback loop that pegs the CL API rate
///    limit, and iOS's own "rate exceeded" log lines emit under our
///    subsystem and quarantine us.  See the method's doc comment for the
///    full incident write-up.
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

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 3.0
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
    /// `pausesLocationUpdatesAutomatically = false` hint.  The hint isn't a
    /// guarantee — the `.fitness` activity classifier can decide the user has
    /// stopped (a common false positive when phone-in-pocket motion looks like
    /// walking rather than cycling) and pause anyway.
    ///
    /// **We do NOT call `startUpdatingLocation()` from here.**  An earlier
    /// version did, on the theory that we'd rather burn a little battery
    /// than lose coverage.  In practice it produced a hard feedback loop:
    /// iOS would pause → we'd restart → conditions hadn't changed → iOS
    /// would pause again → repeat 24,001 times in a single ride, hitting
    /// CoreLocation's API rate limit and quarantining our entire OSLog
    /// subsystem (since iOS logged "Supported CoreLocation API call rate
    /// exceeded" under our subsystem name every iteration).  iOS wins these
    /// fights every time; restart-on-pause is harmful, not helpful.
    ///
    /// Logged once per actual pause so we can still observe it in Console.
    /// If we want a real recovery path in the future, it needs to wait for
    /// some external signal that the underlying condition has changed —
    /// not poll iOS.
    nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor in
            Self.log.notice("didPauseLocationUpdates — iOS auto-paused; NOT restarting (see method comment)")
        }
    }

    /// Logged for symmetry with `didPauseLocationUpdates`.  iOS calls this
    /// when it decides on its own that motion has resumed — happens
    /// naturally when whatever made it pause stops being true.
    nonisolated func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor in
            Self.log.notice("didResumeLocationUpdates")
        }
    }
}
