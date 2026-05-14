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

    /// Set by `ContentView.task` on cold launch when `RideJournal.loadRecoverable()`
    /// returns a non-empty in-progress recording from a prior session that ended
    /// abruptly (force-quit, OS kill, crash).  `RideView` watches this and shows
    /// a one-time recovery alert; on Recover, the value flows into the save sheet
    /// the same way a freshly-stopped ride does.  Cleared once the user resolves
    /// the prompt either way.
    var recoveredRide: Ride?

    func open(_ ride: Ride) {
        loadedRide = ride
        selectedTab = .ride
    }

    func clearLoaded() {
        loadedRide = nil
    }
}
