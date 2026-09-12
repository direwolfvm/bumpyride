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
    /// v1.8 L7: alpha for the visited-cells overlay
    /// (`AppSettings.visitedCellsOpacity`).  A change swaps in a fresh
    /// overlay — MKTileOverlay tiles are rendered once and cached, so
    /// opacity can't be mutated in place.
    var visitedOpacity: Double
    /// `false` → north-up; `true` → map rotates so the rider's heading is up.
    var headingUp: Bool
    /// Heading-up tracking spins up the compass and asks MapKit for a more
    /// precise fix; it is only meaningful while actually riding. Outside a
    /// recording the map follows north-up even when the toggle is on.
    var headingTrackingAllowed: Bool = true
    /// Monotonic counter; each increment re-arms user-location tracking
    /// (snap back after the rider panned the map away).  When the ride is
    /// over it refits the route instead.
    var recenterTrigger: Int
    /// `true` once the ride has ended (`.finished`) — done, but not yet saved
    /// or discarded.  The map stops following, hides the location dot and fits
    /// the whole route, the same view saved-ride playback opens on.
    ///
    /// This also takes MapKit's own location manager out of the picture for
    /// the whole post-ride stretch — the save sheet, the summary, whatever
    /// browsing follows. `showsUserLocation` plus a follow `userTrackingMode`
    /// runs a second CLLocationManager independent of ours, and MetricKit
    /// recorded it asking for navigation-grade accuracy (40 min on 8 Sep) on
    /// days our own manager never left `kCLLocationAccuracyBest`.
    ///
    /// Deliberately *not* extended to `.idle`: before a ride the rider still
    /// wants a map centred on where they are, and suppressing the dot there
    /// left it framing the whole continent. Idle instead drops to plain
    /// `.follow` via `headingTrackingAllowed`, which keeps the map useful
    /// while avoiding the heading-up mode's extra sensor work.
    var rideIsOver: Bool = false

    /// K24: compact hard-brake marker — a small red dot with a thin
    /// white ring (~12 pt), deliberately smaller than the default
    /// MKMarkerAnnotationView teardrop.  Rendered once and reused for
    /// every brake annotation.
    static let brakeMarkerImage: UIImage = {
        let d: CGFloat = 12
        return UIGraphicsImageRenderer(size: CGSize(width: d, height: d)).image { ctx in
            let c = ctx.cgContext
            let rect = CGRect(x: 1.25, y: 1.25, width: d - 2.5, height: d - 2.5)
            c.setFillColor(UIColor(red: 0.92, green: 0.20, blue: 0.20, alpha: 1).cgColor)
            c.fillEllipse(in: rect)
            c.setLineWidth(1.5)
            c.setStrokeColor(UIColor.white.cgColor)
            c.strokeEllipse(in: rect)
        }
    }()

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        let config = MKStandardMapConfiguration(emphasisStyle: .muted)
        config.pointOfInterestFilter = .excludingAll
        map.preferredConfiguration = config
        map.showsCompass = true
        map.showsScale = true
        context.coordinator.mapView = map
        // Follow the rider only while recording; otherwise no dot and no
        // tracking, so MapKit's own location manager never starts.
        map.showsUserLocation = !rideIsOver
        if !rideIsOver {
            map.setUserTrackingMode(effectiveTrackingMode, animated: false)
        }
        context.coordinator.headingUp = headingUp
        context.coordinator.rideIsOver = rideIsOver
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let c = context.coordinator

        // --- Route polylines: extend, don't rebuild.
        //
        // This used to tear down every route overlay and recompute the colour
        // runs across the *whole* points array on each new GPS fix. The work
        // per fix grew with the route, so the total was quadratic in ride
        // length: the 3.17 h / 43 km ride on 12 Sep pushed ~20 million
        // polyline vertices at MapKit over its lifetime, and MetricKit
        // measured GPU time at 2.5x foreground wall time with the phone
        // reaching thermal=serious on much shorter rides.
        //
        // Points only ever append while recording, so every run except the
        // last is already final. Recomputing from the last run's start index
        // and swapping just that one overlay makes the per-fix cost constant
        // — bounded by RouteColoring.maxRunPoints — instead of O(route).
        //
        // The timestamp is compared as well as the count because a fix that
        // lands without growing the buffer still moves the route forward.
        let lastTimestamp = points.last?.timestamp
        if points.count != c.lastPointCount || lastTimestamp != c.lastPointTimestamp {
            let previousCount = c.lastPointCount
            c.lastPointCount = points.count
            c.lastPointTimestamp = lastTimestamp

            // A shrinking buffer means a new ride (or a discard), so nothing
            // already on the map can be reused.
            let fullRebuild = c.routeOverlays.isEmpty || points.count < previousCount
            let from = fullRebuild ? 0 : c.lastRunStartIndex
            let rebuilt = RouteColoring.runs(
                points: points, settings: settings, colorRoute: true, from: from)

            if fullRebuild {
                map.removeOverlays(c.routeOverlays)
                c.routeOverlays.removeAll(keepingCapacity: true)
                c.runColors.removeAll(keepingCapacity: true)
            } else if !rebuilt.isEmpty, let stale = c.routeOverlays.last {
                // Only the last run can have changed; drop just that one.
                map.removeOverlay(stale)
                c.runColors.removeValue(forKey: ObjectIdentifier(stale))
                c.routeOverlays.removeLast()
            }

            for run in rebuilt {
                let poly = MKPolyline(coordinates: run.coordinates, count: run.coordinates.count)
                c.runColors[ObjectIdentifier(poly)] = run.bandIndex < 0
                    ? UIColor.gray.withAlphaComponent(0.75)
                    : settings.bandUIColor(run.bandIndex)
                c.routeOverlays.append(poly)
                // .aboveLabels so the route sits on top of the visited-cell
                // tiles (added at .aboveRoads below).
                map.addOverlay(poly, level: .aboveLabels)
            }
            if let tailStart = rebuilt.last?.startIndex {
                c.lastRunStartIndex = tailStart
            } else if fullRebuild {
                c.lastRunStartIndex = 0
            }
        }

        // --- Visited-cells overlay: toggle on/off, rebuild on grid or
        // opacity change (L7 — opacity is baked into the rendered
        // tiles, so a slider change means a fresh overlay).
        if showVisitedCells != c.showVisited
            || (showVisitedCells && (visitedVersion != c.lastVisitedVersion
                                     || visitedOpacity != c.lastVisitedOpacity)) {
            if let old = c.visitedOverlay {
                map.removeOverlay(old)
                c.visitedOverlay = nil
            }
            if showVisitedCells {
                let ov = VisitedCellsTileOverlay(grid: visitedGrid, opacity: visitedOpacity)
                c.visitedOverlay = ov
                c.lastVisitedVersion = visitedVersion
                c.lastVisitedOpacity = visitedOpacity
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

        // --- Ride over ↔ live.  Entering "over": stop following, hide the
        // dot, fit the route.  Leaving it (a new ride started): put the dot
        // back and follow again.
        if rideIsOver != c.rideIsOver {
            c.rideIsOver = rideIsOver
            if rideIsOver {
                map.setUserTrackingMode(.none, animated: false)
                map.showsUserLocation = false
                fitRoute(on: map, context: context)
            } else {
                map.showsUserLocation = true
                map.setUserTrackingMode(effectiveTrackingMode, animated: false)
            }
        }

        // --- Orientation toggle (live only; a finished ride stays north-up
        // and fitted).
        if headingUp != c.headingUp || headingTrackingAllowed != c.headingTrackingAllowed {
            c.headingUp = headingUp
            c.headingTrackingAllowed = headingTrackingAllowed
            if !rideIsOver {
                map.setUserTrackingMode(effectiveTrackingMode, animated: true)
            }
        }

        // --- Recenter: live → re-arm tracking (the rider panned away and
        // tapped to snap back to "follow me" in the current orientation);
        // over → refit the whole route.
        if recenterTrigger != c.lastRecenterTrigger {
            c.lastRecenterTrigger = recenterTrigger
            if rideIsOver {
                fitRoute(on: map, context: context)
            } else {
                map.setUserTrackingMode(effectiveTrackingMode, animated: true)
            }
        }
    }

    /// Heading-up only while it is allowed; otherwise plain follow.
    private var effectiveTrackingMode: MKUserTrackingMode {
        (headingUp && headingTrackingAllowed) ? .followWithHeading : .follow
    }

    /// Frame every route polyline with a little breathing room.  No-op for
    /// an empty route (Stop tapped before any fix).
    private func fitRoute(on map: MKMapView, context: Context) {
        let overlays = context.coordinator.routeOverlays
        // Nothing to fit before the first ride of the session — leave the
        // camera wherever MapKit put it rather than snapping to null island.
        guard var rect = overlays.first?.boundingMapRect else { return }
        for o in overlays.dropFirst() { rect = rect.union(o.boundingMapRect) }
        map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 44, left: 32, bottom: 44, right: 32), animated: true)
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        weak var mapView: MKMapView?

        var routeOverlays: [MKPolyline] = []
        /// Stroke color per route polyline, keyed by identity — looked up
        /// in `rendererFor`.  Avoids the MKPolyline-subclassing gotcha.
        var runColors: [ObjectIdentifier: UIColor] = [:]
        var lastPointCount: Int = -1
        /// Points index where the last built run begins.  Everything before it
        /// is final, so an incremental update recomputes only from here.
        var lastRunStartIndex: Int = 0
        /// Newest point's timestamp at the last route rebuild.  Advances on
        /// every GPS fix even after the trailing-window cap freezes
        /// `lastPointCount` at 1000 — the rebuild trigger that the count
        /// alone misses past ~5 miles.
        var lastPointTimestamp: Date?

        var visitedOverlay: VisitedCellsTileOverlay?
        var showVisited: Bool = false
        var lastVisitedVersion: Int = -1
        var lastVisitedOpacity: Double = -1

        var brakeAnnos: [BrakeAnnotation] = []
        var closeCallAnnos: [CloseCallAnnotation] = []
        var lastBrakeCount: Int = -1
        var lastCloseCallCount: Int = -1

        var headingUp: Bool = false
        var headingTrackingAllowed: Bool = true
        var lastRecenterTrigger: Int = 0
        var rideIsOver: Bool = false

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
                    // K24: small red dot instead of the full
                    // MKMarkerAnnotationView teardrop.  Hard brakes are
                    // auto-detected and frequent, so a compact marker
                    // keeps a brake-heavy ride from cluttering the map.
                    // (Close calls, which the rider logs deliberately,
                    // keep the prominent marker below.)
                    let v = mapView.dequeueReusableAnnotationView(withIdentifier: "brake")
                        ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "brake")
                    v.annotation = annotation
                    v.image = LiveRouteMapView.brakeMarkerImage
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
