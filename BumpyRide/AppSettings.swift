import SwiftUI
import Observation

/// Bump-map filter — which rides should be aggregated into the personal heat map.
///
/// Pocket-mode rides systematically underreport bumpiness (clothing / body damping
/// attenuates high-frequency content), so mixing them with mounted rides produces
/// inconsistent colors per cell.  Until we have a calibration / normalization step,
/// the filter lets the user partition the data they look at.
///
/// `mountedOrUntagged` includes legacy rides recorded before `pocketMode` existed
/// (`pocketMode == nil`), under the assumption that those rides are most likely
/// mounted — splitting them out would penalize early users with no recourse.
enum BumpMapModeFilter: String, CaseIterable, Hashable {
    case all
    case mountedOrUntagged
    case pocketOnly

    var displayName: String {
        switch self {
        case .all: return "All"
        case .mountedOrUntagged: return "Mounted"
        case .pocketOnly: return "Pocket"
        }
    }
}

/// Which dataset the Bump Map tab is currently visualizing.  Persisted so a
/// user who's chosen a specific mode keeps seeing it when they relaunch.
enum MapViewMode: String, CaseIterable, Hashable {
    /// The original bump heatmap — per-cell average bumpiness.
    case bumps
    /// Sparse brake-event dots — per-cell event count.
    case brakes
    /// User-reported close-call diamonds — per-cell tap count.
    case closeCalls

    var displayName: String {
        switch self {
        case .bumps: return "Bumps"
        case .brakes: return "Brakes"
        // Short label — "Close Calls" overflows the segmented control on
        // narrower iPhone screens.  "Calls" alone is ambiguous, "Close"
        // is misleading (sounds like proximity), so "Close Calls" abridged.
        case .closeCalls: return "Calls"
        }
    }
}

/// User-tunable settings persisted in `UserDefaults`: the bumpiness color thresholds
/// (yellow / orange / red / purple breakpoints in g) and the Bump Map mode filter.
/// Provides `color(for:)` / `uiColor(for:)` helpers used everywhere bumpiness is shown.
///
/// Pocket mode is *not* configured here.  The per-ride toggle on the Ride tab is the
/// only place that controls it — there's no global default, and auto-detect catches
/// any mistagging at save time.
@Observable
final class AppSettings {
    private static let keyYellow = "bumpThresholdYellow"
    private static let keyOrange = "bumpThresholdOrange"
    private static let keyRed = "bumpThresholdRed"
    private static let keyPurple = "bumpThresholdPurple"
    private static let keyBumpMapFilter = "bumpMapModeFilter"
    private static let keyMapViewMode = "mapViewMode"
    private static let keyAutoExportToAppleHealth = "autoExportToAppleHealth"
    private static let keyOpenWatchAppOnLaunch = "openWatchAppOnLaunch"
    private static let keyDebugLogEnabled = "debugLogEnabled"

    var yellowG: Double = 0.5 {
        didSet { UserDefaults.standard.set(yellowG, forKey: Self.keyYellow) }
    }
    var orangeG: Double = 1.0 {
        didSet { UserDefaults.standard.set(orangeG, forKey: Self.keyOrange) }
    }
    var redG: Double = 1.5 {
        didSet { UserDefaults.standard.set(redG, forKey: Self.keyRed) }
    }
    var purpleG: Double = 2.0 {
        didSet { UserDefaults.standard.set(purpleG, forKey: Self.keyPurple) }
    }

    /// Persistent Bump Map filter.  Defaults to `.mountedOrUntagged` since pocket data
    /// reads systematically softer than mounted data and mixing them produces
    /// inconsistent colors per cell.  Users can flip to `.all` or `.pocketOnly` from
    /// the Bump Map tab's filter chip.
    var bumpMapFilter: BumpMapModeFilter = .mountedOrUntagged {
        didSet { UserDefaults.standard.set(bumpMapFilter.rawValue, forKey: Self.keyBumpMapFilter) }
    }

    /// Which dataset the Bump Map tab is rendering — bumpiness heatmap or
    /// brake-event dots.  Defaults to `.bumps` since that's the original
    /// view and most users will start there.  Persisted so a user who
    /// prefers brake mode keeps seeing it across launches.
    var mapViewMode: MapViewMode = .bumps {
        didSet { UserDefaults.standard.set(mapViewMode.rawValue, forKey: Self.keyMapViewMode) }
    }

