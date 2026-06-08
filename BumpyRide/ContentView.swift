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
    @State private var recorder: RideRecorder
    @State private var settings: AppSettings
    @State private var appState: AppState
    @State private var bumpMap = BumpMapStore()
    @State private var brakeMap = BrakeMapStore()
    @State private var closeCallMap = CloseCallMapStore()

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
    /// Lazy cache of per-ride score data fetched from
    /// `/api/rides/{id}/score`.  Lives at the ContentView level so it
    /// survives RideView teardown (e.g., switching tabs and coming
    /// back) — cached scores persist across the playback session.
    @State private var rideScoreCache: RideScoreCache

    /// Owns the app's single `HKHealthStore` and tracks user
    /// authorization for the Apple Health integration.  Read by the
    /// Settings toggle and the per-ride "Add to Apple Health" button
    /// (Phase E) to gate UI on availability + auth state.
    @State private var healthKitAuth: HealthKitAuthManager

    /// MET-based active-energy estimator for the Apple Health write
    /// path.  Caches the user's most-recent bodyMass sample once per
    /// process so we don't re-query HealthKit on every export.
    @State private var healthKitEnergyEstimator: HealthKitEnergyEstimator

    /// Writes individual rides to Apple Health.  Idempotent — re-export
    /// of an already-written ride returns `.alreadyPresent` with the
    /// existing HKWorkout UUID.
    @State private var healthKitExporter: HealthKitExporter

    /// iOS side of the watchOS companion's WatchConnectivity session.
    /// Phase A wires the WCSession lifecycle and surfaces reachability;
    /// Phase C drives the 1 Hz snapshot push from the injected
    /// `RideRecorder`.  Phase D will wire incoming commands back into
    /// the recorder via `handle(command:)`.
    @State private var watchCoordinator: WatchCoordinator

    /// v1.7 watch HealthKit handoff coordinator.  Calls
    /// `HKHealthStore.startWatchApp(toHandle:)` on iPhone-app
    /// foreground when the user has opted in via Settings.  Gates
    /// itself on paired watch + HK availability — see its
    /// `considerLaunchingWatchApp()`.
    @State private var watchLaunchCoordinator: WatchLaunchCoordinator

    /// Drives the scenePhase → foreground watch-app launch trigger.
    /// `.onChange(of: scenePhase)` only fires on changes, so we
    /// also call `considerLaunchingWatchApp()` from the existing
    /// `.task` block to handle cold-start (when scenePhase is
    /// already `.active` at first render).
    @Environment(\.scenePhase) private var scenePhase

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

    /// Last `BrakeEventDetector.revision` we applied across the whole
    /// store.  Stored in `@AppStorage` so it survives launches.  When it's
    /// behind the current revision, the `.task` block force-re-detects
    /// every ride (not just nil-brakeEvents ones) so tuning changes show
    /// up on existing data without requiring the user to re-record.
    @AppStorage("lastAppliedBrakeDetectorRev") private var lastAppliedBrakeDetectorRev: Int = 0

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
        let scoreCache = RideScoreCache(account: webAccount)
        // HealthKit stack: auth manager owns the HKHealthStore, which
        // estimator and exporter both need.  All three are MainActor
        // and have no inter-init dependencies beyond the store handle,
        // so ordering here is fine.
        let healthAuth = HealthKitAuthManager()
        let healthEstimator = HealthKitEnergyEstimator(store: healthAuth.store)
        let healthExporter = HealthKitExporter(store: healthAuth.store, energyEstimator: healthEstimator)
        // Recorder must be constructed explicitly (rather than inline
        // on the @State) so the WatchCoordinator can be initialized
        // with a reference to it.  No semantic change for the rest of
        // the app — recorder behaves the same as before.
        let recorder = RideRecorder()
        // appState is constructed inline on its @State property; we
        // need an explicit reference for WatchCoordinator init too,
        // so promote it here.
        let appState = AppState()
        let watchCoordinator = WatchCoordinator(
            recorder: recorder,
            store: store,
            appState: appState
        )
        // Same lift for settings — WatchLaunchCoordinator gates on
        // `settings.openWatchAppOnLaunch` so it needs a reference,
        // and the construction order means we have to promote
        // settings out of inline @State.
        let settings = AppSettings()
        let watchLaunchCoordinator = WatchLaunchCoordinator(
            settings: settings,
            watchCoordinator: watchCoordinator,
            healthKitAuth: healthAuth
        )
        _cloudStorage = State(initialValue: cloud)
        _store = State(initialValue: store)
        _webAccount = State(initialValue: webAccount)
        _syncQueue = State(initialValue: queue)
        _syncCoordinator = State(initialValue: coordinator)
        _calibration = State(initialValue: calibration)
        _rideScoreCache = State(initialValue: scoreCache)
        _healthKitAuth = State(initialValue: healthAuth)
        _healthKitEnergyEstimator = State(initialValue: healthEstimator)
        _healthKitExporter = State(initialValue: healthExporter)
        _recorder = State(initialValue: recorder)
        _watchCoordinator = State(initialValue: watchCoordinator)
        _watchLaunchCoordinator = State(initialValue: watchLaunchCoordinator)
        _appState = State(initialValue: appState)
        _settings = State(initialValue: settings)
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
                settings: settings,
                rideScoreCache: rideScoreCache,
                healthKitAuth: healthKitAuth,
                healthKitExporter: healthKitExporter
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
                brakeMap: brakeMap,
                closeCallMap: closeCallMap,
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
                cloudStorage: cloudStorage,
                healthKitAuth: healthKitAuth,
                healthKitExporter: healthKitExporter,
                watchCoordinator: watchCoordinator
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
            // Resolve HealthKit auth state from `.unknown` → either
            // `.unavailable` (device can't do HealthKit) or one of the
            // user-facing states.  Has to run before any UI reads the
            // state — cheap and synchronous so it's fine here.
            healthKitAuth.checkOnLaunch()
            // Activate the WatchConnectivity session.  Cheap to call on
            // devices without a paired watch — the session resolves to
            // `.unavailable` and downstream code (Phase B+) gates on
            // `sessionState`.  Idempotent on repeated invocations.
            watchCoordinator.activate()
            // v1.7: consider auto-launching the watch app.  All gates
            // are evaluated inside the coordinator — this is a no-op
            // for users without the toggle on, without a paired watch,
            // or without HealthKit auth granted.  The same call is
            // also made via .onChange(of: scenePhase) below for
            // re-foregrounding.
            await watchLaunchCoordinator.considerLaunchingWatchApp()
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
                    schemaVersion: recoverable.header.schemaVersion,
                    // Surface any close calls captured before the crash so the
                    // user doesn't lose them.  Empty for pre-v3 recoveries
                    // (Recoverable falls back to []).
                    closeCallEvents: recoverable.closeCalls.isEmpty ? nil : recoverable.closeCalls
                )
                appState.selectedTab = .ride
            }

            // v1.7 H2: when a user-initiated ride uploads, immediately
            // kick the score cache to fetch with retry/backoff so the
            // score lands in the Saved tab without the user opening the
            // ride.  Backfill uploads don't fire this — see
            // SyncCoordinator.onUserRideUploaded.
            syncCoordinator.onUserRideUploaded = { [rideScoreCache] rideId in
                rideScoreCache.requestScoreWithRetry(for: rideId)
            }
            // Connect RideStore save/delete to the sync queue + calibration recompute.
            // Idempotent — re-running just overwrites the same closure references.
            store.onRideSaved = { ride in
                syncCoordinator.enqueue(ride.id)
                syncCoordinator.kick()
                calibration.recompute(from: store.rides)
                // Auto-export to Apple Health.  Gated on three things
                // so this stays cheap and doesn't loop:
                //  - user has opted in via Settings,
                //  - auth has been granted (we don't surprise-prompt
                //    here; the toggle did that earlier),
                //  - ride hasn't already been stamped on this device.
                // The third condition is the loop guard: a successful
                // export below re-saves the ride with the stamp set,
                // which fires this callback again — without the nil
                // check we'd re-export forever.
                if settings.autoExportToAppleHealth,
                   healthKitAuth.canWrite,
                   ride.healthKitWorkoutUUID == nil {
                    Task {
                        do {
                            let result = try await healthKitExporter.export(ride)
                            switch result {
                            case .written(let uuid), .alreadyPresent(let uuid):
                                // Quiet save: the stamp is device-local,
                                // and going through onRideSaved here
                                // would re-upload the whole ride to
                                // bumpyride.me and re-push calibration
                                // for a 36-byte field nobody else
                                // interprets.
                                store.updateHealthKitWorkoutUUID(uuid, forRideId: ride.id)
                            case .unavailable:
                                break
                            }
                        } catch {
                            // The exporter already logged the cause.
                            // Failures are non-fatal: the user can
                            // retry via the per-ride button added in
                            // Phase E.
                        }
                    }
                }
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
            // Backfill brake-event detection.  Two cases land in the same code
            // path:
            //
            // 1. Steady state — only rides with `brakeEvents == nil` need work
            //    (legacy v1/v2 rides, or v3 rides synced down from another
            //    device before that device had brake detection).
            //
            // 2. Detector-revision bump — when the constants or algorithm
            //    change meaningfully (see BrakeEventDetector.revision), we
            //    re-detect every ride one more time so the new tuning shows
            //    up on existing data without forcing the user to re-record.
            //    Triggered when the stored last-applied rev is behind the
            //    detector's current rev.
            //
            // Both modes yield between rides so the UI stays responsive, and
            // saves go through the quiet path so the Saved-tab badge doesn't
            // inflate.  Touched IDs get enqueued as backfill afterward so the
            // updated payloads reach the server without looking like fresh
            // user activity.
            let forceReDetect = lastAppliedBrakeDetectorRev < BrakeEventDetector.revision
            let reprocessed = await BrakeReprocessor.reprocessLegacyRides(in: store, forceReDetect: forceReDetect)
            if forceReDetect {
                lastAppliedBrakeDetectorRev = BrakeEventDetector.revision
            }
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
            } else {
                // Disconnect: any cached per-ride scores belonged to the
                // now-defunct token's owner.  Wipe so a re-pair to a
                // different account doesn't surface the old account's
                // points.
                rideScoreCache.invalidateAll()
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
        .onChange(of: scenePhase) { _, newPhase in
            // v1.7: re-foregrounding triggers another considerLaunchingWatchApp pass.
            // SwiftUI's .onChange doesn't fire on the initial value, so cold-start
            // is covered by the same call in the existing .task block above.  Both
            // paths route through the same idempotent coordinator method.
            guard newPhase == .active else { return }
            Task { @MainActor in
                await watchLaunchCoordinator.considerLaunchingWatchApp()
            }
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
