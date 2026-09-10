import Foundation
import CoreLocation

/// Sparse grid of average bumpiness, quantized to ~20 ft cells in lat/lon.
///
/// The longitude cell size is pinned to the DC reference latitude so indices are stable
/// across the app's working region (DC metro, ≤ ~20 mi span).  Near-zero error in
/// that envelope: cos(lat) varies <1% between 38.6° and 39.2°.
nonisolated struct BumpGrid {
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

    /// Explicit because declaring `init?(serialized:)` below suppresses the
    /// synthesized default initializer.
    init() {}

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

    // MARK: - Focus

    /// Bounding box of the cells that hold the bulk of the data, trimming
    /// `trim` of the sample weight off each edge on each axis.  This is what
    /// the map should open on.  The full `minLat…maxLon` extent is dragged
    /// out by any single far-away ride — one trip across town and the
    /// initial camera sits below the overlay's minimum zoom, so nothing
    /// renders.  Trimming 2 % per edge by sample weight ignores such
    /// outliers while keeping every place the rider actually rides.
    func focusBounds(trim: Double = 0.02) -> (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)? {
        guard !cells.isEmpty else { return nil }
        var byIx: [Int: Int] = [:], byIy: [Int: Int] = [:]
        var total = 0
        for (k, e) in cells {
            let (ix, iy) = Self.unpack(k)
            byIx[ix, default: 0] += e.count
            byIy[iy, default: 0] += e.count
            total += e.count
        }
        func band(_ hist: [Int: Int]) -> (Int, Int) {
            let keys = hist.keys.sorted()
            let lo = Double(total) * trim, hi = Double(total) * (1 - trim)
            var acc = 0, a = keys[0], b = keys[keys.count - 1]
            var aSet = false
            for k in keys {
                acc += hist[k]!
                if !aSet && Double(acc) >= lo { a = k; aSet = true }
                if Double(acc) >= hi { b = k; break }
            }
            return (a, b)
        }
        let (ix0, ix1) = band(byIx), (iy0, iy1) = band(byIy)
        return (Double(iy0) * Self.cellLatDeg, Double(iy1 + 1) * Self.cellLatDeg,
                Double(ix0) * Self.cellLonDeg, Double(ix1 + 1) * Self.cellLonDeg)
    }

    // MARK: - Serialization (BumpMapStore disk cache)

    /// Compact binary form: magic, count, then (key, sum, count) triples.
    /// A lifetime grid of a few hundred thousand cells is a few MB and
    /// loads in milliseconds — versus re-reading every ride file.
    private static let magic: UInt32 = 0x4247_5231  // "BGR1"

    func serialized() -> Data {
        var d = Data(capacity: 12 + cells.count * 24)
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        put(Self.magic); put(UInt64(cells.count))
        for (k, e) in cells { put(k); put(e.sum); put(Int64(e.count)) }
        return d
    }

    init?(serialized d: Data) {
        guard d.count >= 12 else { return nil }
        var off = 0
        func take<T>(_: T.Type) -> T? {
            let n = MemoryLayout<T>.size
            guard off + n <= d.count else { return nil }
            let v = d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: T.self) }
            off += n; return v
        }
        guard take(UInt32.self) == Self.magic, let n = take(UInt64.self),
              d.count == 12 + Int(n) * 24 else { return nil }
        var c: [UInt64: Entry] = [:]; c.reserveCapacity(Int(n))
        var mnLat = Double.infinity, mxLat = -Double.infinity, mnLon = Double.infinity, mxLon = -Double.infinity
        for _ in 0..<n {
            guard let k = take(UInt64.self), let sum = take(Double.self), let cnt = take(Int64.self) else { return nil }
            c[k] = Entry(sum: sum, count: Int(cnt))
            let (ix, iy) = Self.unpack(k)
            let (lat, lon) = Self.cellOrigin(ix: ix, iy: iy)
            mnLat = min(mnLat, lat); mxLat = max(mxLat, lat + Self.cellLatDeg)
            mnLon = min(mnLon, lon); mxLon = max(mxLon, lon + Self.cellLonDeg)
        }
        cells = c; minLat = mnLat; maxLat = mxLat; minLon = mnLon; maxLon = mxLon
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
