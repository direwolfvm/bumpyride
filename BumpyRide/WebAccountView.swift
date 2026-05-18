import SwiftUI

/// Settings → Web Account.  Primary path is "Sign in with bumpyride.me", which opens
/// an `ASWebAuthenticationSession` and captures the token automatically.  Manual
/// paste-a-token is kept as a fallback for power users or for when the seamless
/// flow can't be used (e.g. on a device whose Safari is signed out and no keyboard
/// available).
struct WebAccountView: View {
    @Bindable var account: WebAccount
    @Bindable var syncCoordinator: SyncCoordinator
    @Bindable var syncQueue: SyncQueue

    @State private var tokenInput: String = ""

    /// Local cache of `/api/me/sharing` state.  The server is canonical; these are
    /// just the on-screen reflection.  Refreshed on screen appear and whenever
    /// the connected account changes (e.g. pair / re-pair), so toggling via the
    /// web is picked up next time the user opens this view.
    ///
    /// After every PATCH we adopt the server's response wholesale rather than
    /// echoing what we sent: the server enforces force-off (sharing off → eager
    /// off) and clamps eager to false when sharing is off.  Trusting local
    /// state would drift the UI out of sync.
    @State private var publicMapSharing: Bool = false
    @State private var publicMapEager: Bool = false
    @State private var publicMapSharingLoaded: Bool = false
    @State private var publicMapSharingUpdating: Bool = false
    @State private var publicMapEagerUpdating: Bool = false
    @State private var publicMapSharingError: String?

    private let tokensURL = URL(string: "https://bumpyride.me/settings/tokens")!
    private let landingURL = URL(string: "https://bumpyride.me")!

    var body: some View {
        Form {
            switch account.state {
            case .connected(let email):
                connectedSection(email: email)
                publicBumpMapSection
                syncSection
            case .notConnected, .connecting, .error:
                signInSection
                manualTokenSection
                if !syncQueue.isEmpty {
                    pendingWhileDisconnectedSection
                }
            }
            aboutSection
        }
        .navigationTitle("Web Account")
        .navigationBarTitleDisplayMode(.inline)
        // `id:` re-runs the task whenever the connected email changes (nil ⇄ email
        // and email-to-email), covering both first-load and post-pair refresh
        // without a separate .onChange.
        .task(id: account.connectedEmail) {
            await refreshPublicMapSharing()
        }
    }

    // MARK: - Primary: seamless sign-in

