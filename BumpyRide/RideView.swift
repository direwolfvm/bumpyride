import SwiftUI
import UIKit
import CoreLocation

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

    /// Per-ride pocket-mode override.  Initialized from `settings.pocketModeEnabled`
    /// when the view first appears with an idle recorder, and reset to the same
    /// default after each ride ends.  Mid-ride toggling changes the live filter
    /// (and seismograph readout) but doesn't change the `pocketMode` tag stamped
    /// onto the saved Ride — that's snapshotted at `recorder.start()` time.
    @State private var pocketEnabled: Bool = false

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
                        // When the view appears with an idle recorder, sync the per-ride
                        // pocket toggle to the user's default.  Skip if we're mid-recording
                        // so a tab-switch doesn't clobber a value the user explicitly set.
                        if recorder.state == .idle {
                            pocketEnabled = settings.pocketModeEnabled
                            recorder.motion.highPassEnabled = pocketEnabled
                        }
                        setIdleTimer(disabled: recorder.state == .recording)
                    },
                    onStateChange: { newState in
                        setIdleTimer(disabled: newState == .recording)
                        // After a ride ends (finished → idle via recorder.reset()), snap
                        // the toggle back to whatever the current default is — so the next
                        // ride starts fresh from Settings rather than carrying the last
                        // override forward.
                        if newState == .idle {
                            pocketEnabled = settings.pocketModeEnabled
                            recorder.motion.highPassEnabled = pocketEnabled
                        }
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

    private func commitRename() {
        let t = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, var ride = appState.loadedRide else { return }
        ride.title = t
        store.save(ride)
        appState.loadedRide = ride
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

            pocketToggleRow
                .padding(.horizontal)

            controlButtons
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
    }

    /// Per-ride pocket-mode override.  The toggle binding propagates the new value
    /// to the live motion filter immediately, so the seismograph reflects the
    /// change without restarting recording.  Default is reset to
    /// `settings.pocketModeEnabled` whenever the recorder returns to .idle.
    private var pocketToggleRow: some View {
        Toggle(isOn: pocketBinding) {
            HStack(spacing: 10) {
                Image(systemName: "wave.3.right.circle.fill")
                    .font(.title3)
                    .foregroundStyle(pocketEnabled ? Color.accentColor : Color.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Pocket mode")
                        .font(.callout.weight(.medium))
                    Text("Filter pedaling motion when the phone is on your body")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var pocketBinding: Binding<Bool> {
        Binding(
            get: { pocketEnabled },
            set: { newValue in
                pocketEnabled = newValue
                recorder.motion.highPassEnabled = newValue
            }
        )
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

            case .recording:
                Button(role: .destructive) {
                    if let ride = recorder.stop() {
                        pendingRide = ride
                        editableTitle = ride.title
                        showingSaveSheet = true
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

    private var saveSheet: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Ride title", text: $editableTitle)
                        .textInputAutocapitalization(.sentences)
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
