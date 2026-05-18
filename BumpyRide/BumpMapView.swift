import SwiftUI
import MapKit

/// SwiftUI wrapper around `MKMapView` so we can attach the custom tile overlay.
/// SwiftUI's `Map` doesn't accept custom `MKTileOverlay`s, so we drop to UIKit here.
struct BumpMapView: UIViewRepresentable {
    @Bindable var bumpMap: BumpMapStore
    var settings: AppSettings
    /// Single-fix location source used when the user has no ride data yet.  Lets
    /// us center on "where you are" rather than a hardcoded city.  See
    /// `BumpMapLocationHint` for the rationale on a separate CLLocationManager.
    @Bindable var locationHint: BumpMapLocationHint

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
        if context.coordinator.lastDataVersion != bumpMap.dataVersion {
            context.coordinator.lastDataVersion = bumpMap.dataVersion
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
            if let region = bumpMap.boundingRegion {
                context.coordinator.didFitToData = true
                map.setRegion(region, animated: true)
            } else if !context.coordinator.didPanToUserHint,
                      let loc = locationHint.currentLocation {
                context.coordinator.didPanToUserHint = true
                map.setRegion(Self.cityRegion(around: loc.coordinate), animated: true)
            }
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
        let overlay = BumpMapTileOverlay(grid: bumpMap.grid, settings: settings)
        context.coordinator.overlay = overlay
        map.addOverlay(overlay, level: .aboveLabels)
    }

    private func setInitialCamera(on map: MKMapView) {
        if let region = bumpMap.boundingRegion {
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
            let usa = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 39.5, longitude: -98.35),
                span: MKCoordinateSpan(latitudeDelta: 35, longitudeDelta: 60)
            )
            map.setRegion(usa, animated: false)
        }
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        weak var mapView: MKMapView?
        var overlay: BumpMapTileOverlay?
        var lastDataVersion: Int = -1
        var didFitToData: Bool = false
        /// One-shot flag that fires when we auto-pan to the user's location hint
        /// because there's no ride data yet.  Separate from `didFitToData` so
        /// the eventual "first ride saved" auto-fit still wins over the initial
        /// location-based framing.
        var didPanToUserHint: Bool = false

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
