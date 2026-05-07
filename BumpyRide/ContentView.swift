import SwiftUI

struct ContentView: View {
    @State private var recorder = RideRecorder()
    @State private var store = RideStore()
    @State private var settings = AppSettings()
    @State private var appState = AppState()
    @State private var bumpMap = BumpMapStore()

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

            SettingsView(settings: settings)
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(AppState.Tab.settings)
        }
    }
}

#Preview {
    ContentView()
}
