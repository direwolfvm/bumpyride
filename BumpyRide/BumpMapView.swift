import SwiftUI
import MapKit

/// SwiftUI wrapper around `MKMapView` so we can attach the custom tile overlay.
/// SwiftUI's `Map` doesn't accept custom `MKTileOverlay`s, so we drop to UIKit here.
///
/// Renders one of three overlays depending on `mode`:
/// - `.bumps` → `BumpMapTileOverlay` against `bumpMap`
/// - `.brakes` → `BrakeMapTileOverlay` against `brakeMap`
/// - `.closeCalls` → `CloseCallMapTileOverlay` against `closeCallMap`
///
/// Mode switches preserve camera state (zoom/pan).  All three stores
/// rebuild upstream on data/filter changes; this view just picks which to
/// render.
struct BumpMapView: UIViewRepresentable {
    @Bindable var bumpMap: BumpMapStore
    @Bindable var brakeMap: BrakeMapStore
    @Bindable var closeCallMap: CloseCallMapStore
    var settings: AppSettings
    var mode: MapViewMode
    /// Single-fix location source used when the user has no ride data yet.  Lets
    /// us center on "where you are" rather than a hardcoded city.  See
    /// `BumpMapLocationHint` for the rationale on a separate CLLocationManager.
    @Bindable var locationHint: BumpMapLocationHint

    /// Monotonically-incrementing recenter request from the parent's
    /// floating recenter button.  When this changes, `updateUIView`
    /// re-frames the map to the full-data region (the same "initial
    /// view of everything" the map opens with).  An Int counter rather
    /// than a Bool so repeated taps each register as a distinct change.
    var recenterTrigger: Int = 0

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
        rebuildOverlay(on: map, context: context)
        setInitialCamera(on: map)

        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        // Four triggers for rebuilding the overlay:
        // 1. Mode changed (Bumps ↔ Brakes ↔ CloseCalls) — different
        //    overlay class entirely, so we have to swap.
        // 2-4. Currently in one mode and the matching store's data
        //      version changed.
        //
        // Each comparison is gated separately so we don't churn tiles
        // on every SwiftUI redraw.
        let coord = context.coordinator
        let needsRebuild = coord.currentMode != mode
            || (mode == .bumps && coord.lastBumpDataVersion != bumpMap.dataVersion)
            || (mode == .brakes && coord.lastBrakeDataVersion != brakeMap.dataVersion)
            || (mode == .closeCalls && coord.lastCloseCallDataVersion != closeCallMap.dataVersion)
        if needsRebuild {
            rebuildOverlay(on: map, context: context)
        }
        // Camera auto-framing has two one-shot triggers, in priority order:
        //
        // 1. Data arrives → fit to the data bounding box.  This is the strongest
        //    signal; once it fires we never auto-frame again because the user's
        //    pan/zoom shouldn't be fought after they've started interacting.
        //
        // 2. No data yet, but a location hint just landed → pan to the user with
        //    a city-sized span.  Fires at most once, *and* only while we haven't
        //    yet fit-to-data.  When data eventually arrives, branch 1 takes
        //    over (with `didFitToData` still false at that point) and overrides
        //    this initial location-pan.
        if !context.coordinator.didFitToData {
            if let region = dataRegion(for: map) {
                context.coordinator.didFitToData = true
                map.setRegion(region, animated: true)
            } else if !context.coordinator.didPanToUserHint,
                      let loc = locationHint.currentLocation {
                context.coordinator.didPanToUserHint = true
                map.setRegion(Self.cityRegion(around: loc.coordinate), animated: true)
            }
        }

