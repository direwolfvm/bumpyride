import SwiftUI

/// The Bump Map tab — a full-screen `BumpMapView` with floating chrome: a mode-filter
/// chip at the top (All / Mounted / Pocket) and a stats footer at the bottom showing
/// rides / cells / resolution.
///
/// The filter partitions `store.rides` by `pocketMode` before the rides go into
/// `BumpMapStore.rebuildIfNeeded`, which is the simplest way to address the
/// physical-damping mismatch between modes — pocket data reads systematically lower
/// than mounted data for the same road, so mixing them produces inconsistent cell
/// colors.  See the comment on `BumpMapModeFilter` for the policy.
struct BumpMapTabView: View {
    @Bindable var store: RideStore
    @Bindable var bumpMap: BumpMapStore
    @Bindable var settings: AppSettings
    @Bindable var calibration: CalibrationStore

    var body: some View {
        NavigationStack {
            ZStack {
                BumpMapView(bumpMap: bumpMap, settings: settings)
                    .ignoresSafeArea(edges: .bottom)

                VStack {
                    filterChip
                        .padding(.horizontal)
                        .padding(.top, 8)
                    Spacer()
                    footer
                        .padding(.horizontal)
                        .padding(.bottom, 12)
                }
            }
            .navigationTitle("Bump Map")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                bumpMap.rebuildIfNeeded(from: filteredRides, calibration: calibration.calibration)
            }
            .onChange(of: store.rides) { _, _ in
                bumpMap.rebuildIfNeeded(from: filteredRides, calibration: calibration.calibration)
            }
            .onChange(of: settings.bumpMapFilter) { _, _ in
                bumpMap.rebuildIfNeeded(from: filteredRides, calibration: calibration.calibration)
            }
            .onChange(of: calibration.calibration) { _, _ in
                bumpMap.rebuildIfNeeded(from: filteredRides, calibration: calibration.calibration)
            }
        }
    }

    /// Rides filtered by the user's current mode preference.  See `BumpMapModeFilter`.
    private var filteredRides: [Ride] {
        switch settings.bumpMapFilter {
        case .all:
            return store.rides
        case .mountedOrUntagged:
            return store.rides.filter { $0.pocketMode != true }
        case .pocketOnly:
            return store.rides.filter { $0.pocketMode == true }
        }
    }

    private var filterChip: some View {
        Picker("Mode", selection: $settings.bumpMapFilter) {
            ForEach(BumpMapModeFilter.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding(6)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.black.opacity(0.08))
        )
    }

    private var footer: some View {
        HStack(spacing: 14) {
            info("Rides", "\(filteredRides.count)")
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
