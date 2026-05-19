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
    /// Resolves iCloud vs. local storage for rides.  Created before RideStore
    /// because RideStore needs its `ridesDirectoryURL`.  Also owns the
    /// one-shot migration from legacy local Documents into iCloud.
    @State private var cloudStorage: CloudStorage

    /// Last calibration value we successfully PUT to the server.  Used to short-circuit
    /// no-op pushes on triggers like reachability returning while nothing has changed.
    @State private var lastPushedCalibration: WebSyncClient.ServerCalibration?

    /// One-shot flag flipped to `true` after the user dismisses the first-launch
    /// `IntroView`.  Persisted in `UserDefaults` so the sheet appears at most once
    /// per install.  Stored as `@AppStorage` (not `AppSettings`) because it's a
    /// pure UI lifecycle flag, not a user-tunable preference — there's no
    /// "Show intro again" surface anywhere.
    @AppStorage("hasSeenIntro") private var hasSeenIntro: Bool = false
    @State private var showingIntro = false

    init() {
        // Cloud storage must be created BEFORE RideStore so RideStore can be
        // initialized with the resolved directory URL.  Migration of existing
        // local rides into iCloud happens after view appearance (in .task),
        // not here, so init stays synchronous and we can still load the rides
        // that are already in the chosen directory immediately.
        let cloud = CloudStorage()
        let store = RideStore(directoryURL: cloud.ridesDirectoryURL)
        let webAccount = WebAccount()
        let queue = SyncQueue()
        let coordinator = SyncCoordinator(
            queue: queue,
            rideStore: store,
            webAccount: webAccount
        )
        let calibration = CalibrationStore()
        _cloudStorage = State(initialValue: cloud)
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
            // Badge shows only user-initiated unsynced rides — not the backfill
            // catch-up after pairing.  Otherwise a freshly-paired user with 50
            // historical rides would see a "50" badge for the entire upload
            // burst (potentially hours), which makes the tab feel broken.
            // See SyncQueue for the two-bucket structure.
            .badge(syncQueue.userInitiatedCount)
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
                calibration: calibration,
                store: store,
                cloudStorage: cloudStorage
            )
            .tabItem { Label("Settings", systemImage: "gear") }
            .tag(AppState.Tab.settings)
        }
        .sheet(isPresented: $showingIntro) {
            // Dismissing the sheet through Get Started flips both flags
            // together — hasSeenIntro persists across launches so we never show
            // the intro again, and showingIntro tears down this sheet.  We do
            // not set hasSeenIntro on .onDismiss because the sheet is
            // interactive-dismiss-disabled; the only way out is the button.
            IntroView {
                hasSeenIntro = true
                showingIntro = false
            }
        }
        .task {
            // First-launch intro: present once per install.  Checked before any
            // other launch work since this is the user's first impression and
            // anything else surfacing on top of it would look chaotic.
            if !hasSeenIntro {
                showingIntro = true
            }
            // Migrate any rides still sitting in legacy local Documents into
            // iCloud (no-op when iCloud is unavailable, or when there's
            // nothing local to migrate).  Runs before the store's initial
            // load is observed by the UI in practice — RideStore.init
            // already loaded what was in the directory at startup, and we
            // re-load below to pick up freshly-migrated files.
            cloudStorage.migrateLocalRidesIfNeeded()
            store.load()
            // Check for a recoverable ride journal first — this is the recovery
            // path for users whose last session ended abruptly (OS kill, crash,
            // force-quit).  Has to happen before anything else might touch the
            // recorder.  RideView watches `appState.recoveredRide` and shows the
            // alert.  We deliberately don't force-switch tabs here; if a user is
            // on Saved Rides and there's a recovered ride, they'll see the
            // recovery alert when they next visit Ride.
            if let recoverable = RideJournal.loadRecoverable() {
                let endedAt = recoverable.points.last?.timestamp ?? recoverable.header.startedAt
                appState.recoveredRide = Ride(
                    id: recoverable.header.rideId,
                    title: Ride.defaultTitle(for: recoverable.header.startedAt),
                    startedAt: recoverable.header.startedAt,
                    endedAt: endedAt,
                    points: recoverable.points,
                    pocketMode: nil,
                    schemaVersion: recoverable.header.schemaVersion
                )
                appState.selectedTab = .ride
            }

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
            // Pull server calibration on launch (covers the multi-device case: a fresh
            // install on an already-paired account adopts the value the user computed
            // on their other phone).  Then push, in case the local recompute above
            // produced a meaningfully different value.
            await pullThenPushCalibration()
            // Backfill brake-event detection for any ride that doesn't have it
            // yet (legacy v1/v2 rides, or v3 rides synced down from another
            // device before that device had brake detection).  Yields between
            // rides so the UI stays responsive; quiet saves avoid inflating
            // the Saved-tab badge.  We explicitly enqueue the touched IDs as
            // backfill afterward so updated payloads reach the server without
            // looking like fresh user activity.
            let reprocessed = await BrakeReprocessor.reprocessLegacyRides(in: store)
            if !reprocessed.isEmpty {
                syncCoordinator.backfillAll(rideIds: reprocessed)
                syncCoordinator.kick()
            }
        }
        .onChange(of: webAccount.isConnected) { _, isConnected in
            // When a user pairs (or re-pairs after disconnect), seed the queue with
            // every existing local ride so their back catalog gets backed up.  Server
            // upserts are idempotent on Ride.id, so this is safe to call every time
            // and a no-op for rides already in the queue or already synced earlier.
            if isConnected {
                syncCoordinator.backfillAll(rideIds: store.rides.map(\.id))
                syncCoordinator.kick()
                Task { await pullThenPushCalibration() }
            }
        }
        .onChange(of: reachability.isReachable) { _, isReachable in
            // The network coming back is another implicit "do it now" signal — kick the
            // coordinator so a queued upload doesn't sit on its 30 s+ backoff timer
            // while we're already online again.  The kick is idempotent; if we're not
            // paused it's a no-op.  We don't react to going offline because the
            // coordinator's existing transport-error path already handles that.
            if isReachable {
                syncCoordinator.kick()
                // Retry any calibration push that may have failed while offline.
                Task { await pushCalibrationIfChanged() }
            }
        }
        .onChange(of: calibration.calibration) { _, _ in
            // Every meaningful local change triggers a push.  Idempotent on the server
            // and short-circuited locally if the value matches our last successful PUT.
            Task { await pushCalibrationIfChanged() }
        }
    }

    /// GET the server's calibration, adopt if it has more overlap data than us, then
    /// push our (possibly newly-adopted, possibly newly-recomputed) value back.
    private func pullThenPushCalibration() async {
        guard webAccount.isConnected else { return }
        if let remote = try? await webAccount.fetchCalibration() {
            calibration.applyRemoteIfBetter(remote)
        }
        await pushCalibrationIfChanged()
    }

    /// PUT the current local calibration to the server if it differs from the last
    /// value we successfully pushed.  Silent on failure — the next triggering event
    /// (ride save, reconnect, reachability return) will retry.
    private func pushCalibrationIfChanged() async {
        guard webAccount.isConnected else { return }
        let snapshot = calibration.toServerCalibration()
        if snapshot == lastPushedCalibration { return }
        do {
            try await webAccount.setCalibration(snapshot)
            lastPushedCalibration = snapshot
        } catch {
            // Will retry on the next triggering event.  Failures are common during
            // network blips; not worth surfacing.
        }
    }
}

#Preview {
    ContentView()
}
