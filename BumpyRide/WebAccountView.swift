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

    private let tokensURL = URL(string: "https://bumpyride.me/settings/tokens")!
    private let landingURL = URL(string: "https://bumpyride.me")!

    var body: some View {
        Form {
            switch account.state {
            case .connected(let email):
                connectedSection(email: email)
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
