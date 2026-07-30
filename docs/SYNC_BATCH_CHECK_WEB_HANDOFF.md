# Web handoff: batch sync-status check (`/api/sync/ride/check-batch`)

**iOS side: shipped in v1.8 (L1).** The app calls the new endpoint and
falls back to the existing per-ride `/api/sync/ride/check` when it gets
a 404, so the web deploy can land whenever — no coordination needed.

## Why

The v1.7 H5 checksum skip (`SYNC_CHECKSUM_WEB_HANDOFF.md`) checks rides
**one at a time**. A drain pass over a fully-backfilled library (~75
rides) makes 75 sequential HTTP round-trips just to learn that nothing
needs uploading. Observed in the field after the v1.7 detector-revision
bump re-enqueued every ride: even the no-op case took minutes of
serialized checks. One batch request answers the whole queue at once.

## Endpoint

`POST /api/sync/ride/check-batch` — Bearer-token auth, same token the
other `/api/sync/*` endpoints accept.

### Request

```json
{
  "rides": [
    { "rideId": "42DD7057-8A58-47AA-BA6A-02010181AAE2", "hash": "<sha256 hex>" },
    { "rideId": "EF643716-B76A-4720-9088-3095D7597CFA", "hash": "<sha256 hex>" }
  ]
}
```

- `hash` is the SHA-256 (lowercase hex) of the iOS-encoded ride JSON —
  **identical semantics to the existing single check endpoint**. The
  server compares against the same stored content hash
  (`rides.content_hash`, migration 0015).
- Client sends up to its full backfill queue; cap request size
  server-side at something generous (say 500 entries) and return 400
  beyond it. The iOS client today will never exceed a few hundred.

### Response — 200

```json
{ "needed": ["EF643716-B76A-4720-9088-3095D7597CFA"] }
```

- `needed` = ride ids the client must upload: **missing** on the server
  OR stored with a **different** content hash. Order irrelevant.
- Ids absent from `needed` are present-with-matching-hash; the client
  prunes them from its queue without uploading.
- Ids in the request that belong to a *different* account should be
  included in `needed` (the subsequent upload will surface the 409
  conflict exactly as it does today — don't leak other-account
  existence through this endpoint).

### Errors

- `401` unauthenticated — same shape as the other sync endpoints.
- `400` malformed body / over the entry cap.
- Anything else (including the pre-deploy `404`): the iOS client
  silently falls back to per-ride checks, so failure here is never
  user-visible.

## Implementation sketch (web)

One query: `SELECT id, content_hash FROM rides WHERE user_id = $me AND
id = ANY($ids)`, then diff against the submitted pairs. No per-ride
payload reads — `content_hash` is already materialized by migration
0015.

## iOS behavior (for reference)

At the top of a drain pass, if ≥2 backfill rides are queued, the app
encodes + hashes each locally (same work the per-ride path did, just
front-loaded), sends one batch request, prunes everything not in
`needed`, and skips the in-loop per-ride checks for that drain.
User-initiated rides are excluded — they always upload, since the
local copy is the source of truth.

---

## Status: SHIPPED (web, 2026-07-30)

`POST /api/sync/ride/check-batch` is live and matches this contract.
Re-verified against the acceptance criteria on 2026-07-30.

- `{rides: [{rideId, hash}]}` → `{needed: [ids]}`. Bearer auth.
- One indexed query over the caller's own rides (`user_id` +
  `ride_uuid = ANY`), no payload reads, as sketched.
- `needed` = missing **or** foreign-owned **or** null stored hash
  (pre-migration-0015 rides) **or** hash mismatch. Foreign-owned ids
  are reported `needed` rather than 404/403, so the endpoint leaks no
  existence information; the upload path's 409 still owns conflict
  signaling.
- `rideId` is accepted case-insensitively and echoed lowercase; `hash`
  must be 64 lowercase hex chars.
- Cap: 500 entries. 501 → `400`. Empty array → `{needed: []}` without
  touching the DB.
- Repeated ids within one request are deduped, **first entry wins**.

Acceptance verified: a 75-ride drain resolves in a single request, and
an in-sync ride is correctly absent from `needed` (no re-upload).

### Interaction with web-side ride edits

As anticipated in the work order: rides edited on the web (trim,
split, rename) carry a **server-canonical** `content_hash` — a hash of
the server's own JSON serialization, which never equals a hash of the
client's raw bytes. Such rides therefore always report as `needed`.
That is correct and intended: the device copy really is stale. When
iOS then uploads, the `editedAt` conflict rule returns `409 {"error":
"edit conflict", "serverEditedAt": ...}` and the client pulls the
server copy instead. See `RIDE_EDIT_WEB_HANDOFF.md`.
