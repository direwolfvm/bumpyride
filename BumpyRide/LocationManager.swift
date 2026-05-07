import Foundation
import CoreLocation
import Observation

/// Wraps `CLLocationManager` for ride recording.  Configured for cycling-grade GPS
/// (`kCLLocationAccuracyBestForNavigation`, 3 m distance filter, `.fitness` activity)
/// and toggles `allowsBackgroundLocationUpdates` so location continues delivering
/// while the screen is locked or the app is backgrounded — which also keeps the
/// process alive long enough for `MotionManager` to keep producing samples.
@Observable
final class LocationManager: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

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
    }

    func stopUpdating() {
        manager.stopUpdatingLocation()
        // Drop the background-mode opt-in when not recording so the app doesn't show the
        // indicator unnecessarily and iOS isn't asked to keep us alive.
        manager.allowsBackgroundLocationUpdates = false
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
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
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
    }
}
