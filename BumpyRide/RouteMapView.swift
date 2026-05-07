import SwiftUI
import MapKit
import CoreLocation

struct RouteMapView: View {
    var points: [RidePoint]
    var followUser: Bool
    var highlightIndex: Int?
    var settings: AppSettings

    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        Map(position: $cameraPosition) {
            UserAnnotation()

            ForEach(segments(), id: \.id) { seg in
                MapPolyline(coordinates: [seg.start, seg.end])
                    .stroke(seg.color, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }

            if let idx = highlightIndex, points.indices.contains(idx) {
                let p = points[idx]
                Annotation("", coordinate: p.coordinate) {
                    ZStack {
                        Circle()
                            .fill(.white)
                            .frame(width: 18, height: 18)
                        Circle()
                            .fill(settings.color(for: p.bumpiness))
                            .frame(width: 12, height: 12)
                    }
                }
            }
        }
        .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .onAppear { updateCamera(initial: true) }
        .onChange(of: points.count) { _, _ in updateCamera(initial: false) }
        .onChange(of: highlightIndex) { _, _ in centerOnHighlight() }
    }

    private struct Segment: Identifiable {
        let id = UUID()
        let start: CLLocationCoordinate2D
        let end: CLLocationCoordinate2D
        let color: Color
    }

    private func segments() -> [Segment] {
        guard points.count > 1 else { return [] }
        var out: [Segment] = []
        out.reserveCapacity(points.count - 1)
        for i in 1..<points.count {
            let a = points[i - 1]
            let b = points[i]
            let avg = (a.bumpiness + b.bumpiness) / 2
            out.append(Segment(start: a.coordinate, end: b.coordinate, color: settings.color(for: avg)))
        }
        return out
    }

    private func updateCamera(initial: Bool) {
        guard !followUser else {
            if initial { cameraPosition = .userLocation(fallback: .automatic) }
            return
        }
        if let region = boundingRegion() {
            cameraPosition = .region(region)
        }
    }

    private func centerOnHighlight() {
        guard let idx = highlightIndex, points.indices.contains(idx) else { return }
        let p = points[idx]
        let region = MKCoordinateRegion(
            center: p.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
        )
        cameraPosition = .region(region)
    }

    private func boundingRegion() -> MKCoordinateRegion? {
        guard !points.isEmpty else { return nil }
        var minLat = points[0].latitude
        var maxLat = points[0].latitude
        var minLon = points[0].longitude
        var maxLon = points[0].longitude
        for p in points {
            minLat = min(minLat, p.latitude); maxLat = max(maxLat, p.latitude)
            minLon = min(minLon, p.longitude); maxLon = max(maxLon, p.longitude)
        }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.002, (maxLat - minLat) * 1.4),
            longitudeDelta: max(0.002, (maxLon - minLon) * 1.4)
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}
