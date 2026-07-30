# Web work order — pending server-side items (as of iOS v2.0)

Consolidated queue for the bumpyride-web project. Detailed contracts
live in the referenced handoff docs; this is the index, priorities,
and acceptance criteria. Convention unchanged: when an item ships,
append a Status appendix to its handoff doc (as done for
`RIDE_EDIT_WEB_HANDOFF.md`) so the iOS side picks it up.

## Current handoff ledger

| Handoff | Direction | Status |
|---|---|---|
| Achievements (`ACHIEVEMENTS_IOS_HANDOFF.md`) | web → iOS | **Shipped both sides** |
| Ride edit + `editedAt` (`RIDE_EDIT_WEB_HANDOFF.md`) | iOS → web | **Shipped both sides** (incl. iOS pull-on-conflict) |
| Other events (`OTHER_EVENTS_WEB_HANDOFF.md`) | iOS → web | **Pending** — items 1–2 below |
| Batch sync check (`SYNC_BATCH_CHECK_WEB_HANDOFF.md`) | iOS → web | **Pending** — item 3 below |

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

### 2a. Follow-on: `lane-scout` achievement data source

The achievements registry already defines `lane-scout` (safety, per
ride: blocked-lane reports ≥ 1 / 3 / 5 → 100 / 200 / 400), which can
only award once the `other_events` table exists. When item 2 lands,
wire the achievement's metric to count built-in (`is_custom = false`)
`blocked-lane` rows per ride, and backfill awards over eligible rides
like the other per-ride achievements.

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

## Priority order

1. **Item 1** — cheap verification, guards against silent data loss.
2. **Item 2** — unlocks community value of Blocked Lane + the
   `lane-scout` achievement (2a).
3. **Item 3** — pure efficiency; whenever convenient.
