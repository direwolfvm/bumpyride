import SwiftUI
import MapKit
import CoreLocation

/// SwiftUI map view used in the Ride tab.  Renders the route as a series of short
/// `MapPolyline` segments so each segment can be colored independently by the average
/// bumpiness of its endpoints.  Optionally pins a marker at the scrubber's current
/// position during playback.
///
/// **Two display modes**, selected by the `colorRoute` flag:
/// - `colorRoute = true` (default, bumps mode): segments are colored by the
///   bumpiness color scale.  Original behavior.
/// - `colorRoute = false` (brakes mode): segments use a neutral gray so they
///   read as "context" — the route is shown only so brake-event pins have
///   somewhere to attach.  Bumpiness data isn't relevant in this mode.
///
/// `brakeEvents`, when non-empty, are drawn as red incident pins layered on
/// top of the route segments.  Compatible with both color modes — typically
/// non-empty only when `colorRoute = false`, but no enforcement.
struct RouteMapView: View {
    var points: [RidePoint]
    var followUser: Bool
    var highlightIndex: Int?
    var settings: AppSettings
    /// Brake-event pins to render on top of the route.  Empty by default so
    /// callers that don't care about brakes don't have to pass anything.
    var brakeEvents: [BrakeEvent] = []
    /// Close-call pins to render on top of the route.  Different visual
    /// treatment from brake pins (violet diamond vs red circle) so a user
    /// who's looking at both at once can tell them apart.  Empty by default.
    var closeCalls: [CloseCall] = []
    /// `true` (default): color each segment by bumpiness of its endpoints.
    /// `false`: render the whole route in a neutral gray.
    var colorRoute: Bool = true

    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        Map(position: $cameraPosition) {
            UserAnnotation()

            ForEach(segments(), id: \.id) { seg in
                MapPolyline(coordinates: [seg.start, seg.end])
                    .stroke(seg.color, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }

            // Brake-event pins.  Rendered before the scrub highlight so the
            // highlight always sits on top (relevant when the scrubber
            // happens to land on a brake event's location).
            ForEach(brakeEvents) { event in
                Annotation("", coordinate: event.coordinate) {
                    brakeMarker
                }
            }

            // Close-call pins.  Distinct geometry + color from brake pins
            // so the two are unambiguously different when shown together.
            ForEach(closeCalls) { call in
                Annotation("", coordinate: call.coordinate) {
                    closeCallMarker
                }
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

    /// Visual: white ring + red filled disc + white exclamation glyph.
    /// Reads as a warning incident rather than a navigation waypoint.
    /// Size matches the scrub-highlight marker for visual rhythm.
    private var brakeMarker: some View {
        ZStack {
            Circle()
                .fill(.white)
                .frame(width: 20, height: 20)
            Circle()
                .fill(Color(red: 0.92, green: 0.20, blue: 0.20))
                .frame(width: 16, height: 16)
            Image(systemName: "exclamationmark")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.white)
        }
    }

    /// Visual: white-bordered violet diamond.  Geometry matches the close-
    /// call map's diamond tiles for consistency.  Different shape AND color
    /// from the brake marker so a route view showing both reads clearly.
    private var closeCallMarker: some View {
        ZStack {
            Image(systemName: "diamond.fill")
                .font(.system(size: 22))
                .foregroundStyle(.white)
            Image(systemName: "diamond.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color(red: 0.55, green: 0.25, blue: 0.85))
            Image(systemName: "exclamationmark")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.white)
        }
    }

    private struct Segment: Identifiable {
        let id = UUID()
        let start: CLLocationCoordinate2D
        let end: CLLocationCoordinate2D
        let color: Color
    }

    /// Maximum time gap between two consecutive `RidePoint`s that we'll
    /// draw a polyline segment across.  Beyond this, the route is broken
    /// visually so the user sees "missing data" rather than a misleading
    /// straight-line jump across a region we have no GPS for.
    ///
    /// Tuned at 30 s — comfortably above the normal 1–3 s between fixes,
    /// short enough to expose the multi-minute mid-ride dropouts that
    /// motivated this filter.  Two genuinely-separate brakes at the
    /// same intersection ~5–10 s apart still draw connected; only real
    /// dropouts trip the break.
    private static let maxSegmentTimeGapSeconds: TimeInterval = 30

    private func segments() -> [Segment] {
        guard points.count > 1 else { return [] }
        var out: [Segment] = []
        out.reserveCapacity(points.count - 1)
        // Pre-compute the brakes-mode neutral once instead of per-segment.
        // Slightly transparent so the basemap shows the underlying street.
        let neutralColor = Color.gray.opacity(0.75)
        for i in 1..<points.count {
            let a = points[i - 1]
            let b = points[i]
            // Skip drawing a segment when the gap between fixes is long
            // enough that the connecting line wouldn't represent the
            // rider's actual path — typically a mid-ride GPS dropout.
            // The polyline visually breaks here.
            let gap = b.timestamp.timeIntervalSince(a.timestamp)
            if gap > Self.maxSegmentTimeGapSeconds { continue }
            let color: Color
            if colorRoute {
                let avg = (a.bumpiness + b.bumpiness) / 2
                color = settings.color(for: avg)
            } else {
                color = neutralColor
            }
            out.append(Segment(start: a.coordinate, end: b.coordinate, color: color))
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
