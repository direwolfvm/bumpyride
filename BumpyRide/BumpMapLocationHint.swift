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

    /// CoreLocation always fires `locationManagerDidChangeAuthorization` once
    /// just for assigning the delegate, before anything has actually changed.
    /// Treating that as a grant made every instance issue a `requestLocation()`
    /// on top of the one the view asks for on appear (v2.1 U8).
    private var sawInitialAuthorizationCallback = false

    override init() {
        // CLLocationManager.authorizationStatus is callable pre-super.init, so we
        // can prime the published status without an "initialized before super"
        // dance.  Delegate assignment has to wait until after super.init.
        let initialStatus = manager.authorizationStatus
        authorizationStatus = initialStatus
        super.init()
        manager.delegate = self
        // v2.1 U6: deliberately NO location request here.
        //
        // This type is created in a `@State` initializer
        // (`BumpMapTabView.locationHint`), and Swift evaluates that expression
        // every time the view struct is built — SwiftUI keeps only the first
        // instance and throws the rest away.  Each throwaway still ran its
        // `init`, so each one created a CLLocationManager and fired a
        // `requestLocation()` that nothing would ever read.  CoreLocation
        // counts those against an app-wide budget and disables the app's
        // logging once it is exceeded.
        //
        // The auto-request now lives in `BumpMapTabView`'s `.task`, which runs
        // against the single retained instance, once per appearance.
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
    /// Ask for a fix only if we don't already have one and aren't mid-flight.
    /// Safe to call from `.task` / `.onAppear` on every appearance.
    func requestOneShotIfNeeded() {
        guard currentLocation == nil, !isFetching, isAuthorized else { return }
        requestOneShot()
    }

    func requestOneShot() {
        guard !isFetching else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            CLCallAudit.note("hint.requestAuthorization")
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            isFetching = true
            CLCallAudit.note("hint.requestLocation")
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
            // The first callback is CoreLocation announcing the delegate, not a
            // change.  `BumpMapTabView`'s `.task` owns the initial request.
            guard self.sawInitialAuthorizationCallback else {
                self.sawInitialAuthorizationCallback = true
                return
            }
            // The user just granted permission via our prompt — follow through
            // with the fetch they implicitly asked for.
            if self.isAuthorized(status), self.currentLocation == nil, !self.isFetching {
                self.isFetching = true
                CLCallAudit.note("hint.requestLocation.authChange")
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
