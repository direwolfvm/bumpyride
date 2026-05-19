import Foundation
import MapKit
import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Tile overlay that rasterises a `BrakeGrid` into 256×256 tiles.
///
/// Visual design intentionally differs from `BumpMapTileOverlay`:
///
/// - **Filled circles, not squares.**  Brake events are discrete incidents,
///   not a continuous heat field — a dot reads as "something happened here"
///   while a square reads as "this area is X."  Reinforces the mental model
///   that the brake map is a *map of incidents*, not a choropleth.
/// - **Color by event count**, hardcoded thresholds.  1 event → yellow,
///   2–3 → orange, 4–5 → red, 6+ → purple.  Count maxes out fast in
///   practice — a corner the user routinely sketchy-brakes at hits the
///   top of the scale quickly, which is what we want to surface.
/// - **No halo glow.**  Bump-map glow is for low-zoom visibility of soft
///   continuous data; brake events are point-like and don't need the
///   spreading.  A subtle outline ring keeps individual dots visible
///   against the basemap.
///
/// Same tile coordinate math as `BumpMapTileOverlay` (web mercator, 256 px
/// tiles, y-flip to image-space).  Shares the cell key/origin functions
/// with `BumpGrid` so a cell at a given lat/lon lines up exactly between
/// the bump and brake views.
final class BrakeMapTileOverlay: MKTileOverlay {
    let grid: BrakeGrid

    /// Pixel radius of a single-cell dot at "natural" zoom (one cell ≈ a
    /// dozen pixels).  Sub-pixel cells get scaled up to at least this much
    /// so far-zoomed-out brake events stay visible.
    private static let baseDotRadiusPx: CGFloat = 6.0
    /// Outline thickness for the ring around each dot.  Crisp edge.
    private static let outlineWidthPx: CGFloat = 1.5
    /// Outline color — semi-transparent dark to read against any basemap
    /// hue (the muted Apple Maps style uses pale beige + grey).
    private static let outlineColor = UIColor(white: 0.1, alpha: 0.55)

    init(grid: BrakeGrid) {
        self.grid = grid
        super.init(urlTemplate: nil)
        self.tileSize = CGSize(width: 256, height: 256)
        self.canReplaceMapContent = false
        // Same z-range as the bump map.  Below z=11 a 20 ft cell is
        // subpixel and the overlay reduces to noise; above z=20 MapKit
        // hands us tiles whose lat/lon span is too small to be meaningful.
        self.minimumZ = 11
        self.maximumZ = 20
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, (any Error)?) -> Void) {
        let grid = self.grid
        DispatchQueue.global(qos: .userInitiated).async {
            let data = Self.render(path: path, grid: grid)
            result(data, nil)
        }
    }

    // MARK: - Rendering

    private static func render(path: MKTileOverlayPath, grid: BrakeGrid) -> Data? {
        let tilePx = 256
        let (latMin, latMax, lonMin, lonMax) = tileBounds(z: path.z, x: path.x, y: path.y)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: tilePx, height: tilePx,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.clear(CGRect(x: 0, y: 0, width: tilePx, height: tilePx))

        // Same y-flip as BumpMapTileOverlay so the rest of the drawing uses
        // image-space (y = 0 at top) instead of CG's default y-up.
        ctx.translateBy(x: 0, y: CGFloat(tilePx))
        ctx.scaleBy(x: 1, y: -1)

        let mercYMax = mercatorY(lat: latMax)
        let mercYMin = mercatorY(lat: latMin)
        let mercYSpan = mercYMax - mercYMin
        let lonSpan = lonMax - lonMin

        // Expand the query bounds by the dot radius so dots whose centers
        // are just outside the tile still get drawn into this tile (no
        // seams where a dot is clipped at the edge).
        let dotMargin = Double(baseDotRadiusPx + outlineWidthPx)
        let marginLat = dotMargin * (latMax - latMin) / Double(tilePx)
        let marginLon = dotMargin * lonSpan / Double(tilePx)
        let entries = grid.entries(
            latRange: (latMin - marginLat)...(latMax + marginLat),
            lonRange: (lonMin - marginLon)...(lonMax + marginLon)
        )

        // Approximate pixels per cell at this zoom.  Used to size dots —
        // when a cell is bigger than the base dot, expand the dot to fill
        // it so the user-perceived "incident hotspot" scales with zoom.
        let cellSpan = BumpGrid.cellLatDeg
        let gridLatSpan = (latMax - latMin) / cellSpan
        let pxPerCell = Double(tilePx) / max(1.0, gridLatSpan)
        let dotRadius = max(Double(baseDotRadiusPx), pxPerCell / 2)

        for (ix, iy, count) in entries {
            let (cellLat, cellLon) = BumpGrid.cellOrigin(ix: ix, iy: iy)
            // Center of the cell in degrees → tile pixel coords.
            let centerLat = cellLat + BumpGrid.cellLatDeg / 2
            let centerLon = cellLon + BumpGrid.cellLonDeg / 2

            let px = (centerLon - lonMin) / lonSpan * Double(tilePx)
            let py = (mercYMax - mercatorY(lat: centerLat)) / mercYSpan * Double(tilePx)

            let rect = CGRect(
                x: px - dotRadius,
                y: py - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            )
            let fill = color(forCount: count)
            ctx.setFillColor(fill.cgColor)
            ctx.fillEllipse(in: rect)

            // Outline ring for definition against the basemap.
            ctx.setStrokeColor(Self.outlineColor.cgColor)
            ctx.setLineWidth(Self.outlineWidthPx)
            ctx.strokeEllipse(in: rect)
        }

        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out as CFMutableData,
            UTType.png.identifier as CFString,
            1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Count → fill color.  Hardcoded thresholds tuned for "a typical
    /// commuter cyclist's bumpyride map" — most cells will have 1 event
    /// (yellow), a handful of repeated-incident corners will hit 2–3
    /// (orange), and the worst spots (sketchy intersections the rider
    /// has hit hard 4+ times) saturate at red/purple.  Can be moved to
    /// `AppSettings` later if users want to retune.
    private static func color(forCount count: Int) -> UIColor {
        switch count {
        case 1:
            return UIColor(red: 0.95, green: 0.85, blue: 0.20, alpha: 0.92)  // yellow
        case 2...3:
            return UIColor(red: 0.98, green: 0.55, blue: 0.15, alpha: 0.92)  // orange
        case 4...5:
            return UIColor(red: 0.92, green: 0.20, blue: 0.20, alpha: 0.92)  // red
        default:
            return UIColor(red: 0.60, green: 0.25, blue: 0.85, alpha: 0.92)  // purple, 6+
        }
    }

    // MARK: - Tile math (duplicated from BumpMapTileOverlay)

    /// Standard web-mercator tile → lat/lon bounds.
    private static func tileBounds(z: Int, x: Int, y: Int) -> (Double, Double, Double, Double) {
        let n = pow(2.0, Double(z))
        let lonMin = Double(x) / n * 360.0 - 180.0
        let lonMax = Double(x + 1) / n * 360.0 - 180.0
        let latMax = atan(sinh(.pi * (1 - 2 * Double(y) / n))) * 180.0 / .pi
        let latMin = atan(sinh(.pi * (1 - 2 * Double(y + 1) / n))) * 180.0 / .pi
        return (latMin, latMax, lonMin, lonMax)
    }

    private static func mercatorY(lat: Double) -> Double {
        log(tan(.pi / 4 + lat * .pi / 360))
    }
}
