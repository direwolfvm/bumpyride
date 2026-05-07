import Foundation
import Observation

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
