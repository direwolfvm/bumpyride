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
}

#Preview {
    ContentView(session: WatchSessionManager())
}