    /// Whether each newly-finalized ride should be automatically written
    /// to Apple Health as an `HKWorkout`.  Defaults to `false` so the
    /// integration is opt-in — flipping the Settings toggle from off to
    /// on for the first time triggers the HealthKit auth sheet; only on
    /// successful auth does the value land at `true`.
    ///
    /// Auto-export is gated on three conditions in `ContentView`:
    ///  - this setting is `true`,
    ///  - `HealthKitAuthManager.canWrite` is `true`,
    ///  - the ride doesn't already have a `healthKitWorkoutUUID`.
    ///
    /// The last condition prevents an infinite loop: after a successful
    /// export we re-save the ride with the stamp set, which re-fires the
    /// `onRideSaved` callback — without this guard we'd re-export the
    /// same ride forever.
    var autoExportToAppleHealth: Bool = false {
        didSet { UserDefaults.standard.set(autoExportToAppleHealth, forKey: Self.keyAutoExportToAppleHealth) }
    }

    /// Whether opening the iPhone app should also open the BumpyRide
    /// watch app and start a HealthKit workout session.  Defaults to
    /// `false` so the behavior is opt-in — auto-launching the watch
    /// app would be surprising to users who upgrade from v1.6.
    ///
    /// The toggle's secondary purpose: a running `HKWorkoutSession`
    /// on the watch is the only way to read heart rate during a ride,
    /// so this flag also gates whether watch-collected heart rate
    /// data lands in the saved ride's HealthKit workout.  Settings
    /// copy describes both effects so the user understands what
    /// they're enabling.
    ///
    /// The Settings row that drives this is hidden entirely when no
    /// Apple Watch is paired (gated on
    /// `WatchCoordinator.isPaired`) — no point exposing a setting
    /// the user can't act on.
    var openWatchAppOnLaunch: Bool = false {
        didSet { UserDefaults.standard.set(openWatchAppOnLaunch, forKey: Self.keyOpenWatchAppOnLaunch) }
    }

