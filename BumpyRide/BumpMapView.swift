import SwiftUI
import MapKit

/// SwiftUI wrapper around `MKMapView` so we can attach the custom tile overlay.
/// SwiftUI's `Map` doesn't accept custom `MKTileOverlay`s, so we drop to UIKit here.
struct BumpMapView: UIViewRepresentable {
    @Bindable var bumpMap: BumpMapStore
    var settings: AppSettings

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
        // The first time real data shows up after launch, fit the camera to the data
        // bounding box.  We only do this once so the user's pan/zoom isn't fought.
        if !context.coordinator.didFitToData,
           let region = bumpMap.boundingRegion {
            context.coordinator.didFitToData = true
            map.setRegion(region, animated: true)
        }
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
        } else {
            // Default to DC metro when there's no data yet.  As soon as a rebuild
            // populates the bumpMap, `updateUIView` will fit-to-data automatically.
            let dc = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 38.9072, longitude: -77.0369),
                span: MKCoordinateSpan(latitudeDelta: 0.35, longitudeDelta: 0.35)
            )
            map.setRegion(dc, animated: false)
        }
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        weak var mapView: MKMapView?
        var overlay: BumpMapTileOverlay?
        var lastDataVersion: Int = -1
        var didFitToData: Bool = false

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
