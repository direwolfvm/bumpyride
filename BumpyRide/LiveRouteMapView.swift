import SwiftUI
import MapKit

/// `MKMapView`-backed map used during **live recording** only.  Saved-ride
/// playback stays on the SwiftUI `RouteMapView`; this exists because the two
/// recording-screen features the user asked for are exactly the things
/// SwiftUI's `Map` can't do:
///
///   1. A translucent **visited-cells** tile overlay (`VisitedCellsTileOverlay`)
///      — SwiftUI `Map` rejects custom `MKTileOverlay`s.
///   2. **Heading-up** orientation — `MKMapView.userTrackingMode =
///      .followWithHeading`, which SwiftUI `Map` doesn't expose cleanly.
///
/// The route itself is drawn with the same banding the playback map uses
/// (`RouteColoring`), so the two surfaces stay visually consistent.
struct LiveRouteMapView: UIViewRepresentable {
    var points: [RidePoint]
    var brakeEvents: [BrakeEvent]
    var closeCalls: [CloseCall]
    var settings: AppSettings
    /// Lifetime visited-cells grid (`BumpMapStore.grid`) — every cell the
    /// rider has data in.  Only rendered when `showVisitedCells` is on.
    var visitedGrid: BumpGrid
    /// `BumpMapStore.dataVersion`, so we rebuild the overlay when the grid
    /// changes (e.g. a ride just saved mid-session).
    var visitedVersion: Int
    var showVisitedCells: Bool
    /// `false` → north-up; `true` → map rotates so the rider's heading is up.
    var headingUp: Bool
    /// Monotonic counter; each increment re-arms user-location tracking
    /// (snap back after the rider panned the map away).
    var recenterTrigger: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        let config = MKStandardMapConfiguration(emphasisStyle: .muted)
        config.pointOfInterestFilter = .excludingAll
        map.preferredConfiguration = config
        map.showsUserLocation = true
        map.showsCompass = true
        map.showsScale = true
        context.coordinator.mapView = map
        // Follow the rider from the start; orientation per the toggle.
        map.setUserTrackingMode(headingUp ? .followWithHeading : .follow, animated: false)
        context.coordinator.headingUp = headingUp
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let c = context.coordinator

        // --- Route polylines: rebuild only when the point buffer changed.
        // The live buffer is a trailing window (bounded), and banding
        // collapses it to a handful of runs, so a full rebuild here is a
        // few dozen overlays — cheap, and far below the old per-pair count.
        if points.count != c.lastPointCount {
            c.lastPointCount = points.count
            map.removeOverlays(c.routeOverlays)
            c.routeOverlays.removeAll(keepingCapacity: true)
            c.runColors.removeAll(keepingCapacity: true)
            for run in RouteColoring.runs(points: points, settings: settings, colorRoute: true) {
                let poly = MKPolyline(coordinates: run.coordinates, count: run.coordinates.count)
                c.runColors[ObjectIdentifier(poly)] = run.bandIndex < 0
                    ? UIColor.gray.withAlphaComponent(0.75)
                    : settings.bandUIColor(run.bandIndex)
                c.routeOverlays.append(poly)
                // .aboveLabels so the route sits on top of the visited-cell
                // tiles (added at .aboveRoads below).
                map.addOverlay(poly, level: .aboveLabels)
            }
        }

        // --- Visited-cells overlay: toggle on/off, rebuild on grid change.
        if showVisitedCells != c.showVisited
            || (showVisitedCells && visitedVersion != c.lastVisitedVersion) {
            if let old = c.visitedOverlay {
                map.removeOverlay(old)
                c.visitedOverlay = nil
            }
            if showVisitedCells {
                let ov = VisitedCellsTileOverlay(grid: visitedGrid)
                c.visitedOverlay = ov
                c.lastVisitedVersion = visitedVersion
                map.addOverlay(ov, level: .aboveRoads)
            }
            c.showVisited = showVisitedCells
        }

