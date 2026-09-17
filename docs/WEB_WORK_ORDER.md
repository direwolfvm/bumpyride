# Web work order — pending server-side items (as of iOS v2.0)

Consolidated queue for the bumpyride-web project. Detailed contracts
live in the referenced handoff docs; this is the index, priorities,
and acceptance criteria. Convention unchanged: when an item ships,
append a Status appendix to its handoff doc (as done for
`RIDE_EDIT_WEB_HANDOFF.md`) so the iOS side picks it up.

> **2026-09-17: item 4 CLOSED — root cause was an iOS bug.** The hash
> echo answered it on the first ride. Our wire encoder set no
> `outputFormatting`; `JSONEncoder` guarantees no key order and Swift
> seeds dictionary hashing per process, so every re-encode of an
> unchanged ride produced a different byte sequence — same length,
> ~94 % of byte positions reordered. Every hash iOS ever sent was
> effectively random, which is why the endpoint returned 100 % `needed`
> forever. Fixed in iOS v2.1 U12 (canonical `.sortedKeys` encoder shared
> by the upload body and the hash). **Nothing needed server-side**: one
> more full re-upload replaces the stale hashes, held for Wi-Fi, and the
> endpoint prunes from then on. Detail in the "Cause found" appendix to
> `SYNC_BATCH_CHECK_WEB_HANDOFF.md`.
>
> **2026-09-16: item 4 investigated — both hypotheses ruled out, fix
> shipped server-side.** `content_hash` is neither NULL (242 of 246
> production rides carry one) nor server-canonical (ingest has always
> hashed the raw request body). The real defect was that neither side
> could see the other's hash, so a total mismatch went unnoticed for
> six weeks. The server now echoes `contentHash` on upload **and** on
> `GET /api/sync/rides`, so iOS can adopt the server's values and
> reconcile the whole library without re-uploading it. Full evidence
> and the iOS-side follow-up in the appendix to
> `SYNC_BATCH_CHECK_WEB_HANDOFF.md`.
>
> **2026-07-30: this queue was empty — every item 1-3 is shipped and
> verified server-side.** Items 2/2a/3 had in fact shipped before this
> work order was written (web PRs #63, #65, #66); their handoff docs
> were missing the Status appendix, which is why they still read
> "Pending" here. Appendices are now written, so the ledger and the
> docs agree. Item 1 was a verification task and **passed with no data
> loss found** — details under each item.

## Current handoff ledger

| Handoff | Direction | Status |
|---|---|---|
| Achievements (`ACHIEVEMENTS_IOS_HANDOFF.md`) | web → iOS | **Shipped both sides** |
| Ride edit + `editedAt` (`RIDE_EDIT_WEB_HANDOFF.md`) | iOS → web | **Shipped both sides** (incl. iOS pull-on-conflict) |
| Other events (`OTHER_EVENTS_WEB_HANDOFF.md`) | iOS → web | **Shipped both sides** — see doc appendix |
| Batch sync check (`SYNC_BATCH_CHECK_WEB_HANDOFF.md`) | iOS → web | Shipped; hash now echoed for reconciliation — **iOS action needed**, see item 4 |

## 1. URGENT — verify `otherEvents` round-trip survival

iOS v2.0 ride payloads carry an additive `otherEvents` array (and, as
of Q1, an `editedAt` field — already handled server-side). If the
server's storage or restore path re-serializes rides through a schema
that drops unknown keys, **every logged event is silently destroyed on
restore** — user data loss, invisible until someone restores.

- Acceptance: upload a ride with `otherEvents` → `GET
  /api/sync/ride/{id}` returns the array byte-equivalent (or at least
  key-complete). If the ride-edit work already made storage
  server-canonical, confirm the canonical schema includes
  `otherEvents` — a canonicalizer with a fixed field list is exactly
  the kind of code that drops unknown keys.
- Zero new features required; this is a data-integrity check on
  existing behavior. **Do this first.**

### ✅ DONE 2026-07-30 — no data loss found

Storage is not canonicalized: ride payloads are stored **decomposed
into relational tables**, and restore re-materializes them from
columns. There is no whole-payload JSON schema that could drop unknown
keys, and `otherEvents` has had dedicated storage since migration
0018. Verified by upload → restore: 5/5 events returned, key sets and
values identical, whole-payload key set complete.

The instinct behind the warning was still right, and it caught
something. The ride editor **does** build a server-canonical payload
(to slice points and re-derive stats), and its `buildSlice` helper had
exactly the fixed field list the item describes. It happened to list
every field that exists today, so nothing was being lost — but the
next additive field would have been silently dropped on any web
trim/split. Rewritten to carry-by-default (spread the loaded payload,
override only what an edit must change: slice bounds, and the
deliberate `healthKitWorkoutUUID` clear / `editedAt` restamp). A
regression test now asserts no payload, point, or event key is lost
across a trim and a split, so future additive fields are covered
without anyone remembering to update the editor.

One documented normalization: restored timestamps are UTC ISO-8601
with milliseconds (`...T10:01:00.000Z`) whatever offset form was
uploaded. Same instant — key-complete, not byte-identical.

## 2. Other events — ingest + privacy rule

Full contract: `OTHER_EVENTS_WEB_HANDOFF.md`.

- `other_events` table on ride ingest (mirror the close-call
  migration pattern): `ride_id`, `event_id`, `ts`, `lat`, `lon`,
  `kind`, `is_custom`, denormalized `user_id`.
- **The privacy rule (non-negotiable):** `isCustom: true` rows are
  owner-only everywhere, forever. Key privacy on the flag, not
  registry membership. On ingest, an `isCustom: false` event whose
  `kind` isn't in the registry (`blocked-lane` is the only entry
  today) degrades **toward privacy** — treat as custom, never publish
  into public surfaces.
