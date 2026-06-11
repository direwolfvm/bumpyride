import Foundation
import CoreLocation
import Observation
import OSLog
#if canImport(WeatherKit)
import WeatherKit
#endif

/// Owner of the app's WeatherKit cache for the v1.7 live-recording
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
    // DebugLog so weather fetch outcomes (especially the failure
    // reason) land in the iCloud sidecar — the only way to see
    // WeatherKit's actual error on-device during a real ride, which
    // is exactly what we need to confirm whether the overlay's
    // not-showing is the WeatherKit auth/JWT propagation or something
    // else.
    nonisolated private static let log = DebugLog(category: "weather")

    /// Last successfully fetched current weather.  `nil` until the
    /// first fetch lands.  UI binds to this via `@Observable`
    /// tracking — the chip hides itself entirely while `nil`.
    #if canImport(WeatherKit)
    private(set) var current: CurrentWeather?
    #else
    private(set) var current: Never?  // Unreachable; satisfies type checker on non-iOS platforms.
    #endif

    /// When `current` was successfully fetched.  Drives the time-
    /// based freshness gate.  Only updated on success.
    @ObservationIgnored private var lastFetchAt: Date?

    /// Where `current` was successfully fetched.  Drives the
    /// distance-based freshness gate.  Only updated on success.
    @ObservationIgnored private var lastFetchLocation: CLLocation?

    /// When the most recent fetch attempt began, regardless of
    /// outcome.  Drives the failure-backoff gate so a permanent
    /// configuration error (e.g. WeatherKit App-ID enrollment not
    /// yet propagated through Apple's services) doesn't get
    /// hammered at 1 Hz by the polling loop.  We attempt at most
    /// once per `failureBackoffSeconds` when there's no fresh
    /// cache.
    @ObservationIgnored private var lastAttemptAt: Date?

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

    /// Minimum gap between fetch attempts after a failure.  30 s
    /// is short enough that real transient network blips recover
    /// quickly, long enough that a permanent auth error (e.g.
    /// WeatherKit App-ID enrollment not yet propagated) doesn't
    /// produce the four-log-lines-per-second noise the 1 Hz
    /// polling loop would otherwise generate.
    private static let failureBackoffSeconds: TimeInterval = 30

    init() {}

    /// Refresh the current weather for the given location, if our
    /// cache is stale by time or distance (or if `force` is true).
    /// Idempotent and concurrency-safe — overlapping invocations
    /// from the polling loop coalesce onto a single in-flight task.
    ///
    /// **Coalescing**: if a fetch is already in flight, this call
    /// is a no-op.  Otherwise it spawns a new Task that hits
    /// WeatherKit and publishes the result, then clears
    /// `fetchTask` so the next refresh can run.
    func refresh(near location: CLLocation, force: Bool = false) {
        #if canImport(WeatherKit)
        if !force {
            // Cache hit gate: a recent successful fetch close to
            // this location is what we want.
            if isCacheFresh(for: location) {
                return
            }
            // Failure backoff gate: any recent attempt — success
            // OR failure — that didn't already pass the freshness
            // gate above means we should wait.  Without this, a
            // failed fetch leaves `current` nil → cache is never
            // fresh → next polling tick (1 s later) tries again,
            // producing one log line per second.
            if let lastAttemptAt,
               Date().timeIntervalSince(lastAttemptAt) < Self.failureBackoffSeconds {
                return
            }
        }
        // In-flight: coalesce.
        if fetchTask != nil {
            return
        }
        // Stamp the attempt BEFORE awaiting so a second refresh
        // call that arrives during the await doesn't double-spawn.
        // The fetchTask presence check above also catches this,
        // but updating lastAttemptAt eagerly means the backoff
        // window starts now rather than at task completion.
        lastAttemptAt = Date()
        fetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                Self.log.info("Fetching weather near (\(String(format: "%.4f", location.coordinate.latitude)), \(String(format: "%.4f", location.coordinate.longitude)))")
                let weather = try await WeatherService.shared.weather(for: location)
                self.current = weather.currentWeather
                self.lastFetchAt = Date()
                self.lastFetchLocation = location
                Self.log.info("Weather fetched: \(weather.currentWeather.temperature.formatted()), wind \(weather.currentWeather.wind.speed.formatted()) from \(String(format: "%.0f", weather.currentWeather.wind.direction.value))°")
            } catch {
                Self.log.error("WeatherKit fetch failed: \(String(describing: error))")
                // Leave `current` and the success stamps alone — if
                // we had a previous successful fetch the chip
                // continues showing it; if not, the chip stays
                // hidden.  lastAttemptAt was set before the await,
                // so the next refresh call within
                // `failureBackoffSeconds` will be gated.
            }
            self.fetchTask = nil
        }
        #else
        Self.log.notice("WeatherKit not available on this platform; skipping refresh")
        #endif
    }

    /// Diagnostic snapshot of the coordinator's gate state, logged
    /// once when RideView starts polling so the sidecar shows whether
    /// we're even attempting fetches (vs. silently gated by a recent
    /// failure backoff or a still-fresh cache).  Helps distinguish
    /// "WeatherKit is erroring" from "we never called it."
    func logDiagnosticState() {
        #if canImport(WeatherKit)
        let hasCache = current != nil
        let lastAttempt = lastAttemptAt.map { String(format: "%.0fs ago", Date().timeIntervalSince($0)) } ?? "never"
        Self.log.info("Weather state: hasCache=\(hasCache) lastAttempt=\(lastAttempt)")
        #else
        Self.log.notice("Weather: WeatherKit not built into this platform")
        #endif
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
