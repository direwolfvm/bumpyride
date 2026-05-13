import Foundation
import Observation

/// Cross-tab connection state for the bumpyride-web account.  Owns the `TokenStorage`
/// (Keychain) and the `WebSyncClient` (HTTP).  Views observe `state` to decide whether
/// to show "Not connected", "Connecting…", "Connected as …", or an error message.
///
/// Phase-1 scope (current): paste a token, validate via `/api/me`, persist on success.
/// Phase 2+ will add a sync queue and an `uploadRide` path.
@Observable
final class WebAccount {
    enum State: Equatable {
        case notConnected
        case connecting
        case connected(email: String)
        case error(message: String)
    }

    private(set) var state: State

    private let client: WebSyncClient
    private let storage: TokenStorage

    init(client: WebSyncClient = WebSyncClient(), storage: TokenStorage = TokenStorage()) {
        self.client = client
        self.storage = storage
        if let stored = storage.load() {
            self.state = .connected(email: stored.email)
        } else {
            self.state = .notConnected
        }
    }

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    var connectedEmail: String? {
        if case let .connected(email) = state { return email }
        return nil
    }

    /// Validate a pasted token and, on success, persist it.  Maps client errors to
    /// user-readable copy.
    func connect(token rawToken: String) async {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            state = .error(message: "Please paste a token from bumpyride.me/settings/tokens.")
            return
        }

        state = .connecting
        do {
            let me = try await client.getMe(token: token)
            try storage.save(token: token, email: me.email)
            state = .connected(email: me.email)
        } catch WebSyncClient.ClientError.unauthorized {
            state = .error(message: "That token isn't valid. Copy a fresh one from bumpyride.me/settings/tokens.")
        } catch WebSyncClient.ClientError.transport {
            state = .error(message: "Couldn't reach bumpyride.me. Check your network and try again.")
        } catch WebSyncClient.ClientError.http(let status) {
            state = .error(message: "Server returned an unexpected status (\(status)). Try again in a moment.")
        } catch WebSyncClient.ClientError.decoding {
            state = .error(message: "Server response didn't look like what we expected. Try again later.")
        } catch let error as TokenStorage.StorageError {
            switch error {
            case .keychain(let status):
                state = .error(message: "Couldn't save the token to Keychain (status \(status)). Try again.")
            case .malformed:
                state = .error(message: "Couldn't save the token.")
            }
        } catch {
            state = .error(message: "Unexpected error: \(error.localizedDescription)")
        }
    }

    /// Clear the stored token from the device.  The token remains valid on the
    /// server until the user revokes it at `bumpyride.me/settings/tokens`.
    func disconnect() {
        storage.delete()
        state = .notConnected
    }
}