- Public tile layer for built-in kinds can follow later (same sharing
  gates as close calls); the table + privacy rule are the blocking
  parts.
- Acceptance: ingest writes rows with correct `is_custom`; unknown
  kind + `isCustom: false` stored as private; no custom kind ever
  served from a public endpoint.

### ✅ DONE — shipped in web PR #63 (migration 0018), re-verified 2026-07-30

All three acceptance criteria pass. The implementation keys privacy on
a **second, server-computed** column (`is_public_eligible =
registry(kind) ∧ NOT isCustom`) while storing the client's `is_custom`
verbatim — so skew degrades toward privacy *without* corrupting the
round-trip item 1 depends on. Verified: `blocked-lane`/`false` →
eligible; `Broken glass`/`true` → private; `future-kind-v9`/`false` →
stored `false`, published never. No `/api/public/` route reads the
table at all today. Full contract in the handoff doc's appendix.

### 2a. Follow-on: `lane-scout` achievement data source

The achievements registry already defines `lane-scout` (safety, per
ride: blocked-lane reports ≥ 1 / 3 / 5 → 100 / 200 / 400), which can
only award once the `other_events` table exists. When item 2 lands,
wire the achievement's metric to count built-in (`is_custom = false`)
`blocked-lane` rows per ride, and backfill awards over eligible rides
like the other per-ride achievements.

### ✅ DONE — shipped in web PR #66, re-verified 2026-07-30

Wired and backfilled (migration 0020) with the rest of the registry.
One refinement on the spec: the metric filters on `is_public_eligible`
rather than `NOT is_custom`, which additionally excludes registry-skew
events — an event we can't confirm is a real blocked-lane report
shouldn't earn safety points. Verified: 3 built-in + 1 custom + 1 skew
awards exactly 200.

## 3. Batch sync-status check

Full contract: `SYNC_BATCH_CHECK_WEB_HANDOFF.md`.

- `POST /api/sync/ride/check-batch`: `{rides: [{rideId, hash}]}` →
  `{needed: [ids]}` (missing OR hash-mismatched). Single indexed query
  against the existing `content_hash` column; no payload reads.
