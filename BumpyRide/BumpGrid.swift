import Foundation
import CoreLocation

/// Sparse grid of average bumpiness, quantized to ~20 ft cells in lat/lon.
///
/// The longitude cell size is pinned to the DC reference latitude so indices are stable
/// across the app's working region (DC metro, ≤ ~20 mi span).  Near-zero error in
/// that envelope: cos(lat) varies <1% between 38.6° and 39.2°.
struct BumpGrid {
    /// Reference latitude used to size longitude cells (constant across the region).
    static let referenceLatitude: Double = 38.9

    /// Side length of one cell in feet.
    static let cellSizeFeet: Double = 20.0
    static let cellSizeMeters: Double = cellSizeFeet * 0.3048

    /// Meters per degree of latitude (near-constant).
    private static let metersPerDegreeLat: Double = 111_320.0
    private static var metersPerDegreeLon: Double {
        cos(referenceLatitude * .pi / 180.0) * metersPerDegreeLat
    }

    static let cellLatDeg: Double = cellSizeMeters / metersPerDegreeLat
    static let cellLonDeg: Double = cellSizeMeters / metersPerDegreeLon

    struct Entry {
        var sum: Double
        var count: Int
        var average: Double { count > 0 ? sum / Double(count) : 0 }
    }

    private(set) var cells: [UInt64: Entry] = [:]
    private(set) var minLat: Double = .infinity
    private(set) var maxLat: Double = -.infinity
    private(set) var minLon: Double = .infinity
    private(set) var maxLon: Double = -.infinity

    var count: Int { cells.count }
    var isEmpty: Bool { cells.isEmpty }

    // MARK: - Index math

    static func gridIndex(lat: Double, lon: Double) -> (ix: Int, iy: Int) {
        let ix = Int(floor(lon / cellLonDeg))
        let iy = Int(floor(lat / cellLatDeg))
        return (ix, iy)
    }

    static func key(ix: Int, iy: Int) -> UInt64 {
        let ux = UInt32(bitPattern: Int32(clamping: ix))
        let uy = UInt32(bitPattern: Int32(clamping: iy))
        return (UInt64(uy) << 32) | UInt64(ux)
    }

    static func unpack(_ k: UInt64) -> (ix: Int, iy: Int) {
        let ux = UInt32(truncatingIfNeeded: k)
        let uy = UInt32(truncatingIfNeeded: k >> 32)
        return (Int(Int32(bitPattern: ux)), Int(Int32(bitPattern: uy)))
    }

    /// Bottom-left corner (min-lat, min-lon) of cell `(ix, iy)` in degrees.
    static func cellOrigin(ix: Int, iy: Int) -> (lat: Double, lon: Double) {
        (Double(iy) * cellLatDeg, Double(ix) * cellLonDeg)
    }

    // MARK: - Mutation

    mutating func add(lat: Double, lon: Double, bumpiness: Double) {
        let (ix, iy) = Self.gridIndex(lat: lat, lon: lon)
        let k = Self.key(ix: ix, iy: iy)
        if var e = cells[k] {
            e.sum += bumpiness
            e.count += 1
            cells[k] = e
        } else {
            cells[k] = Entry(sum: bumpiness, count: 1)
        }
        if lat < minLat { minLat = lat }
        if lat > maxLat { maxLat = lat }
        if lon < minLon { minLon = lon }
        if lon > maxLon { maxLon = lon }
    }

    // MARK: - Query

    /// Return cells whose origin lies inside the given bounding box.
    /// Picks whichever iteration strategy is cheaper: scan the box or scan the dict.
    func entries(
        latRange: ClosedRange<Double>,
        lonRange: ClosedRange<Double>
    ) -> [(ix: Int, iy: Int, average: Double)] {
        guard !cells.isEmpty else { return [] }

        let ixMin = Int(floor(lonRange.lowerBound / Self.cellLonDeg))
        let ixMax = Int(floor(lonRange.upperBound / Self.cellLonDeg))
        let iyMin = Int(floor(latRange.lowerBound / Self.cellLatDeg))
        let iyMax = Int(floor(latRange.upperBound / Self.cellLatDeg))

        let area = (ixMax - ixMin + 1) * (iyMax - iyMin + 1)
        var out: [(Int, Int, Double)] = []
        out.reserveCapacity(min(area, cells.count))

        if area <= cells.count {
            for ix in ixMin...ixMax {
                for iy in iyMin...iyMax {
                    if let e = cells[Self.key(ix: ix, iy: iy)] {
                        out.append((ix, iy, e.average))
                    }
                }
            }
        } else {
            for (k, e) in cells {
                let (ix, iy) = Self.unpack(k)
                if ix >= ixMin, ix <= ixMax, iy >= iyMin, iy <= iyMax {
                    out.append((ix, iy, e.average))
                }
            }
        }
        return out
    }
}