        // Explicit recenter request from the parent's floating button.
        // Overrides the one-shot auto-frame guards above — the user is
        // deliberately asking to return to the full-data view after
        // panning/zooming around.  Reframes to the same region the map
        // opened with (all data → user-hint city → contiguous US).
        if recenterTrigger != context.coordinator.lastRecenterTrigger {
            context.coordinator.lastRecenterTrigger = recenterTrigger
            map.setRegion(recenterRegion(for: map), animated: true)
        }
    }

    /// The "show everything" region used by the recenter button —
    /// mirrors `setInitialCamera`'s priority: full-data bounding box
    /// first, then the user's location hint at city zoom, then the
    /// contiguous-US fallback.
    private func recenterRegion(for map: MKMapView) -> MKCoordinateRegion {
        if let region = dataRegion(for: map) {
            return region
        } else if let loc = locationHint.currentLocation {
            return Self.cityRegion(around: loc.coordinate)
        } else {
            return Self.usaRegion
        }
    }

    /// City-sized framing — ~7 mi across.  Tuned to feel like "I just opened
    /// Apple Maps to my city" rather than "zoomed in on my block" or "showing
    /// the whole state."
    private static func cityRegion(around center: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
        )
    }

    private func rebuildOverlay(on map: MKMapView, context: Context) {
        if let old = context.coordinator.overlay {
            map.removeOverlay(old)
        }
        let overlay: MKTileOverlay
        switch mode {
        case .bumps:
            overlay = BumpMapTileOverlay(grid: bumpMap.grid, settings: settings)
            context.coordinator.lastBumpDataVersion = bumpMap.dataVersion
        case .brakes:
            overlay = BrakeMapTileOverlay(grid: brakeMap.grid)
            context.coordinator.lastBrakeDataVersion = brakeMap.dataVersion
        case .closeCalls:
            overlay = CloseCallMapTileOverlay(grid: closeCallMap.grid)
            context.coordinator.lastCloseCallDataVersion = closeCallMap.dataVersion
        }
        context.coordinator.overlay = overlay
        context.coordinator.currentMode = mode
        map.addOverlay(overlay, level: .aboveLabels)
    }

    /// The overlay skips tiles below `BumpMapTileOverlay.minimumZ`, so a
    /// region wider than roughly 0.27° of longitude on a phone opens on an
    /// empty map — which is exactly what happened once the rider's data
    /// spanned more than one town.  Two defences: frame the *focus* region
    /// (where the data mass is, outliers trimmed) rather than the full
    /// extent, and clamp the span so the camera can never land below the
    /// overlay's minimum zoom.  A genuinely wide focus region then opens
    /// centred on the densest data at the shallowest zoom that still
    /// renders, and the user pans from there.
    private static let minOpeningZoom: Double = 11.3

    private func dataRegion(for map: MKMapView) -> MKCoordinateRegion? {
        guard let region = bumpMap.focusRegion ?? bumpMap.boundingRegion else { return nil }
        let size = map.bounds.size
        let w = size.width > 0 ? size.width : UIScreen.main.bounds.width
        let h = size.height > 0 ? size.height : UIScreen.main.bounds.height * 0.7
        // Region → map-point rect, zoom from whichever axis is tighter.
        let nw = MKMapPoint(CLLocationCoordinate2D(latitude: region.center.latitude + region.span.latitudeDelta / 2,
                                                   longitude: region.center.longitude - region.span.longitudeDelta / 2))
        let se = MKMapPoint(CLLocationCoordinate2D(latitude: region.center.latitude - region.span.latitudeDelta / 2,
                                                   longitude: region.center.longitude + region.span.longitudeDelta / 2))
        let rect = MKMapRect(x: nw.x, y: nw.y, width: se.x - nw.x, height: se.y - nw.y)
        guard rect.width > 0, rect.height > 0 else { return region }
        let zx = log2(MKMapSize.world.width / rect.width * (w / 256))
        let zy = log2(MKMapSize.world.height / rect.height * (h / 256))
        let z = min(zx, zy)
        guard z < Self.minOpeningZoom else { return region }
        let k = pow(2.0, z - Self.minOpeningZoom)          // < 1: shrink
        let shrunk = MKMapRect(x: rect.midX - rect.width * k / 2, y: rect.midY - rect.height * k / 2,
                               width: rect.width * k, height: rect.height * k)
        return MKCoordinateRegion(shrunk)
    }

    private func setInitialCamera(on map: MKMapView) {
        if let region = dataRegion(for: map) {
            map.setRegion(region, animated: false)
        } else if let loc = locationHint.currentLocation {
            // The hint already has a fix — most likely path for a returning
            // user who's previously granted location.  Center on them.
            map.setRegion(Self.cityRegion(around: loc.coordinate), animated: false)
        } else {
            // No data, no location hint.  Frame the contiguous US — wide enough
            // that no single user feels like the app is pointing at someone
            // else's city, narrow enough that they can recognize the rough
            // shape.  When the hint lands (either automatically because we're
            // already authorized, or because the user taps "Use my location"
            // in the empty state), updateUIView pans to them.
            map.setRegion(Self.usaRegion, animated: false)
        }
    }

    /// Contiguous-US framing — the final fallback when there's neither
    /// ride data nor a location fix to center on.
    private static let usaRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 39.5, longitude: -98.35),
        span: MKCoordinateSpan(latitudeDelta: 35, longitudeDelta: 60)
    )

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        weak var mapView: MKMapView?
        /// Currently-installed overlay — either a `BumpMapTileOverlay` or a
        /// `BrakeMapTileOverlay`.  Held as the protocol-erased base class so
        /// the dispatcher and the remove() path don't have to switch on type.
        var overlay: MKTileOverlay?
        /// Which mode the currently-installed overlay represents.  `nil`
        /// before the first `rebuildOverlay` call.
        var currentMode: MapViewMode?
        /// Last bumpMap.dataVersion we rendered.  Compared against the
        /// store's current version to decide whether a rebuild is needed
        /// while in `.bumps` mode.  Symmetric with siblings.
        var lastBumpDataVersion: Int = -1
        var lastBrakeDataVersion: Int = -1
        var lastCloseCallDataVersion: Int = -1
        var didFitToData: Bool = false
        /// One-shot flag that fires when we auto-pan to the user's location hint
        /// because there's no ride data yet.  Separate from `didFitToData` so
        /// the eventual "first ride saved" auto-fit still wins over the initial
        /// location-based framing.
        var didPanToUserHint: Bool = false
        /// Last recenter-trigger value we acted on.  Compared against the
        /// parent's `recenterTrigger` so a change (button tap) fires exactly
        /// one reframe.  Starts at 0 to match the parent's initial value —
        /// no spurious recenter on first render.
        var lastRecenterTrigger: Int = 0

        nonisolated func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: tile)
                renderer.alpha = 1.0
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
