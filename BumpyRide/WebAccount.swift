import Foundation
import Observation

/// Cross-tab connection state for the bumpyride-web account.  Owns the `TokenStorage`
/// (Keychain) and the `WebSyncClient` (HTTP).  Views observe `state` to decide whether
/// to show "Not connected", "Connecting…", "Connected as …", or an error message.
///
/// Two connect paths:
///
/// - `connectViaPairing()` — seamless flow.  Opens `ASWebAuthenticationSession` at
///   `bumpyride.me/ios-pair`, captures the redirected token automatically.
/// - `connect(token:)` — manual fallback.  Validates a token the user has pasted from
///   `bumpyride.me/settings/tokens`.
///
/// Both routes funnel into `validateAndStore(token:)` so the post-validation behavior
/// is identical: hit `/api/me`, persist on success, surface typed errors on failure.
///
/// Phase 2+ will add an `uploadRide` queue.
@Observable
final class WebAccount {
    enum State: Equatable {
        case notConnected
        case connecting
        case connected(email: String)
        case error(message: String)
    }

    private(set) var state: State

    private let baseURL: URL
    private let client: WebSyncClient
    private let storage: TokenStorage

    init(
        baseURL: URL = WebSyncClient.defaultBaseURL,
        client: WebSyncClient = WebSyncClient(),
        storage: TokenStorage = TokenStorage()
    ) {
        self.baseURL = baseURL
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

    /// Run the seamless `ASWebAuthenticationSession` pairing flow.  On success the
    /// returned token is validated and persisted just like a manually pasted one.
    func connectViaPairing() async {
        state = .connecting
        let pairing = WebPairingService()
        let token: String
        do {
            token = try await pairing.pair(baseURL: baseURL)
        } catch WebPairingService.PairingError.userCancelled {
            // Quietly return to "not connected" without an error banner — user
            // explicitly dismissed the sheet.
            state = .notConnected
            return
        } catch let error as WebPairingService.PairingError {
            state = .error(message: error.errorDescription ?? "Couldn't sign in.")
            return
        } catch {
            state = .error(message: "Couldn't sign in: \(error.localizedDescription)")
            return
        }
        await validateAndStore(token: token)
    }

    /// Validate a manually pasted token and, on success, persist it.
    func connect(token rawToken: String) async {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            state = .error(message: "Please paste a token from bumpyride.me/settings/tokens.")
            return
        }
        state = .connecting
        await validateAndStore(token: token)
    }

    /// Clear the stored token from the device.  The token remains valid on the
    /// server until the user revokes it at `bumpyride.me/settings/tokens`.
    func disconnect() {
        storage.delete()
        state = .notConnected
    }

    /// Called by `SyncCoordinator` when an upload comes back with 401 — the token
    /// has been revoked server-side (or was never valid).  Wipes Keychain and puts
    /// the account into an error state so the Settings row reflects "needs to
    /// re-pair" rather than a stale "Connected as …".
    func invalidate() {
        storage.delete()
        state = .error(message: "Your sync connection was invalidated. Sign in again to keep syncing rides.")
    }

    // MARK: - Public bump map sharing

    /// Read the user's public-bump-map opt-in from `/api/me/sharing`.  Surfaces a
    /// 401 by calling `invalidate()` (same semantics as a 401 from `/api/sync/ride`)
    /// and then rethrowing so the caller knows the fetch failed.
    func fetchSharing() async throws -> Bool {
        guard let stored = storage.load() else {
            throw WebSyncClient.ClientError.unauthorized
        }
        do {
            return try await client.getSharing(token: stored.token)
        } catch WebSyncClient.ClientError.unauthorized {
            invalidate()
            throw WebSyncClient.ClientError.unauthorized
        }
    }

    /// Write the user's public-bump-map opt-in.  Server atomically backfills (or
    /// subtracts) the user's rides into the public aggregate.  Surfaces 401 the same
    /// way `fetchSharing` does.
    func setSharing(_ newValue: Bool) async throws {
        guard let stored = storage.load() else {
            throw WebSyncClient.ClientError.unauthorized
        }
        do {
            try await client.setSharing(shareToPublicMap: newValue, token: stored.token)
        } catch WebSyncClient.ClientError.unauthorized {
            invalidate()
            throw WebSyncClient.ClientError.unauthorized
        }
    }

    // MARK: - Pocket-mode calibration

    /// Read the server's stored pocket-mode calibration.  Same 401-then-invalidate
    /// semantics as `fetchSharing`.
    func fetchCalibration() async throws -> WebSyncClient.ServerCalibration {
        guard let stored = storage.load() else {
            throw WebSyncClient.ClientError.unauthorized
        }
        do {
            return try await client.getCalibration(token: stored.token)
        } catch WebSyncClient.ClientError.unauthorized {
            invalidate()
            throw WebSyncClient.ClientError.unauthorized
        }
    }

    /// Push a calibration value to the server.  Idempotent; safe to retry on
    /// transport failure.  Used by `ContentView` whenever the local
    /// `CalibrationStore` produces a new value, or whenever a connection / network
    /// state change suggests our last push may have been lost.
    func setCalibration(_ value: WebSyncClient.ServerCalibration) async throws {
        guard let stored = storage.load() else {
            throw WebSyncClient.ClientError.unauthorized
        }
        do {
            try await client.setCalibration(value, token: stored.token)
        } catch WebSyncClient.ClientError.unauthorized {
            invalidate()
            throw WebSyncClient.ClientError.unauthorized
        }
    }

    // MARK: - Private

    private func validateAndStore(token: String) async {
        do {
            let me = try await client.getMe(token: token)
            try storage.save(token: token, email: me.email)
            state = .connected(email: me.email)
        } catch WebSyncClient.ClientError.unauthorized {
            state = .error(message: "That token isn't valid. Try signing in again, or copy a fresh one from bumpyride.me/settings/tokens.")
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
}
