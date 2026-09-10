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

    /// Region the map should *open* on: the cells holding ~96 % of the
    /// sample weight, padded.  `boundingRegion` is the full extent and is
    /// what the outlier problem is made of — see `BumpGrid.focusBounds`.
    var focusRegion: MKCoordinateRegion? {
        guard let b = grid.focusBounds() else { return nil }
        let center = CLLocationCoordinate2D(latitude: (b.minLat + b.maxLat) / 2,
                                            longitude: (b.minLon + b.maxLon) / 2)
        return MKCoordinateRegion(center: center, span: MKCoordinateSpan(
            latitudeDelta: max(0.005, (b.maxLat - b.minLat) * 1.3),
            longitudeDelta: max(0.005, (b.maxLon - b.minLon) * 1.3)))
    }

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
        lastCalibration = calibration

        // Disk cache first.  The fold below re-reads and decodes every ride
        // file (hundreds of MB for a long-time rider) and that is the whole
        // reason the visited-cells overlay used to take so long to appear
        // after launch.  A grid built for this exact ride set + calibration
        // is a few MB on disk and loads in milliseconds.
        if let cached = await Self.loadCached(signature: sig) {
            grid = cached
            dataVersion &+= 1
            return
        }

        let pocketGain = calibration.pocketGain
        let useCalibration = calibration.confidence >= CalibrationStore.minOverlappingCells

        let g = await store.foldRides(ids: rides.map(\.id), initial: BumpGrid()) { grid, ride in
            let gain = (useCalibration && ride.pocketMode == true) ? pocketGain : 1.0
            for p in ride.points {
                grid.add(lat: p.latitude, lon: p.longitude, bumpiness: p.bumpiness * gain)
            }
        }
        // The signature may have moved on while we were folding (another
        // rebuild raced us); only publish if we're still current.
        guard sig == lastSignature else { return }
        grid = g
        dataVersion &+= 1
        Self.storeCached(g, signature: sig)
    }

    /// Calibration the current `grid` was built with — needed to fold a
    /// newly saved ride in with the same gain.
    private var lastCalibration: CalibrationStore.PocketCalibration = .init()

    /// Fold one just-saved ride into the existing grid instead of rebuilding
    /// from scratch.  Valid only when the grid is current for "all rides
    /// except this one" under the same calibration; otherwise it's a no-op
    /// and the next `rebuildIfNeeded` does the full job.  Edits (same id,
    /// different point count) are not incremental — the old points can't be
    /// subtracted out of averaged cells.
    func noteRideSaved(_ ride: Ride, rides: [RideSummary]) {
        let others = rides.filter { $0.id != ride.id }
        guard others.count == rides.count - 1,
              Self.signature(others, calibration: lastCalibration) == lastSignature else { return }
        let useCalibration = lastCalibration.confidence >= CalibrationStore.minOverlappingCells
        let gain = (useCalibration && ride.pocketMode == true) ? lastCalibration.pocketGain : 1.0
        var g = grid
        for p in ride.points {
            g.add(lat: p.latitude, lon: p.longitude, bumpiness: p.bumpiness * gain)
        }
        grid = g
        lastSignature = Self.signature(rides, calibration: lastCalibration)
        dataVersion &+= 1
        Self.storeCached(g, signature: lastSignature)
    }

    // MARK: - Disk cache

    /// Caches/ (never iCloud): `bump-grid-<hash>.bin`, one per signature.
    /// Several are kept so switching the All/Mounted/Pocket filter, or
    /// alternating between the tab's calibrated grid and the live map's
    /// uncalibrated one, doesn't thrash a single slot.
    nonisolated private static let maxCacheFiles = 4

    nonisolated private static func cacheURL(for signature: String) -> URL {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325          // FNV-1a
        for b in signature.utf8 { h ^= UInt64(b); h &*= 0x0000_0100_0000_01b3 }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(String(format: "bump-grid-%016llx.bin", h))
    }

    nonisolated private static func loadCached(signature: String) async -> BumpGrid? {
        let url = cacheURL(for: signature)
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            return BumpGrid(serialized: data)
        }.value
    }

    nonisolated private static func storeCached(_ grid: BumpGrid, signature: String) {
        let url = cacheURL(for: signature)
        Task.detached(priority: .utility) {
            try? grid.serialized().write(to: url, options: .atomic)
            // Prune: keep the newest `maxCacheFiles`.
            let dir = url.deletingLastPathComponent()
            let fm = FileManager.default
            guard let names = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            let mine = names.filter { $0.lastPathComponent.hasPrefix("bump-grid-") }
                .sorted { (a, b) in
                    let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return da > db
                }
            for stale in mine.dropFirst(maxCacheFiles) { try? fm.removeItem(at: stale) }
        }
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
