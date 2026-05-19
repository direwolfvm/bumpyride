import Foundation
import MapKit
import Observation

/// Aggregated brake-event counts across all saved rides.  Mirrors
/// `BumpMapStore`'s lifecycle: rebuilt from source rides on demand, signature-
/// cached so we skip rebuilds when nothing relevant changed.
///
/// Skips rides whose `brakeEvents` is `nil` ("not yet detected") so the brake
/// map doesn't lie by omission — they'll appear once `BrakeReprocessor` runs
/// on the next launch.  `brakeEvents == []` (detected, none found) is
/// included in the signature but contributes no cells.
@Observable
final class BrakeMapStore {
    private(set) var grid = BrakeGrid()
    /// Bumps whenever `grid` is replaced, so map tile overlays can invalidate.
    private(set) var dataVersion: Int = 0
    /// Last ride-state signature we rebuilt from, to skip needless rebuilds.
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

    /// Rebuild the grid from the given rides unless the input hasn't changed.
    ///
    /// Unlike `BumpMapStore`, no calibration parameter — calibration corrects
    /// for the bumpiness systematic damping in pocket mode, which doesn't
    /// apply to GPS-derived deceleration.  A hard brake reads the same regardless
    /// of where the phone was carried.
    func rebuildIfNeeded(from rides: [Ride]) {
        let sig = Self.signature(rides)
        guard sig != lastSignature else { return }
        lastSignature = sig

        var g = BrakeGrid()
        for r in rides {
            // `brakeEvents == nil` means detection hasn't run on this ride yet
            // (legacy ride queued for backfill, or a fresh sync-down).  Skip
            // — don't pretend it has zero events.  `brakeEvents == []` means
            // detection ran and found nothing; iterating that empty array is
            // a no-op.
            guard let events = r.brakeEvents else { continue }
            for e in events {
                g.add(lat: e.latitude, lon: e.longitude)
            }
        }
        grid = g
        dataVersion &+= 1
    }

    /// Cache-bust signature.  Includes each ride's id + a token that captures
    /// whether `brakeEvents` is "not detected," "empty," or "N events" — that
    /// trio of states is what differentiates two ride sets for the brake
    /// aggregation.
    private static func signature(_ rides: [Ride]) -> String {
        var parts: [String] = []
        parts.reserveCapacity(rides.count)
        for r in rides {
            // -1 = nil (not detected), N >= 0 = detected with N events.
            // Distinguishes pre-reprocess from post-reprocess for the same ride.
            let token = r.brakeEvents.map { String($0.count) } ?? "nil"
            parts.append("\(r.id.uuidString):\(token)")
        }
        parts.sort()
        return parts.joined(separator: "|")
    }
}
