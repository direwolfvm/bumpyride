import Foundation
import CoreLocation
import Observation

/// Lightweight one-shot location source dedicated to the Bump Map tab.  Used to
/// answer "where should we center the map when the user has no ride data yet?"
///
/// Deliberately separate from `RideRecorder.location` for two reasons:
/// 1. Decoupling — the recorder's `LocationManager` owns the live recording stream
///    and toggles `allowsBackgroundLocationUpdates`, which we don't want for a
///    map-centering hint.  Stomping its state from the BumpMap tab would be a
///    cross-cutting concern that breaks if recording flow changes.
/// 2. Lifecycle — we want a single GPS fix on appear (or when the user explicitly
///    taps "Use my location"), not a continuous stream.  `requestLocation()` is
///    the right CoreLocation API for that, but calling it on the recorder's
///    instance would interleave with `startUpdatingLocation()` in confusing ways.
///
/// Two CLLocationManager instances in the same app is fine — iOS shares the
/// underlying location subsystem between them.  The hint manager doesn't pay for
/// background updates or set `pausesLocationUpdatesAutomatically = false`, so it
/// has minimal battery impact.
@Observable
@MainActor
final class BumpMapLocationHint: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    private(set) var authorizationStatus: CLAuthorizationStatus
    private(set) var currentLocation: CLLocation?

    /// `true` while a `requestLocation()` call is in flight — used by the empty-
    /// state overlay to swap the "Use my location" button for a progress view so
    /// the user gets feedback that the tap registered.
    private(set) var isFetching: Bool = false

    override init() {
        // CLLocationManager.authorizationStatus is callable pre-super.init, so we
        // can prime the published status without an "initialized before super"
        // dance.  Delegate assignment has to wait until after super.init.
        let initialStatus = manager.authorizationStatus
        authorizationStatus = initialStatus
        super.init()
        manager.delegate = self
        // If the user has already granted permission in a prior session (most
        // likely path — they recorded a ride before opening Bump Map), kick off
        // a fix immediately so the empty state has something to center on by the
        // time it renders.  Free signal; harmless if it never lands.
        if isAuthorized(initialStatus) {
            requestOneShot()
        }
    }

    /// `true` when the OS will let us call `requestLocation()` and expect a fix.
    var isAuthorized: Bool {
        isAuthorized(authorizationStatus)
    }

    private func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedWhenInUse || status == .authorizedAlways
    }

    /// Request a single GPS fix.  If permission hasn't been asked yet, this
    /// triggers the system prompt; the delegate's authorization callback will
    /// then issue the actual `requestLocation()` once the user responds.
    /// Idempotent — a second call while a fetch is already in flight is a no-op.
    func requestOneShot() {
        guard !isFetching else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            isFetching = true
            manager.requestLocation()
        case .denied, .restricted:
            // Nothing we can do here — caller (the empty-state overlay) should
            // detect this state and show a Settings deep link instead of the
            // "Use my location" button.
            break
        @unknown default:
            break
        }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let received = locations.last
        Task { @MainActor in
            self.isFetching = false
            if let loc = received {
                self.currentLocation = loc
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            // If the user just granted permission via our prompt, follow through
            // with the location fetch they implicitly asked for by tapping the
            // "Use my location" button.
            if self.isAuthorized(status), self.currentLocation == nil, !self.isFetching {
                self.isFetching = true
                manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        Task { @MainActor in
            self.isFetching = false
            // Silent — the empty state simply continues to show the request UI.
            // requestLocation() commonly fails transiently (e.g., cold start
            // before any GPS fix is cached) and the user can tap again.
        }
    }
}
