import Foundation
import CoreLocation

/// View-agnostic logic for splitting a ride's points into contiguous
/// same-color-band polyline runs.  Extracted from `RouteMapView` so the
/// SwiftUI `Map` (saved-ride playback) and the `MKMapView`-backed live
/// map (`LiveRouteMapView`) color the route identically:
///
///   • band by the **max** bumpiness of each segment's two endpoints
///     (K19 — averaging washed isolated jolts into the low bands),
///   • coalesce contiguous same-band segments into one multi-point run
///     (K16 — one overlay per run instead of one per point-pair), and
///   • break the run on a > 30 s GPS gap so dropouts don't draw a
///     misleading straight line.
enum RouteColoring {
    /// Maximum time gap between consecutive fixes we'll connect.  Beyond
    /// this the run breaks (the polyline visually splits at a dropout).
    static let maxSegmentTimeGapSeconds: TimeInterval = 30

    /// v2.1 U7: hard cap on the vertices in one run, independent of colour.
    ///
    /// Without it a ride along smooth road is a single run covering the whole
    /// route, and the live map's incremental update (which can only rebuild
    /// the *last* run) degenerates back into rebuilding everything on every
    /// GPS fix.  Splitting at a fixed length bounds that work.  Adjacent runs
    /// share their boundary vertex exactly as colour-change runs do, so the
    /// route still draws continuously; the only visible effect is more, and
    /// smaller, overlays — which MapKit culls better anyway.
    static let maxRunPoints = 256

    struct Run {
        /// Index of the run's first point — stable across rebuilds so a
        /// consumer can diff incrementally if it wants to.
        let startIndex: Int
        let coordinates: [CLLocationCoordinate2D]
        /// Legend band 0...4 in color mode, or `-1` in neutral (brakes)
        /// mode.  Consumers map this to their own color type.
        let bandIndex: Int
    }

    /// Build the color runs.  `colorRoute == false` yields a single
    /// band (-1) per gap-free stretch — the brakes-mode neutral route.
    ///
    /// `from` starts the segment walk at that point index, reporting absolute
    /// `startIndex` values, so a live caller can recompute just the tail of a
    /// growing route instead of the whole thing (v2.1 U7).  Points only ever
    /// append during recording, so every run before the last is final once
    /// built.
    static func runs(
        points: [RidePoint],
        settings: AppSettings,
        colorRoute: Bool,
        from startAt: Int = 0
    ) -> [Run] {
        guard points.count > 1, startAt < points.count - 1 else { return [] }
        var out: [Run] = []

        var startIdx: Int? = nil
        var coords: [CLLocationCoordinate2D] = []
        var curBand = 0

        func flush() {
            if let s = startIdx, coords.count >= 2 {
                out.append(Run(
                    startIndex: s,
                    coordinates: coords,
                    bandIndex: colorRoute ? curBand : -1
                ))
            }
            startIdx = nil
            coords = []
        }

        for k in max(0, startAt)..<(points.count - 1) {
            let a = points[k]
            let b = points[k + 1]
            let gap = b.timestamp.timeIntervalSince(a.timestamp)
            if gap > maxSegmentTimeGapSeconds {
                flush()
                continue
            }
            let band = colorRoute ? settings.colorBand(for: max(a.bumpiness, b.bumpiness)) : 0
            if startIdx == nil {
                startIdx = k
                coords = [a.coordinate, b.coordinate]
                curBand = band
            } else if band == curBand && coords.count < maxRunPoints {
                coords.append(b.coordinate)
            } else {
                flush()
                startIdx = k
                coords = [a.coordinate, b.coordinate]
                curBand = band
            }
        }
        flush()
        return out
    }
}
