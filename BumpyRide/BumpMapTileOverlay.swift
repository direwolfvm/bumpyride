import Foundation
import MapKit
import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Custom tile overlay that rasterises the `BumpGrid` into 256×256 tiles, colored
/// per cell by the app's bumpiness→color function.  Semi-transparent so the muted
/// basemap shows through.
final class BumpMapTileOverlay: MKTileOverlay {
    let grid: BumpGrid
    let settings: AppSettings
    private static let tileFillAlpha: CGFloat = 0.78
    /// Pixel radius of the purple glow halo, fixed in screen-space.  Because tiles are
    /// rendered at the zoom level they're displayed at, a fixed pixel radius means the
    /// halo's geographic radius shrinks as the user zooms in (and grows when zoomed out),
    /// which is the behavior the design called for.
    /// Two-layer halo: a tight, bright "core" near the cell perimeter for crisp edge
    /// definition, plus a wider, deeper aura for visibility when zoomed out.  Both fade
    /// out with their own Gaussian, so far-field haze stays low while near-cell glow
    /// reads as a vivid neon ring.
    private static let innerGlowRadiusPx: CGFloat = 7.0
    private static let innerGlowColor = UIColor(red: 0.85, green: 0.50, blue: 1.0, alpha: 1.0)
    private static let outerGlowRadiusPx: CGFloat = 22.0
    private static let outerGlowColor = UIColor(red: 0.55, green: 0.18, blue: 0.95, alpha: 0.78)
    private static let maxGlowRadiusPx: CGFloat = 22.0

    init(grid: BumpGrid, settings: AppSettings) {
        self.grid = grid
        self.settings = settings
        super.init(urlTemplate: nil)
        self.tileSize = CGSize(width: 256, height: 256)
        self.canReplaceMapContent = false
        // Skip global-scale tiles — at zooms where a 20-ft cell is subpixel,
        // the overlay would just be noise.
        self.minimumZ = 11
        self.maximumZ = 20
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, (any Error)?) -> Void) {
        // Snapshot the things the render needs (values types / thread-safe readers).
        let grid = self.grid
        let settings = self.settings

        DispatchQueue.global(qos: .userInitiated).async {
            let data = Self.render(path: path, grid: grid, settings: settings)
            result(data, nil)
        }
    }

    // MARK: - Rendering

    private static func render(path: MKTileOverlayPath, grid: BumpGrid, settings: AppSettings) -> Data? {
        let tilePx = 256
        let bounds = tileBounds(z: path.z, x: path.x, y: path.y)
        let (latMin, latMax, lonMin, lonMax) = bounds

        let cellSpan = BumpGrid.cellLatDeg
        let gridLatSpan = (latMax - latMin) / cellSpan
        let approxPixPerCell = Double(tilePx) / max(1.0, gridLatSpan)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: tilePx, height: tilePx,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.clear(CGRect(x: 0, y: 0, width: tilePx, height: tilePx))

        // CGBitmapContext is y-up (origin bottom-left), but the resulting PNG pixel rows
        // are read top-down by MapKit (row 0 = north edge of tile).  Flip the axis so the
        // rest of the drawing code can use image-space conventions: y = 0 at the top.
        ctx.translateBy(x: 0, y: CGFloat(tilePx))
        ctx.scaleBy(x: 1, y: -1)

        // Pre-compute merc projection bounds for y-axis.
        let mercYMax = mercatorY(lat: latMax)
        let mercYMin = mercatorY(lat: latMin)
        let mercYSpan = mercYMax - mercYMin
        let lonSpan = lonMax - lonMin

        // Expand the query bounds by the *largest* glow radius so cells just outside the
        // tile still contribute their halo into this tile (no seams at tile edges).
        let glowLat = Double(Self.maxGlowRadiusPx) * (latMax - latMin) / Double(tilePx)
        let glowLon = Double(Self.maxGlowRadiusPx) * lonSpan / Double(tilePx)
        let entries = grid.entries(
            latRange: (latMin - glowLat)...(latMax + glowLat),
            lonRange: (lonMin - glowLon)...(lonMax + glowLon)
        )

        // Minimum on-screen size so sparse cells at low zoom stay visible.
        let minPx = max(1.0, min(3.0, approxPixPerCell))

        // Pre-compute each cell's pixel rect once — used by both the glow pass and the
        // color pass so they line up exactly.
        struct CellRect { let rect: CGRect; let avg: Double }
        var rects: [CellRect] = []
        rects.reserveCapacity(entries.count)
        for (ix, iy, avg) in entries {
            let (cellLat, cellLon) = BumpGrid.cellOrigin(ix: ix, iy: iy)

            let x0 = (cellLon - lonMin) / lonSpan * Double(tilePx)
            let x1 = (cellLon + BumpGrid.cellLonDeg - lonMin) / lonSpan * Double(tilePx)

            let y0 = (mercYMax - mercatorY(lat: cellLat + BumpGrid.cellLatDeg)) / mercYSpan * Double(tilePx)
            let y1 = (mercYMax - mercatorY(lat: cellLat)) / mercYSpan * Double(tilePx)

            // Anchor the pixel-minimum padding on the cell's geometric center so a
            // sub-pixel cell doesn't systematically drift toward one corner as zoom changes.
            let cx = (x0 + x1) / 2
            let cy = (y0 + y1) / 2
            let w = max(minPx, x1 - x0)
            let h = max(minPx, y1 - y0)
            rects.append(CellRect(
                rect: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h),
                avg: avg
            ))
        }

        // Pass 1 — glow halo, in two stacked layers.  Building one combined path of all
        // cell rects and filling once per layer keeps this fast: CG draws the blurred
        // halo around the union's outer perimeter rather than computing a separate halo
        // per cell.  The layered Gaussian shadows give the halo a "neon" character —
        // bright edge ring (inner) blending into a wider soft aura (outer).
        let combined: CGPath? = {
            guard !rects.isEmpty else { return nil }
            let p = CGMutablePath()
            for cr in rects { p.addRect(cr.rect) }
            return p
        }()

        if let combined {
            // Outer aura first so the brighter inner pass sits on top of it.
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: Self.outerGlowRadiusPx, color: Self.outerGlowColor.cgColor)
            ctx.setFillColor(Self.outerGlowColor.cgColor)
            ctx.addPath(combined)
            ctx.fillPath()
            ctx.restoreGState()

            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: Self.innerGlowRadiusPx, color: Self.innerGlowColor.cgColor)
            ctx.setFillColor(Self.innerGlowColor.cgColor)
            ctx.addPath(combined)
            ctx.fillPath()
            ctx.restoreGState()
        }

        // Pass 2 — color the cells.  Use `.copy` blend mode so each cell's pixels
        // *replace* the underlying purple from the glow pass instead of compositing on top
        // of it (which would tint every cell purple).  Outside the cell rects the glow is
        // untouched, so we keep the halo only on the perimeter.
        ctx.saveGState()
        ctx.setBlendMode(.copy)
        for cr in rects {
            let color = settings.uiColor(for: cr.avg).withAlphaComponent(Self.tileFillAlpha)
            ctx.setFillColor(color.cgColor)
            ctx.fill(cr.rect)
        }
        ctx.restoreGState()

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
