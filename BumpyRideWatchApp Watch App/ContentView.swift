import SwiftUI
import WatchKit

/// Phase E placeholder UI.  Now contains all four major affordances —
/// connectivity indicator (Phase B), Pause/Stop controls (Phase D),
/// close-call button (Phase E), and the diagnostic snapshot row (Phase
/// C) — laid out as a vertically scrolling stack.  Phase G replaces
/// this with a proper paged TabView where the close-call button is
/// the default page front-and-center.
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

    /// Phase F stop-confirmation alert visibility.  Driven by the Stop
    /// button's tap; the alert's "Stop and save" button fires the
    /// actual auto-save command.
    @State private var showingStopConfirm: Bool = false

    /// Phase F post-save "Saved" toast.  Shown optimistically the
    /// moment the watch sends `.stop(autoSave: true)` — iOS-side save
    /// failures aren't acknowledged back, on the assumption that
    /// local writes rarely fail and the user would notice on the
    /// phone if they did.  Auto-clears after
    /// `savedToastSeconds`.
    @State private var showingSavedToast: Bool = false

    /// Seconds the "Saved" toast remains visible after a watch-
    /// initiated stop+save.  Short enough to feel snappy, long
    /// enough to be readable on a glance.
    private static let savedToastSeconds: TimeInterval = 2.0

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "bicycle")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("BumpyRide")
                .font(.headline)

            Divider()
                .padding(.horizontal, 8)

            connectivityRow
                .font(.caption2)

            // Phase B verification affordance.  Sends a ping to iOS
            // and updates `session.pingResult` with the round-trip
            // outcome — gives the user explicit proof the transport
            // is working, vs. just trusting `isReachable`.  This row
            // goes away in Phase G when the real UI lands.
            if case .activated = session.sessionState {
                pingRow
                    .font(.caption2)

                // Phase E close-call button.  The safety affordance —
                // big tap target, haptic on confirm, visible only when
                // the iPhone is recording so it's only there when it
                // can actually do something useful.  In Phase G this
                // moves to the default page of the paged TabView and
                // dominates the screen.
                closeCallButton

                // Phase D control row.  Visible only when the iPhone
                // says it's mid-ride; gives the watch user a way to
                // pause/resume/stop without picking up the phone.
                // Phase F adds the stop confirmation alert + auto-save.
                controlsRow

                snapshotRow
                    .font(.caption2)
            }
        }
        .padding(.horizontal, 6)
        .multilineTextAlignment(.center)
        .overlay {
            if showingSavedToast {
                savedToast
                    .transition(.opacity.combined(with: .scale))
            }
        }
        .animation(.easeOut(duration: 0.18), value: showingSavedToast)
    }

    /// Centered green-check "Saved" pill shown briefly after a
    /// watch-initiated stop+save.  Opaque enough to read against any
    /// background, sized small so it doesn't fully obscure the
    /// underlying snapshot during fade-out.
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

    /// Phase E close-call button.  Visible only while the iPhone is
    /// actively recording — surfacing it during `.paused` or
    /// `.idle`/`.finished` would invite taps that no-op on the iOS
    /// side (the recorder's `canLogCloseCall` gates on `.recording`).
    ///
    /// On tap:
    ///   1. Send `.closeCall` via `session.send` (sendMessage when
    ///      reachable, transferUserInfo fallback for offline-replay).
    ///   2. Fire `.success` haptic on the watch so the rider knows the
    ///      tap registered without looking down at the screen.
    ///   3. Flash a green "Logged ✓" state for `closeCallFeedbackSeconds`,
    ///      doubling as a debounce so a frantic double-tap doesn't
    ///      queue two events.
    ///
    /// Per the v1.6 spec the close-call affordance NEVER silently
    /// fails — the haptic fires unconditionally on tap so the rider
    /// gets confirmation even if the WCSession transport happens to
    /// be queueing for offline replay at that moment.
    @ViewBuilder
    private var closeCallButton: some View {
        let s = session.lastSnapshot
        if s.state == .recording {
            Button {
                tapCloseCall()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: closeCallFlash ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.title3)
                    Text(closeCallFlash ? "Logged" : "Close call")
                        .font(.callout.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(closeCallFlash ? .green : .purple)
            .disabled(closeCallFlash)
        }
    }

    private func tapCloseCall() {
        session.send(.closeCall)
        WKInterfaceDevice.current().play(.success)
        closeCallFlash = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.closeCallFeedbackSeconds * 1_000_000_000))
            closeCallFlash = false
        }
    }

    /// Phase D control surface.  Rendered when the iPhone snapshot
    /// reports `.recording` or `.paused`.  Pause/Resume swap based on
    /// state; Stop is always available (and currently fires-and-forgets
    /// — Phase F adds confirmation + auto-save).
    ///
    /// Buttons send via `session.send(_:)`, which uses sendMessage
    /// when reachable and transferUserInfo as a queued fallback.  No
    /// optimistic local state — the next snapshot push from iOS (the
    /// Phase C fast-path triggered by handle(command:)) updates the
    /// UI within tens of ms.
    @ViewBuilder
    private var controlsRow: some View {
        let s = session.lastSnapshot
        if s.state == .recording || s.state == .paused {
            HStack(spacing: 6) {
                Button {
                    if s.state == .recording {
                        session.send(.pause)
                    } else {
                        session.send(.resume)
                    }
                } label: {
                    Image(systemName: s.state == .recording ? "pause.fill" : "play.fill")
                        .font(.body)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(s.state == .recording ? .orange : .green)

                Button {
                    // Phase F: confirm before stopping so a misclick
                    // on a bouncy ride doesn't accidentally wrap up
                    // a recording.  The actual command goes out from
                    // the alert's confirm action below.
                    showingStopConfirm = true
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.body)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .controlSize(.small)
            .alert("Stop ride?", isPresented: $showingStopConfirm) {
                Button("Stop & Save", role: .destructive) {
                    confirmStopAndSave()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your ride will be saved on your iPhone with the default title.")
            }
        }
    }

    /// Confirmed stop+save path.  Sends `.stop(autoSave: true)`, which
    /// the iOS WatchCoordinator routes through the full finalize-and-
    /// save pipeline (default title, pocket-mode detection, brake
    /// detection, persist).  Locally displays a green "Saved" toast
    /// for `savedToastSeconds` — optimistic since local writes rarely
    /// fail.  The next snapshot iOS pushes will already show `.idle`,
    /// hiding the controls and close-call button.
    private func confirmStopAndSave() {
        session.send(.stop(autoSave: true))
        WKInterfaceDevice.current().play(.success)
        showingSavedToast = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.savedToastSeconds * 1_000_000_000))
            showingSavedToast = false
        }
    }

    @ViewBuilder
    private var pingRow: some View {
        Button {
            session.ping()
        } label: {
            HStack(spacing: 4) {
                switch session.pingResult {
                case .none:
                    Image(systemName: "antenna.radiowaves.left.and.right")
                    Text("Ping iPhone")
                case .pending:
                    ProgressView().controlSize(.mini)
                    Text("Pinging…")
                case .success:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Round-trip OK")
                case .failure(let message):
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                    Text(message)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
    }

    @ViewBuilder
    private var connectivityRow: some View {
        switch session.sessionState {
        case .unavailable:
            Label("Watch connectivity unavailable", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .notActivated, .activating:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Connecting…")
            }
            .foregroundStyle(.secondary)
        case .failed(let message):
            VStack(spacing: 2) {
                Label("Connection failed", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        case .activated:
            if session.isReachable {
                Label("Phone connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Phone not reachable", systemImage: "iphone.slash")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Phase C diagnostic.  Shows the latest snapshot iOS has pushed —
    /// state, elapsed time, distance, and bumpiness stats.  Replaced
    /// in Phase G by the real paged TabView UI.  Only renders when the
    /// session is `.activated` (gated above) so we don't show stale
    /// `.idle` numbers before iOS has had a chance to push.
    @ViewBuilder
    private var snapshotRow: some View {
        let s = session.lastSnapshot
        Divider().padding(.horizontal, 8)
        VStack(alignment: .leading, spacing: 2) {
            statLine(label: "State", value: s.state.rawValue.capitalized)
            if s.state != .idle {
                statLine(label: "Elapsed", value: Self.formatElapsed(s.elapsedSeconds))
                statLine(label: "Distance", value: Self.formatDistance(s.distanceMeters))
                statLine(label: "Max", value: String(format: "%.2f g", s.maxBumpiness))
                statLine(label: "Avg", value: String(format: "%.2f g", s.averageBumpiness))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private func statLine(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
    }

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
            // Feet for very short distances — matches iOS Formatters.distance.
            let feet = meters * 3.28084
            return String(format: "%.0f ft", feet)
        }
        return String(format: "%.2f mi", miles)
    }
}

#Preview {
    ContentView(session: WatchSessionManager())
}
