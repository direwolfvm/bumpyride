import Foundation
import OSLog

/// Thin HTTP client for `bumpyride.me`.  Modeled on the reference `SyncClient`
/// in [`bumpyride-web/docs/IOS_INTEGRATION.md`](https://github.com/direwolfvm/bumpyride-web/blob/main/docs/IOS_INTEGRATION.md).
///
/// Today this implements only `getMe(token:)` (the token-validation probe used
/// when the user pastes a fresh token).  `uploadRide(_:token:)` will land in the
/// next phase when we add the per-ride sync queue.
actor WebSyncClient {
    /// Production base URL.  The Cloud Run fallback URL from the integration guide
    /// is intentionally not wired up here — we'd add it via a build-flag-selectable
    /// `baseURL` if/when QA needs to switch environments.
    static let defaultBaseURL = URL(string: "https://bumpyride.me")!

    enum ClientError: Error, Equatable {
        case unauthorized            // 401
        case validationFailed        // 400 — payload doesn't match SCHEMA.md
        case conflict                // 409 — ride owned by a different account
        case http(status: Int)       // any other non-2xx
        case transport               // URLSession threw (offline, DNS, TLS)
        case decoding                // 2xx with a body we can't parse
    }

    /// Subset of `/api/me` we care about.  `name` may be null on the server side.
    struct Me: Decodable, Equatable {
        let id: String
        let email: String
        let name: String?
    }

    private let baseURL: URL
    private let session: URLSession
    private let log = Logger(subsystem: "com.herbertindustries.BumpyRide", category: "websync")

    init(baseURL: URL = WebSyncClient.defaultBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Validate a bearer token by hitting `/api/me`.  On 2xx returns the identity
    /// the server associates with the token.  On 401 throws `.unauthorized` —
    /// callers should surface this to the user as "the token isn't valid".
    func getMe(token: String) async throws -> Me {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/me"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClientError.transport
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClientError.transport
        }

        switch http.statusCode {
        case 200..<300:
            do {
                return try JSONDecoder().decode(Me.self, from: data)
            } catch {
                throw ClientError.decoding
            }
        case 401:
            throw ClientError.unauthorized
        default:
            throw ClientError.http(status: http.statusCode)
        }
    }

    /// The shape of `/api/me/sharing` responses.  Both GET and PATCH return at least
    /// `shareToPublicMap`; PATCH additionally returns `changed`, which we don't read.
    private struct SharingResponse: Decodable {
        let shareToPublicMap: Bool
    }

    /// Wire-format type for `/api/me/calibration`.  Mirrors the spec at
    /// `docs/CALIBRATION.md`: `pocketGain` is the multiplier the server applies to
    /// pocket-mode samples; `confidence` is the count of overlapping cells the iOS
    /// algorithm used (the server applies the gain only when `confidence >= 3`).
    struct ServerCalibration: Codable, Equatable, Sendable {
        let pocketGain: Double
        let confidence: Int
        let lastComputedAt: Date?
    }

    /// Read the user's public-bump-map opt-in setting.
    func getSharing(token: String) async throws -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/me/sharing"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClientError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw ClientError.transport }

        switch http.statusCode {
        case 200..<300:
            do {
                return try JSONDecoder().decode(SharingResponse.self, from: data).shareToPublicMap
            } catch {
                throw ClientError.decoding
            }
        case 401:
            throw ClientError.unauthorized
        default:
            throw ClientError.http(status: http.statusCode)
        }
    }

    /// Flip the public-bump-map opt-in.  The server atomically backfills (or subtracts)
    /// the user's existing rides into the public aggregate, which for large libraries
    /// can take ~2 s — hence the longer-than-default timeout.  Idempotent: sending the
    /// same value the server already has returns 200 with `changed: false`, which we
    /// treat as success.
    func setSharing(shareToPublicMap: Bool, token: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/me/sharing"))
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10  // ~2 s expected; 10 s slack for retry & DNS

        let body = ["shareToPublicMap": shareToPublicMap]
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw ClientError.validationFailed
        }

        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw ClientError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw ClientError.transport }

        switch http.statusCode {
        case 200..<300:
            return
        case 400:
            throw ClientError.validationFailed
        case 401:
            throw ClientError.unauthorized
        default:
            throw ClientError.http(status: http.statusCode)
        }
    }

    /// Read the user's stored pocket-mode calibration from `GET /api/me/calibration`.
    /// Defaults (for users who've never PUT) come back as
    /// `{ pocketGain: 1.0, confidence: 0, lastComputedAt: null }`.
    func getCalibration(token: String) async throws -> ServerCalibration {
        log.info("GET /api/me/calibration")
        var request = URLRequest(url: baseURL.appendingPathComponent("api/me/calibration"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClientError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw ClientError.transport }

        switch http.statusCode {
        case 200..<300:
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode(ServerCalibration.self, from: data)
            } catch {
                throw ClientError.decoding
            }
        case 401:
            throw ClientError.unauthorized
        default:
            throw ClientError.http(status: http.statusCode)
        }
    }

    /// Write the user's pocket-mode calibration via `PUT /api/me/calibration`.
    /// Idempotent: writing the same value twice is harmless.  Server enforces the
    /// `[0.5, 5.0]` clamp on `pocketGain` and a non-negative `confidence`.
    func setCalibration(_ value: ServerCalibration, token: String) async throws {
        log.info("PUT /api/me/calibration — gain=\(value.pocketGain, privacy: .public) conf=\(value.confidence, privacy: .public)")
        var request = URLRequest(url: baseURL.appendingPathComponent("api/me/calibration"))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            request.httpBody = try encoder.encode(value)
        } catch {
            throw ClientError.validationFailed
        }

        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw ClientError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw ClientError.transport }

        switch http.statusCode {
        case 200..<300:
            return
        case 400:
            throw ClientError.validationFailed
        case 401:
            throw ClientError.unauthorized
        default:
            throw ClientError.http(status: http.statusCode)
        }
    }

    /// Upload a single ride to `POST /api/sync/ride`.  Idempotent on `Ride.id` —
    /// re-uploading the same ride (after a trim/split, after a retry, etc.) is safe
    /// and reconciles the server-side aggregate.
    ///
    /// The body is passed in as pre-encoded JSON `Data` so the encode step happens
    /// on the caller's actor.  This avoids hopping `Ride`'s MainActor-isolated
    /// `Encodable` conformance into this non-MainActor actor.
    func uploadRide(jsonBody: Data, token: String) async throws {
        log.info("POST /api/sync/ride — \(jsonBody.count, privacy: .public) byte body")
        var request = URLRequest(url: baseURL.appendingPathComponent("api/sync/ride"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Rides can be several MB once accelWindow is included; allow the network
        // stack longer than the default for /api/me.
        request.timeoutInterval = 60
        request.httpBody = jsonBody

        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw ClientError.transport
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClientError.transport
        }

        switch http.statusCode {
        case 200..<300:
            return
        case 400:
            throw ClientError.validationFailed
        case 401:
            throw ClientError.unauthorized
        case 409:
            throw ClientError.conflict
        default:
            throw ClientError.http(status: http.statusCode)
        }
    }
}