    private var signInSection: some View {
        Section {
            Button {
                Task { await account.connectViaPairing() }
            } label: {
                HStack(spacing: 8) {
                    if account.state == .connecting {
                        ProgressView()
                            .controlSize(.small)
                        Text("Signing in…")
                    } else {
                        Image(systemName: "arrow.up.forward.circle.fill")
                        Text("Sign in with bumpyride.me")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(account.state == .connecting)

            if case .error(let message) = account.state {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Connect")
        } footer: {
            Text("Opens bumpyride.me in a secure window so you can sign in (or sign up). If you're already signed in on this device, it'll connect right away. The token is sent back to this app automatically — Safari history never sees it.")
        }
    }

    // MARK: - Fallback: manual paste

    private var manualTokenSection: some View {
        Section {
            Link(destination: tokensURL) {
                Label("Open /settings/tokens", systemImage: "safari")
            }

            TextField("Paste token", text: $tokenInput, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(2...4)
                .font(.callout.monospaced())
                .disabled(account.state == .connecting)

            Button {
                Task { await pasteConnect() }
            } label: {
                Text("Connect with this token")
                    .frame(maxWidth: .infinity)
            }
            .disabled(account.state == .connecting || tokenIsEmpty)
        } header: {
            Text("Or paste a token")
        } footer: {
            Text("Create one at bumpyride.me/settings/tokens and paste it here. Useful if the Sign-in button isn't working for some reason.")
        }
    }

    private var tokenIsEmpty: Bool {
        tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func pasteConnect() async {
        await account.connect(token: tokenInput)
        if case .connected = account.state {
            tokenInput = ""
        }
    }

    // MARK: - Connected

    private func connectedSection(email: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connected as")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(email)
                    .font(.body.weight(.semibold))
            }
            .padding(.vertical, 2)

            Button(role: .destructive) {
                account.disconnect()
                tokenInput = ""
            } label: {
                Label("Disconnect", systemImage: "link.badge.minus")
            }
        } header: {
            Text("Connection")
        } footer: {
            Text("Disconnecting removes the token from this device only. To revoke it on the server too, visit bumpyride.me/settings/tokens.")
        }
    }

    // MARK: - Public bump map opt-in (shown when connected)

    private var publicBumpMapSection: some View {
        Section {
            // Primary opt-in.  Disabled while loading or while either PATCH is
            // in flight — the eager toggle below is also affected by an
            // in-flight sharing change, so they share the same gate.
            Toggle(isOn: publicMapSharingBinding) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Share my rides on the public bump map")
                    Text("Adds your bumpiness samples to the public heat map at bumpyride.me/map. Routes, timestamps, and per-user attribution are not published — only the per-cell average. Cells with fewer than 3 different riders stay hidden, so a solo segment never appears.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!publicMapSharingLoaded || publicMapSharingUpdating || publicMapEagerUpdating)

            // Eager-render sub-toggle.  Hidden — not just disabled — when
            // sharing is off, mirroring the web's UI and matching the server's
            // force-off rule (eager is meaningless without sharing).
            if publicMapSharing {
                Toggle(isOn: publicMapEagerBinding) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Show my data without the 3-rider threshold")
                        Text("Off (default): your cells stay hidden until at least 3 different riders have contributed to the same area, so individual routes can't be inferred. On: your cells appear on the public map right away — a careful observer could trace your routes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(!publicMapSharingLoaded || publicMapSharingUpdating || publicMapEagerUpdating)
            }

            if publicMapSharingUpdating {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(publicMapSharing ? "Adding your rides to the public map…" : "Removing your rides from the public map…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if publicMapEagerUpdating {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(publicMapEager ? "Updating: your cells will appear immediately…" : "Updating: your cells will wait for the 3-rider threshold…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = publicMapSharingError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Public bump map")
        } footer: {
            Text("Toggling sharing on backfills your existing rides into the public aggregate; toggling off subtracts them. You can change either setting at any time.")
        }
    }

    /// Binding for the primary opt-in.  Optimistically flips local state on
    /// tap (so the toggle moves immediately, no snap-back flicker) and kicks
    /// off the PATCH.  Server response is adopted as truth on success;
    /// failure paths revert.
    private var publicMapSharingBinding: Binding<Bool> {
        Binding(
            get: { publicMapSharing },
            set: { newValue in
                publicMapSharing = newValue
                // Mirror the server's force-off rule in the local UI so the
                // eager toggle visually disappears in lockstep with sharing
                // turning off.  Server will also clear eager and we'll adopt
                // its response, but doing it locally first avoids a flicker.
                if !newValue {
                    publicMapEager = false
                }
                publicMapSharingError = nil
                Task { await applyPublicMapSharing(newValue) }
            }
        )
    }

    /// Binding for the eager sub-toggle.  Same optimistic pattern as the
    /// primary.  Only ever invoked when sharing is on (the toggle is hidden
    /// otherwise), so we don't have to defensively handle the "sharing off,
    /// eager on" case — that's a server-side clamp we'd just adopt anyway.
    private var publicMapEagerBinding: Binding<Bool> {
        Binding(
            get: { publicMapEager },
            set: { newValue in
                publicMapEager = newValue
                publicMapSharingError = nil
                Task { await applyPublicMapEager(newValue) }
            }
        )
    }

    private func refreshPublicMapSharing() async {
        guard case .connected = account.state else {
            publicMapSharingLoaded = false
            return
        }
        do {
            let settings = try await account.fetchSharing()
            adopt(settings)
            publicMapSharingLoaded = true
            publicMapSharingError = nil
        } catch WebSyncClient.ClientError.unauthorized {
            // WebAccount.fetchSharing already invalidated; view will re-render
            // with the not-connected section. Nothing else to do here.
            publicMapSharingLoaded = false
        } catch {
            // Quiet failure — the toggles stay disabled and the next
            // screen-appear will retry.  Don't show a banner for a background
            // refresh.
            publicMapSharingLoaded = false
        }
    }

    /// Push a primary opt-in change to the server.  Server's response is the
    /// authoritative post-state for *both* fields (force-off clears eager), so
    /// we adopt the whole returned struct rather than just remembering what we
    /// sent.
    private func applyPublicMapSharing(_ newValue: Bool) async {
        publicMapSharingUpdating = true
        defer { publicMapSharingUpdating = false }
        do {
            let settings = try await account.setSharing(shareToPublicMap: newValue)
            adopt(settings)
        } catch WebSyncClient.ClientError.unauthorized {
            // Account already invalidated; view will transition away from the
            // connected section.  No revert needed (section will disappear).
        } catch WebSyncClient.ClientError.transport {
            revertSharing(to: !newValue, message: "Couldn't reach bumpyride.me. Check your network and try again.")
        } catch WebSyncClient.ClientError.validationFailed {
            revertSharing(to: !newValue, message: "The server didn't accept that change. Try again later.")
        } catch WebSyncClient.ClientError.http(let status) {
            revertSharing(to: !newValue, message: "Server returned an unexpected status (\(status)). Try again.")
        } catch {
            revertSharing(to: !newValue, message: "Couldn't update setting. Try again.")
        }
    }

    /// Push an eager-toggle change to the server.  Same adoption-of-response
    /// pattern as `applyPublicMapSharing`.  On failure we revert eager only —
    /// sharing's local state wasn't speculatively touched.
    private func applyPublicMapEager(_ newValue: Bool) async {
        publicMapEagerUpdating = true
        defer { publicMapEagerUpdating = false }
        do {
            let settings = try await account.setSharing(publicMapEager: newValue)
            adopt(settings)
        } catch WebSyncClient.ClientError.unauthorized {
            // Same as above.
        } catch WebSyncClient.ClientError.transport {
            revertEager(to: !newValue, message: "Couldn't reach bumpyride.me. Check your network and try again.")
        } catch WebSyncClient.ClientError.validationFailed {
            revertEager(to: !newValue, message: "The server didn't accept that change. Try again later.")
        } catch WebSyncClient.ClientError.http(let status) {
            revertEager(to: !newValue, message: "Server returned an unexpected status (\(status)). Try again.")
        } catch {
            revertEager(to: !newValue, message: "Couldn't update setting. Try again.")
        }
    }

    private func adopt(_ settings: WebSyncClient.SharingSettings) {
        publicMapSharing = settings.shareToPublicMap
        publicMapEager = settings.publicMapEager
    }

    private func revertSharing(to previous: Bool, message: String) {
        publicMapSharing = previous
        // If we were turning sharing off, we'd preemptively cleared eager in
        // the binding's setter.  On revert, we don't know the true eager
        // state without a re-fetch — but in practice the most common transport
        // failure is offline, in which case the server didn't process our
        // PATCH at all, so eager is still whatever it was.  Leave it alone;
        // next refreshPublicMapSharing will reconcile.
        publicMapSharingError = message
    }

    private func revertEager(to previous: Bool, message: String) {
        publicMapEager = previous
        publicMapSharingError = message
    }

    // MARK: - Sync (shown when connected)

    private var syncSection: some View {
        Section {
            syncStatusRow
            Button {
                syncCoordinator.kick()
            } label: {
                Label("Sync now", systemImage: "arrow.clockwise.icloud")
            }
            .disabled(!shouldEnableSyncNow)
        } header: {
            Text("Sync")
        } footer: {
            Text("Rides upload automatically as you save them. Use Sync now if a transient error has put sync into backoff and you want to retry sooner.")
        }
    }

    private var syncStatusRow: some View {
        HStack(spacing: 12) {
            syncStatusIcon
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(syncStatusTitle)
                    .font(.body)
                if let detail = syncStatusDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
    }

    @ViewBuilder
    private var syncStatusIcon: some View {
        switch syncCoordinator.state {
        case .idle:
            Image(systemName: "checkmark.icloud.fill")
                .font(.title3)
                .foregroundStyle(.green)
        case .syncing:
            ProgressView()
                .controlSize(.small)
        case .paused:
            Image(systemName: "exclamationmark.icloud.fill")
                .font(.title3)
                .foregroundStyle(.orange)
        case .waitingForAuth:
            Image(systemName: "key.icloud.fill")
                .font(.title3)
                .foregroundStyle(.orange)
        }
    }

    private var syncStatusTitle: String {
        switch syncCoordinator.state {
        case .idle:
            return syncQueue.isEmpty ? "All up to date" : "Idle"
        case .syncing(let remaining):
            return remaining == 1 ? "Syncing 1 ride" : "Syncing \(remaining) rides"
        case .paused:
            return "Paused — will retry"
        case .waitingForAuth:
            return "Waiting to sign in again"
        }
    }

    private var syncStatusDetail: String? {
        switch syncCoordinator.state {
        case .idle:
            return nil
        case .syncing:
            return nil
        case .paused(let reason, let retryAt):
            return "\(reason) · retry \(Self.retryTimeFormatter.string(from: retryAt))"
        case .waitingForAuth:
            return "Tap Sign in above to resume."
        }
    }

    private var shouldEnableSyncNow: Bool {
        switch syncCoordinator.state {
        case .paused: return true
        case .idle: return !syncQueue.isEmpty   // useful as a "kick the tires" force
        case .syncing, .waitingForAuth: return false
        }
    }

    private static let retryTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    // MARK: - Pending uploads while disconnected

    private var pendingWhileDisconnectedSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "key.icloud.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(syncQueue.count) ride\(syncQueue.count == 1 ? "" : "s") waiting to sync")
                        .font(.body)
                    Text("Sign in to a web account to upload them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        } header: {
            Text("Pending uploads")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            Link(destination: landingURL) {
                Label("About bumpyride.me", systemImage: "info.circle")
            }
        } header: {
            Text("About")
        }
    }
}

#Preview("Not connected") {
    NavigationStack {
        WebAccountView(
            account: WebAccount(),
            syncCoordinator: SyncCoordinator(
                queue: SyncQueue(),
                rideStore: RideStore(),
                webAccount: WebAccount()
            ),
            syncQueue: SyncQueue()
        )
    }
}
