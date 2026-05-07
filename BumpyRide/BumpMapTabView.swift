import SwiftUI

/// The Bump Map tab — a full-screen `BumpMapView` with a floating footer showing
/// rides / cells / resolution.  Triggers `BumpMapStore.rebuildIfNeeded` on appear and
/// whenever the rides collection changes, so saves/deletes/edits flow through.
struct BumpMapTabView: View {
    @Bindable var store: RideStore
    @Bindable var bumpMap: BumpMapStore
    var settings: AppSettings

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                BumpMapView(bumpMap: bumpMap, settings: settings)
                    .ignoresSafeArea(edges: .bottom)

                footer
                    .padding(.horizontal)
                    .padding(.bottom, 12)
            }
            .navigationTitle("Bump Map")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                bumpMap.rebuildIfNeeded(from: store.rides)
            }
            .onChange(of: store.rides) { _, _ in
                bumpMap.rebuildIfNeeded(from: store.rides)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            info("Rides", "\(store.rides.count)")
            Divider().frame(height: 24)
            info("Cells", formatted(bumpMap.grid.count))
            Divider().frame(height: 24)
            info("Resolution", "\(Int(BumpGrid.cellSizeFeet)) ft")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.black.opacity(0.08))
        )
    }

    private func info(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit().weight(.medium))
        }
        .frame(maxWidth: .infinity)
    }

    private func formatted(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
