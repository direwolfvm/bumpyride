import SwiftUI

/// Root view: a `TabView` hosting Ride, Saved, Bump Map, and Settings tabs.  Owns the
/// long-lived state objects (recorder, store, settings, app state, bump map, sync
/// queue, sync coordinator, web account) and passes references down — this is the
/// single source of truth for the running app.
///
/// The sync stack is built eagerly in `init` so child views can take a non-optional
/// `SyncCoordinator` via `@Bindable`.  Callbacks (`RideStore.onRideSaved`, etc.) are
/// wired in `.task` since those want to run once per appearance, not once per view
/// rebuild.
struct ContentView: View {
    @State private var recorder = RideRecorder()
    @State private var settings = AppSettings()
    @State private var appState = AppState()
    @State private var bumpMap = BumpMapStore()

    @State private var store: RideStore
    @State private var webAccount: WebAccount
    @State private var syncQueue: SyncQueue
    @State private var syncCoordinator: SyncCoordinator
    @State private var calibration: CalibrationStore
    @State private var reachability = NetworkReachability()

    init() {
        let store = RideStore()
        let webAccount = WebAccount()
        let queue = SyncQueue()
        let coordinator = SyncCoordinator(
            queue: queue,
            rideStore: store,
            webAccount: webAccount
        )
        let calibration = CalibrationStore()
        _store = State(initialValue: store)
        _webAccount = State(initialValue: webAccount)
        _syncQueue = State(initialValue: queue)
        _syncCoordinator = State(initialValue: coordinator)
        _calibration = State(initialValue: calibration)
    }

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
                settings: settings,
                syncCoordinator: syncCoordinator,
                webAccount: webAccount
            )
            .tabItem { Label("Saved", systemImage: "list.bullet.rectangle") }
            .badge(syncQueue.count)
            .tag(AppState.Tab.saved)

            BumpMapTabView(
                store: store,
                bumpMap: bumpMap,
                settings: settings,
                calibration: calibration
            )
            .tabItem { Label("Bump Map", systemImage: "square.grid.3x3.fill") }
            .tag(AppState.Tab.bumpMap)

            SettingsView(
                settings: settings,
                webAccount: webAccount,
                syncCoordinator: syncCoordinator,
                syncQueue: syncQueue,
                calibration: calibration
            )
            .tabItem { Label("Settings", systemImage: "gear") }
            .tag(AppState.Tab.settings)
        }
        .task {
            // Connect RideStore save/delete to the sync queue + calibration recompute.
            // Idempotent — re-running just overwrites the same closure references.
            store.onRideSaved = { ride in
                syncCoordinator.enqueue(ride.id)
                syncCoordinator.kick()
                calibration.recompute(from: store.rides)
            }
            store.onRideDeleted = { id in
                syncCoordinator.remove(id)
                calibration.recompute(from: store.rides)
            }
            // Recompute on launch in case rides were added on another device and
            // synced down (currently no such path; future-proofing) or for users
            // who saved rides under an older build that didn't have calibration yet.
            calibration.recompute(from: store.rides)
            // If the user was already paired in a prior session (token in Keychain →
            // WebAccount.init() set state to .connected before the view was even built),
            // .onChange(of: isConnected) won't fire — SwiftUI only observes transitions.
            // Without this, any locally saved rides would silently sit outside the
            // queue, and status(forRide:) would return .synced for them ("not in queue"
            // is its current definition of synced), producing a false "everything
            // synced" UI with zero actual POSTs to /api/sync/ride.  Server upserts are
            // idempotent on Ride.id, so re-seeding on every launch is safe — at most
            // one duplicate-but-successful POST per ride per launch.
            if webAccount.isConnected {
                syncCoordinator.backfillAll(rideIds: store.rides.map(\.id))
            }
            // Drain anything queued from prior sessions / paired devices.
            syncCoordinator.kick()
        }
        .onChange(of: webAccount.isConnected) { _, isConnected in
            // When a user pairs (or re-pairs after disconnect), seed the queue with
            // every existing local ride so their back catalog gets backed up.  Server
            // upserts are idempotent on Ride.id, so this is safe to call every time
            // and a no-op for rides already in the queue or already synced earlier.
            if isConnected {
                syncCoordinator.backfillAll(rideIds: store.rides.map(\.id))
                syncCoordinator.kick()
            }
        }
        .onChange(of: reachability.isReachable) { _, isReachable in
            // The network coming back is another implicit "do it now" signal — kick the
            // coordinator so a queued upload doesn't sit on its 30 s+ backoff timer
            // while we're already online again.  The kick is idempotent; if we're not
            // paused it's a no-op.  We don't react to going offline because the
            // coordinator's existing transport-error path already handles that.
            if isReachable { syncCoordinator.kick() }
        }
    }
}

#Preview {
    ContentView()
}
