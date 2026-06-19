import Foundation
import MapKit
import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Tile overlay that paints every cell the rider has visited as a flat,
/// translucent purple square — the iOS analog of the sister web app's
/// "visited cells" layer.  Modeled on `BumpMapTileOverlay`'s tile
/// geometry but stripped to a single solid-fill pass: no per-cell
/// bumpiness color, no neon glow, just "I've been here."
///
/// Fed by `BumpMapStore.grid`, whose key set is exactly the cells the
/// rider has data in.  Like the bump overlay, each tile only rasterizes
/// the cells inside its own bounds, off the main thread, so it stays
/// cheap even with a large lifetime grid.
final class VisitedCellsTileOverlay: MKTileOverlay {
    let grid: BumpGrid

    /// Translucent purple matching the bump map's glow family, low enough
    /// alpha that the muted basemap and the colored route both read
    /// through it.
    private static let fillColor = UIColor(red: 0.55, green: 0.25, blue: 0.85, alpha: 0.30)

    init(grid: BumpGrid) {
        self.grid = grid
        super.init(urlTemplate: nil)
        self.tileSize = CGSize(width: 256, height: 256)
        self.canReplaceMapContent = false
        // Below z11 a 20-ft cell is subpixel — skip, same as the bump map.
        self.minimumZ = 11
        self.maximumZ = 20
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, (any Error)?) -> Void) {
        let grid = self.grid
        DispatchQueue.global(qos: .userInitiated).async {
            result(Self.render(path: path, grid: grid), nil)
        }
    }

    // MARK: - Rendering

    private static func render(path: MKTileOverlayPath, grid: BumpGrid) -> Data? {
        let tilePx = 256
        let (latMin, latMax, lonMin, lonMax) = tileBounds(z: path.z, x: path.x, y: path.y)

        let gridLatSpan = (latMax - latMin) / BumpGrid.cellLatDeg
        let approxPixPerCell = Double(tilePx) / max(1.0, gridLatSpan)

        guard let ctx = CGContext(
            data: nil,
            width: tilePx, height: tilePx,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.clear(CGRect(x: 0, y: 0, width: tilePx, height: tilePx))
        // Match BumpMapTileOverlay's axis flip so cell rects line up.
        ctx.translateBy(x: 0, y: CGFloat(tilePx))
        ctx.scaleBy(x: 1, y: -1)

        let mercYMax = mercatorY(lat: latMax)
        let mercYMin = mercatorY(lat: latMin)
        let mercYSpan = mercYMax - mercYMin
        let lonSpan = lonMax - lonMin

        let entries = grid.entries(latRange: latMin...latMax, lonRange: lonMin...lonMax)
        guard !entries.isEmpty else { return nil }

        // Keep sparse cells visible at low zoom.
        let minPx = max(1.0, min(3.0, approxPixPerCell))

        ctx.setFillColor(Self.fillColor.cgColor)
        for (ix, iy, _) in entries {
            let (cellLat, cellLon) = BumpGrid.cellOrigin(ix: ix, iy: iy)
            let x0 = (cellLon - lonMin) / lonSpan * Double(tilePx)
            let x1 = (cellLon + BumpGrid.cellLonDeg - lonMin) / lonSpan * Double(tilePx)
            let y0 = (mercYMax - mercatorY(lat: cellLat + BumpGrid.cellLatDeg)) / mercYSpan * Double(tilePx)
            let y1 = (mercYMax - mercatorY(lat: cellLat)) / mercYSpan * Double(tilePx)
            let cx = (x0 + x1) / 2
            let cy = (y0 + y1) / 2
            let w = max(minPx, x1 - x0)
            let h = max(minPx, y1 - y0)
            ctx.fill(CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h))
        }

        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

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
