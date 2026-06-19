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
    static func runs(points: [RidePoint], settings: AppSettings, colorRoute: Bool) -> [Run] {
        guard points.count > 1 else { return [] }
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

        for k in 0..<(points.count - 1) {
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
            } else if band == curBand {
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
