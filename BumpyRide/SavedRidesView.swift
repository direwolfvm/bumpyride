import SwiftUI

/// The Saved tab.  Shows a list of all saved rides with summary metadata, a colored
/// bar reflecting average bumpiness, and a Pocket Mode badge for rides recorded with
/// the high-pass filter on.  Tapping a row loads the ride into the Ride tab for
/// playback; swipe-to-delete removes it from the store.
struct SavedRidesView: View {
    @Bindable var store: RideStore
    @Bindable var appState: AppState
    var settings: AppSettings
    /// Per-row cloud icons are derived from the coordinator's queue + state, and
    /// hidden entirely when the user isn't connected to a web account.
    @Bindable var syncCoordinator: SyncCoordinator
    @Bindable var webAccount: WebAccount

    var body: some View {
        NavigationStack {
            Group {
                if store.rides.isEmpty {
                    ContentUnavailableView(
                        "No Saved Rides",
                        systemImage: "bicycle",
                        description: Text("Record a ride in the Ride tab and save it here.")
                    )
                } else {
                    List {
                        ForEach(store.rides) { ride in
                            Button {
                                appState.open(ride)
                            } label: {
                                rideRow(ride)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { indexSet in
                            for idx in indexSet { store.delete(store.rides[idx]) }
                        }
                    }
                }
            }
            .navigationTitle("Saved Rides")
        }
    }

    private func rideRow(_ ride: Ride) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(settings.color(for: ride.averageBumpiness))
                .frame(width: 8, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(ride.title)
                        .font(.headline)
                        .lineLimit(1)
                    if ride.pocketMode == true {
                        Image(systemName: "wave.3.right.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.tint)
                            .accessibilityLabel("Recorded in pocket mode")
                    }
                }
                HStack(spacing: 8) {
                    Text(Formatters.dateTime(ride.startedAt))
                    Text("·")
                    Text(Formatters.distance(ride.distanceMeters))
                    Text("·")
                    Text(Formatters.duration(ride.duration))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.2fg", ride.maxBumpiness))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(settings.color(for: ride.maxBumpiness))
                Text("max")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            syncIndicator(for: ride)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func syncIndicator(for ride: Ride) -> some View {
        // Hide entirely when the user has no web account — keep the row clean for
        // people who don't use sync.  Still show queued rides if the user paired
        // then disconnected (queue persists; reconnecting drains it).
        let status = syncCoordinator.status(forRide: ride.id)
        let shouldShow = webAccount.isConnected || status != .synced
        if shouldShow {
            switch status {
            case .synced:
                Image(systemName: "checkmark.icloud.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Synced")
            case .queued:
                Image(systemName: "icloud.and.arrow.up")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Queued to sync")
            case .uploading:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Uploading")
            case .paused:
                Image(systemName: "exclamationmark.icloud.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Sync paused — will retry")
            case .waitingForAuth:
                Image(systemName: "key.icloud.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Sign in to sync")
            }
        }
    }
}
