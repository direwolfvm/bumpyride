import SwiftUI
import MapKit
import CoreLocation
#if canImport(WeatherKit)
import WeatherKit
#endif

/// SwiftUI map view used in the Ride tab.  Renders the route as colored
/// polylines, each segment colored by the **max** bumpiness of its two
/// endpoints (peak-preserving — averaging washed isolated jolts down into
/// the lower bands).  Contiguous same-band segments are coalesced into a
/// single multi-point polyline for performance.  Optionally pins a marker
/// at the scrubber's current position during playback.
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
    /// v1.7: latest fetched current weather, or nil if no fetch has
    /// landed yet.  When non-nil, the `WeatherChip` overlay renders
    /// in the map's top-trailing corner.  Live-recording callers
    /// pass `weatherCoordinator.current`; playback callers pass
    /// nil (weather isn't displayed in playback in v1.7).
    #if canImport(WeatherKit)
    var weather: CurrentWeather? = nil
    #endif
    /// v1.7: bike's compass heading in degrees, or nil if not
    /// reliable.  Forwarded to `WeatherChip` for the headwind /
    /// tailwind / crosswind label and the relative arrow rotation.
    /// Live callers gate on `CLLocation.speed >= 3 m/s` because
    /// `CLLocation.course` is unreliable below that.
    var bikeHeading: Double? = nil

    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        Map(position: $cameraPosition) {
            UserAnnotation()

            ForEach(colorRuns()) { run in
                MapPolyline(coordinates: run.coordinates)
                    .stroke(run.color, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
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
        .overlay(alignment: .topTrailing) {
            #if canImport(WeatherKit)
            if let weather {
                WeatherChip(weather: weather, bikeHeading: bikeHeading)
                    .padding(8)
            }
            #endif
        }
        .overlay(alignment: .bottomTrailing) {
            recenterButton
                .padding(12)
        }
        .onAppear { updateCamera(initial: true) }
        .onChange(of: points.count) { _, _ in updateCamera(initial: false) }
        .onChange(of: highlightIndex) { _, _ in centerOnHighlight() }
    }

    /// Floating recenter control.  Context-aware:
    /// - **Live recording** (`followUser`): re-arms user-location
    ///   tracking, snapping back to where the rider is now after they've
    ///   panned around the map.  Icon: `location.fill`.
    /// - **Playback** (`!followUser`): refits the whole route's bounding
    ///   box — the saved-ride analog of "show everything."  Icon:
    ///   `arrow.up.left.and.arrow.down.right`.
    ///
    /// Sits bottom-trailing so it clears the top-trailing weather chip
    /// and the system compass/scale controls.
    private var recenterButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.4)) { recenter() }
        } label: {
            Image(systemName: followUser ? "location.fill" : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.black.opacity(0.12)))
        }
        .accessibilityLabel(followUser ? "Recenter on my location" : "Fit route")
    }

    /// Apply the recenter action for the current context.  See
    /// `recenterButton` for the live-vs-playback split.
    private func recenter() {
        if followUser {
            cameraPosition = .userLocation(fallback: .automatic)
        } else if let region = boundingRegion() {
            cameraPosition = .region(region)
        }
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

    /// A contiguous run of route points that all fall in the same
    /// bumpiness color band, drawn as a single multi-point polyline.
    ///
    /// `id` is the index of the run's first point — **stable across
    /// renders** so SwiftUI/MapKit can diff incrementally.  During
    /// live recording, every run except the last keeps the same id +
    /// coordinates + color tick-to-tick, so MapKit leaves those
    /// overlays untouched and only updates the growing tail run (or
    /// appends one new run when the band changes).  This is the fix
    /// for the old per-segment approach, which minted a fresh UUID
    /// per render and forced a full teardown/rebuild of every overlay
    /// every frame.
    private struct ColorRun: Identifiable {
        let id: Int
        let coordinates: [CLLocationCoordinate2D]
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

    /// Build the route as a small set of multi-point polylines —
    /// one per contiguous run of same-color-band points (bumps mode)
    /// or one per gap-free stretch (brakes mode).
    ///
    /// Why coalesce: drawing one `MapPolyline` per point-pair means
    /// ~2,000 overlays on a 4-mile ride, and MapKit redraws every
    /// visible overlay each frame on pan/zoom/camera-follow — the
    /// route was the dominant cost in the live display and it scaled
    /// with ride length.  Merging adjacent same-band segments drops
    /// the overlay count to a few dozen.  In brakes mode (single
    /// neutral color) it collapses to one polyline per dropout-free
    /// stretch.
    ///
    /// Adjacent runs share their boundary vertex (the new run starts
    /// at the same point the previous run ended), so the banded route
    /// is visually continuous — no seams at color transitions.  A
    /// time gap > `maxSegmentTimeGapSeconds` ends the current run and
    /// the next point starts a fresh one, preserving the dropout
    /// break behavior.
    private func colorRuns() -> [ColorRun] {
        guard points.count > 1 else { return [] }
        let neutralColor = Color.gray.opacity(0.75)
        var runs: [ColorRun] = []

        var startIdx: Int? = nil
        var coords: [CLLocationCoordinate2D] = []
        var curBand: Int = 0

        func flush() {
            if let s = startIdx, coords.count >= 2 {
                let color = colorRoute ? settings.bandColor(curBand) : neutralColor
                runs.append(ColorRun(id: s, coordinates: coords, color: color))
            }
            startIdx = nil
            coords = []
        }

        for k in 0..<(points.count - 1) {
            let a = points[k]
            let b = points[k + 1]
            // Long gap = GPS dropout; break the polyline rather than
            // draw a misleading straight line across unmapped terrain.
            let gap = b.timestamp.timeIntervalSince(a.timestamp)
            if gap > Self.maxSegmentTimeGapSeconds {
                flush()
                continue
            }
            // In brakes mode every segment is band 0 (neutral), so the
            // whole gap-free stretch coalesces into one run.
            //
            // Color by the MAX bumpiness of the segment's two endpoints,
            // not the average.  Averaging halved every isolated jolt —
            // a single 2.0 g pothole between two smooth 0.3 g points read
            // as 1.15 g (orange) instead of 2.0 g (purple), and most of
            // the route collapsed into green/yellow.  Max preserves the
            // peak so a rough spot actually shows its true band; the cost
            // is that a run is only as smooth as its roughest endpoint,
            // which is the right bias for a map whose whole purpose is
            // surfacing rough pavement.
            let band = colorRoute ? settings.colorBand(for: max(a.bumpiness, b.bumpiness)) : 0
            if startIdx == nil {
                startIdx = k
                coords = [a.coordinate, b.coordinate]
                curBand = band
            } else if band == curBand {
                coords.append(b.coordinate)
            } else {
                // Band change: close the current run (ending at `a`),
                // start a new one beginning at `a` so the two polylines
                // share the boundary vertex and read as continuous.
                flush()
                startIdx = k
                coords = [a.coordinate, b.coordinate]
                curBand = band
            }
        }
        flush()
        return runs
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
