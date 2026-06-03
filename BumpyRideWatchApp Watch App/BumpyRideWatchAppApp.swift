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

    var body: some Scene {
        WindowGroup {
            ContentView(session: session)
                .task {
                    session.activate()
                }
        }
    }
}
