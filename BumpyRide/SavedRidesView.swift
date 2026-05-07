import SwiftUI

/// The Saved tab.  Shows a list of all saved rides with summary metadata, a colored
/// bar reflecting average bumpiness, and a Pocket Mode badge for rides recorded with
/// the high-pass filter on.  Tapping a row loads the ride into the Ride tab for
/// playback; swipe-to-delete removes it from the store.
struct SavedRidesView: View {
    @Bindable var store: RideStore
    @Bindable var appState: AppState
    var settings: AppSettings

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

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
