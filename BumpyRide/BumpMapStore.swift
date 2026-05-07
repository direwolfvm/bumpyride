import Foundation
import MapKit
import Observation

/// Aggregated bumpiness across all saved rides.  Rebuilt from the source rides
/// on demand — that's O(total points) and measured in milliseconds for typical
/// ride counts, which beats the complexity of keeping an incremental index in sync.
@Observable
final class BumpMapStore {
    private(set) var grid = BumpGrid()
    /// Bumps whenever `grid` is replaced, so map tile overlays can invalidate.
    private(set) var dataVersion: Int = 0
    /// Last ride-state signature we rebuilt from (id + points count), to skip needless rebuilds.
    private var lastSignature: String = ""

    var boundingRegion: MKCoordinateRegion? {
        guard !grid.isEmpty, grid.minLat.isFinite else { return nil }
        let center = CLLocationCoordinate2D(
            latitude: (grid.minLat + grid.maxLat) / 2,
            longitude: (grid.minLon + grid.maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.005, (grid.maxLat - grid.minLat) * 1.4),
            longitudeDelta: max(0.005, (grid.maxLon - grid.minLon) * 1.4)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    /// Rebuild the grid from the given rides, unless the input hasn't changed.
    func rebuildIfNeeded(from rides: [Ride]) {
        let sig = Self.signature(rides)
        guard sig != lastSignature else { return }
        lastSignature = sig

        var g = BumpGrid()
        for r in rides {
            for p in r.points {
                g.add(lat: p.latitude, lon: p.longitude, bumpiness: p.bumpiness)
            }
        }
        grid = g
        dataVersion &+= 1
    }

    private static func signature(_ rides: [Ride]) -> String {
        // Ride id + point count is enough — editing trims points, which changes count.
        var parts: [String] = []
        parts.reserveCapacity(rides.count)
        for r in rides {
            parts.append("\(r.id.uuidString):\(r.points.count)")
        }
        parts.sort()
        return parts.joined(separator: "|")
    }
}
