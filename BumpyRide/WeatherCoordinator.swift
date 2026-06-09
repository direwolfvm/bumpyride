import Foundation
import CoreLocation
import Observation
import OSLog
#if canImport(WeatherKit)
import WeatherKit
#endif

/// Owner of the app's WeatherKit cache for the v1.8 live-recording
/// weather overlay.  One instance for the whole app, lives at the
/// `ContentView` level alongside the other root coordinators.
///
/// **Why a coordinator and not just a `WeatherService` call**: the
/// `Map` overlay updates on every location change (~1 Hz during
/// recording), but hitting WeatherKit at that rate would burn the
/// 500k/month free-tier quota in a single ride and produce no
/// better data — outdoor weather doesn't change second-by-second.
/// The coordinator's freshness gate (15 min OR 2 mi moved,
/// whichever first) keeps actual network calls to a handful per
/// hour-long ride.
///
/// **Threading**: `@MainActor` because the UI binds to `current`.
/// The actual fetch happens on a `Task` that hops to a background
/// queue inside WeatherService and returns to MainActor for the
/// publish.
///
/// **I1 scope**: this file establishes the shape (cache fields,
/// freshness constants, the `refresh(near:)` entry point) but the
/// `refresh` body is a stub.  I2 fills in the real WeatherService
/// call; I3 builds the chip UI; I4 wires the chip into the
/// `RouteMapView` overlay and starts the 1 Hz polling from
/// `RideView`.
@Observable
@MainActor
final class WeatherCoordinator {
    nonisolated private static let log = Logger(
        subsystem: "com.herbertindustries.BumpyRide",
        category: "weather"
    )

    /// Last successfully fetched current weather.  `nil` until the
    /// first fetch lands.  UI binds to this via `@Observable`
    /// tracking — the chip hides itself entirely while `nil`.
    #if canImport(WeatherKit)
    private(set) var current: CurrentWeather?
    #else
    private(set) var current: Never?  // Unreachable; satisfies type checker on non-iOS platforms.
    #endif

    /// When `current` was successfully fetched.  Drives the time-
    /// based freshness gate.
    @ObservationIgnored private var lastFetchAt: Date?

    /// Where `current` was successfully fetched.  Drives the
    /// distance-based freshness gate.
    @ObservationIgnored private var lastFetchLocation: CLLocation?

    /// In-flight fetch task, if any.  Used to coalesce overlapping
    /// `refresh(near:)` calls from the 1 Hz polling loop in
    /// `RideView` — we don't want N concurrent WeatherKit hits when
    /// the network is slow.
    @ObservationIgnored private var fetchTask: Task<Void, Never>?

    /// Maximum age before a cached observation is considered stale.
    /// Outdoor weather doesn't change in seconds; 15 min is plenty
    /// of resolution for a recreational ride.
    private static let staleAfterSeconds: TimeInterval = 15 * 60

    /// Distance threshold for invalidating the cache on movement.
    /// 2 mi (~3.2 km) is enough to cross most local weather pattern
    /// boundaries while still permitting reuse across an
    /// in-neighborhood loop.
    private static let staleAfterMeters: CLLocationDistance = 3_200

    init() {}

    /// Refresh the current weather for the given location, if our
    /// cache is stale by time or distance (or if `force` is true).
    /// Idempotent and concurrency-safe — overlapping invocations
    /// from the polling loop coalesce onto a single in-flight task.
    ///
    /// **I1 placeholder**: this body currently logs and returns.
    /// Phase I2 replaces it with the actual `WeatherService` call.
    func refresh(near location: CLLocation, force: Bool = false) {
        // Phase I2 will replace this with the real implementation.
        // The signature is locked here so I3/I4's callers can
        // already bind against it.
        Self.log.debug("refresh(near:) called (I1 stub)")
    }

    /// True if our cache is still fresh relative to the supplied
    /// location.  Phase I2 uses this for the freshness gate;
    /// exposed here in I1 for inspection by tests / debug UI.
    func isCacheFresh(for location: CLLocation) -> Bool {
        guard current != nil,
              let lastFetchAt,
              let lastFetchLocation else {
            return false
        }
        if Date().timeIntervalSince(lastFetchAt) > Self.staleAfterSeconds {
            return false
        }
        if location.distance(from: lastFetchLocation) > Self.staleAfterMeters {
            return false
        }
        return true
    }
}
