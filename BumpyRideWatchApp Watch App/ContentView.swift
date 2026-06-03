import SwiftUI
import WatchKit

/// Phase G UI.  A three-page `TabView` (page style, swipe between)
/// matching the v1.6 design:
///
///   Page 1 — Controls (default).  Close-call button dominates the
///   screen while recording; Pause/Stop below it.  Adapts to .paused
///   (Resume/Stop) and .idle/.finished (connectivity / "start from
///   iPhone" hint).  Default landing page so a wrist-raise after
///   spotting a hazard surfaces the close-call button immediately.
///
///   Page 2 — Time + Distance.  Large monospaced numbers for the
///   two "where am I in this ride" metrics.
///
///   Page 3 — Bumpiness.  Max + average for the "how rough is this
///   ride" view.
///
/// The Phase B/C/D/E ping button and diagnostic snapshot row have
/// been removed — they were debug affordances explicitly tagged for
/// Phase G cleanup.  Connectivity state is now folded into the
/// controls page's idle layout.
struct ContentView: View {
    @Bindable var session: WatchSessionManager

    /// Brief "Logged ✓" confirmation flag for the close-call button.
    /// Set true on tap, auto-reset to false after `closeCallFeedbackSeconds`
    /// so the user has visual confirmation that their tap registered
    /// without having to read the (potentially lagging) snapshot.
    @State private var closeCallFlash: Bool = false

    /// Seconds the close-call button shows its "Logged ✓" state.
    /// Doubles as a debounce — the button is disabled during this
    /// window so a frantic double-tap doesn't queue two events.
    private static let closeCallFeedbackSeconds: TimeInterval = 2.0

    /// Phase F stop-confirmation alert visibility.
    @State private var showingStopConfirm: Bool = false

    /// Phase F post-save "Saved" toast (overlay across all pages).
    @State private var showingSavedToast: Bool = false

    /// Seconds the "Saved" toast remains visible after a watch-
    /// initiated stop+save.
    private static let savedToastSeconds: TimeInterval = 2.0

    var body: some View {
        TabView {
            controlPage
                .tag(0)
            timeDistancePage
                .tag(1)
            bumpinessPage
                .tag(2)
        }
        .tabViewStyle(.page)
        .overlay {
            if showingSavedToast {
                savedToast
                    .transition(.opacity.combined(with: .scale))
            }
        }
        .animation(.easeOut(duration: 0.18), value: showingSavedToast)
    }

    // MARK: - Page 1: Controls (default)

