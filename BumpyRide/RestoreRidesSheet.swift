import SwiftUI

/// Modal flow for the server-side restore feature.  Two visual halves:
///
/// 1. **Setup**: fetch the manifest list (paginated via
///    `account.listRides(cursor:)`) and show the user a confirmation
///    preview — total ride count, estimated download size, how many
///    will be added vs. overwritten.
/// 2. **Run**: instantiate a `RestoreCoordinator`, kick it off, and
///    render based on its `phase` (downloading / succeeded / cancelled /
///    failed).
///
/// Mirrors the visual language and state-machine style of the existing
/// `ClearDataSheet` and `DeleteAccountSheet` in `WebAccountView.swift`,
/// adapted to this flow's distinct setup-then-run shape.
struct RestoreRidesSheet: View {
    let account: WebAccount
    let store: RideStore

    @Environment(\.dismiss) private var dismiss

    /// State machine for the setup half.  Once the user confirms in
    /// `.ready`, we transition to `.running` and the body delegates to
    /// `coordinator.phase` for the rest of the flow.
    enum SheetPhase: Equatable {
        case loadingManifests
        case ready(manifests: [WebSyncClient.RideManifest])
        case loadingFailed(message: String)
        case running
    }

    @State private var sheetPhase: SheetPhase = .loadingManifests
    @State private var coordinator: RestoreCoordinator?

    var body: some View {
        NavigationStack {
            Form {
                switch sheetPhase {
                case .loadingManifests:
                    loadingManifestsContent
                case .ready(let manifests):
                    readyContent(manifests: manifests)
                case .loadingFailed(let message):
                    loadingFailedContent(message: message)
                case .running:
                    runningContent
                }
            }
            .navigationTitle("Restore my rides")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if shouldShowToolbarCancel {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
            // Block swipe-to-dismiss during the active restore so the
            // user can't accidentally orphan an in-flight Task by
            // pulling the sheet down.  They must use the explicit
            // Cancel button to abort.  Setup states + terminal states
            // are fine to dismiss freely.
            .interactiveDismissDisabled(blockInteractiveDismiss)
        }
        .task {
            if case .loadingManifests = sheetPhase {
                await loadManifests()
            }
        }
    }

    // MARK: - Toolbar / dismiss gating

    /// Show the toolbar Cancel button while we're not in a terminal
    /// running state (a terminal state already shows a Done button in
    /// the body, so duplicating in the toolbar would be noisy).
    private var shouldShowToolbarCancel: Bool {
        switch sheetPhase {
        case .loadingManifests, .ready, .loadingFailed:
            return true
        case .running:
            // In running, the body's own Cancel/Done button handles it.
            return false
        }
    }

    /// Disable swipe-down only while the download is in flight.
    /// Cancellable, failed, and succeeded states leave the user free to
    /// dismiss with a swipe.
    private var blockInteractiveDismiss: Bool {
        guard case .running = sheetPhase else { return false }
        guard let c = coordinator else { return true }
        switch c.phase {
        case .downloading: return true
        case .idle, .succeeded, .cancelled, .failed: return false
        }
    }

    // MARK: - Setup phase content

    @ViewBuilder
    private var loadingManifestsContent: some View {
        Section {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Loading your rides…")
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Asking bumpyride.me for the list of rides linked to your account.")
        }
    }

    @ViewBuilder
    private func readyContent(manifests: [WebSyncClient.RideManifest]) -> some View {
        let serverIds = Set(manifests.map(\.id))
        let localIds = Set(store.rides.map(\.id))
        let willAdd = serverIds.subtracting(localIds).count
        let willOverwrite = serverIds.intersection(localIds).count
        let totalBytes = manifests.reduce(0) { $0 + $1.sizeBytes }

        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text("\(manifests.count) ride\(manifests.count == 1 ? "" : "s") available")
                        .font(.body.weight(.semibold))
                } icon: {
                    Image(systemName: "icloud.and.arrow.down.fill")
                        .foregroundStyle(.blue)
                }
                Text("~\(Self.bytesFormatter.string(fromByteCount: Int64(totalBytes))) to download")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Summary")
        }

