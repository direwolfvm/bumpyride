import SwiftUI
import MapKit
import UIKit
import CoreLocation

@MainActor
enum RideImageExporter {
    enum ExportError: Error {
        case noData
        case snapshotFailed
        case renderFailed
    }

    static func export(ride: Ride, settings: AppSettings) async throws -> UIImage {
        guard !ride.points.isEmpty else { throw ExportError.noData }

        let mapSize = CGSize(width: 1200, height: 900)
        let mapImage = try await mapSnapshot(for: ride, size: mapSize, settings: settings)

        let content = ExportComposition(
            ride: ride,
            mapImage: mapImage,
            settings: settings
        )
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.proposedSize = .init(width: 1200, height: nil)
        guard let image = renderer.uiImage else { throw ExportError.renderFailed }
        return flattenedOpaque(image)
    }

    static func saveToPhotos(_ image: UIImage) {
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
    }

    private static func flattenedOpaque(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = image.scale
        let size = image.size
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            image.draw(at: .zero)
        }
    }

    private static func mapSnapshot(for ride: Ride, size: CGSize, settings: AppSettings) async throws -> UIImage {
        let region = boundingRegion(for: ride)
        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = size
        options.scale = 2.0
        options.mapType = .mutedStandard
        options.pointOfInterestFilter = .excludingAll

        let snapshotter = MKMapSnapshotter(options: options)
        let snapshot: MKMapSnapshotter.Snapshot = try await withCheckedThrowingContinuation { cont in
            snapshotter.start(with: .global(qos: .userInitiated)) { snap, err in
                if let snap { cont.resume(returning: snap) }
                else { cont.resume(throwing: err ?? ExportError.snapshotFailed) }
            }
        }

        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { rendererCtx in
            snapshot.image.draw(at: .zero)
            let ctx = rendererCtx.cgContext
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(6)

            let pts = ride.points
            guard pts.count > 1 else { return }
            for i in 1..<pts.count {
                let a = snapshot.point(for: pts[i - 1].coordinate)
                let b = snapshot.point(for: pts[i].coordinate)
                let avg = (pts[i - 1].bumpiness + pts[i].bumpiness) / 2
                ctx.setStrokeColor(settings.uiColor(for: avg).cgColor)
                ctx.move(to: a)
                ctx.addLine(to: b)
                ctx.strokePath()
            }

            if let first = pts.first {
                let p = snapshot.point(for: first.coordinate)
                drawDot(ctx: ctx, at: p, color: UIColor.white, radius: 10)
                drawDot(ctx: ctx, at: p, color: UIColor.systemGreen, radius: 6)
            }
            if let last = pts.last {
                let p = snapshot.point(for: last.coordinate)
                drawDot(ctx: ctx, at: p, color: UIColor.white, radius: 10)
                drawDot(ctx: ctx, at: p, color: UIColor.systemRed, radius: 6)
            }
        }
        return img
    }

    private static func drawDot(ctx: CGContext, at p: CGPoint, color: UIColor, radius: CGFloat) {
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
    }

    private static func boundingRegion(for ride: Ride) -> MKCoordinateRegion {
        let pts = ride.points
        if pts.isEmpty {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
        }
        var minLat = pts[0].latitude, maxLat = pts[0].latitude
        var minLon = pts[0].longitude, maxLon = pts[0].longitude
        for p in pts {
            minLat = min(minLat, p.latitude); maxLat = max(maxLat, p.latitude)
            minLon = min(minLon, p.longitude); maxLon = max(maxLon, p.longitude)
        }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.003, (maxLat - minLat) * 1.4),
            longitudeDelta: max(0.003, (maxLon - minLon) * 1.4)
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}

private struct ExportComposition: View {
    let ride: Ride
    let mapImage: UIImage
    let settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ride.title)
                    .font(.system(size: 40, weight: .bold))
                Text(Formatters.dateTime(ride.startedAt))
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }

            Image(uiImage: mapImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            bumpinessChart
                .frame(height: 220)

            legend

            HStack(spacing: 24) {
                stat("Distance", Formatters.distance(ride.distanceMeters))
                stat("Duration", Formatters.duration(ride.duration))
                stat("Avg", String(format: "%.2fg", ride.averageBumpiness))
                stat("Max", String(format: "%.2fg", ride.maxBumpiness))
            }

            Text("BumpyRide")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(40)
        .frame(width: 1200)
        .background(Color.white)
    }

    private var bumpinessChart: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(Color.black)
                Canvas { ctx, size in
                    let pts = ride.points
                    guard !pts.isEmpty else { return }
                    let barWidth = size.width / CGFloat(pts.count)
                    let topG = max(0.5, settings.topG)
                    for (i, p) in pts.enumerated() {
                        let norm = min(1.0, p.bumpiness / topG)
                        let h = CGFloat(norm) * (size.height - 24)
                        let rect = CGRect(x: CGFloat(i) * barWidth, y: size.height - h - 8, width: max(1, barWidth), height: h)
                        ctx.fill(Path(rect), with: .color(settings.color(for: p.bumpiness)))
                    }
                }
                .padding(12)
                VStack {
                    HStack {
                        Text("BUMPINESS OVER TIME")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                        Spacer()
                        Text(String(format: "scale 0–%.1fg", max(0.5, settings.topG)))
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    Spacer()
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            legendItem(color: settings.color(for: 0), label: "smooth")
            legendItem(color: settings.color(for: settings.yellowG), label: String(format: "%.1fg", settings.yellowG))
            legendItem(color: settings.color(for: settings.orangeG), label: String(format: "%.1fg", settings.orangeG))
            legendItem(color: settings.color(for: settings.redG), label: String(format: "%.1fg", settings.redG))
            legendItem(color: settings.color(for: settings.purpleG), label: String(format: "%.1fg+", settings.purpleG))
            Spacer()
        }
        .font(.system(size: 14).monospacedDigit())
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 18, height: 12)
            Text(label).foregroundStyle(.secondary)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 14)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .semibold).monospacedDigit())
        }
    }
}
