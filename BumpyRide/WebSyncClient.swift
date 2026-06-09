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

    /// Server-side state of `/api/me/sharing`.  GET always returns both fields;
    /// PATCH bodies may include either, both, or neither (server keeps unsent
    /// fields unchanged) — but the PATCH response always returns the full
    /// post-mutation state, plus a `changed` boolean we don't model because
    /// we adopt the returned values regardless.
    ///
    /// The contract has a force-off rule the server enforces: setting
    /// `shareToPublicMap = false` clears `publicMapEager` to `false`; sending
    /// `publicMapEager = true` while sharing is off is clamped to `false`.
    /// Callers MUST trust the returned struct rather than echoing what they
    /// sent, otherwise the UI will drift out of sync with reality.
    struct SharingSettings: Codable, Equatable, Sendable {
        let shareToPublicMap: Bool
        let publicMapEager: Bool
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

    /// Server-side state of `/api/me/score`.  Contract from bumpyride-web PR #39:
    /// gamification layer on top of the public bump map.  Three tiers of points
    /// for each 20 ft cell a ride touches — 10 / 5 / 1 — with a 20-level
    /// progression ladder.
    ///
    /// `eligible` is false when the user isn't currently sharing publicly.
    /// In that state, all the counts and points are zero and the level is
    /// the starting one — the UI uses this flag to swap to an empty-state
    /// view rather than showing a misleadingly-low score.
    struct ScoreData: Codable, Equatable, Sendable {
        let totalPoints: Int
        let breakdown: ScoreBreakdown
        let level: CurrentLevel
        /// All 20 levels in ascending order.  Server side stores them in
        /// `src/lib/levels.ts`; we don't duplicate the list on iOS — we
        /// just render what the server sends.  Lets the server add levels
        /// (or rename them) without an iOS update.
        let levels: [Level]
        let eligible: Bool
    }

    /// Per-tier cell counts from `/api/me/score`.  These are *cell counts*,
    /// not point totals — multiply by the tier weights (10 / 5 / 1) to get
    /// the per-tier contribution to `totalPoints`.
    ///
    /// Note: server JSON key is `repeat`, which is a Swift keyword.  Mapped
    /// to `repeats` (plural) via `CodingKeys` for ergonomic call-site usage.
    struct ScoreBreakdown: Codable, Equatable, Sendable {
        /// Count of cells where this user was the first ever to record bump
        /// data.  Each contributes 10 points.
        let firstEver: Int
        /// Count of cells where this user was the first of their rides but
        /// others had already mapped them.  Each contributes 5 points.
        let firstForYou: Int
        /// Count of cells the user has been to before, but whose previous
        /// visit was more than 10 days ago (server-defined window
        /// `STALE_REFRESH_DAYS`).  Each contributes 3 points.  Server-side
        /// migration 0016 added this tier between `firstForYou` and
        /// `repeats`; older server deployments don't return it, so it's
        /// optional and defaults to 0 at the call site.
        let staleRefresh: Int?
        /// Count of subsequent visits to cells this user already mapped
        /// within the freshness window.  Each contributes 1 point.
        let repeats: Int

        private enum CodingKeys: String, CodingKey {
            case firstEver
            case firstForYou
            case staleRefresh
            case repeats = "repeat"
        }
    }

    /// Where the user currently sits on the 20-level ladder.  `progress` is
    /// 0.0 at the bottom of this level and 1.0 right before the next one
    /// (server computed against `threshold` and `nextThreshold`).  At the
    /// top level, `nextThreshold == threshold` and `progress == 1.0` — the
    /// UI should treat that as "maxed out."
    struct CurrentLevel: Codable, Equatable, Sendable {
        let index: Int
        let name: String
        let threshold: Int
        let nextThreshold: Int
        let progress: Double
    }

    /// Server-side state of `GET /api/rides/{id}/score`.  Smaller sibling of
    /// `ScoreData`: same `ScoreBreakdown` shape (so iOS can reuse the type
    /// it already has), but scoped to a single ride's `score_events` rather
    /// than the user's lifetime totals.
    ///
    /// `eligible` is the 200-with-flag pattern documented in
    /// `docs/PER_RIDE_SCORE_WEB_HANDOFF.md`: covers both pocket-mode rides
    /// and rides uploaded while sharing was off, distinguishing "this
    /// specific ride didn't qualify" from "ride doesn't exist" (which is
    /// 404) without throwing.  All counts are zero when `eligible: false`.
    struct RideScoreData: Codable, Equatable, Sendable {
        let rideId: UUID
        let totalPoints: Int
        let breakdown: ScoreBreakdown
        let eligible: Bool
    }

    /// Lightweight metadata for one ride from `/api/sync/rides`.  Used by
    /// the iOS restore flow to drive the confirmation UI ("N rides on
    /// server, ~X MB to download") and then iterate by id to fetch each
    /// full payload via `/api/sync/ride/{id}`.
    ///
    /// `sizeBytes` is an *estimate* derived server-side from
    /// `point_count` (per `docs/SERVER_RESTORE_WEB_HANDOFF.md`) — close
    /// enough to size the user-facing download warning, but not a
    /// commitment to exact wire-bytes.  Don't pre-allocate buffers off
    /// it.
    struct RideManifest: Codable, Equatable, Sendable, Identifiable {
        let id: UUID
        let title: String
        let startedAt: Date
        let endedAt: Date
        let pointCount: Int
        let sizeBytes: Int
    }

    /// One page of the cursor-paginated `/api/sync/rides` response.
    /// `nextCursor == nil` is the terminal page.  `totalCount` is the
    /// global count across all pages, used by the progress sheet.
    struct RideListPage: Codable, Equatable, Sendable {
        let rides: [RideManifest]
        let nextCursor: String?
        let totalCount: Int
    }

    /// One row in the level ladder.  `id` from `index` for `ForEach`.
    struct Level: Codable, Equatable, Sendable, Identifiable {
        let index: Int
        let name: String
        let threshold: Int

        var id: Int { index }
    }

    /// Read the user's full public-bump-map sharing state.  Returns both
    /// `shareToPublicMap` and `publicMapEager` — see `SharingSettings`.
    func getSharing(token: String) async throws -> SharingSettings {
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
                return try JSONDecoder().decode(SharingSettings.self, from: data)
            } catch {
                throw ClientError.decoding
            }
        case 401:
            throw ClientError.unauthorized
        default:
            throw ClientError.http(status: http.statusCode)
        }
    }

    /// Update one or both sharing fields.  Each field is optional in the body —
    /// the server keeps omitted fields at their current value.  When
    /// `shareToPublicMap` flips on or off, the server atomically backfills (or
    /// subtracts) the user's existing rides into the public aggregate, which
    /// for large libraries can take ~2 s — hence the longer-than-default
    /// timeout.  Idempotent: sending the same value the server already has
    /// returns 200 with `changed: false`, which we treat as success.
    ///
    /// Returns the server's authoritative post-PATCH state.  Callers should
    /// adopt this directly rather than echoing what they sent: the server
    /// enforces a force-off rule (turning `shareToPublicMap` off clears
    /// `publicMapEager`) and clamps `publicMapEager = true` to `false` if
    /// sharing is currently off.
    func setSharing(
        shareToPublicMap: Bool? = nil,
        publicMapEager: Bool? = nil,
        token: String
    ) async throws -> SharingSettings {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/me/sharing"))
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10  // ~2 s expected; 10 s slack for retry & DNS

        // Build the body with only the fields the caller supplied.  Sending an
        // empty body is technically valid (server treats it as a read-only no-op
        // that still returns current state) but we don't bother modeling it —
        // the public API requires at least one non-nil field for any useful call.
        var body: [String: Bool] = [:]
        if let v = shareToPublicMap { body["shareToPublicMap"] = v }
        if let v = publicMapEager { body["publicMapEager"] = v }
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw ClientError.validationFailed
        }

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
            // PATCH responses also include `"changed": Bool`; SharingSettings
            // doesn't model it (the field is uninteresting once we have the
            // post-state) and JSONDecoder ignores unknown keys by default,
            // so the decode is lossy-but-correct.
            do {
                return try JSONDecoder().decode(SharingSettings.self, from: data)
            } catch {
                throw ClientError.decoding
            }
        case 400:
            throw ClientError.validationFailed
        case 401:
            throw ClientError.unauthorized
        default:
            throw ClientError.http(status: http.statusCode)
        }
    }

    /// Wire-format response from `/api/me/clear-data` and
    /// `/api/me/delete-account`.  Both endpoints return the same shape:
    ///
    /// - `ok` is always true on a 2xx (server raises a status code otherwise).
    /// - `ridesOrphaned` is the count of rides re-parented to an anonymized
    ///   user when `keepPublicContributions = true`.  Their per-cell
    ///   contributions stay on the public maps; the link to the original
    ///   account is severed.
    /// - `ridesDeleted` is the count of rides fully deleted (cascade-delete
    ///   plus public-map subtraction).  Happens when
    ///   `keepPublicContributions = false` *or* the user wasn't sharing
    ///   publicly to begin with.
    ///
    /// Exactly one of `ridesOrphaned` / `ridesDeleted` will be non-zero per
    /// call — the four-way matrix on the server's side maps the user's
    /// (sharing? × keep?) combination to one bucket or the other.  iOS
    /// uses the numbers for confirmation copy ("Removed 47 rides").
    struct DataDeletionResult: Codable, Equatable, Sendable {
        let ok: Bool
        let ridesOrphaned: Int
        let ridesDeleted: Int
    }

    /// `POST /api/me/clear-data` — drop every ride from the server, keep the
    /// account.  `keepPublicContributions = true` re-parents the rides to a
    /// fresh anonymized user so their public-map cells survive; `false`
    /// cascade-deletes the rides and subtracts their contributions from the
    /// public aggregate (same path as flipping the sharing toggle off).
    ///
    /// Returns the deletion summary.  Like the sharing endpoint, slow path
    /// can take a couple seconds for a large library, so we use the same
    /// 10 s timeout.  Token stays valid after this call (only the user's
    /// rides are touched).
    func clearData(keepPublicContributions: Bool, token: String) async throws -> DataDeletionResult {
        log.info("POST /api/me/clear-data keep=\(keepPublicContributions, privacy: .public)")
        var request = URLRequest(url: baseURL.appendingPathComponent("api/me/clear-data"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        do {
            request.httpBody = try JSONEncoder().encode(["keepPublicContributions": keepPublicContributions])
        } catch {
            throw ClientError.validationFailed
        }

        return try await postAndDecode(request)
    }

    /// `POST /api/me/delete-account` — drop every ride AND remove the user.
    /// The server requires `confirmEmail` to match the account's email
    /// (case-insensitive) as a stray-click guard.  Behavior of
    /// `keepPublicContributions` is identical to `clearData` above; what
    /// changes is that the user row itself is dropped (or replaced with
    /// the anonymized stub holding the orphaned rides).
    ///
    /// **After a successful 2xx, the bearer token is invalidated server-
    /// side** — the user row is gone (or anonymized) and the token
    /// cascade-dropped with it.  Subsequent calls with the same token
    /// return 401.  Callers should treat this as the trigger to wipe the
    /// local Keychain entry and transition to a disconnected state.
    func deleteAccount(
        keepPublicContributions: Bool,
        confirmEmail: String,
        token: String
    ) async throws -> DataDeletionResult {
        log.info("POST /api/me/delete-account keep=\(keepPublicContributions, privacy: .public)")
        var request = URLRequest(url: baseURL.appendingPathComponent("api/me/delete-account"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        struct Body: Encodable {
            let keepPublicContributions: Bool
            let confirmEmail: String
        }
        do {
            request.httpBody = try JSONEncoder().encode(Body(
                keepPublicContributions: keepPublicContributions,
                confirmEmail: confirmEmail
            ))
        } catch {
            throw ClientError.validationFailed
        }

        return try await postAndDecode(request)
    }

    /// Shared 2xx/400/401/error decode path for the two destructive
    /// endpoints.  Both have identical response shape and error mapping,
    /// so factoring this out keeps the calling methods readable.
    private func postAndDecode(_ request: URLRequest) async throws -> DataDeletionResult {
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
                return try JSONDecoder().decode(DataDeletionResult.self, from: data)
            } catch {
                throw ClientError.decoding
            }
        case 400:
            // Wrong confirmEmail, missing field, etc.  Caller surfaces this
            // as a user-fixable error (probably "the email doesn't match").
            throw ClientError.validationFailed
        case 401:
            throw ClientError.unauthorized
        default:
            throw ClientError.http(status: http.statusCode)
        }
    }

    /// Read the user's gamification score from `GET /api/me/score`.  Server
    /// is authoritative for both the totals and the level progression; iOS
    /// just renders what comes back.  See `ScoreData` for the structure.
    ///
    /// When the user isn't currently sharing publicly, the server still
    /// responds 200 with `eligible: false` and zeroed-out counts — the UI
    /// uses the flag to switch to an empty state rather than displaying
    /// a misleading "0 points" hero card.
    func getScore(token: String) async throws -> ScoreData {
        log.info("GET /api/me/score")
        var request = URLRequest(url: baseURL.appendingPathComponent("api/me/score"))
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
                return try JSONDecoder().decode(ScoreData.self, from: data)
            } catch {
                throw ClientError.decoding
            }
        case 401:
            throw ClientError.unauthorized
        default:
            throw ClientError.http(status: http.statusCode)
        }
    }

    /// Read the per-ride score from `GET /api/rides/{id}/score`.  Returns
    /// `RideScoreData` with the same breakdown shape as `/api/me/score`,
    /// scoped to this one ride's `score_events` rows server-side.
    ///
    /// Per the contract in `docs/PER_RIDE_SCORE_WEB_HANDOFF.md`, 404 means
    /// the ride doesn't exist or isn't owned by this user; 200 with
    /// `eligible: false` means the ride exists but didn't earn points
    /// (pocket-mode or sharing-off at sync time).  Callers should hide the
    /// "Points earned" stat on `eligible: false` rather than show 0.
    func getRideScore(rideId: UUID, token: String) async throws -> RideScoreData {
        log.info("GET /api/rides/\(rideId.uuidString, privacy: .public)/score")
        var request = URLRequest(url: baseURL.appendingPathComponent("api/rides/\(rideId.uuidString)/score"))
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
                return try JSONDecoder().decode(RideScoreData.self, from: data)
            } catch {
                throw ClientError.decoding
            }
        case 401:
            throw ClientError.unauthorized
        case 404:
            // Ride doesn't exist or isn't owned by this token's user.
            // Distinct from the eligible: false case (which is 200).
            throw ClientError.http(status: 404)
        default:
            throw ClientError.http(status: http.statusCode)
        }
    }

    /// List one page of the user's rides from `GET /api/sync/rides` for
    /// the restore flow.  Cursor-paginated; `cursor == nil` returns the
    /// first page (sorted `started_at DESC` per the contract).
    /// `nextCursor == nil` in the response means we've hit the end.
    ///
    /// `limit` defaults server-side to 100, capped at 500.  We pass
    /// `nil` (server default) here; the orchestrator in the
    /// `RestoreCoordinator` controls page size via this knob.
    func listRides(cursor: String? = nil, limit: Int? = nil, token: String) async throws -> RideListPage {
        log.info("GET /api/sync/rides (cursor=\(cursor != nil, privacy: .public), limit=\(limit ?? 0, privacy: .public))")
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/sync/rides"),
            resolvingAgainstBaseURL: false
        )!
        var queryItems: [URLQueryItem] = []
        if let cursor { queryItems.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let limit { queryItems.append(URLQueryItem(name: "limit", value: "\(limit)")) }
        if !queryItems.isEmpty { components.queryItems = queryItems }

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Generous timeout; the list query is cheap server-side, but
        // we'd rather forgive a slow network than fail the whole
        // restore on a transient.
        request.timeoutInterval = 15

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
                return try decoder.decode(RideListPage.self, from: data)
            } catch {
                throw ClientError.decoding
            }
        case 400:
            // Most likely a stale or malformed cursor.  Surfaces as a
            // restartable failure — the user can retry from page 1.
            throw ClientError.validationFailed
        case 401:
            throw ClientError.unauthorized
        default:
            throw ClientError.http(status: http.statusCode)
        }
    }

    /// Download a full ride payload from `GET /api/sync/ride/{id}` as
    /// raw bytes.  Returns the iOS-shape JSON the server stores for
    /// this ride; the caller decodes on its own actor.
    ///
    /// Returning `Data` rather than `Ride` mirrors the pattern in
    /// `uploadRide(jsonBody:)`: `Ride`'s `Decodable` (and `Encodable`)
    /// conformance is `MainActor`-isolated, which the actor-isolated
    /// `WebSyncClient` can't reach into without a Swift 6 violation.
    /// The caller (typically `RestoreCoordinator` on `@MainActor`)
    /// decodes the bytes using the standard `.iso8601` strategy.
    ///
    /// Timeout is bumped to 60 s here because individual ride payloads
    /// can be multi-MB on long pocketed rides (the May 27 export was
    /// 5.4 MB).  At very slow connections we'd rather wait than fail
    /// and have to retry from scratch — and the RestoreCoordinator
    /// retries individual rides on transport errors anyway.
    func downloadRide(rideId: UUID, token: String) async throws -> Data {
        log.info("GET /api/sync/ride/\(rideId.uuidString, privacy: .public)")
        var request = URLRequest(url: baseURL.appendingPathComponent("api/sync/ride/\(rideId.uuidString)"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60

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
            return data
        case 401:
            throw ClientError.unauthorized
        case 404:
            // Ride doesn't exist (or doesn't belong to this user, which
            // the server collapses into a 404 to avoid leaking
            // enumeration).  Distinct case worth surfacing so the
            // RestoreCoordinator can skip and continue.
            throw ClientError.http(status: 404)
        case 429:
            // Server-side rate limit.  Surfaces as a generic transient
            // error; caller backs off and retries.
            throw ClientError.http(status: 429)
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
    /// Response from `POST /api/sync/ride/check` — the v1.7 H5
    /// backfill-skip optimization.  See
    /// `docs/SYNC_CHECKSUM_WEB_HANDOFF.md` for the full contract.
    struct RideCheckResponse: Codable, Equatable, Sendable {
        /// `true` if the server has a ride row with the given UUID.
        /// `false` means we have to upload — server has nothing.
        let exists: Bool
        /// `true` if the SHA-256 of the server's stored ride payload
        /// matches the hash the client supplied.  Only meaningful
        /// when `exists == true`.  When `exists && hashMatches`,
        /// the client can skip the multi-MB upload entirely.
        let hashMatches: Bool
    }

    /// Ask the server whether it already has a ride byte-for-byte
    /// before uploading it.  v1.7 H5 backfill optimization: a
    /// freshly-paired user who's about to upload 50 historical
    /// rides can skip the upload of any ride the server already
    /// has stored with the same content hash, instead of
    /// re-shipping multi-MB payloads.
    ///
    /// Per the handoff doc (`docs/SYNC_CHECKSUM_WEB_HANDOFF.md`),
    /// the server computes its hash on the same wire bytes the
    /// client would send (the iOS-encoded ride JSON).
    ///
    /// Returns `.exists: false` for any ride id the server hasn't
    /// seen — that's the upload-path signal.  Returns
    /// `.exists: true, .hashMatches: false` when the server has a
    /// ride with the same UUID but different content (e.g., the
    /// user trimmed locally and the local copy is newer) — also
    /// an upload-path signal.  Only `.exists && .hashMatches`
    /// authorizes the client to skip upload.
    ///
    /// Errors mirror `uploadRide`'s: 401 → unauthorized, 4xx →
    /// validation/http, transport → transport.
    func checkRide(id: UUID, hash: String, token: String) async throws -> RideCheckResponse {
        log.debug("POST /api/sync/ride/check — id=\(id, privacy: .public)")
        var request = URLRequest(url: baseURL.appendingPathComponent("api/sync/ride/check"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        struct Request: Encodable {
            let rideId: UUID
            let hash: String
        }
        do {
            request.httpBody = try JSONEncoder().encode(Request(rideId: id, hash: hash))
        } catch {
            throw ClientError.validationFailed
        }

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
                return try JSONDecoder().decode(RideCheckResponse.self, from: data)
            } catch {
                throw ClientError.decoding
            }
        case 400:
            throw ClientError.validationFailed
        case 401:
            throw ClientError.unauthorized
        default:
            throw ClientError.http(status: http.statusCode)
        }
    }

    func uploadRide(jsonBody: Data, token: String) async throws {
        // .debug (not .info) — during a backlog catch-up this fires for every
        // queued ride in rapid succession, and we recently learned that
        // per-action .info volume contributes to OSLog subsystem quarantine.
        // .debug stays in-memory only; sufficient for live Console debugging
        // but doesn't reach disk in production.
        log.debug("POST /api/sync/ride — \(jsonBody.count, privacy: .public) byte body")
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