        if !manifests.isEmpty {
            Section {
                HStack {
                    Label("New on this device", systemImage: "plus.circle")
                    Spacer()
                    Text("\(willAdd)").font(.callout.monospacedDigit().weight(.medium))
                }
                HStack {
                    Label("Already here (will be overwritten)", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    Text("\(willOverwrite)").font(.callout.monospacedDigit().weight(.medium))
                }
            } footer: {
                Text(willOverwrite > 0
                     ? "Existing rides with the same ID will be replaced by the server's copies."
                     : "All restored rides will be new to this device.")
            }

            Section {
                Button {
                    startRestore(manifests: manifests)
                } label: {
                    Text("Restore \(manifests.count) ride\(manifests.count == 1 ? "" : "s")")
                        .frame(maxWidth: .infinity)
                }
            }
        } else {
            Section {
                Label("No rides to restore", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Your bumpyride.me account doesn't have any rides recorded yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func loadingFailedContent(message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
        Section {
            Button("Try again") {
                Task {
                    sheetPhase = .loadingManifests
                    await loadManifests()
                }
            }
            Button("Cancel") { dismiss() }
        }
    }

    // MARK: - Running phase content

    @ViewBuilder
    private var runningContent: some View {
        if let c = coordinator {
            switch c.phase {
            case .idle:
                // Brief; we transition from .idle → .downloading
                // synchronously in start().  Shown only if SwiftUI
                // happens to render between phases.
                Section {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Preparing…").foregroundStyle(.secondary)
                    }
                }
            case .downloading(let idx, let total, let title):
                downloadingContent(idx: idx, total: total, title: title, coordinator: c)
            case .succeeded(let restored, let skipped):
                succeededContent(restored: restored, skipped: skipped)
            case .cancelled(let restored):
                cancelledContent(restored: restored)
            case .failed(let message, let restored):
                failedContent(message: message, restored: restored)
            }
        }
    }

    @ViewBuilder
    private func downloadingContent(idx: Int, total: Int, title: String, coordinator: RestoreCoordinator) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                // Show "N of M" with +1 offset since idx is 0-based but
                // humans count from 1.
                Text("Restoring \(idx + 1) of \(total)")
                    .font(.callout.weight(.semibold))
                ProgressView(value: Double(idx), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
                    .tint(.blue)
                Text(title.isEmpty ? " " : title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.vertical, 4)
        }
        Section {
            Button(role: .destructive) {
                coordinator.cancel()
            } label: {
                Text("Cancel restore")
                    .frame(maxWidth: .infinity)
            }
        } footer: {
            Text("Already-restored rides will be kept. Cancelling stops the queue.")
        }
    }

    @ViewBuilder
    private func succeededContent(restored: Int, skipped: Int) -> some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Done.")
                        .font(.headline)
                    Text("Restored \(restored) ride\(restored == 1 ? "" : "s").")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if skipped > 0 {
                        Text("\(skipped) couldn't be downloaded and were skipped.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        Section {
            Button("Done") { dismiss() }
        }
    }

    @ViewBuilder
    private func cancelledContent(restored: Int) -> some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Restore cancelled.")
                        .font(.headline)
                    Text("Restored \(restored) ride\(restored == 1 ? "" : "s") before stopping.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "stop.circle.fill")
                    .foregroundStyle(.orange)
            }
        }
        Section {
            Button("Done") { dismiss() }
        }
    }

    @ViewBuilder
    private func failedContent(message: String, restored: Int) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            if restored > 0 {
                Text("Restored \(restored) ride\(restored == 1 ? "" : "s") before the failure.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        Section {
            Button("Done") { dismiss() }
        }
    }

    // MARK: - Actions

    /// Load every page of the user's rides from the server and
    /// transition to `.ready(manifests:)`.  On any error, transitions
    /// to `.loadingFailed(message:)`.
    private func loadManifests() async {
        var all: [WebSyncClient.RideManifest] = []
        var cursor: String? = nil
        repeat {
            do {
                let page = try await account.listRides(cursor: cursor)
                all.append(contentsOf: page.rides)
                cursor = page.nextCursor
            } catch WebSyncClient.ClientError.unauthorized {
                sheetPhase = .loadingFailed(message: "Your sign-in expired. Sign in again, then retry.")
                return
            } catch WebSyncClient.ClientError.transport {
                sheetPhase = .loadingFailed(message: "Couldn't reach bumpyride.me. Check your network and try again.")
                return
            } catch WebSyncClient.ClientError.validationFailed {
                // Stale cursor (per the contract) — should be rare for a
                // freshly-started listing, but recover by treating the
                // current accumulation as final.  If we have nothing,
                // surface as a generic failure.
                if all.isEmpty {
                    sheetPhase = .loadingFailed(message: "Couldn't load your rides. Try again later.")
                    return
                }
                cursor = nil
            } catch {
                sheetPhase = .loadingFailed(message: "Couldn't load your rides. Try again later.")
                return
            }
        } while cursor != nil

        sheetPhase = .ready(manifests: all)
    }

    /// Instantiate the coordinator and start the download.  Transitions
    /// the sheet to `.running`; the running content takes over rendering
    /// from `coordinator.phase`.
    private func startRestore(manifests: [WebSyncClient.RideManifest]) {
        let c = RestoreCoordinator(account: account, store: store)
        coordinator = c
        sheetPhase = .running
        c.start(restoring: manifests)
    }

    // MARK: - Helpers

    private static let bytesFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.includesUnit = true
        return f
    }()
}
