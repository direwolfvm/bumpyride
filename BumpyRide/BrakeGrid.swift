import Foundation
import CoreLocation

/// Sparse grid of brake-event counts, quantized to the same ~20 ft cells as
/// `BumpGrid`.  Different per-cell statistic (count of events, not running
/// average of intensity), but same cell math — they share `BumpGrid`'s
/// constants for `cellSizeFeet`, `referenceLatitude`, and the lat/lon → key
/// projection so a cell at lat/lon `(38.9, -77.0)` has the same key in both
/// grids.  Lets us layer them in the same view if we ever want to.
///
/// **Why count instead of intensity**: brake events are already filtered by
/// the detector to "hard" (≥ 0.25 g, ≥ 0.8 s).  Once an event passes that bar,
/// the more interesting aggregate question is "how many times" rather than
/// "how hard on average" — a corner where the user brakes hard 8 times is
/// notable even if each one is barely above threshold; a single 0.5 g brake
/// could be a one-off.  The detector's threshold acts as the intensity gate.
struct BrakeGrid {
    /// Per-cell tally.  Keys match `BumpGrid.key(ix:iy:)`.
    private(set) var cells: [UInt64: Int] = [:]

    private(set) var minLat: Double = .infinity
    private(set) var maxLat: Double = -.infinity
    private(set) var minLon: Double = .infinity
    private(set) var maxLon: Double = -.infinity

    var count: Int { cells.count }
    var isEmpty: Bool { cells.isEmpty }

    /// Sum of event counts across all cells.  Used by the Bump Map tab's
    /// stats footer to show "Events: N" alongside cell count.
    var totalEvents: Int {
        var sum = 0
        for v in cells.values { sum += v }
        return sum
    }

    /// Largest per-cell event count.  Drives the color scale's top end —
    /// a tile renderer can use this to scale colors against the maximum
    /// rather than hardcoded thresholds.  Returns 0 if empty.
    var maxCount: Int { cells.values.max() ?? 0 }

    mutating func add(lat: Double, lon: Double) {
        let (ix, iy) = BumpGrid.gridIndex(lat: lat, lon: lon)
        let k = BumpGrid.key(ix: ix, iy: iy)
        cells[k, default: 0] += 1
        if lat < minLat { minLat = lat }
        if lat > maxLat { maxLat = lat }
        if lon < minLon { minLon = lon }
        if lon > maxLon { maxLon = lon }
    }

    /// Return cells whose origin lies inside the given bounding box.
    /// Same iteration-strategy switch as `BumpGrid.entries` — scan the
    /// smaller of the box footprint or the dict.
    func entries(
        latRange: ClosedRange<Double>,
        lonRange: ClosedRange<Double>
    ) -> [(ix: Int, iy: Int, count: Int)] {
        guard !cells.isEmpty else { return [] }

        let ixMin = Int(floor(lonRange.lowerBound / BumpGrid.cellLonDeg))
        let ixMax = Int(floor(lonRange.upperBound / BumpGrid.cellLonDeg))
        let iyMin = Int(floor(latRange.lowerBound / BumpGrid.cellLatDeg))
        let iyMax = Int(floor(latRange.upperBound / BumpGrid.cellLatDeg))

        let area = (ixMax - ixMin + 1) * (iyMax - iyMin + 1)
        var out: [(Int, Int, Int)] = []
        out.reserveCapacity(min(area, cells.count))

        if area <= cells.count {
            for ix in ixMin...ixMax {
                for iy in iyMin...iyMax {
                    if let c = cells[BumpGrid.key(ix: ix, iy: iy)] {
                        out.append((ix, iy, c))
                    }
                }
            }
        } else {
            for (k, c) in cells {
                let (ix, iy) = BumpGrid.unpack(k)
                if ix >= ixMin, ix <= ixMax, iy >= iyMin, iy <= iyMax {
                    out.append((ix, iy, c))
                }
            }
        }
        return out
    }
}
