import SwiftUI

/// Watch app entry.  The auto-generated struct name keeps Xcode's
/// disambiguation suffix (`Watch_AppApp`) because renaming it would
/// touch the `@main` plumbing for marginal cosmetic value.
///
/// Owns the long-lived state for the watch app:
///   - `WatchSessionManager` for WatchConnectivity (v1.6 Phase B+)
///   - `WatchAppDelegate` for the iOS → watch HKWorkoutConfiguration
///     handoff via `@WKApplicationDelegateAdaptor` (v1.7 Phase D)
///
/// Activation of the WC session is kicked off in a `.task` rather
/// than in `init` so the App-conformance bootstrap stays fast.
@main
struct BumpyRideWatchApp_Watch_AppApp: App {
    /// System-managed `WKApplicationDelegate` instance.  Created and
    /// retained by `@WKApplicationDelegateAdaptor` for the lifetime
    /// of the app.  Its `pendingWorkoutConfiguration` is the only
    /// way the v1.7 iOS-triggered workout handoff reaches our code.
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate

    @State private var session = WatchSessionManager()

    /// HKWorkoutSession owner for the v1.7 watch HealthKit handoff.
    /// Starts a session when `appDelegate.pendingWorkoutConfiguration`
    /// is set (handled by the `.onChange` below).  Phase F will wire
    /// its `stop()` to the iPhone's ride-stop signal.
    @State private var workoutManager = WatchWorkoutManager()

    var body: some Scene {
        WindowGroup {
            ContentView(session: session)
                .task {
                    session.activate()
                }
                .onChange(of: appDelegate.pendingWorkoutConfiguration) { _, config in
                    // v1.7 Phase E: receive the workout configuration
                    // from the delegate and spin up the HKWorkoutSession.
                    // Clear the delegate's stash after consumption so a
                    // subsequent startWatchApp from iOS is treated as a
                    // fresh event rather than a state-comparison no-op.
                    guard let config else { return }
                    workoutManager.start(with: config)
                    appDelegate.pendingWorkoutConfiguration = nil
                }
        }
    }
}
