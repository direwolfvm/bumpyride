import SwiftUI

/// Root view: a `TabView` hosting Ride, Saved, Bump Map, and Settings tabs.  Owns the
/// long-lived state objects (recorder, store, settings, app state, bump map) and passes
/// references down — this is the single source of truth for the running app.
struct ContentView: View {
    @State private var recorder = RideRecorder()
    @State private var store = RideStore()
    @State private var settings = AppSettings()
    @State private var appState = AppState()
    @State private var bumpMap = BumpMapStore()
    @State private var webAccount = WebAccount()

    var body: some View {
        TabView(selection: Binding(
            get: { appState.selectedTab },
            set: { appState.selectedTab = $0 }
        )) {
            RideView(
                recorder: recorder,
                appState: appState,
                store: store,
                settings: settings
            )
            .tabItem { Label("Ride", systemImage: "bicycle") }
            .tag(AppState.Tab.ride)

            SavedRidesView(
                store: store,
                appState: appState,
                settings: settings
            )
            .tabItem { Label("Saved", systemImage: "list.bullet.rectangle") }
            .tag(AppState.Tab.saved)

            BumpMapTabView(
                store: store,
                bumpMap: bumpMap,
                settings: settings
            )
            .tabItem { Label("Bump Map", systemImage: "square.grid.3x3.fill") }
            .tag(AppState.Tab.bumpMap)

            SettingsView(settings: settings, webAccount: webAccount)
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(AppState.Tab.settings)
        }
    }
}

#Preview {
    ContentView()
}