    /// Diagnostics toggle.  When on, every `DebugLog` call also writes
    /// its line to a plain-text sidecar file in the iCloud Rides folder:
    /// `<rideId>-debug.log` during a recording, `session-YYYY-MM-DD.log`
    /// otherwise.  Off-state cost is one Bool read per log site, so
    /// leaving it off in steady state has no real perf or storage hit.
    ///
    /// The didSet pushes the new value into `DebugLogSink.enabled` so
    /// the static fast-path stays in sync without any observation
    /// indirection.  Sidecar files older than 14 days are GC'd by the
    /// sink at app launch.
    var debugLogEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(debugLogEnabled, forKey: Self.keyDebugLogEnabled)
            DebugLogSink.enabled = debugLogEnabled
        }
    }

    init() {
        let d = UserDefaults.standard
        if let v = d.object(forKey: Self.keyYellow) as? Double { yellowG = v }
        if let v = d.object(forKey: Self.keyOrange) as? Double { orangeG = v }
        if let v = d.object(forKey: Self.keyRed) as? Double { redG = v }
        if let v = d.object(forKey: Self.keyPurple) as? Double { purpleG = v }
        if let raw = d.string(forKey: Self.keyBumpMapFilter),
           let f = BumpMapModeFilter(rawValue: raw) {
            bumpMapFilter = f
        }
        if let raw = d.string(forKey: Self.keyMapViewMode),
           let m = MapViewMode(rawValue: raw) {
            mapViewMode = m
        }
        // Default false when the key is absent — `object(forKey:) as? Bool`
        // returns nil for "never set," not for "set to false," so this is
        // a clean opt-in.
        if let v = d.object(forKey: Self.keyAutoExportToAppleHealth) as? Bool {
            autoExportToAppleHealth = v
        }
        if let v = d.object(forKey: Self.keyOpenWatchAppOnLaunch) as? Bool {
            openWatchAppOnLaunch = v
        }
        if let v = d.object(forKey: Self.keyDebugLogEnabled) as? Bool {
            debugLogEnabled = v
            // Push the static snapshot too, since assigning the @Observable
            // property in init doesn't fire didSet (per Swift semantics).
            DebugLogSink.enabled = v
        }
    }

    func resetToDefaults() {
        yellowG = 0.5
        orangeG = 1.0
        redG = 1.5
        purpleG = 2.0
        bumpMapFilter = .mountedOrUntagged
        mapViewMode = .bumps
        autoExportToAppleHealth = false
        openWatchAppOnLaunch = false
        debugLogEnabled = false
    }

    private struct Stop {
        let threshold: Double
        let r: Double
        let g: Double
        let b: Double
    }

    private var stops: [Stop] {
        [
            Stop(threshold: 0.0,     r: 0.20, g: 0.85, b: 0.35),
            Stop(threshold: yellowG, r: 0.95, g: 0.85, b: 0.20),
            Stop(threshold: orangeG, r: 0.98, g: 0.55, b: 0.15),
            Stop(threshold: redG,    r: 0.92, g: 0.20, b: 0.20),
            Stop(threshold: purpleG, r: 0.60, g: 0.25, b: 0.85)
        ]
    }

    var topG: Double { purpleG }

    func color(for bumpiness: Double) -> Color {
        let (r, g, b) = rgb(for: bumpiness)
        return Color(red: r, green: g, blue: b)
    }

    func uiColor(for bumpiness: Double) -> UIColor {
        let (r, g, b) = rgb(for: bumpiness)
        return UIColor(red: r, green: g, blue: b, alpha: 1)
    }

    /// Index (0...4) of the discrete color band a bumpiness value
    /// falls into — green / yellow / orange / red / purple, keyed off
    /// the four user-tunable thresholds.  Distinct from `color(for:)`,
    /// which interpolates a smooth gradient between stops.
    ///
    /// Used by `RouteMapView` to coalesce contiguous same-band route
    /// segments into a single multi-point polyline: drawing one
    /// overlay per band-run instead of one per point-pair is what
    /// keeps the live map performant on long rides (a 4-mile ride is
    /// ~2,000 point-pairs; banding collapses that to a few dozen
    /// overlays).  The band boundaries are exactly the legend stops,
    /// so the banded route matches the color scale the user sees.
    func colorBand(for bumpiness: Double) -> Int {
        let v = max(0, bumpiness)
        if v >= purpleG { return 4 }
        if v >= redG { return 3 }
        if v >= orangeG { return 2 }
        if v >= yellowG { return 1 }
        return 0
    }

    /// Representative color for a band index from `colorBand(for:)`.
    /// Returns the exact legend stop color (not an interpolated
    /// value), so a banded route reads as discrete bands matching the
    /// Settings color-scale preview.  Clamps out-of-range indices.
    func bandColor(_ band: Int) -> Color {
        switch max(0, min(4, band)) {
        case 0: return color(for: 0)        // green stop
        case 1: return color(for: yellowG)  // yellow stop
        case 2: return color(for: orangeG)  // orange stop
        case 3: return color(for: redG)     // red stop
        default: return color(for: purpleG) // purple stop
        }
    }

    /// `UIColor` variant of `bandColor(_:)` for UIKit consumers (the
    /// MKMapView-backed live map colors its `MKPolyline` runs with this).
    func bandUIColor(_ band: Int) -> UIColor {
        switch max(0, min(4, band)) {
        case 0: return uiColor(for: 0)
        case 1: return uiColor(for: yellowG)
        case 2: return uiColor(for: orangeG)
        case 3: return uiColor(for: redG)
        default: return uiColor(for: purpleG)
        }
    }

    private func rgb(for bumpiness: Double) -> (Double, Double, Double) {
        let sorted = stops
        let v = max(0, bumpiness)
        if v <= sorted.first!.threshold {
            let s = sorted.first!
            return (s.r, s.g, s.b)
        }
        if v >= sorted.last!.threshold {
            let s = sorted.last!
            return (s.r, s.g, s.b)
        }
        for i in 1..<sorted.count where v <= sorted[i].threshold {
            let lo = sorted[i - 1], hi = sorted[i]
            let span = max(0.0001, hi.threshold - lo.threshold)
            let t = (v - lo.threshold) / span
            return (
                lo.r + (hi.r - lo.r) * t,
                lo.g + (hi.g - lo.g) * t,
                lo.b + (hi.b - lo.b) * t
            )
        }
        let last = sorted.last!
        return (last.r, last.g, last.b)
    }
}
