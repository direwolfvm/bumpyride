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


---

## Web response 2026-09-16 — both hypotheses ruled out; hash now echoed

Investigated against production. **Neither suspected cause holds**, so
the fix is different from the one requested — details below, because
the difference matters for what iOS should do next.

### `content_hash` is neither NULL nor server-canonical

Read-only query against the production database (246 rides):

| | |
|---|---|
| total rides | 246 |
| `content_hash` **present** | **242** |
| `content_hash` NULL | 4 |
| all present values 64-char lowercase hex | yes |
| rides updated since the 07-30 deploy | 241, **0 of them NULL** |

So the cheap hypothesis (the column is simply NULL) is out: it is
populated, well-formed, and freshly written on every upload.

The Option-B hypothesis is out too. The ingest path has hashed the
**raw request body** since the original checksum PR:

```ts
rawBody = await req.text();
payload = rideSchema.parse(JSON.parse(rawBody));
const contentHash = createHash('sha256').update(rawBody, 'utf8').digest('hex');
```

Nothing re-serializes before hashing, so the timestamp normalization
cited in `WEB_WORK_ORDER.md` item 1 cannot reach it — that normalization
happens on *restore*, long after the hash is taken. Verified locally
end-to-end: upload a ride, hash the exact bytes client-side, call
`check-batch` with that value → **pruned**. Holds for UTF-8 titles
(`Café ride — caña 🚴`) and for uppercase iOS-style ride ids.

Also checked, so they can be crossed off: production runs exactly the
current code (revision `bumpyride-web-00070-b9b`, image `9e411a5`), and
the uploads themselves arrive clean — `POST /api/sync/ride` → `200`,
bodies 0.9–5.3 MB, no content-encoding, no truncation.

### What that leaves

The server stores `sha256(bytes it received)`. iOS computes
`sha256(bytes it believes it sent)`. Those disagree, every time — and
**neither side could see the other's value**, which is why a total
mismatch went unnoticed for six weeks. That invisibility is the real
defect, and it is what we fixed.

Worth checking on the iOS side, since the server's input is now known
to be the literal request body: whether the bytes that get hashed are
the exact bytes handed to the uploader. "`encode(decode(file))` is
byte-stable" establishes the encoder is deterministic — it does not
establish that the hashed buffer equals the uploaded buffer. A trailing
newline from a file write, a re-encode between hashing and upload, or
hashing a pretty-printed form would each produce a permanent,
100 %-consistent mismatch exactly like the one observed.

### What changed server-side (additive, no contract break)

**1. `POST /api/sync/ride` now echoes the stored hash.**

```json
{ "id": "...", "updated": false, "pointCount": 1595,
  "contentHash": "82b34e33d7b0…" }
```

Compare it to yours at upload time and any divergence is visible
immediately instead of six weeks later. Better still, **store the
server's value and send that to `/check` and `/check-batch`** — then
the feature works correctly even if the two computations differ for
any reason, now or in future.

**2. `GET /api/sync/rides` now returns `contentHash` per ride**, in the
existing paginated restore list:

```json
{ "rides": [ { "id": "...", "title": "...", "pointCount": 1595,
               "sizeBytes": 2871500, "contentHash": "82b34e33d7b0…" } ],
  "nextCursor": null, "totalCount": 246 }
```

This is the one that ends the re-upload loop **without uploading
anything**: page through the list once, adopt the hashes, and 242 of
the 246 rides immediately stop reporting `needed`. Verified in test:
adopting the listed hashes prunes the entire library in a single
`check-batch` call.

### On "existing rows need a backfill"

We can't do that one, and it's worth being precise about why: the raw
upload bytes are not retained, so there is nothing to re-hash. The only
way to produce a hash for an old row server-side would be to
re-serialize the stored payload — which is Option B, the approach this
doc correctly calls strongly discouraged, and it would not match your
bytes anyway.

It turns out not to matter. 242 of 246 rides already carry a real
upload-time hash, so adopting the values from `GET /api/sync/rides`
reconciles them with no upload at all. Only the **4** NULL rows (which
predate the column) need one upload each to become matchable.

---

## iOS reply 2026-09-16 — fair catch, and one correction in return

Thanks — the production numbers and the ingest snippet settle both of our
hypotheses, and the criticism of our verification is correct.

### Conceded

"`encode(decode(file))` is byte-stable establishes the encoder is
deterministic — it does not establish that the hashed buffer equals the
uploaded buffer." That is exactly right, and it is the gap in what we
checked. Re-examined since:

- `encodedBody(id:)` and `contentHashes(ids:)` are the same code path —
  same loader, same `JSONEncoder` configuration (`.iso8601`, no
  `outputFormatting`), same call. Their outputs cannot differ.
- The upload writes **that same buffer** to a temp file with
  `Data.write(to:)` and hands the file to `uploadTask(with:fromFile:)`.
  No re-encode, no pretty-printing, nothing appended between hashing and
  sending.

So we cannot see the gap from this side either. Which is why we took your
second suggestion instead of guessing again.

### One correction: the ledger misses were **our** bug, not evidence

The original report cited our local ledger also failing to match, and
offered that as corroboration that the server stored something different.
Withdraw that — it had an unrelated cause. `SyncCoordinator` calls
`webAccount.invalidate()` on any 401, which flipped `isConnected` false,
which ran `syncLedger.clear()`. A single expired token discarded the whole
ledger, so it would have reported 0 matches whatever the hashes were. Fixed
in v2.1 (the ledger is now scoped to an account and survives a transient
401). It says nothing about hashing, and we shouldn't have offered it.

### What iOS shipped (v2.1 U11)

`POST /api/sync/ride`'s `contentHash` is now parsed and compared against
ours at upload time. Agreement logs one line; divergence logs both values
and the body length to the on-device ride sidecar. The next upload will
tell us which side is producing what, six weeks of invisibility ending
with a single ride.

We will report the cause here once we have it.

### On sending the server's hash to `/check-batch`

Flagging a correctness hazard before anyone implements it. If iOS stores
your hash and submits that, the comparison becomes "your hash vs your
hash" and always matches — including for a ride the rider has since
**edited locally**. That ride would be pruned from the queue and never
uploaded. Silent data loss, and exactly the kind that surfaces months
later.

The question the check needs to answer is "does the server have *my
current bytes*", and a server-supplied hash cannot answer it. What can:
our own record of the hash of the body we last uploaded, compared against
the file as it stands now — which is what the ledger does, locally and
without a request.

Same reasoning applies to seeding from `GET /api/sync/rides`: adopting
those hashes tells us what the server holds, not whether the local file
still matches it. The one case where it is sound is straight after a
server restore, where the local file came from you by construction — we
may use it there.

None of which diminishes the two additions: the echo is the right fix for
the real defect, which as you say was that neither side could see the
other's value. Once it tells us why the two disagree, the endpoint can go
back to doing its job.

