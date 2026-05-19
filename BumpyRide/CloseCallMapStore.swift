import Foundation
import MapKit
import Observation

/// Aggregated close-call counts across all saved rides.  Sibling to
/// `BumpMapStore` and `BrakeMapStore`; same observable + signature-cached
/// rebuild lifecycle.
///
/// Treats `nil` and `[]` identically for the iteration — both mean "no
/// close calls."  Unlike `brakeEvents`, there's no background reprocessor
/// for close calls (the data isn't computable post-hoc — it's user-
/// initiated), so the signature doesn't need to distinguish "not yet
/// detected" from "detected, none."
@Observable
final class CloseCallMapStore {
    private(set) var grid = CloseCallGrid()
    private(set) var dataVersion: Int = 0
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

    /// Rebuild the grid from the given rides unless the input hasn't
    /// changed.  No calibration parameter — close calls are point events,
    /// not intensity measurements; nothing to correct for.
    func rebuildIfNeeded(from rides: [Ride]) {
        let sig = Self.signature(rides)
        guard sig != lastSignature else { return }
        lastSignature = sig

        var g = CloseCallGrid()
        for r in rides {
            // Nil-coalesce to []: both states render identically here.
            for c in r.closeCallEvents ?? [] {
                g.add(lat: c.latitude, lon: c.longitude)
            }
        }
        grid = g
        dataVersion &+= 1
    }

    private static func signature(_ rides: [Ride]) -> String {
        var parts: [String] = []
        parts.reserveCapacity(rides.count)
        for r in rides {
            // Count tracks both [...] → "N" and nil/[] → "0" the same way,
            // since they're rendered identically.
            let n = r.closeCallEvents?.count ?? 0
            parts.append("\(r.id.uuidString):\(n)")
        }
        parts.sort()
        return parts.joined(separator: "|")
    }
}
