import SwiftUI
import CoreLocation

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
    @Bindable var brakeMap: BrakeMapStore
    @Bindable var closeCallMap: CloseCallMapStore
    @Bindable var settings: AppSettings
    @Bindable var calibration: CalibrationStore

    /// Location source for the "where should we center the empty map?" question.
    /// Lives on the tab so it survives BumpMapView teardown/rebuilds and so the
    /// empty-state overlay can drive permission requests without poking the
    /// `MKMapView` wrapper.  See `BumpMapLocationHint`.
    @State private var locationHint = BumpMapLocationHint()

    /// True when the user has no rides at all — drives the empty-state overlay
    /// and the show/hide of the filter chip + footer chrome.  We use rides count
    /// rather than `bumpMap.boundingRegion == nil` because the bump map can
    /// briefly look empty during the initial rebuild even when rides exist.
    private var hasAnyRides: Bool { !store.rides.isEmpty }

    var body: some View {
        NavigationStack {
            ZStack {
                BumpMapView(
                    bumpMap: bumpMap,
                    brakeMap: brakeMap,
                    closeCallMap: closeCallMap,
                    settings: settings,
                    mode: settings.mapViewMode,
                    locationHint: locationHint
                )
                .ignoresSafeArea(edges: .bottom)

                // Chrome (filter + stats) is shown only when there's data to
                // operate on.  Hiding it in the empty state keeps the focus on
                // the welcome message and avoids "Rides: 0 / Cells: 0" noise.
                if hasAnyRides {
                    VStack(spacing: 8) {
                        filterChip
                        viewModeChip
                        Spacer()
                        footer
                            .padding(.bottom, 12)
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                } else {
                    emptyState
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                rebuildBothMaps()
            }
            .onChange(of: store.rides) { _, _ in
                rebuildBothMaps()
            }
            .onChange(of: settings.bumpMapFilter) { _, _ in
                rebuildBothMaps()
            }
            .onChange(of: calibration.calibration) { _, _ in
                // Calibration only affects the bump map's per-cell averages —
                // brake counts are unaffected.  Just rebuild bumps.
                bumpMap.rebuildIfNeeded(from: filteredRides, calibration: calibration.calibration)
            }
        }
    }

    /// Rebuild all three aggregation stores against the current filtered
    /// ride set.  Called on appear and on any filter / ride-list change.
    /// All stores short-circuit if their signature hasn't changed, so this
    /// is cheap to call eagerly.  Same filtered rides for all three so the
    /// All/Mounted/Pocket chip filters them in lockstep — a user looking
    /// only at mounted rides sees their bumps, brakes, AND close calls
    /// filtered the same way.
    private func rebuildBothMaps() {
        bumpMap.rebuildIfNeeded(from: filteredRides, calibration: calibration.calibration)
        brakeMap.rebuildIfNeeded(from: filteredRides)
        closeCallMap.rebuildIfNeeded(from: filteredRides)
    }

    /// Navigation title adapts to the current view mode so the chrome
    /// reflects what the user is looking at.
    private var navigationTitle: String {
        switch settings.mapViewMode {
        case .bumps: return "Bump Map"
        case .brakes: return "Brake Map"
        case .closeCalls: return "Close Calls"
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

    /// Picker for `MapViewMode` (Bumps vs Brakes).  Lives below the
    /// All/Mounted/Pocket filter so a user can read top-to-bottom: "show
    /// rides where… as a heatmap of…"  Same visual treatment as the filter
    /// chip for consistency.
    private var viewModeChip: some View {
        Picker("View", selection: $settings.mapViewMode) {
            ForEach(MapViewMode.allCases, id: \.self) { mode in
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

    /// Stats strip at the bottom of the map area.  Three layouts depending
    /// on the active view mode:
    ///
    /// - **Bumps**: Rides / Cells / Resolution — the "how much data have I
    ///   accumulated" stats most relevant to a heat map.
    /// - **Brakes**: Rides / Events / Resolution — event count is the
    ///   informative number, not cell count.
    /// - **Close Calls**: Rides / Calls / Resolution — same shape as
    ///   brakes; "Calls" is the natural short label.
    private var footer: some View {
        HStack(spacing: 14) {
            info("Rides", "\(filteredRides.count)")
            Divider().frame(height: 24)
            switch settings.mapViewMode {
            case .bumps:
                info("Cells", formatted(bumpMap.grid.count))
            case .brakes:
                info("Events", formatted(brakeMap.grid.totalEvents))
            case .closeCalls:
                info("Calls", formatted(closeCallMap.grid.totalEvents))
            }
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

    /// Centered welcome card shown when `store.rides.isEmpty`.  Adapts to the
    /// location-permission state of `locationHint`:
    ///
    /// - `.notDetermined`: shows a "Use my location" button that triggers the
    ///   system permission prompt.  On grant, the hint auto-fetches a fix and
    ///   `BumpMapView` pans to the user.
    /// - `.denied` / `.restricted`: shows a deep-link to Settings since the
    ///   only way back is the OS-level toggle.
    /// - authorized: the hint requested a fix on init; we just wait for it
    ///   silently.  If for some reason none arrives, the user always has the
    ///   Start Ride path as the primary action.
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "map")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                Text("No rides yet")
                    .font(.title2.bold())
                Text("Start a ride and your bumpiness data will appear here as a heat map.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            emptyStateLocationAction
        }
        .padding(24)
        .frame(maxWidth: 340)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.black.opacity(0.08))
        )
        .padding(.horizontal, 24)
    }

    /// The button (or status) at the bottom of the empty-state card.  Pulled
    /// into its own helper because the three permission branches each need a
    /// slightly different label / action / button style and inlining them
    /// inflates the `emptyState` body too much to read.
    @ViewBuilder
    private var emptyStateLocationAction: some View {
        switch locationHint.authorizationStatus {
        case .notDetermined:
            Button {
                locationHint.requestOneShot()
            } label: {
                if locationHint.isFetching {
                    ProgressView()
                } else {
                    Label("Use my location", systemImage: "location.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        case .denied, .restricted:
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Open Settings", systemImage: "gear")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        case .authorizedWhenInUse, .authorizedAlways:
            if locationHint.isFetching {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Finding you…").foregroundStyle(.secondary)
                }
                .font(.footnote)
            }
            // Otherwise no action — we either already have a fix (and the map
            // is centered on the user) or we're waiting for one passively.
        @unknown default:
            EmptyView()
        }
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