    @ViewBuilder
    private var controlPage: some View {
        let s = session.lastSnapshot
        VStack(spacing: 8) {
            // Top status sliver — tiny indicator of what the iPhone is
            // doing.  Helps the rider confirm at a glance that the
            // watch is showing fresh state.
            stateSliver(for: s.state)
                .font(.caption2)
                .foregroundStyle(.secondary)

            switch s.state {
            case .recording:
                closeCallButton
                Spacer(minLength: 4)
                pauseOnlyRow
            case .paused:
                pausedIndicator
                Spacer(minLength: 4)
                stopResumeRow
            case .idle, .finished:
                Spacer(minLength: 4)
                idleHint
                Spacer(minLength: 4)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 12)  // Clearance for page dots.
        .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private func stateSliver(for state: WatchSnapshot.RecorderState) -> some View {
        switch state {
        case .recording:
            Label("Recording", systemImage: "record.circle.fill")
                .foregroundStyle(.red)
        case .paused:
            Label("Paused", systemImage: "pause.circle.fill")
                .foregroundStyle(.orange)
        case .finished:
            Label("Finished", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .idle:
            connectivitySliver
        }
    }

    /// Sliver shown when the iPhone is idle — collapses connectivity
    /// state into a single line so the bulk of the screen is the
    /// idle hint, not a wall of status text.
    @ViewBuilder
    private var connectivitySliver: some View {
        switch session.sessionState {
        case .unavailable:
            Label("Connectivity unavailable", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .notActivated, .activating:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Connecting…")
            }
        case .failed:
            Label("Connection failed", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        case .activated:
            if session.isReachable {
                Label("Phone connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Phone not reachable", systemImage: "iphone.slash")
            }
        }
    }

    /// Idle/finished default hint — encourages starting a ride from
    /// the iPhone.  Big bike icon + short message.  No buttons because
    /// starting a ride from the watch isn't supported in v1.6 (would
    /// require the watch to own GPS / motion, which is a much larger
    /// feature scoped out per the v1.6 plan).
    private var idleHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "bicycle")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text("Start a ride from your iPhone")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// Big purple close-call button.  Fills most of the page while
    /// recording — the safety affordance.  See `tapCloseCall` for
    /// behavior.
    ///
    /// Label uses `.subheadline` (smaller than the original headline)
    /// with `minimumScaleFactor(0.7)` so the text shrinks-to-fit
    /// on small watches rather than wrapping or clipping against
    /// the button's rounded edges.
    @ViewBuilder
    private var closeCallButton: some View {
        Button {
            tapCloseCall()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: closeCallFlash ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 38, weight: .bold))
                Text(closeCallFlash ? "Logged" : "Close Call")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(closeCallFlash ? .green : .purple)
        .disabled(closeCallFlash)
    }

    /// Big "Paused" indicator shown when the iPhone is in `.paused`
    /// state.  Visual signal that the ride is alive but sampling has
    /// halted; reassures the user that taps below will resume rather
    /// than start fresh.
    private var pausedIndicator: some View {
        VStack(spacing: 8) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(.orange)
            Text("Ride Paused")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Single full-width Pause button shown while recording.
    /// Deliberately the only control available — to Stop a ride you
    /// must first Pause it, which forces an explicit two-step
    /// (Pause → Stop or Pause → Resume).  Makes accidental Stop
    /// during an active ride much harder; bumpy roads + jersey
    /// pocket make for plenty of unintended taps.
    private var pauseOnlyRow: some View {
        Button {
            session.send(.pause)
        } label: {
            Image(systemName: "pause.fill")
                .font(.body)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.orange)
        .controlSize(.small)
    }

    /// Stop + Resume button row, shown while paused.  Stop is left
    /// (the "I really meant it" second step of the two-tap stop flow,
    /// gated by confirmation); Resume is right (the recovery action
    /// when the user paused only to take a break or correct a
    /// misclick on the previous Pause).
    private var stopResumeRow: some View {
        HStack(spacing: 6) {
            Button {
                showingStopConfirm = true
            } label: {
                Image(systemName: "stop.fill")
                    .font(.body)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)

            Button {
                session.send(.resume)
            } label: {
                Image(systemName: "play.fill")
                    .font(.body)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.green)
        }
        .controlSize(.small)
        .stopConfirmAlert(
            isPresented: $showingStopConfirm,
            onConfirm: confirmStopAndSave
        )
    }

    // MARK: - Page 2: Time + Distance

    private var timeDistancePage: some View {
        let s = session.lastSnapshot
        let active = s.state != .idle
        return statsPageScaffold(title: "Ride Stats") {
            statRow(
                label: "Elapsed",
                value: active ? Self.formatElapsed(s.elapsedSeconds) : "—"
            )
            statRow(
                label: "Distance",
                value: active ? Self.formatDistance(s.distanceMeters) : "—"
            )
        }
    }

    // MARK: - Page 3: Bumpiness

    private var bumpinessPage: some View {
        let s = session.lastSnapshot
        let active = s.state != .idle
        return statsPageScaffold(title: "Bumpiness") {
            statRow(
                label: "Max",
                value: active ? String(format: "%.2f g", s.maxBumpiness) : "—"
            )
            statRow(
                label: "Avg",
                value: active ? String(format: "%.2f g", s.averageBumpiness) : "—"
            )
        }
    }

    /// Shared layout chrome for stats pages.  Title at top in caption
    /// style; content vertically centered.
    private func statsPageScaffold<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 14) {
                content()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 12)  // Page dots clearance.
    }

    /// One stat — small label above, big monospaced value below.
    /// Stacked vertically so it reads as a single labeled number
    /// even at a glance.
    private func statRow(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title2, design: .rounded).monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    // MARK: - Saved toast (overlay)

    /// Centered green-check "Saved" pill shown briefly after a
    /// watch-initiated stop+save.  Renders as an overlay across all
    /// pages so the user sees it regardless of which one they're on
    /// when they tap Stop & Save.
    private var savedToast: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
            Text("Saved")
                .font(.headline)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Actions

    private func tapCloseCall() {
        session.send(.closeCall)
        WKInterfaceDevice.current().play(.success)
        closeCallFlash = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.closeCallFeedbackSeconds * 1_000_000_000))
            closeCallFlash = false
        }
    }

    private func confirmStopAndSave() {
        session.send(.stop(autoSave: true))
        WKInterfaceDevice.current().play(.success)
        showingSavedToast = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.savedToastSeconds * 1_000_000_000))
            showingSavedToast = false
        }
    }

    // MARK: - Formatters

    private static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    private static func formatDistance(_ meters: Double) -> String {
        let miles = meters / 1609.344
        if miles < 0.1 {
            let feet = meters * 3.28084
            return String(format: "%.0f ft", feet)
        }
        return String(format: "%.2f mi", miles)
    }
}

/// Stop-confirmation alert as a reusable view modifier so both the
/// `.recording` and `.paused` control rows can attach identical
/// confirm UX without duplicating the buttons + message.
private extension View {
    func stopConfirmAlert(
        isPresented: Binding<Bool>,
        onConfirm: @escaping () -> Void
    ) -> some View {
        alert("Stop ride?", isPresented: isPresented) {
            Button("Stop & Save", role: .destructive) {
                onConfirm()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your ride will be saved on your iPhone with the default title.")
        }
    }
}

#Preview {
    ContentView(session: WatchSessionManager())
}
