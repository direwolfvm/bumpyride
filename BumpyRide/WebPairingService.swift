import Foundation
import AuthenticationServices
import UIKit

/// Drives the seamless sign-in flow against `bumpyride.me`.  See [`docs/WEB_PAIRING.md`](../../docs/WEB_PAIRING.md)
/// for the full protocol — including the `/ios-pair` endpoint contract the web side
/// must implement.
///
/// The flow:
///
/// 1. iOS app generates a random `state` and opens an `ASWebAuthenticationSession`
///    at `https://bumpyride.me/ios-pair?callback_scheme=bumpyride&state=<random>`.
/// 2. The session shares Safari cookies (`prefersEphemeralWebBrowserSession = false`),
///    so a recently signed-in user is auto-recognized.  Otherwise they sign in or up
///    in the system-managed browser.
/// 3. The web app mints a fresh API token and 302s to `bumpyride://pair?token=…&state=…`.
/// 4. `ASWebAuthenticationSession` captures the callback URL — never exposed to other
///    apps or Safari history — and resumes our continuation with it.
/// 5. We verify the round-tripped `state` matches and hand the token to `WebAccount`
///    for the normal validate-and-persist path.
///
/// The custom scheme `bumpyride` is intentionally NOT declared in Info.plist's
/// `CFBundleURLTypes`: `ASWebAuthenticationSession` captures the callback internally
/// while the session is active, and skipping the system-wide registration prevents
/// any other app from claiming the same scheme to intercept tokens.
@MainActor
final class WebPairingService: NSObject {
    static let callbackScheme = "bumpyride"

    enum PairingError: LocalizedError {
        case malformedURL
        case userCancelled
        case stateMismatch
        case tokenMissing
        case underlying(any Error)

        var errorDescription: String? {
            switch self {
            case .malformedURL:
                return "Couldn't build the pairing URL."
            case .userCancelled:
                return "Sign-in was cancelled."
            case .stateMismatch:
                return "The server's response didn't match the pairing request. Try again."
            case .tokenMissing:
                return "The server didn't return a token."
            case .underlying(let error):
                return error.localizedDescription
            }
        }
    }

    /// Held strongly during the session's lifetime; cleared in the callback so it
    /// doesn't outlive the flow.
    private var session: ASWebAuthenticationSession?

    /// Run the pairing flow, returning the bearer token on success.  Caller should
    /// pass this to `WebSyncClient.getMe(token:)` to validate before storing.
    func pair(baseURL: URL) async throws -> String {
        let state = UUID().uuidString
        guard let url = buildPairingURL(baseURL: baseURL, state: state) else {
            throw PairingError.malformedURL
        }

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: Self.callbackScheme
            ) { [weak self] callbackURL, error in
                self?.session = nil
                if let asError = error as? ASWebAuthenticationSessionError,
                   asError.code == .canceledLogin {
                    continuation.resume(throwing: PairingError.userCancelled)
                } else if let error {
                    continuation.resume(throwing: PairingError.underlying(error))
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: PairingError.userCancelled)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }

        return try parseCallback(callback, expectedState: state)
    }

    private func buildPairingURL(baseURL: URL, state: String) -> URL? {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("ios-pair"),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "callback_scheme", value: Self.callbackScheme),
            URLQueryItem(name: "state", value: state)
        ]
        return components.url
    }

    private func parseCallback(_ url: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw PairingError.malformedURL
        }
        let items = components.queryItems ?? []
        let returnedState = items.first(where: { $0.name == "state" })?.value
        guard returnedState == expectedState else {
            throw PairingError.stateMismatch
        }
        guard let token = items.first(where: { $0.name == "token" })?.value, !token.isEmpty else {
            throw PairingError.tokenMissing
        }
        return token
    }
}

extension WebPairingService: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // ASWebAuthenticationSession invokes this on the main thread; hop into the
        // MainActor's isolation domain to read UIApplication.connectedScenes safely.
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let windows = scenes.flatMap(\.windows)
            if let key = windows.first(where: { $0.isKeyWindow }) { return key }
            if let any = windows.first { return any }
            guard let firstScene = scenes.first else {
                // The auth session can't actually be invoked without a hosting scene;
                // this branch only fires if our caller is wildly out of context.
                preconditionFailure("No active UIWindowScene available to host the auth session")
            }
            return UIWindow(windowScene: firstScene)
        }
    }
}
