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
    var settings: AppSettings

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
                store.save(updated)
                if let second = newSecond { store.save(second) }
                appState.loadedRide = updated
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
            appState.clearLoaded()
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
                    appState.clearLoaded()
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

    private var liveContent: some View {
        VStack(spacing: 12) {
            SeismographView(
                samples: recorder.liveSamples,
                bumpiness: recorder.currentBumpiness,
                capacity: recorder.motion.windowCapacity,
                settings: settings
            )
            .frame(height: 160)
            .padding(.horizontal)

            RouteMapView(
                points: recorder.points,
                followUser: recorder.state == .recording,
                highlightIndex: nil,
                settings: settings
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)

            statsBar(
                pointsCount: recorder.points.count,
                distance: currentLiveDistance,
                maxBump: currentLiveMaxBumpiness
            )
            .padding(.horizontal)

            if let banner = permissionBanner() {
                banner
                    .padding(.horizontal)
            }

            controlButtons
                .padding(.horizontal)
                .padding(.bottom, 8)
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
        return locationOK && recorder.motion.isAvailable
    }

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
                Button(role: .destructive) {
                    if let ride = recorder.stop() {
                        presentSaveSheet(for: ride)
                    } else {
                        recorder.reset()
                    }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
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
        VStack(spacing: 12) {
            SessionBumpinessChart(
                points: ride.points,
                scrubIndex: clampedScrub(for: ride),
                zoom: zoom,
                settings: settings
            )
            .frame(height: 160)
            .padding(.horizontal)

            RouteMapView(
                points: ride.points,
                followUser: false,
                highlightIndex: clampedScrub(for: ride),
                settings: settings
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)

            scrubberSection(for: ride)
                .padding(.horizontal)

            statsBar(
                pointsCount: ride.points.count,
                distance: ride.distanceMeters,
                maxBump: ride.maxBumpiness
            )
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

    private func statsBar(pointsCount: Int, distance: Double, maxBump: Double) -> some View {
        HStack(spacing: 16) {
            stat(label: "Points", value: "\(pointsCount)")
            Divider().frame(height: 24)
            stat(label: "Distance", value: Formatters.distance(distance))
            Divider().frame(height: 24)
            stat(label: "Max", value: String(format: "%.2fg", maxBump))
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

    private var currentLiveDistance: Double {
        let pts = recorder.points
        guard pts.count > 1 else { return 0 }
        var d: Double = 0
        for i in 1..<pts.count {
            let a = CLLocation(latitude: pts[i-1].latitude, longitude: pts[i-1].longitude)
            let b = CLLocation(latitude: pts[i].latitude, longitude: pts[i].longitude)
            d += b.distance(from: a)
        }
        return d
    }

    private var currentLiveMaxBumpiness: Double {
        recorder.points.map(\.bumpiness).max() ?? recorder.currentBumpiness
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
