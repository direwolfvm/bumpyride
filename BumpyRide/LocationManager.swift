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
/// **Instrumentation note**: every CoreLocation delegate callback emits an OSLog
/// line under subsystem `com.herbertindustries.BumpyRide`, category `location`.
/// View live in Console.app (device must be plugged in or sharing via wifi):
///   `subsystem:com.herbertindustries.BumpyRide category:location`
/// Added 2026-05 to diagnose pocket-mode GPS drop reports — see the
/// `locationManagerDidPause` / `didFailWithError` log lines first when
/// investigating a "GPS went quiet mid-ride" complaint.
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
        let received = locations
        Task { @MainActor in
            guard let loc = received.last else { return }
            // Per-fix log: accuracy + age + speed.  These three numbers tell us
            // everything we need to diagnose pocket-mode dropouts — a sudden
            // jump in horizontalAccuracy is the smoking gun for "phone went
            // into a pocket and GPS degraded."  Age >> 0 means iOS is feeding
            // us cached fixes (also a degradation signal).
            let age = -loc.timestamp.timeIntervalSinceNow
            Self.log.debug("didUpdateLocations: hAcc=\(loc.horizontalAccuracy, format: .fixed(precision: 1), privacy: .public)m vAcc=\(loc.verticalAccuracy, format: .fixed(precision: 1), privacy: .public)m speed=\(loc.speed, format: .fixed(precision: 2), privacy: .public)m/s age=\(age, format: .fixed(precision: 2), privacy: .public)s")
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
    /// walking rather than cycling) and pause anyway.  When that happens we
    /// immediately re-arm updates; we'd rather burn a little extra battery
    /// than lose mid-ride GPS coverage.
    nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor in
            Self.log.notice("didPauseLocationUpdates — auto-paused by iOS; restarting immediately")
            manager.startUpdatingLocation()
        }
    }

    /// Logged for symmetry with `didPauseLocationUpdates`.  iOS calls this if
    /// it decides on its own that motion has resumed.  No action needed — we
    /// already re-armed `startUpdatingLocation()` on pause.
    nonisolated func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor in
            Self.log.notice("didResumeLocationUpdates")
        }
    }
}
