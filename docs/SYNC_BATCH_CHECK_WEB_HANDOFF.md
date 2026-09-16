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

---

## Field report 2026-09-16 — the endpoint has never pruned anything

**iOS → web. Not urgent (the client now works around it), but the
endpoint is currently a no-op and should either be fixed or retired.**

### Symptom

Every drain, on a fully-backfilled library, gets back *all* rides in
`needed`:

```
drain start: queued=238 (user=1 backfill=237) ...
server batch check: 0/237 already on server, 237 to upload
```

That is 0 pruned out of 237, on every request. The decisive detail:
one drain uploaded **131 rides successfully (HTTP 200)**, and the very
next check, minutes later, still reported `0/239 already on server`.
Uploading does not make a ride subsequently report as present.

Consequence on the device: the app re-uploaded its library repeatedly —
**453 MB in a single drain, 519 MB of cellular in one day** against a
627 MB library.

### Ruled out on the iOS side

Before raising this we checked our own half of the contract:

- The submitted `hash` is SHA-256 (lowercase hex) of the **exact bytes**
  sent as the `POST /api/sync/ride` body. The upload writes that same
  buffer to a file and uploads from it; nothing re-encodes in between.
- Encoding is byte-stable: `encode(decode(file))` produces identical
  bytes across independent loads (tested directly), so our hash for an
  unchanged ride does not drift between drains.
- The client also keeps its own record of the hash the server accepted,
  and that record likewise never matched — consistent with the server
  storing something other than what we sent, rather than with client
  instability.

### Leading hypothesis

`content_hash` looks like it is derived from the **re-materialized**
payload rather than from the raw upload body — Option B in
`SYNC_CHECKSUM_WEB_HANDOFF.md`, which that doc flags as "strongly
discouraged" precisely because "any subtle difference in key ordering,
whitespace, floating-point repr, or date format ... will produce a
mismatch even when the rides are semantically identical."

Two things in `WEB_WORK_ORDER.md` item 1 make that fit:

1. Ride payloads are stored **decomposed into relational tables** and
   re-materialized from columns, so there is no raw body retained to
   hash unless it is hashed at ingest.
2. The documented normalization — restored timestamps come back as
   `...T10:01:00.000Z` whatever offset form was uploaded, "key-complete,
   not byte-identical". A date-format difference **alone** guarantees a
   permanent mismatch for every ride.

Alternative worth checking first because it is cheaper: `content_hash`
is simply NULL for these rows. The shipped notes above already list
"null stored hash (pre-migration-0015 rides)" as always-`needed`, and
if the upload path never populates it, every ride stays in that state
forever.

### Cheapest diagnostic

Take one ride that iOS has definitely uploaded. Compare:

```sql
SELECT content_hash FROM rides WHERE ride_uuid = '<id>';
```

against `sha256(<raw bytes of the last POST /api/sync/ride body>)`.

- NULL → the upload path isn't populating it.
- Present but different → it is being computed from the decomposed or
  re-materialized form; switch to hashing the request body at ingest
  (Option A) and backfill.

### What we need

`content_hash` = `sha256(raw request body)` recorded at upload time, so
that a ride just uploaded reports as present on the next check. Existing
rows need a backfill, or they will report `needed` until their next
upload.

### Not blocking

iOS v2.1 added a local ledger (`SyncLedger`) recording the hash of the
body the server accepted per ride, pruned before any network call. Steady
state is now zero requests instead of one per ride, so the batch endpoint
is no longer load-bearing for us. Fixing it restores a useful
cross-check; leaving it as-is costs a redundant round-trip per drain.

**Note the web-side-edit case documented above is different and remains
correct** — a ride edited on the web *should* report `needed`. What is
wrong here is that rides never touched by the web editor also always do.

