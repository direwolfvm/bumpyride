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
    ///
    /// `calibration` lets the caller correct for pocket-mode systematic damping —
    /// pocket-tagged samples get multiplied by `calibration.pocketGain` before they
    /// enter the grid.  Untagged and explicitly-mounted samples flow through
    /// unchanged.  The calibration value is included in the cache-busting signature
    /// so a recalibration after new overlapping data triggers a rebuild.
    /// v2.0 P1: summaries in, points streamed.  The grid needs every
    /// ride's points, but holding them all resident is what the lazy
    /// store exists to avoid — so the rebuild folds full rides one at
    /// a time off-main via `store.foldRides` (peak memory: one ride).
    /// The signature short-circuit is computed from summaries alone.
    func rebuildIfNeeded(
        from rides: [RideSummary],
        calibration: CalibrationStore.PocketCalibration = .init(),
        store: RideStore
    ) async {
        let sig = Self.signature(rides, calibration: calibration)
        guard sig != lastSignature else { return }
        lastSignature = sig

        let pocketGain = calibration.pocketGain
        let useCalibration = calibration.confidence >= CalibrationStore.minOverlappingCells

        let g = await store.foldRides(ids: rides.map(\.id), initial: BumpGrid()) { grid, ride in
            let gain = (useCalibration && ride.pocketMode == true) ? pocketGain : 1.0
            for p in ride.points {
                grid.add(lat: p.latitude, lon: p.longitude, bumpiness: p.bumpiness * gain)
            }
        }
        grid = g
        dataVersion &+= 1
    }

    private static func signature(_ rides: [RideSummary], calibration: CalibrationStore.PocketCalibration) -> String {
        // Ride id + point count is enough — editing trims points, which changes count.
        // Calibration gain rounded to 4 decimals so trivial recomputes don't churn.
        var parts: [String] = []
        parts.reserveCapacity(rides.count + 1)
        for r in rides {
            parts.append("\(r.id.uuidString):\(r.pointCount)")
        }
        parts.sort()
        let k = (calibration.confidence >= CalibrationStore.minOverlappingCells)
            ? String(format: "%.4f", calibration.pocketGain)
            : "1"
        parts.append("k=\(k)")
        return parts.joined(separator: "|")
    }
}
