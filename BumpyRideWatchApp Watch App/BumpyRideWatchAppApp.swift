import SwiftUI

/// Watch app entry.  The auto-generated struct name keeps Xcode's
/// disambiguation suffix (`Watch_AppApp`) because renaming it would
/// touch the `@main` plumbing for marginal cosmetic value.
///
/// Owns the single `WatchSessionManager` instance for the app, passes
/// it down to `ContentView`.  Activation is kicked off in a `.task`
/// rather than in `init` to keep the App-conformance bootstrap fast
/// and to match the lifecycle of SwiftUI views — the session
/// activates as soon as the UI is on screen.
@main
struct BumpyRideWatchApp_Watch_AppApp: App {
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
