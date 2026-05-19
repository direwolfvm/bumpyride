import Foundation
import CoreLocation

/// Sparse grid of close-call counts, quantized to the same ~20 ft cells as
/// `BumpGrid` and `BrakeGrid`.  Same cell math, same key convention — a
/// cell at any lat/lon has identical keys across all three grids, so future
/// "show me everything at this corner" layered views are trivial.
///
/// **Why count rather than something richer**: close-call events only carry
/// timestamp + location (no severity, no category — see `CloseCall`).  Count
/// is the only meaningful aggregate, and it's the right metric anyway: a
/// corner with 5 logged close calls is more notable than one with 1,
/// regardless of how each rider felt about each individual incident.
struct CloseCallGrid {
    /// Per-cell tally.  Keys match `BumpGrid.key(ix:iy:)`.
    private(set) var cells: [UInt64: Int] = [:]

    private(set) var minLat: Double = .infinity
    private(set) var maxLat: Double = -.infinity
    private(set) var minLon: Double = .infinity
    private(set) var maxLon: Double = -.infinity

    var count: Int { cells.count }
    var isEmpty: Bool { cells.isEmpty }

    /// Sum of event counts across all cells.  Used by the Bump Map tab's
    /// stats footer to show "Calls: N" in close-calls mode.
    var totalEvents: Int {
        var sum = 0
        for v in cells.values { sum += v }
        return sum
    }

    /// Largest per-cell event count.  Could drive a dynamic color scale
    /// later if we want — for v1.0 the renderer uses hardcoded thresholds.
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
    /// Same iteration-strategy switch as the sibling grids — scan whichever
    /// is smaller, the box footprint or the dict.
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
