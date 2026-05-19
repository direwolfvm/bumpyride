import Foundation
import MapKit
import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Tile overlay that rasterises a `CloseCallGrid` into 256×256 tiles.
///
/// Visual choices designed to be **distinct at a glance** from both the
/// bump map (colored squares with neon halo) and the brake map (red
/// circles with subtle outline):
///
/// - **Filled diamonds**.  Different geometry from squares and circles —
///   reads as a warning marker without conflicting with the other map's
///   visual vocabulary.  Same effect as a square rotated 45°, computed
///   directly so we don't pay the GState rotation cost.
/// - **Violet palette**.  Stays away from the bump map's
///   yellow/orange/red/purple gradient and the brake map's same gradient.
///   Pale violet for low counts, deepening to magenta for high.
/// - **Subtle dark outline**, like the brake map dots, for definition
///   against the muted basemap.
///
/// Same tile coordinate math as the sibling overlays.
final class CloseCallMapTileOverlay: MKTileOverlay {
    let grid: CloseCallGrid

    /// Half-diagonal of a single-cell diamond at "natural" zoom.  Acts as
    /// a floor so sparse cells at low zoom remain visible.
    private static let baseDiamondHalfPx: CGFloat = 7.0
    private static let outlineWidthPx: CGFloat = 1.5
    private static let outlineColor = UIColor(white: 0.1, alpha: 0.55)

    init(grid: CloseCallGrid) {
        self.grid = grid
        super.init(urlTemplate: nil)
        self.tileSize = CGSize(width: 256, height: 256)
        self.canReplaceMapContent = false
        // Same z-range as the sibling overlays.
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

    private static func render(path: MKTileOverlayPath, grid: CloseCallGrid) -> Data? {
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
        ctx.translateBy(x: 0, y: CGFloat(tilePx))
        ctx.scaleBy(x: 1, y: -1)

        let mercYMax = mercatorY(lat: latMax)
        let mercYMin = mercatorY(lat: latMin)
        let mercYSpan = mercYMax - mercYMin
        let lonSpan = lonMax - lonMin

        // Margin around the tile so diamonds straddling the edge still
        // render into this tile (no seams).
        let margin = Double(baseDiamondHalfPx + outlineWidthPx)
        let marginLat = margin * (latMax - latMin) / Double(tilePx)
        let marginLon = margin * lonSpan / Double(tilePx)
        let entries = grid.entries(
            latRange: (latMin - marginLat)...(latMax + marginLat),
            lonRange: (lonMin - marginLon)...(lonMax + marginLon)
        )

        let cellSpan = BumpGrid.cellLatDeg
        let gridLatSpan = (latMax - latMin) / cellSpan
        let pxPerCell = Double(tilePx) / max(1.0, gridLatSpan)
        let halfDiag = max(Double(baseDiamondHalfPx), pxPerCell / 2)

        for (ix, iy, count) in entries {
            let (cellLat, cellLon) = BumpGrid.cellOrigin(ix: ix, iy: iy)
            let centerLat = cellLat + BumpGrid.cellLatDeg / 2
            let centerLon = cellLon + BumpGrid.cellLonDeg / 2

            let cx = (centerLon - lonMin) / lonSpan * Double(tilePx)
            let cy = (mercYMax - mercatorY(lat: centerLat)) / mercYSpan * Double(tilePx)

            // Diamond corners: top, right, bottom, left.  Drawing the
            // path directly avoids the CGContext rotation overhead.
            let path = CGMutablePath()
            path.move(to: CGPoint(x: cx, y: cy - halfDiag))         // top
            path.addLine(to: CGPoint(x: cx + halfDiag, y: cy))      // right
            path.addLine(to: CGPoint(x: cx, y: cy + halfDiag))      // bottom
            path.addLine(to: CGPoint(x: cx - halfDiag, y: cy))      // left
            path.closeSubpath()

            ctx.addPath(path)
            ctx.setFillColor(color(forCount: count).cgColor)
            ctx.fillPath()

            ctx.addPath(path)
            ctx.setStrokeColor(Self.outlineColor.cgColor)
            ctx.setLineWidth(Self.outlineWidthPx)
            ctx.strokePath()
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

    /// Count → fill color.  Violet ramp distinct from the brake-map's
    /// yellow→purple and the bump-map's yellow→purple.  Tuned for the
    /// expected close-call density (much sparser than brakes — most
    /// cells will be a count of 1).
    private static func color(forCount count: Int) -> UIColor {
        switch count {
        case 1:
            return UIColor(red: 0.65, green: 0.45, blue: 0.92, alpha: 0.90)  // pale violet
        case 2...3:
            return UIColor(red: 0.55, green: 0.25, blue: 0.85, alpha: 0.92)  // mid violet
        case 4...5:
            return UIColor(red: 0.65, green: 0.18, blue: 0.75, alpha: 0.94)  // deep violet
        default:
            return UIColor(red: 0.78, green: 0.15, blue: 0.55, alpha: 0.96)  // magenta, 6+
        }
    }

    // MARK: - Tile math

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
