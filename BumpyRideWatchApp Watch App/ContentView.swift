import SwiftUI

/// **Phase B placeholder.**  Shows the WatchConnectivity session state
/// and whether the iPhone is reachable, with a small bike-icon header.
/// No interactive controls yet — Phases D-G build the close-call
/// button, pause/resume/stop, and the stats carousel.
///
/// The status indicator gives the user immediate feedback that the
/// watch app and iPhone app are talking.  During development we'll
/// rely on this to verify the pairing.
struct ContentView: View {
    @Bindable var session: WatchSessionManager

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

                snapshotRow
                    .font(.caption2)
            }
        }
        .padding(.horizontal, 6)
        .multilineTextAlignment(.center)
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
