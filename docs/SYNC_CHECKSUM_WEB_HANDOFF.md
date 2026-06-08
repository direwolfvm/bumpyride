# Sync Checksum (v1.7 H5) — Web Handoff

This document defines the contract for `POST /api/sync/ride/check`, the optimization that lets the iOS client skip re-uploading backfill rides the server already has byte-for-byte.

The iOS client side ships in v1.7 (committed alongside this doc). The endpoint is **strictly opt-in** from the client's perspective: if the endpoint returns a 4xx/5xx, the client silently falls through to the normal `POST /api/sync/ride` upload path. So the web side can deploy in any order without breaking iOS.

---

## Goal

A freshly-paired user lands on the iPhone with N historical rides that need to push to the web account. Many of those rides may already be on the server from previous installs / other devices. Today the iOS client uploads all of them blind, re-sending the full multi-MB payload for each — wasteful bandwidth, time, and server compute.

With the check endpoint, the client computes a SHA-256 of the JSON wire bytes it *would* upload, asks the server "do you have this ride with this hash?", and skips the upload if so.

---

## Endpoint

### `POST /api/sync/ride/check`

#### Request

Headers:
```
Authorization: Bearer <token>
Content-Type: application/json
```

Body:
```json
{
  "rideId": "55E9B0BB-7CBE-4F23-9E0A-1D2C3F4A5B6C",
  "hash": "9af15a3a7b8c0e5f4d2e1a0b9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d"
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `rideId` | UUID string (uppercase) | Yes | The ride's stable `Ride.id`. Matches the `id` field documented in `SCHEMA.md`. |
| `hash` | hex string, 64 chars | Yes | SHA-256 of the wire bytes the client would send to `POST /api/sync/ride`. Lowercase hex, no leading `0x`. |

#### Response

`200 OK`:
```json
{
  "exists": true,
  "hashMatches": true
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `exists` | bool | Yes | `true` if the server has a ride row with the given `rideId`. `false` otherwise. |
| `hashMatches` | bool | Yes | `true` if the server's stored content hash matches the client's. Meaningless when `exists == false` — set to `false` for consistency. |

Other status codes:

| Status | Meaning | iOS client behavior |
|---|---|---|
| `400` | Malformed request body | Falls through to upload path. Logs the failure. |
| `401` | Invalid / expired token | Invalidates the local account, surfaces the "needs to re-pair" UI. Same path as 401 from `/api/sync/ride`. |
| `5xx` | Server error | Falls through to upload path. Doesn't retry the check. |

The iOS client treats *any* non-200 response as "upload normally." It will never persist a wrong answer.

---

## Hashing details

### What gets hashed

The SHA-256 input is the **exact bytes the iOS client would send to `POST /api/sync/ride`** as the request body. The client computes this from the same `JSONEncoder` instance used by the upload path.

This means the server must hash on the **same bytes** — specifically, on what the iOS client sent during the original upload, not on a re-serialization of the parsed model.

### How the server should compute and store the hash

Two implementation options, equivalent from the client's perspective:

#### Option A — Hash on first upload, store

When `POST /api/sync/ride` lands, before parsing the body for storage:

```
hash = sha256(request.body)
```

Store this hash alongside the ride row (e.g., a `content_hash` column). On a check request, look it up by `rideId` and string-compare against the client's submitted `hash`.

This is the simplest path and matches "what the client actually sent" exactly. Recommended.

#### Option B — Re-serialize on demand

Re-serialize the stored ride model to JSON on each check request and hash that. **Strongly discouraged**: any subtle difference in key ordering, whitespace, floating-point repr, or date format between Swift's `JSONEncoder` and the server's serializer will produce a mismatch even when the rides are semantically identical, and the optimization silently no-ops.

If Option B is the only option, the server must use **the same canonicalization the iOS client uses**: ISO-8601 dates with timezone, no whitespace between keys/values, Swift's default float repr, key order matching `Ride.CodingKeys`.

### Hash algorithm

- **SHA-256** (RFC 4634). Standard library on every platform; FIPS-approved; collision-resistant for this scale.
- Output: 32 bytes, hex-encoded lowercase (64 chars).

The iOS client uses `CryptoKit.SHA256.hash(data:)` and converts to lowercase hex via `.map { String(format: "%02x", $0) }.joined()`.

---

## When the iOS client calls this

**Backfill rides only.** The client tracks two buckets per `SyncQueue`: `userInitiatedIds` (newly-saved rides) and `backfillIds` (catch-up after pairing). User-initiated rides ALWAYS upload — they're the local source of truth, and a 50 ms check round-trip would just delay the v1.7 H1+H2+H3 fast-path (which gets the per-ride score and level-up celebration into the user's hands within seconds of the upload).

Backfill rides take the check path:

```
1. SyncCoordinator picks the next backfill ride.
2. Encode body as if uploading.
3. Compute SHA-256 of the encoded body.
4. POST /api/sync/ride/check with rideId + hash.
5. If exists && hashMatches: remove from queue without uploading.
6. Else: POST /api/sync/ride with the full body as before.
```

The check happens once per backfill ride. Failures don't loop — they fall through to the upload path immediately.

---

## Expected impact

For a user who reinstalls the app with their original web account:

| Scenario | v1.6 behavior | v1.7 H5 behavior |
|---|---|---|
| 50 rides queued for backfill, all already on server | 50 × multi-MB POSTs (minutes) | 50 × ~200 B check requests (seconds) |
| 50 rides queued, none on server | 50 × multi-MB POSTs (no change) | 50 × ~200 B checks + 50 × multi-MB POSTs (slightly slower) |
| Mixed: 30 already on server, 20 new | 50 × multi-MB POSTs | 50 × ~200 B checks + 20 × multi-MB POSTs (~60% bandwidth saved) |

The pessimistic case (no rides on server) is ~200 B × N extra requests. At typical N <= 100 this is well under 20 KB of overhead.

---

## Things the server can rely on

- `rideId` is always a valid UUID string. Malformed → 400.
- `hash` is always exactly 64 lowercase hex characters. Malformed → 400.
- The Authorization header is always present (the iOS client gates on `webAccount.isConnected`). If missing → 401.
- The client retries gracefully — a transient 5xx isn't a permanent skip; the client will upload the ride normally and the next backfill pass will re-check.

## Things the server should NOT do

- **Don't 404 for unknown ride IDs.** Return `{exists: false, hashMatches: false}` with 200. The iOS client treats this as "upload normally" — same as a fresh ride. A 404 would be surface-level wrong (the ride does exist locally) and the client may interpret it differently.
- **Don't include the ride payload in the check response.** This endpoint is purely a yes/no signal. Keep it small.

---

## Open questions

None blocking. Ship when ready; iOS H5 is already in place and falls through correctly if the endpoint isn't yet deployed.

If the web side wants to evolve the hash algorithm later (e.g., SHA-384 for some reason), add a `hashAlgo` field to the request and version the contract.
