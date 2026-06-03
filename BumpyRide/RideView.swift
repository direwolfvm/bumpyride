import SwiftUI
import UIKit
import CoreLocation
import CoreMotion

/// The Ride tab: shows the live recording UI when no ride is loaded, or the playback
/// UI (seismograph chart + colored map + scrubber + zoom) when `appState.loadedRide`
/// is set.  Owns the save sheet, the trim/split editor, rename/delete alerts, and
/// the export-to-Photos flow.  Drives the screen-on idle timer and pushes Pocket Mode
/// state changes into the `MotionManager`.
struct RideView: View {
    @Bindable var recorder: RideRecorder
    @Bindable var appState: AppState
    var store: RideStore
    @Bindable var settings: AppSettings
    /// Lazy per-ride score cache shared with `ContentView` so the
    /// playback view can show a "Points earned" stat for the currently-
    /// loaded ride.  Survives view teardown (e.g. tab switches), so
    /// scores stay cached across sessions in the same launch.
    @Bindable var rideScoreCache: RideScoreCache
    /// Auth state for the Apple Health integration.  The per-ride Apple
    /// Health row hides entirely when HealthKit isn't available, and
    /// triggers an auth request before the first manual export if the
    /// user hasn't already granted via the Settings toggle.
    @Bindable var healthKitAuth: HealthKitAuthManager
    /// Writes individual rides to Apple Health.  Used by the per-ride
    /// "Add to Apple Health" button.  Same instance as the auto-export
    /// path in `ContentView.onRideSaved`, so the exporter's idempotency
    /// check naturally dedups manual + auto attempts.
    ///
    /// Plain `let` (not `@Bindable`) — the exporter has no observable
    /// state for the view to bind to; it's a stateless command service.
    let healthKitExporter: HealthKitExporter

    @State private var showingSaveSheet: Bool = false
    @State private var pendingRide: Ride?
    @State private var editableTitle: String = ""

    @State private var scrubIndex: Int = 0
    @State private var zoom: Double = 1.0

    @State private var showingEditSheet: Bool = false
    @State private var showingRenameAlert: Bool = false
    @State private var renameText: String = ""
    @State private var showingDeleteConfirm: Bool = false
    @State private var showingStartOverConfirm: Bool = false

    @State private var showExportAlert: Bool = false
    @State private var exportAlertTitle: String = ""
    @State private var exportAlertMessage: String = ""
    @State private var isExporting: Bool = false

    /// Local "currently writing this ride to HealthKit" flag for the
    /// per-ride Apple Health row's spinner.  Persists across the
    /// auth-then-export sequence so the row stays in "Adding…" state
    /// from the moment of tap until completion.  Reset by the ride's
    /// `.task(id:)` block when the loaded ride changes.
    @State private var isExportingToHealth: Bool = false

    /// Inline error caption under the Apple Health row.  `nil` when no
    /// error to show; cleared at the start of each export attempt and
    /// when the loaded ride changes.
    @State private var healthExportError: String?

    /// Live brake-event list maintained during recording so the live
    /// map can render red brake pins alongside the bumpiness polyline.
    /// Recomputed at ~1 Hz by a polling task in `liveContent` while
    /// `recorder.state == .recording`; cleared on pause / stop.
    ///
    /// We re-run the post-hoc detector on the in-progress points
    /// rather than maintaining a separate streaming detector — same
    /// algorithm at save time and during recording, so what the user
    /// sees live matches what the saved ride keeps.  The detector is
    /// O(N) and pure, so a 1 Hz recompute on a several-thousand-point
    /// ride is single-digit milliseconds.
    @State private var liveBrakeEvents: [BrakeEvent] = []

    /// Pocket-mode value the save sheet will commit.  Primed from
    /// `MountStyleDetector`'s verdict on Stop; user can override via the toggle in
    /// the Sensing section before tapping Save.
    @State private var pendingPocketMode: Bool = false

    /// Auto-detect result for the just-recorded ride.  Surfaced as a small caption
    /// on the Sensing section so the user can see what the detector concluded
    /// (and decide whether to override).  `nil` when detection couldn't run —
    /// extremely short rides or accelWindow data missing entirely.
    @State private var pendingMountDetection: MountStyleDetector.Result?

    /// Controls the "Recover unfinished ride?" alert that fires when
    /// `ContentView.task` finds a non-empty journal on launch.
    @State private var showingRecoveryAlert: Bool = false

    /// The most recently-logged close call awaiting its undo window.  Drives
    /// the brief "Close call logged" banner that appears under the Log
    /// button.  Set on tap, cleared by Undo or auto-dismissed after the
    /// task in `scheduleCloseCallBannerDismiss`.
    @State private var pendingCloseCall: CloseCall?
    /// Monotonic counter incremented on every Log tap.  Used to invalidate
    /// stale auto-dismiss tasks — if a user taps Log twice within 5 seconds,
    /// the first tap's dismiss task sees a mismatched counter and bails,
    /// leaving the second tap's banner visible for its full window.
    @State private var closeCallTapGeneration: Int = 0

    private func setIdleTimer(disabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = disabled
    }