        // --- Brake / close-call markers: rebuild on count change.
        if brakeEvents.count != c.lastBrakeCount {
            c.lastBrakeCount = brakeEvents.count
            map.removeAnnotations(c.brakeAnnos)
            c.brakeAnnos = brakeEvents.map { BrakeAnnotation($0.coordinate) }
            map.addAnnotations(c.brakeAnnos)
        }
        if closeCalls.count != c.lastCloseCallCount {
            c.lastCloseCallCount = closeCalls.count
            map.removeAnnotations(c.closeCallAnnos)
            c.closeCallAnnos = closeCalls.map { CloseCallAnnotation($0.coordinate) }
            map.addAnnotations(c.closeCallAnnos)
        }

        // --- Orientation toggle.
        if headingUp != c.headingUp {
            c.headingUp = headingUp
            map.setUserTrackingMode(headingUp ? .followWithHeading : .follow, animated: true)
        }

        // --- Recenter: re-arm tracking (the rider panned away and tapped
        // the button to snap back to "follow me" in the current orientation).
        if recenterTrigger != c.lastRecenterTrigger {
            c.lastRecenterTrigger = recenterTrigger
            map.setUserTrackingMode(headingUp ? .followWithHeading : .follow, animated: true)
        }
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        weak var mapView: MKMapView?

        var routeOverlays: [MKPolyline] = []
        /// Stroke color per route polyline, keyed by identity — looked up
        /// in `rendererFor`.  Avoids the MKPolyline-subclassing gotcha.
        var runColors: [ObjectIdentifier: UIColor] = [:]
        var lastPointCount: Int = -1

        var visitedOverlay: VisitedCellsTileOverlay?
        var showVisited: Bool = false
        var lastVisitedVersion: Int = -1

        var brakeAnnos: [BrakeAnnotation] = []
        var closeCallAnnos: [CloseCallAnnotation] = []
        var lastBrakeCount: Int = -1
        var lastCloseCallCount: Int = -1

        var headingUp: Bool = false
        var lastRecenterTrigger: Int = 0

        // MKMapViewDelegate callbacks arrive on the main thread; `nonisolated`
        // satisfies the protocol's Sendable shape and we hop back via
        // assumeIsolated to touch coordinator state.
        nonisolated func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            MainActor.assumeIsolated {
                if let tile = overlay as? MKTileOverlay {
                    return MKTileOverlayRenderer(tileOverlay: tile)
                }
                if let poly = overlay as? MKPolyline {
                    let r = MKPolylineRenderer(polyline: poly)
                    r.strokeColor = runColors[ObjectIdentifier(poly)] ?? .gray
                    r.lineWidth = 6
                    r.lineCap = .round
                    r.lineJoin = .round
                    return r
                }
                return MKOverlayRenderer(overlay: overlay)
            }
        }

        nonisolated func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            MainActor.assumeIsolated {
                if annotation is MKUserLocation { return nil }
                if annotation is BrakeAnnotation {
                    let v = mapView.dequeueReusableAnnotationView(withIdentifier: "brake") as? MKMarkerAnnotationView
                        ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "brake")
                    v.annotation = annotation
                    v.markerTintColor = UIColor(red: 0.92, green: 0.20, blue: 0.20, alpha: 1)
                    v.glyphImage = UIImage(systemName: "exclamationmark")
                    v.displayPriority = .required
                    return v
                }
                if annotation is CloseCallAnnotation {
                    let v = mapView.dequeueReusableAnnotationView(withIdentifier: "closecall") as? MKMarkerAnnotationView
                        ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "closecall")
                    v.annotation = annotation
                    v.markerTintColor = UIColor(red: 0.55, green: 0.25, blue: 0.85, alpha: 1)
                    v.glyphImage = UIImage(systemName: "exclamationmark.triangle.fill")
                    v.displayPriority = .required
                    return v
                }
                return nil
            }
        }
    }
}

/// Live hard-brake marker annotation.
final class BrakeAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    init(_ coordinate: CLLocationCoordinate2D) { self.coordinate = coordinate }
}

/// Live close-call marker annotation.
final class CloseCallAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    init(_ coordinate: CLLocationCoordinate2D) { self.coordinate = coordinate }
}
