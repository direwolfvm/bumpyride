import Foundation
import Observation

/// Lightweight cross-tab UI state: which tab is selected and which saved ride is
/// currently loaded into the Ride tab for playback.  Lets the Saved Rides tab open
/// a ride into the Ride tab without having to push a navigation destination.
@Observable
final class AppState {
    enum Tab: Int, Hashable { case ride = 0, saved = 1, bumpMap = 2, settings = 3 }

    var selectedTab: Tab = .ride
    var loadedRide: Ride?

    func open(_ ride: Ride) {
        loadedRide = ride
        selectedTab = .ride
    }

    func clearLoaded() {
        loadedRide = nil
    }
}