    var body: some View {
        NavigationStack {
            rootContent
                .modifier(RideViewNavModifier(title: appState.loadedRide?.title ?? "BumpyRide", toolbar: { toolbarContent }))
                .modifier(RideViewLifecycleModifier(
                    recorder: recorder,
                    loadedId: appState.loadedRide?.id,
                    onAppearAction: {
                        recorder.requestPermissions()
                        setIdleTimer(disabled: recorder.state == .recording)
                    },
                    onStateChange: { newState in
                        setIdleTimer(disabled: newState == .recording)
                    },
                    onLoadedChange: { scrubIndex = 0; zoom = 1.0 },
                    onDisappearAction: {
                        if recorder.state != .recording {
                            setIdleTimer(disabled: false)
                        }
                    }
                ))
                .sheet(isPresented: $showingSaveSheet, onDismiss: { pendingRide = nil }) { saveSheet }
                .sheet(isPresented: $showingEditSheet) { editSheet }
                .task {
                    // ContentView.task sets recoveredRide on launch (before this view
                    // first renders, usually).  .onChange won't fire for already-set
                    // values, so check here on appear too.  No-op if already nil.
                    if appState.recoveredRide != nil {
                        showingRecoveryAlert = true
                    }
                }
                .onChange(of: appState.recoveredRide?.id) { _, newID in
                    if newID != nil {
                        showingRecoveryAlert = true
                    }
                }
                .alert("Recover unfinished ride?", isPresented: $showingRecoveryAlert, presenting: appState.recoveredRide) { recovered in
                    Button("Recover") {
                        acceptRecovery()
                    }
                    Button("Discard", role: .destructive) {
                        declineRecovery()
                    }
                } message: { recovered in
                    Text("BumpyRide found an unfinished recording from \(Formatters.dateTime(recovered.startedAt)) with \(recovered.points.count) sample\(recovered.points.count == 1 ? "" : "s"). The recording was interrupted before it was saved — recover it now, or discard.")
                }
                .modifier(RideViewAlertsModifier(
                    showingRename: $showingRenameAlert,
                    renameText: $renameText,
                    onRenameSave: commitRename,
                    showingDelete: $showingDeleteConfirm,
                    onDelete: commitDelete,
                    showingStartOver: $showingStartOverConfirm,
                    onStartOver: startOver,
                    showingExport: $showExportAlert,
                    exportTitle: exportAlertTitle,
                    exportMessage: exportAlertMessage
                ))
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        if let ride = appState.loadedRide {
            viewerContent(for: ride)
        } else {
            liveContent
        }
    }

    @ViewBuilder
    private var editSheet: some View {
        if let ride = appState.loadedRide {
            EditRideView(original: ride, settings: settings) { updated, newSecond in
                // Trim/split changes the points array, which invalidates any
                // pre-existing brakeEvents (they may reference timestamps
                // outside the new bounds).  Re-detect on both halves before
                // saving so the brake map and Ride view stay consistent
                // with the edited points.
                let updatedWithBrakes = updated.withDetectedBrakeEvents()
                store.save(updatedWithBrakes)
                if let second = newSecond {
                    store.save(second.withDetectedBrakeEvents())
                }
                appState.loadedRide = updatedWithBrakes
            }
        }
    }

    /// Open the save sheet pre-populated for `ride` — running the auto-detect to
    /// prime the pocket-mode toggle.  Called from both the Stop button (freshly-
    /// recorded ride) and the recovery accept path (ride reconstructed from the
    /// on-disk journal).
    private func presentSaveSheet(for ride: Ride) {
        pendingRide = ride
        editableTitle = ride.title
        let detection = MountStyleDetector.analyze(ride)
        pendingMountDetection = detection
        pendingPocketMode = (detection?.verdict == .likelyPocket)
        showingSaveSheet = true
    }

    /// User tapped "Recover" in the recovery alert.  Route the recovered ride
    /// into the save sheet, identical to a just-stopped ride.
    private func acceptRecovery() {
        guard let recovered = appState.recoveredRide else { return }
        appState.recoveredRide = nil
        presentSaveSheet(for: recovered)
        // The save sheet's Save / Discard paths both call `recorder.reset()`,
        // which in turn calls `journal.clear()`, so we don't have to do
        // anything extra to clean up the on-disk journal here.
    }

    /// User tapped "Discard" in the recovery alert.  Drop the recovered ride
    /// and clear the on-disk journal.
    private func declineRecovery() {
        appState.recoveredRide = nil
        RideJournal.clearAny()
    }

    private func commitRename() {
        let t = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, var ride = appState.loadedRide else { return }
        ride.title = t
        store.save(ride)
        appState.loadedRide = ride
    }

    /// Binding for the toolbar's Recording mode submenu picker.  Reading returns the
    /// loaded ride's current `pocketMode` (including `nil` for legacy untagged rides,
    /// which means no Picker option is checked).  Writing updates the ride in place,
    /// recomputes bumpiness through the appropriate filter (for v2 rides where the
    /// raw accelWindow is preserved), and re-saves — which fans out to the sync
    /// queue (re-uploads with new tag + recomputed values) and the calibration store
    /// (recomputes with the corrected mode bucket).
    private var pocketModeBinding: Binding<Bool?> {
        Binding(
            get: { appState.loadedRide?.pocketMode },
            set: { newValue in
                guard let new = newValue, var ride = appState.loadedRide, ride.pocketMode != new else { return }
                ride.pocketMode = new
                // For v2 rides we have the raw accelWindow on disk, so we can
                // recompute bumpiness in either direction without information loss.
                // For v1 rides the accelWindow was already filtered when the
                // original tag was pocket — we can't undo that, so just flip the
                // tag and accept the slight inconsistency.
                if ride.schemaVersion >= 2 {
                    ride = new ? ride.reprocessedWithPocketHPF() : ride.reprocessedAsMounted()
                }
                store.save(ride)
                appState.loadedRide = ride
            }
        )
    }

    private func commitDelete() {
        if let ride = appState.loadedRide {
            store.delete(ride)
            // Drop any cached score for this id so a re-restore of the
            // same UUID later doesn't surface stale data.
            rideScoreCache.invalidate(ride.id)
            // Same "return to where you came from" semantic as the X
            // button — after deleting, the user wants to see the
            // updated list, which is the Saved tab.
            appState.dismissLoaded()
        }
    }

    private func startOver() {
        appState.clearLoaded()
        recorder.reset()
        recorder.start()
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if appState.loadedRide != nil {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    // dismissLoaded restores the tab the user was on
                    // when they opened the ride (typically Saved).
                    // clearLoaded would leave them on the now-idle Ride
                    // tab, which was the original bug.
                    appState.dismissLoaded()
                } label: {
                    Label("Clear", systemImage: "xmark")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        renameText = appState.loadedRide?.title ?? ""
                        showingRenameAlert = true
                    } label: { Label("Rename", systemImage: "pencil") }

                    Picker(selection: pocketModeBinding) {
                        Text("Mounted").tag(Bool?.some(false))
                        Text("Pocket").tag(Bool?.some(true))
                    } label: {
                        Label("Recording mode", systemImage: "wave.3.right.circle")
                    }

                    Button {
                        showingEditSheet = true
                    } label: { Label("Trim or Split", systemImage: "scissors") }

                    Button {
                        exportCurrentRide()
                    } label: { Label(isExporting ? "Exporting…" : "Export to Photos", systemImage: "square.and.arrow.up") }
                        .disabled(isExporting)

                    Divider()

                    Button(role: .destructive) {
                        showingDeleteConfirm = true
                    } label: { Label("Delete", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    // MARK: Live recording / idle content

    /// Current GPS speed in m/s, or `nil` if there's no fresh fix.
    /// `CLLocation.speed` is non-optional but uses negative values to
    /// signal "no valid speed" — collapse that into `nil` here so the
    /// SeismographView's optional-handling kicks in.
    private var liveCurrentSpeedMps: Double? {
        guard let loc = recorder.currentLocation else { return nil }
        return loc.speed >= 0 ? loc.speed : nil
    }

    private var liveContent: some View {
        VStack(spacing: 12) {
            SeismographView(
                samples: recorder.liveSamples,
                bumpiness: recorder.currentBumpiness,
                capacity: recorder.motion.windowCapacity,
                currentSpeed: liveCurrentSpeedMps,
                settings: settings
            )
            .frame(height: 160)
            .padding(.horizontal)

            RouteMapView(
                points: liveDisplayPoints,
                followUser: recorder.state == .recording,
                highlightIndex: nil,
                settings: settings,
                // Live markers — red pins for hard brakes (detected
                // post-hoc at ~1 Hz from the in-progress points, see
                // `liveBrakeEvents` doc), violet diamonds for
                // close-calls (already tracked live by RideRecorder).
                // Both render regardless of bumpiness coloring; the
                // user wanted to see them appear as they happen.
                brakeEvents: liveBrakeEvents,
                closeCalls: recorder.closeCalls
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)

            // Live recording stats — always in bumps mode regardless of the
            // user's saved-ride view-mode preference.  Brake detection runs
            // post-hoc at save time, so there are no live brake events to
            // surface here.  Close-call event count is also intentionally
            // omitted from the live stats per the v1.3 design — the user
            // is logging them via the button below; surfacing a running
            // count would tempt mid-ride attention.
            //
            // TimelineView ticks the stats bar at 1 Hz independently of
            // the recorder's data-driven re-renders so the elapsed-time
            // readout keeps advancing even when the user has paused, the
            // GPS is between fixes, etc.  When the recorder hasn't been
            // started yet (`startedAt == nil`) we pass 0, giving a
            // "0:00" display rather than a stale jump.
            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                let elapsed = recorder.startedAt
                    .map { max(0, context.date.timeIntervalSince($0)) } ?? 0
                statsBar(
                    pointsCount: recorder.points.count,
                    distance: recorder.totalDistanceMeters,
                    maxBump: recorder.maxRecordedBumpiness,
                    brakeEvents: [],
                    closeCalls: [],
                    mode: .bumps,
                    elapsedTime: elapsed
                )
            }
            .padding(.horizontal)

            if let banner = permissionBanner() {
                banner
                    .padding(.horizontal)
            }

            // Close-call logging — visible only during recording or pause.
            // Sits above the primary controls so the user can find it
            // by feel without looking away from the road.  Banner +
            // button stack together so the layout doesn't jump as the
            // banner shows/hides.
            if recorder.state == .recording || recorder.state == .paused {
                VStack(spacing: 8) {
                    logCloseCallButton
                    if let pending = pendingCloseCall {
                        closeCallUndoBanner(for: pending)
                    }
                }
                .padding(.horizontal)
                // Smooth slide-in/out for the banner.
                .animation(.easeInOut(duration: 0.2), value: pendingCloseCall?.id)
            }

            controlButtons
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
        // Live brake-event detection.  Re-runs whenever the recorder
        // changes state — task body checks state on each tick and
        // either polls (while recording) or clears (otherwise).
        //
        // Inherent ~1.5 s latency from the centered finite-difference
        // smoothing window: a brake at the absolute tail of the
        // points buffer can't be resolved until a couple of GPS fixes
        // arrive after it.  Markers pop in slightly delayed and stay
        // put once the window settles around them — same fidelity as
        // the post-hoc detector at save time.
        .task(id: recorder.state) {
            guard recorder.state == .recording else {
                liveBrakeEvents = []
                return
            }
            // Compute immediately on transition into .recording so
            // the first marker doesn't wait a full second after a
            // resume from pause.
            liveBrakeEvents = BrakeEventDetector.detect(in: recorder.points)
            // 1 Hz poll.  Cooperative cancellation via Task.isCancelled
            // when SwiftUI tears the task down (state change, view
            // disappear).  Re-check state every wake so a stale task
            // can't keep running past a pause.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, recorder.state == .recording else { break }
                liveBrakeEvents = BrakeEventDetector.detect(in: recorder.points)
            }
        }
    }

    /// Full-width "Log close call" button.  Purple tint matches the
    /// violet diamonds used for close-call markers on the route map and
    /// the close-call tile-overlay diamonds on the Bump Map tab —
    /// consistent visual identity across surfaces.  Still distinct from
    /// the green Start/Resume and red Stop so a thumb stab during a
    /// stressful moment can't easily hit the wrong action.  Disabled
    /// while we don't yet have a GPS fix — the button stays visible so
    /// the user knows where to find it once a fix arrives, rather than
    /// appearing-and-disappearing.
    private var logCloseCallButton: some View {
        Button {
            handleCloseCallTap()
        } label: {
            Label("Log Close Call", systemImage: "exclamationmark.triangle.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.purple)
        .controlSize(.large)
        .disabled(!recorder.canLogCloseCall)
    }

    /// Brief confirmation + undo affordance shown for 5 s after a tap.
    /// One row: checkmark + "Close call logged" + "Undo" button.  Designed
    /// to be glanceable — a rider should not need to read it carefully.
    /// Matches the button's purple tint for visual continuity with the
    /// preceding tap.
    private func closeCallUndoBanner(for call: CloseCall) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.purple)
            Text("Close call logged")
                .font(.callout.weight(.medium))
            Spacer()
            Button("Undo") {
                undoPendingCloseCall(call)
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(.purple)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.purple.opacity(0.4), lineWidth: 1)
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// Tap handler: capture the call, run haptic, show the banner, queue
    /// auto-dismiss for 5 s out.  Multiple taps in quick succession show
    /// the *latest* call's banner — the generation counter invalidates
    /// stale dismiss tasks so the most recent banner gets its full window.
    private func handleCloseCallTap() {
        guard let call = recorder.logCloseCall() else { return }
        // Light tactile feedback — distinct enough to register through
        // gloves without being startling on a quiet road.
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        pendingCloseCall = call
        closeCallTapGeneration += 1
        scheduleCloseCallBannerDismiss(generation: closeCallTapGeneration)
    }

    /// User tapped Undo within the 5 s window.  Remove the call from the
    /// recorder, hide the banner immediately.  Idempotent in case the
    /// banner is still on-screen but the user double-taps Undo.
    private func undoPendingCloseCall(_ call: CloseCall) {
        recorder.undoCloseCall(id: call.id)
        // Light feedback so the cancel registers as confirmed.
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        pendingCloseCall = nil
    }

    /// Fire-and-forget task that clears `pendingCloseCall` after 5 s
    /// *unless* a newer Log tap has already taken over (generation
    /// mismatch).  Doesn't cancel the recorder's stored call — the user
    /// affirmed it by letting the banner expire.
    private func scheduleCloseCallBannerDismiss(generation: Int) {
        Task {
            try? await Task.sleep(for: .seconds(5))
            // If another tap happened between now and the sleep, leave
            // its banner alone — only the latest tap's dismiss task
            // should fire.
            guard generation == closeCallTapGeneration else { return }
            pendingCloseCall = nil
        }
    }

    /// Banner rendered above the Start/Stop button when the app can't actually
    /// record because of a permission state.  Currently surfaces:
    ///   - Location denied / restricted: a Settings shortcut.
    ///   - Motion unavailable: explanatory text (no Settings action since the
    ///     iOS Motion & Fitness privacy toggle doesn't deep-link easily and
    ///     unavailability is rare in practice).
    /// Returns nil when everything is good — caller doesn't render anything.
    private func permissionBanner() -> AnyView? {
        let locationStatus = recorder.location.authorizationStatus
        if locationStatus == .denied || locationStatus == .restricted {
            return AnyView(permissionBannerRow(
                icon: "location.slash.fill",
                title: "Location access is off",
                subtitle: "BumpyRide needs your location to record routes. Tap to open Settings and re-enable it.",
                actionLabel: "Open Settings",
                action: openAppSettings
            ))
        }
        if !recorder.motion.isAvailable {
            return AnyView(permissionBannerRow(
                icon: "exclamationmark.triangle.fill",
                title: "Motion sensing unavailable",
                subtitle: "This device doesn't report accelerometer data, so bumpiness can't be measured.",
                actionLabel: nil,
                action: nil
            ))
        }
        return nil
    }

    private func permissionBannerRow(
        icon: String,
        title: String,
        subtitle: String,
        actionLabel: String?,
        action: (() -> Void)?
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionLabel, let action {
                    Button(action: action) {
                        Text(actionLabel)
                            .font(.callout.weight(.medium))
                    }
                    .padding(.top, 2)
                }
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.3))
        )
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Whether the Start Ride button should be enabled.  Disabled when we know
    /// for sure recording can't produce useful data.  `.notDetermined` is allowed
    /// because the first tap will trigger the system permission prompt.
    private var canStartRecording: Bool {
        let status = recorder.location.authorizationStatus
        let locationOK = status == .authorizedAlways
            || status == .authorizedWhenInUse
            || status == .notDetermined
        #if targetEnvironment(simulator)
        // The iOS Simulator has no accelerometer, so
        // CMMotionManager.isDeviceMotionAvailable is permanently false
        // there.  Bypass the motion gate in simulator builds so we can
        // exercise downstream paths (watch sync, save flow, sync queue,
        // brake detector) without a physical device.  MotionManager's
        // own start() no-ops when the sensor isn't available, so a
        // simulator "ride" produces bumpiness=0 throughout — still
        // useful for testing every code path that depends on a ride
        // being in flight.  No-op on a physical iPhone.
        return locationOK
        #else
        return locationOK && recorder.motion.isAvailable
        #endif
    }

    /// Live-recording control surface.  Three layouts, one per recorder state:
    ///
    /// - `.idle` / `.finished`: a single big green **Start Ride** button.
    /// - `.recording`: a single orange **Pause Ride** button.  Tapping it doesn't
    ///   end the ride — it just halts sampling so the user can lock in a break
    ///   without losing the points so far.
    /// - `.paused`: two buttons side-by-side, **Resume** (green) and **Stop Ride**
    ///   (red, opens the save sheet).
    ///
    /// The "Stop is reached only from a pause" pattern is borrowed from the
    /// Apple Fitness / Strava convention — it makes accidentally ending a ride
    /// a two-tap action and matches the request the user made when promoting
    /// this to v1.1.
    private var controlButtons: some View {
        HStack(spacing: 12) {
            switch recorder.state {
            case .idle, .finished:
                Button { recorder.start() } label: {
                    Label("Start Ride", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
                .disabled(!canStartRecording)

            case .recording:
                Button { recorder.pause() } label: {
                    Label("Pause Ride", systemImage: "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.large)

            case .paused:
                Button { recorder.resume() } label: {
                    Label("Resume", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)

                Button(role: .destructive) {
                    if let ride = recorder.stop() {
                        presentSaveSheet(for: ride)
                    } else {
                        recorder.reset()
                    }
                } label: {
                    Label("Stop Ride", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
            }
        }
    }

    // MARK: Viewer content

    private func viewerContent(for ride: Ride) -> some View {
        let mode = settings.mapViewMode
        let brakeEvents = ride.brakeEvents ?? []
        let closeCalls = ride.closeCallEvents ?? []
        return VStack(spacing: 12) {
            // Bumpiness / Brakes / Calls toggle.  Reuses the same
            // AppSettings flag as the Bump Map tab — toggling on one
            // surface follows through to the other.
            playbackModeChip
                .padding(.horizontal)

            // Chart area swaps content based on mode.  Same vertical
            // real estate (~160 pt) regardless so the layout below
            // doesn't reflow on toggle.
            chartArea(for: ride, mode: mode, brakeEvents: brakeEvents, closeCalls: closeCalls)
                .frame(height: 160)
                .padding(.horizontal)

            RouteMapView(
                points: ride.points,
                followUser: false,
                highlightIndex: clampedScrub(for: ride),
                settings: settings,
                brakeEvents: mode == .brakes ? brakeEvents : [],
                closeCalls: mode == .closeCalls ? closeCalls : [],
                // Colored polyline in bumps mode only.  In brakes /
                // close-calls modes, the polyline is neutral context so
                // the pins / diamonds carry the visual weight.
                colorRoute: mode == .bumps
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)

            scrubberSection(for: ride)
                .padding(.horizontal)

            statsBar(
                pointsCount: ride.points.count,
                distance: ride.distanceMeters,
                maxBump: ride.maxBumpiness,
                brakeEvents: brakeEvents,
                closeCalls: closeCalls,
                mode: mode
            )
            .padding(.horizontal)

            // Per-ride score row — only renders when the cache has a
            // .loaded entry for this ride.  Loading, ineligible, and
            // failed all collapse to no row so the layout doesn't
            // flicker.  Request kicked off in .task below.
            rideScoreRow(for: ride)
                .padding(.horizontal)

            // Per-ride Apple Health row.  Three visual states — already
            // in Health (✓), currently exporting (spinner), or
            // not-yet-in-Health (Add button).  Hidden entirely on
            // devices without HealthKit.  See `appleHealthRow` doc.
            appleHealthRow(for: ride)
                .padding(.horizontal)

            Button {
                showingStartOverConfirm = true
            } label: {
                Label("Start New Ride", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.large)
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        // Kick off the score fetch when the viewer opens / the loaded
        // ride changes.  Idempotent — `requestScore` is a no-op when an
        // entry already exists for this id.  Also reset the per-ride
        // Apple Health row's transient state so a stale spinner or
        // error from a previously-viewed ride doesn't carry over.
        .task(id: ride.id) {
            rideScoreCache.requestScore(for: ride.id)
            isExportingToHealth = false
            healthExportError = nil
        }
    }

    /// "Points earned: N" row shown only when the per-ride score is
    /// available and the ride was eligible.  See `RideScoreCache.Entry`
    /// for the state breakdown; loading / ineligible / failed all
    /// render nothing.
    @ViewBuilder
    private func rideScoreRow(for ride: Ride) -> some View {
        if case .loaded(let data) = rideScoreCache.entry(for: ride.id) {
            HStack(spacing: 10) {
                Image(systemName: "trophy.fill")
                    .font(.callout)
                    .foregroundStyle(.yellow)
                Text("Points earned")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(data.totalPoints)")
                    .font(.callout.monospacedDigit().weight(.bold))
                    .foregroundStyle(.primary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    /// Per-ride Apple Health row.  Three visual states, all sharing the
    /// same outer chrome so the layout doesn't shift between them:
    ///
    ///  - **Exporting**: spinner + "Adding to Apple Health…"
    ///  - **Already in Health** (`ride.healthKitWorkoutUUID != nil`):
    ///    green ✓ + "In Apple Health"
    ///  - **Not in Health, idle**: tappable Button "Add to Apple Health"
    ///
    /// Hidden entirely on devices without HealthKit.  Stale-on-cross-
    /// device-restore is a known limitation (see `Ride.healthKitWorkoutUUID`
    /// doc): the badge may briefly say ✓ for a restored ride that isn't
    /// actually in this device's HealthKit, until the user taps and the
    /// exporter's idempotency check writes fresh.
    @ViewBuilder
    private func appleHealthRow(for ride: Ride) -> some View {
        if healthKitAuth.isAvailable {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if isExportingToHealth {
                        HStack(spacing: 10) {
                            Image(systemName: "heart.text.square.fill")
                                .font(.callout)
                                .foregroundStyle(.pink)
                            Text("Adding to Apple Health…")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                    } else if ride.healthKitWorkoutUUID != nil {
                        HStack(spacing: 10) {
                            Image(systemName: "heart.text.square.fill")
                                .font(.callout)
                                .foregroundStyle(.pink)
                            Text("In Apple Health")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .font(.callout)
                                .foregroundStyle(.green)
                        }
                    } else {
                        Button {
                            addRideToHealth(ride)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "heart.text.square.fill")
                                    .font(.callout)
                                    .foregroundStyle(.pink)
                                Text("Add to Apple Health")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "plus.circle.fill")
                                    .font(.callout)
                                    .foregroundStyle(.blue)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                if let message = healthExportError {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
            }
        }
    }

    /// Drive a manual Apple Health export for the given ride.  Handles
    /// the auth-then-export sequence as one logical operation: spinner
    /// goes up immediately on tap, comes down once the whole thing has
    /// either succeeded or failed.  On success patches the loaded ride
    /// with the resulting HKWorkout UUID and re-saves — the row then
    /// re-renders into the ✓ state from the updated struct.
    private func addRideToHealth(_ ride: Ride) {
        healthExportError = nil
        isExportingToHealth = true
        Task {
            defer { isExportingToHealth = false }

            // Auth-on-demand.  If the user enabled auto-export earlier
            // this branch is skipped; if they're using the manual button
            // as a first touch, prompt now.
            if !healthKitAuth.canWrite {
                let granted = await healthKitAuth.requestAuthorization()
                guard granted else {
                    // .denied is a hard error (e.g. missing entitlement);
                    // anything else is "user dismissed without granting,"
                    // which is a soft no — phrase the message accordingly.
                    if case .denied = healthKitAuth.state {
                        healthExportError = "Couldn't enable Apple Health access."
                    } else {
                        healthExportError = "Apple Health access not granted."
                    }
                    return
                }
            }

            do {
                let result = try await healthKitExporter.export(ride)
                switch result {
                case .written(let uuid), .alreadyPresent(let uuid):
                    // Quiet save: the stamp is device-local, and
                    // running through onRideSaved would re-enqueue a
                    // multi-MB upload to bumpyride.me for a field the
                    // server doesn't interpret.  See RideStore's
                    // updateHealthKitWorkoutUUID doc for details.
                    store.updateHealthKitWorkoutUUID(uuid, forRideId: ride.id)
                    // Also patch appState so the viewer renders the
                    // updated struct (its `ride` parameter is a value
                    // type; we need to push the new copy through).
                    var updated = ride
                    updated.healthKitWorkoutUUID = uuid
                    appState.loadedRide = updated
                case .unavailable:
                    healthExportError = "Apple Health isn't available on this device."
                }
            } catch {
                // Underlying cause already logged by HealthKitExporter.
                // User-visible message stays generic; tapping again
                // will retry.
                healthExportError = "Couldn't add to Apple Health. Try again."
            }
        }
    }

    /// Dispatch the chart-area content for the current view mode.
    /// Extracted so `viewerContent` stays readable and the per-mode
    /// branches don't repeat the `.frame` / `.padding` chrome.
    @ViewBuilder
    private func chartArea(for ride: Ride, mode: MapViewMode, brakeEvents: [BrakeEvent], closeCalls: [CloseCall]) -> some View {
        switch mode {
        case .bumps:
            SessionBumpinessChart(
                points: ride.points,
                scrubIndex: clampedScrub(for: ride),
                zoom: zoom,
                settings: settings
            )
        case .brakes:
            brakeEventList(for: ride, events: brakeEvents)
        case .closeCalls:
            closeCallEventList(for: ride, calls: closeCalls)
        }
    }

    /// Bumpiness / Brakes picker, shown above the chart area.  Same style as
    /// the Bump Map tab's view-mode chip for visual consistency.
    private var playbackModeChip: some View {
        Picker("View", selection: $settings.mapViewMode) {
            ForEach(MapViewMode.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    /// Scrollable list of brake events in this ride.  Each row jumps the
    /// scrubber to the matching point when tapped, which in turn moves the
    /// route map's highlight pin to that location.  Empty-state messages
    /// handle the two zero-events cases distinctly:
    /// - `brakeEvents == nil`: detection hasn't run yet.  Most likely the
    ///   user opened a legacy ride before the reprocessor finished.  Tell
    ///   them it's pending.
    /// - `brakeEvents == []`: detection ran and found nothing.  Celebrate it.
    @ViewBuilder
    private func brakeEventList(for ride: Ride, events: [BrakeEvent]) -> some View {
        if ride.brakeEvents == nil {
            emptyBrakesPanel(
                icon: "hourglass",
                title: "Detecting…",
                subtitle: "Brake detection runs in the background on rides recorded before this feature existed. Check back in a moment."
            )
        } else if events.isEmpty {
            emptyBrakesPanel(
                icon: "hand.thumbsup",
                title: "No hard brakes",
                subtitle: "Nice and smooth — no decelerations above the threshold on this ride."
            )
        } else {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(events.enumerated()), id: \.element.id) { idx, event in
                        brakeEventRow(index: idx + 1, event: event, ride: ride)
                    }
                }
                .padding(.vertical, 8)
            }
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func emptyBrakesPanel(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// One row in the brake event list.  Tapping snaps the scrubber to the
    /// nearest ride point in time to the event's timestamp.
    private func brakeEventRow(index: Int, event: BrakeEvent, ride: Ride) -> some View {
        Button {
            scrubIndex = nearestPointIndex(to: event.timestamp, in: ride.points)
        } label: {
            HStack(spacing: 12) {
                Text("\(index)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .trailing)

                VStack(alignment: .leading, spacing: 2) {
                    Text(elapsedLabel(for: event, in: ride))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.primary)
                    Text(durationLabel(for: event))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(decelLabel(for: event))
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(decelColor(for: event))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(.tertiarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    /// "mm:ss into the ride" timestamp display for an event.
    private func elapsedLabel(for event: BrakeEvent, in ride: Ride) -> String {
        let elapsed = max(0, event.timestamp.timeIntervalSince(ride.startedAt))
        return Formatters.duration(elapsed)
    }

    /// "sustained 1.2 s" subtext.
    private func durationLabel(for event: BrakeEvent) -> String {
        String(format: "sustained %.1f s", event.durationSeconds)
    }

    /// Peak deceleration formatted as g-units.  Converting m/s² → g
    /// (÷ 9.80665) keeps the readout consistent with the bumpiness display,
    /// which is already in g across the app.
    private func decelLabel(for event: BrakeEvent) -> String {
        let g = event.peakDecelerationMPS2 / 9.80665
        return String(format: "%.2f g", g)
    }

    /// Color the peak-decel readout on a count-style scale.  Mirrors the
    /// brake-map tile colors: yellow → orange → red → purple as severity
    /// rises.  Thresholds in m/s² are picked to be slightly looser than
    /// the detector's 2.5 m/s² floor so a borderline event renders
    /// distinguishably from a moderate one.
    private func decelColor(for event: BrakeEvent) -> Color {
        let d = event.peakDecelerationMPS2
        if d < 3.0 { return Color(red: 0.85, green: 0.70, blue: 0.10) }      // yellow
        if d < 4.0 { return Color(red: 0.95, green: 0.45, blue: 0.10) }      // orange
        if d < 5.0 { return Color(red: 0.85, green: 0.15, blue: 0.15) }      // red
        return Color(red: 0.55, green: 0.20, blue: 0.80)                      // purple
    }

    /// Scrollable list of user-reported close calls in this ride.  Same
    /// interaction as the brake-event list — tapping a row jumps the
    /// scrubber to the nearest ride point in time.  Empty-state messages
    /// distinguish the two zero-call cases:
    /// - `closeCallEvents == nil`: ride predates the feature.  Nothing to
    ///   log because the button didn't exist when it was recorded.
    /// - `closeCallEvents == []`: feature was available, no calls logged.
    @ViewBuilder
    private func closeCallEventList(for ride: Ride, calls: [CloseCall]) -> some View {
        if ride.closeCallEvents == nil {
            emptyBrakesPanel(
                icon: "calendar.badge.exclamationmark",
                title: "Predates this feature",
                subtitle: "Close-call reporting was added after this ride was recorded — the button didn't exist yet."
            )
        } else if calls.isEmpty {
            emptyBrakesPanel(
                icon: "hand.thumbsup",
                title: "No close calls",
                subtitle: "You didn't log any close calls on this ride."
            )
        } else {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(calls.enumerated()), id: \.element.id) { idx, call in
                        closeCallEventRow(index: idx + 1, call: call, ride: ride)
                    }
                }
                .padding(.vertical, 8)
            }
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    /// One row in the close-call list.  Simpler than the brake row (no
    /// peak / duration since close calls only carry time + location), but
    /// same tap-to-scrub interaction.  Long-press surfaces a Delete option
    /// in a context menu — the way to remove an accidental tap that
    /// slipped through the 5 s live undo window.
    ///
    /// Brake-event rows are intentionally NOT given a Delete option:
    /// brakes are auto-detected, so any deletion would be re-applied next
    /// time the detector runs.  Only user-initiated events make sense to
    /// edit; the rest are derived from the underlying points.
    private func closeCallEventRow(index: Int, call: CloseCall, ride: Ride) -> some View {
        Button {
            scrubIndex = nearestPointIndex(to: call.timestamp, in: ride.points)
        } label: {
            HStack(spacing: 12) {
                Text("\(index)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .trailing)

                VStack(alignment: .leading, spacing: 2) {
                    Text(elapsedLabel(for: call, in: ride))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.primary)
                    Text("close call")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Violet diamond matching the close-call map's color so
                // the visual identity stays consistent across surfaces.
                Image(systemName: "diamond.fill")
                    .font(.callout)
                    .foregroundStyle(Color(red: 0.55, green: 0.25, blue: 0.85))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(.tertiarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .contextMenu {
            Button(role: .destructive) {
                deleteCloseCall(call)
            } label: {
                Label("Delete close call", systemImage: "trash")
            }
        }
    }

    /// Remove a single close call from the currently-loaded ride and
    /// persist.  Re-saves through `store.save(_:)` so the standard fan-out
    /// happens — the sync queue picks up the updated payload, and the
    /// in-memory store + iCloud both reflect the deletion.  If the
    /// closeCallEvents array becomes empty, we leave it as `[]` rather
    /// than nilling it — the user did intentionally have close-call
    /// reporting active on this ride, and `[]` is the truthful state.
    private func deleteCloseCall(_ call: CloseCall) {
        guard var ride = appState.loadedRide else { return }
        guard var events = ride.closeCallEvents else { return }
        events.removeAll { $0.id == call.id }
        ride.closeCallEvents = events
        store.save(ride)
        appState.loadedRide = ride
    }

    /// "mm:ss into the ride" timestamp for a close-call row.
    private func elapsedLabel(for call: CloseCall, in ride: Ride) -> String {
        let elapsed = max(0, call.timestamp.timeIntervalSince(ride.startedAt))
        return Formatters.duration(elapsed)
    }

    /// Find the index of the ride point whose timestamp is closest to
    /// `target`.  Linear scan — fine for typical ride sizes.  Returns 0 for
    /// an empty array (defensive; callers should already guard).
    private func nearestPointIndex(to target: Date, in points: [RidePoint]) -> Int {
        guard !points.isEmpty else { return 0 }
        var bestIdx = 0
        var bestDelta = abs(points[0].timestamp.timeIntervalSince(target))
        for i in 1..<points.count {
            let delta = abs(points[i].timestamp.timeIntervalSince(target))
            if delta < bestDelta {
                bestDelta = delta
                bestIdx = i
            }
        }
        return bestIdx
    }

    private func scrubberSection(for ride: Ride) -> some View {
        let maxIdx = max(0, ride.points.count - 1)
        return VStack(spacing: 8) {
            HStack {
                Text(scrubTimeLabel(for: ride))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if ride.points.indices.contains(clampedScrub(for: ride)) {
                    let p = ride.points[clampedScrub(for: ride)]
                    Text(String(format: "%.2f g", p.bumpiness))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(settings.color(for: p.bumpiness))
                }
            }
            Slider(
                value: Binding(
                    get: { Double(clampedScrub(for: ride)) },
                    set: { scrubIndex = Int($0.rounded()) }
                ),
                in: 0...Double(maxIdx),
                step: 1
            )
            HStack(spacing: 8) {
                Image(systemName: "arrow.left.and.right.square")
                    .foregroundStyle(.secondary)
                Slider(value: $zoom, in: 0.05...1.0)
                Text(zoomLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var zoomLabel: String {
        if zoom >= 0.999 { return "All" }
        return String(format: "%.0f%%", zoom * 100)
    }

    private func scrubTimeLabel(for ride: Ride) -> String {
        let idx = clampedScrub(for: ride)
        guard ride.points.indices.contains(idx) else { return "—" }
        let elapsed = ride.points[idx].timestamp.timeIntervalSince(ride.startedAt)
        return "\(Formatters.duration(max(0, elapsed))) / \(Formatters.duration(ride.duration))"
    }

    private func clampedScrub(for ride: Ride) -> Int {
        let maxIdx = max(0, ride.points.count - 1)
        return min(max(0, scrubIndex), maxIdx)
    }

    // MARK: Stats

    /// Three-column ride summary at the bottom of the playback view.
    /// Three layouts, one per mode:
    ///
    /// - **Bumps**: Points / Distance / Max bumpiness.  Original.
    /// - **Brakes**: Events / Distance / Max decel — per-brake stats.
    /// - **Close Calls**: Calls / Distance / — — center column stays
    ///   useful (route length) but there's no third aggregate worth
    ///   showing (close calls have no magnitude), so we omit it
    ///   gracefully with an em-dash rather than inventing a metric.
    /// Stats bar at the bottom of the recording / playback views.
    ///
    /// `elapsedTime`, when non-nil, switches to the live-mode layout:
    ///   Time / Distance / Avg / Max
    /// where Avg is `distance / elapsedTime` converted to mph.  Playback
    /// callers omit `elapsedTime` and get the original three-column
    /// layout with mode-specific stats in the first and last slots.
    private func statsBar(
        pointsCount: Int,
        distance: Double,
        maxBump: Double,
        brakeEvents: [BrakeEvent],
        closeCalls: [CloseCall],
        mode: MapViewMode,
        elapsedTime: TimeInterval? = nil
    ) -> some View {
        HStack(spacing: 16) {
            if let elapsedTime {
                stat(label: "Time", value: Formatters.duration(elapsedTime))
            } else {
                switch mode {
                case .bumps:
                    stat(label: "Points", value: "\(pointsCount)")
                case .brakes:
                    stat(label: "Events", value: "\(brakeEvents.count)")
                case .closeCalls:
                    stat(label: "Calls", value: "\(closeCalls.count)")
                }
            }
            Divider().frame(height: 24)
            stat(label: "Distance", value: Formatters.distance(distance))
            // Average speed slot — live mode only.  Trip-average (total
            // distance / total elapsed including stops), not moving-
            // average; mirrors what most cycling apps default to.
            // Guards against zero elapsed (first frame after start) so
            // we don't flash NaN/Inf for a tick.
            if let elapsedTime, elapsedTime > 0 {
                Divider().frame(height: 24)
                let avgMps = distance / elapsedTime
                stat(label: "Avg", value: Formatters.speed(avgMps))
            }
            Divider().frame(height: 24)
            switch mode {
            case .bumps:
                stat(label: "Max", value: String(format: "%.2fg", maxBump))
            case .brakes:
                let maxDecelG = (brakeEvents.map(\.peakDecelerationMPS2).max() ?? 0) / 9.80665
                stat(label: "Max", value: brakeEvents.isEmpty ? "—" : String(format: "%.2fg", maxDecelG))
            case .closeCalls:
                // No intensity associated with a close call.  Show an
                // em-dash placeholder rather than forcing a meaningless
                // metric into the slot.
                stat(label: "—", value: "—")
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func stat(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit().weight(.medium))
        }
        .frame(maxWidth: .infinity)
    }

    /// Cap on the number of recent `RidePoint`s passed to the live
    /// `RouteMapView`.  On a long ride the recorder's `points` array can
    /// grow into the thousands, and the map renders one `MapPolyline`
    /// view per segment — that view-count grows with the array and
    /// makes the live view increasingly laggy.  Capping to the most
    /// recent ~1000 keeps the SwiftUI view hierarchy bounded.
    ///
    /// 1000 points ≈ 16 min of riding at ~1 Hz sampling.  The map
    /// follows the user (`followUser: true` during recording), so older
    /// portions of the route are off-screen anyway; clipping them from
    /// the view hierarchy is a no-op visually.  Saved-ride playback
    /// uses the full points array, so the trim only applies to the
    /// live recording UI.
    private static let maxLivePolylinePoints: Int = 1000

    /// Trailing window of points fed to the live `RouteMapView`.  See
    /// `maxLivePolylinePoints` for why we cap.  Cheap: `Array.suffix` is
    /// O(min(count, max)).
    private var liveDisplayPoints: [RidePoint] {
        let pts = recorder.points
        if pts.count <= Self.maxLivePolylinePoints {
            return pts
        }
        return Array(pts.suffix(Self.maxLivePolylinePoints))
    }

    // MARK: Save sheet

    /// Caption shown under the Sensing toggle reflecting what `MountStyleDetector`
    /// concluded.  The toggle's initial state was primed from this verdict, so the
    /// caption explains *why* the toggle is in its current position.
    private var detectionCaption: String? {
        guard let detection = pendingMountDetection else { return nil }
        switch detection.verdict {
        case .likelyPocket:
            return "Auto-detected as pocket mode based on this ride's vibration signature."
        case .likelyMounted:
            return "Auto-detected as mounted based on this ride's vibration signature."
        case .ambiguous:
            return "Vibration signature was inconclusive — defaulting to mounted. Flip if needed."
        }
    }

    private var saveSheet: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Ride title", text: $editableTitle)
                        .textInputAutocapitalization(.sentences)
                }

                Section {
                    Toggle(isOn: $pendingPocketMode) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Recorded in pocket mode")
                            if let caption = detectionCaption {
                                Text(caption)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text("Was the phone on your body during this ride?")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Sensing")
                } footer: {
                    Text("BumpyRide reads the 1–3 Hz cadence band against the 3+ Hz bump band and tags the ride accordingly. If pocket: the saved bumpiness gets recomputed through a 3 Hz high-pass before storage. You can edit the tag from the saved ride's menu later.")
                }

                if let ride = pendingRide {
                    Section("Summary") {
                        LabeledContent("Distance", value: Formatters.distance(ride.distanceMeters))
                        LabeledContent("Duration", value: Formatters.duration(ride.duration))
                        LabeledContent("Samples", value: "\(ride.points.count)")
                        LabeledContent("Max bumpiness", value: String(format: "%.2f g", ride.maxBumpiness))
                    }
                }
            }
            .navigationTitle("Save Ride")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard", role: .destructive) {
                        showingSaveSheet = false
                        recorder.reset()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if var ride = pendingRide {
                            ride.title = editableTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Ride.defaultTitle(for: ride.startedAt)
                                : editableTitle
                            ride.pocketMode = pendingPocketMode
                            // v2 rides are recorded raw — if this is pocket-tagged,
                            // re-run each point's accelWindow through the HPF and
                            // recompute bumpiness so the saved values match the
                            // "pocket-mode RMS" semantic (no cadence noise).
                            if pendingPocketMode {
                                ride = ride.reprocessedWithPocketHPF()
                            }
                            // Brake detection runs after pocket-mode reprocessing
                            // because the algorithm itself doesn't depend on
                            // bumpiness — order doesn't actually matter, but
                            // semantically "all post-hoc analysis happens here,
                            // in one place" reads cleaner.  Always called: an
                            // empty result becomes brakeEvents = [], which is
                            // the "detected, no events" signal the reprocessor
                            // distinguishes from nil.
                            ride = ride.withDetectedBrakeEvents()
                            store.save(ride)
                            appState.loadedRide = ride
                        }
                        showingSaveSheet = false
                        recorder.reset()
                    }
                }
            }
        }
    }

    // MARK: Export

    private func exportCurrentRide() {
        guard let ride = appState.loadedRide else { return }
        isExporting = true
        Task {
            do {
                let image = try await RideImageExporter.export(ride: ride, settings: settings)
                RideImageExporter.saveToPhotos(image)
                exportAlertTitle = "Saved to Photos"
                exportAlertMessage = "Your ride image was saved to your photo library."
            } catch {
                exportAlertTitle = "Export Failed"
                exportAlertMessage = "Couldn't build the ride image: \(error.localizedDescription)"
            }
            isExporting = false
            showExportAlert = true
        }
    }
}

private struct RideViewNavModifier<Toolbar: ToolbarContent>: ViewModifier {
    let title: String
    @ToolbarContentBuilder let toolbar: () -> Toolbar

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar() }
    }
}

private struct RideViewLifecycleModifier: ViewModifier {
    let recorder: RideRecorder
    let loadedId: UUID?
    let onAppearAction: () -> Void
    let onStateChange: (RideRecorder.State) -> Void
    let onLoadedChange: () -> Void
    let onDisappearAction: () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear(perform: onAppearAction)
            .onChange(of: recorder.state) { _, newState in onStateChange(newState) }
            .onChange(of: loadedId) { _, _ in onLoadedChange() }
            .onDisappear(perform: onDisappearAction)
    }
}

private struct RideViewAlertsModifier: ViewModifier {
    @Binding var showingRename: Bool
    @Binding var renameText: String
    let onRenameSave: () -> Void

    @Binding var showingDelete: Bool
    let onDelete: () -> Void

    @Binding var showingStartOver: Bool
    let onStartOver: () -> Void

    @Binding var showingExport: Bool
    let exportTitle: String
    let exportMessage: String

    func body(content: Content) -> some View {
        content
            .alert("Rename Ride", isPresented: $showingRename) {
                TextField("Title", text: $renameText)
                Button("Cancel", role: .cancel) {}
                Button("Save", action: onRenameSave)
            }
            .alert("Delete Ride?", isPresented: $showingDelete) {
                Button("Delete", role: .destructive, action: onDelete)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This ride will be permanently deleted.")
            }
            .alert("Start a new ride?", isPresented: $showingStartOver) {
                Button("Start New", role: .destructive, action: onStartOver)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The currently loaded ride will be cleared from view (it remains saved).")
            }
            .alert(exportTitle, isPresented: $showingExport) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportMessage)
            }
    }
}
