import SwiftUI

/// Settings → Web Account.  Either prompts the user to paste a token and validates
/// it against `/api/me`, or shows the connected email + a disconnect button.
struct WebAccountView: View {
    @Bindable var account: WebAccount

    @State private var tokenInput: String = ""

    private let tokensURL = URL(string: "https://bumpyride.me/settings/tokens")!
    private let landingURL = URL(string: "https://bumpyride.me")!

    var body: some View {
        Form {
            switch account.state {
            case .connected(let email):
                connectedSection(email: email)
            case .notConnected, .connecting, .error:
                connectSection
            }
            aboutSection
        }
        .navigationTitle("Web Account")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Connect (not yet connected)

    private var connectSection: some View {
        Section {
            instructionText
            Link(destination: tokensURL) {
                Label("Open bumpyride.me/settings/tokens", systemImage: "safari")
            }

            TextField("Paste token", text: $tokenInput, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(2...4)
                .font(.callout.monospaced())
                .disabled(account.state == .connecting)

            if case .error(let message) = account.state {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Button(action: { Task { await connectTapped() } }) {
                HStack {
                    if account.state == .connecting {
                        ProgressView()
                            .controlSize(.small)
                        Text("Connecting…")
                    } else {
                        Text("Connect")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(account.state == .connecting || tokenIsEmpty)
        } header: {
            Text("Connect")
        } footer: {
            Text("Syncing is optional. Without an account, your rides stay on this device only.")
        }
    }

    private var instructionText: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("1. Sign up at bumpyride.me in a browser.")
            Text("2. Create a token at /settings/tokens and copy it.")
            Text("3. Paste it below and tap Connect.")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var tokenIsEmpty: Bool {
        tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func connectTapped() async {
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

    // MARK: - About

    private var aboutSection: some View {
        Section {
            Link(destination: landingURL) {
                Label("About bumpyride.me", systemImage: "info.circle")
            }
        } header: {
            Text("About")
        } footer: {
            Text("Once connected, future versions of BumpyRide will sync your rides to your web account. This release only validates and stores the token.")
        }
    }
}

#Preview("Not connected") {
    NavigationStack {
        WebAccountView(account: WebAccount())
    }
}
