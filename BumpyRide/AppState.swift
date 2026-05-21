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

    /// Tab the user was on when they called `open(_:)` — typically `.saved`,
    /// since that's the only surface that opens a ride today, but kept
    /// generic so future "tap a route on the Bump Map" entry points
    /// restore correctly.  `dismissLoaded()` reads + clears this; the
    /// "Start new ride" flow uses `clearLoaded()` instead so it stays on
    /// the Ride tab to begin recording.
    private var openedFromTab: Tab?

    /// Open a saved ride for playback on the Ride tab.  Remembers the
    /// current tab so `dismissLoaded()` can return there.
    func open(_ ride: Ride) {
        openedFromTab = selectedTab
        loadedRide = ride
        selectedTab = .ride
    }

    /// User tapped the X (or finished deleting) and wants to be done
    /// viewing this ride.  Clears the loaded ride AND restores the tab
    /// they came from — almost always Saved Rides.  Falls back to staying
    /// on the Ride tab if no origin was tracked.
    func dismissLoaded() {
        loadedRide = nil
        if let from = openedFromTab {
            selectedTab = from
        }
        openedFromTab = nil
    }

    /// Used by the "Start new ride" path inside the playback view.  Drops
    /// the loaded ride without changing tabs — the caller is about to
    /// start recording, so staying on the Ride tab is correct.
    func clearLoaded() {
        loadedRide = nil
        openedFromTab = nil
    }
}
