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

    /// Read the user's full public-bump-map sharing state (both `shareToPublicMap`
    /// and `publicMapEager`).  Surfaces a 401 by calling `invalidate()` (same
    /// semantics as a 401 from `/api/sync/ride`) and then rethrowing so the
    /// caller knows the fetch failed.
    func fetchSharing() async throws -> WebSyncClient.SharingSettings {
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

    /// Patch one or both sharing fields.  Returns the server's authoritative
    /// post-PATCH state, which the caller MUST adopt directly — the server
    /// enforces a force-off rule (turning `shareToPublicMap` off clears
    /// `publicMapEager`) and clamps eager to false if sharing is currently
    /// off.  Echoing what we sent would drift the UI out of sync.
    ///
    /// Surfaces 401 the same way `fetchSharing` does.
    func setSharing(
        shareToPublicMap: Bool? = nil,
        publicMapEager: Bool? = nil
    ) async throws -> WebSyncClient.SharingSettings {
        guard let stored = storage.load() else {
            throw WebSyncClient.ClientError.unauthorized
        }
        do {
            return try await client.setSharing(
                shareToPublicMap: shareToPublicMap,
                publicMapEager: publicMapEager,
                token: stored.token
            )
        } catch WebSyncClient.ClientError.unauthorized {
            invalidate()
            throw WebSyncClient.ClientError.unauthorized
        }
    }

    // MARK: - Destructive operations

    /// Drop every ride from the server, keeping the account.  See
    /// `WebSyncClient.clearData` for the keep/drop matrix.  Token stays
    /// valid after this call; account state is untouched.
    ///
    /// Caller is responsible for any iOS-side cleanup (sync queue drain,
    /// local-ride deletion).  This method only handles the network side.
    func clearWebData(keepPublicContributions: Bool) async throws -> WebSyncClient.DataDeletionResult {
        guard let stored = storage.load() else {
            throw WebSyncClient.ClientError.unauthorized
        }
        do {
            return try await client.clearData(keepPublicContributions: keepPublicContributions, token: stored.token)
        } catch WebSyncClient.ClientError.unauthorized {
            invalidate()
            throw WebSyncClient.ClientError.unauthorized
        }
    }

    /// Drop every ride AND remove the user.  See `WebSyncClient.deleteAccount`
    /// for the keep/drop matrix and the `confirmEmail` stray-click guard.
    ///
    /// **On a successful return, the token is invalidated server-side**
    /// (the user row is gone and the token cascade-dropped).  This method
    /// follows through with a local `invalidate()` so the in-memory state
    /// transitions to `.error` and the Keychain entry is wiped.  Caller
    /// should also clear local rides + sync queue, since the bumpyride.me
    /// presence is gone.
    func deleteWebAccount(
        keepPublicContributions: Bool,
        confirmEmail: String
    ) async throws -> WebSyncClient.DataDeletionResult {
        guard let stored = storage.load() else {
            throw WebSyncClient.ClientError.unauthorized
        }
        do {
            let result = try await client.deleteAccount(
                keepPublicContributions: keepPublicContributions,
                confirmEmail: confirmEmail,
                token: stored.token
            )
            // Server side has dropped (or anonymized) the user row.  Our
            // token is now dead.  Wipe Keychain + transition state so the
            // UI reflects disconnection.  Reuse invalidate() but with a
            // friendlier message than the "session was invalidated" copy
            // it uses for unexpected 401s.
            storage.delete()
            state = .notConnected
            return result
        } catch WebSyncClient.ClientError.unauthorized {
            // The token was already invalid before we even tried.  Clean up
            // the same way invalidate() would, but treat it as not-connected
            // rather than the error state used for surprising 401s.
            storage.delete()
            state = .notConnected
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