- Other-account ids go in `needed` (the upload path's 409 owns
  conflict signaling; don't leak existence here).
- Cap entries (~500) → 400 beyond.
- iOS already ships the client with silent fallback to per-ride
  checks on 404 — deploy any time, zero coordination.
- Note: rides edited on the web keep a server-canonical
  `content_hash` that never matches client bytes; reporting them
  `needed` is correct (the subsequent upload 409s and iOS adopts —
  see the ride-edit doc's appendices).
- Acceptance: a 75-ride no-op drain makes 1 check request instead of
  75; pruned rides don't re-upload.

### ✅ DONE — shipped in web PR #65, re-verified 2026-07-30

Acceptance verified directly: a 75-entry batch resolves in one request
and the in-sync ride is absent from `needed`. Cap enforced at 500 (501
→ 400). Foreign-owned ids land in `needed` as specified. One behavior
worth knowing on the client: repeated ids inside a single request are
deduped, **first entry wins**. The web-edit / `content_hash`
interaction you flagged behaves exactly as you predicted — see the
handoff doc's appendix.

## 4. Batch sync check returns every ride as `needed`

**Reported from the field 2026-09-16.** The endpoint is live and
well-formed, but `needed` has always come back containing 100 % of the
submitted ids — including rides uploaded successfully minutes earlier.
On device this drove repeated whole-library re-uploads: 453 MB in one
drain, 519 MB of cellular in a day, against a 627 MB library.

~~iOS has verified its half (hash is SHA-256 of the exact uploaded bytes;
encoding is byte-stable across loads). Leading hypothesis is that
`content_hash` is derived from the decomposed / re-materialized payload
rather than from the raw upload body — Option B in
`SYNC_CHECKSUM_WEB_HANDOFF.md` — in which case the timestamp
normalization documented in item 1 alone guarantees a permanent
mismatch. Cheaper alternative to check first: the column is simply
NULL.~~

**Struck 2026-09-16 — both hypotheses were wrong** (see the doc's "Web
response" appendix: `content_hash` is populated for 242 of 246 rides and
is taken from the raw request body at ingest). Two corrections to the
original report, for the record:

- "iOS has verified its half" was overstated. Byte-stable
  `encode(decode(file))` proves the *encoder* is deterministic; it does
  not prove the hashed buffer equals the uploaded buffer. Re-examined
  since — same code path, same encoder, buffer written straight to the
  upload file with no re-encode — so the gap is still not visible from
  the iOS side either.
- The report cited the local ledger's misses as corroboration. That was
  wrong and is withdrawn: the ledger was being wiped on any 401
  (iOS-side bug, fixed in v2.1 U10), so it would have reported zero
  matches regardless of hashing.

- Diagnostic and full evidence: appendix to
  `SYNC_BATCH_CHECK_WEB_HANDOFF.md`.
- Acceptance: a ride uploaded via `POST /api/sync/ride` is absent from
  `needed` on the next `check-batch` call with the same hash. Existing
  rows backfilled.
- **Not blocking.** iOS v2.1 added a local ledger that makes steady
  state free regardless; this restores a cross-check rather than
  unblocking anything.

### Status 2026-09-16 — instrumented both sides, cause still unknown

Server echoes `contentHash` on upload and on `GET /api/sync/rides`
(web, shipped). iOS v2.1 U11 parses the upload echo and logs any
divergence — both hashes and the body length — to the on-device ride
sidecar. **The next upload identifies the culprit.**

One hazard flagged against the suggested iOS-side fix, before anyone
builds it: if iOS submits the *server's* hash to `check-batch`, the
comparison becomes server-hash vs server-hash and always matches —
including for a ride edited locally since upload, which would then be
pruned and never uploaded. A server-supplied hash cannot answer "does
the server have my current bytes"; only a local record of what we last
sent can. Detail in the doc's "iOS reply" appendix.

### ✅ INVESTIGATED + FIXED 2026-09-16 — but not the way the report expected

Both hypotheses are wrong, checked directly against production:

- **Not NULL.** 242 of 246 rides carry a `content_hash`; all are
  64-char lowercase hex; of the 241 rides updated since the 07-30
  deploy, **zero** are NULL. (4 legacy rows predate the column.)
- **Not server-canonical.** Ingest hashes `await req.text()` — the raw
  request body — and always has. The timestamp normalization from item
  1 happens on *restore*, after the hash is taken, so it can't reach
  it. Verified locally: upload, hash the exact bytes client-side,
  `check-batch` → pruned. Holds for UTF-8 titles and uppercase ids.

Production runs the current code (`9e411a5`) and uploads arrive clean
(200, 0.9–5.3 MB, no content-encoding). So the server stores
`sha256(bytes received)` and iOS computes `sha256(bytes it believes it
sent)`, and those differ — with no way for either side to see it. That
invisibility was the actual defect.

**Shipped:** `POST /api/sync/ride` now echoes `contentHash`, and `GET
/api/sync/rides` returns it per ride. Adopting the listed values
reconciles 242 rides with **no upload at all** — verified to prune an
entire library in one `check-batch` call.

**iOS follow-up:** adopt the server's hash rather than trying to match
it, and check whether the hashed buffer is byte-identical to the
uploaded one (a deterministic encoder doesn't prove that). A backfill
was requested but is impossible — raw bytes aren't retained, and
re-serializing to hash would be Option B. It's moot: only the 4 NULL
rows need an upload.

## Priority order

1. **Item 1** — cheap verification, guards against silent data loss.
2. **Item 2** — unlocks community value of Blocked Lane + the
   `lane-scout` achievement (2a).
3. **Item 3** — pure efficiency; whenever convenient.
4. **Item 4** — server side done 2026-09-16; ball is with iOS to adopt
   the echoed hash (one list call reconciles the library).

## Next up

Nothing blocking. The one deferred piece, called out in item 2 and
left deliberately un-built, is the **public tile layer for built-in
other-event kinds** (`blocked-lane` today) — same sharing gates as the
close-calls layer, filtering on `is_public_eligible`. Say the word and
it can follow the brakes/close-calls layer pattern.
