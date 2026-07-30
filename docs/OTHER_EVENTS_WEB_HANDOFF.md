# Web handoff: "other events" (`Ride.otherEvents`)

**iOS side: shipped in v2.0.** Ride payloads arriving at
`POST /api/sync/ride` may now carry an additive `otherEvents` array.
Until the web side lands, store-and-round-trip is sufficient (the
field must survive upload → restore untouched, like
`healthKitWorkoutUUID` does today). This doc specs what to build when
the web side picks it up.

## What it is

Riders can log point events beyond close calls during a ride via a
"Log Event" button. Two flavors with **different privacy rules**:

1. **Built-in kinds** (`isCustom: false`) — drawn from a stable
   registry shared between the apps. Community data: eligible for the
   public map layers, exactly like close calls.
2. **Custom kinds** (`isCustom: true`) — free-text labels the rider
   defines in the iOS Settings. **Private to the owning account.**
   These must never appear in public tiles, cross-account aggregates,
   or any surface other than the owner's own maps/ride views.

## Wire schema

Additive optional array on the ride payload (full table in
`SCHEMA.md` → `OtherEvent` object):

```json
"otherEvents": [
  {
    "id": "7B1C9A02-4E1F-4B7D-9A31-0C2D8F6E5A44",
    "timestamp": "2026-07-20T14:31:02Z",
    "latitude": 38.84131,
    "longitude": -77.04790,
    "kind": "blocked-lane",
    "isCustom": false
  },
  {
    "id": "0F2E8D11-9C4A-4F02-B7E6-3A5D1C8B9E77",
    "timestamp": "2026-07-20T14:44:57Z",
    "latitude": 38.85502,
    "longitude": -77.05211,
    "kind": "Broken glass",
    "isCustom": true
  }
]
```

- `null`/missing array = ride predates the feature; `[]` = feature
  available, nothing logged. Same semantics as `closeCallEvents`.
- `kind` for built-ins is a registry identifier; for customs it's the
  rider's label verbatim (iOS caps custom labels at 40 chars, 20
  distinct kinds per account — enforce the same caps server-side).

## Built-in kind registry

Append-only; identifiers are wire format and are never renamed.

| `kind` | Display name | Since |
|--------|--------------|-------|
| `blocked-lane` | Blocked Lane | iOS v2.0 |

New kinds will be added here (and in `OtherEvent.builtinKinds` in the
iOS app) as the class grows.

## The privacy rule — server responsibilities

- **Key on `isCustom`, not on registry membership**, for storage
  routing: `isCustom: true` rows are owner-only everywhere.
- **Validate the flag on ingest**: if `isCustom: false` but `kind` is
  not in the registry above, treat the event as custom (private)
  rather than rejecting the ride — a client/server registry version
  skew must degrade toward privacy, never toward publishing junk into
  public tiles.
- Public map layers (when built) include only validated built-in
  kinds, with the same sharing gate as close calls: only rides from
  accounts with public sharing on, mounted-mode only if that's the
  close-call precedent.

## Storage sketch

Mirror the close-call migration pattern: an `other_events` table
(`ride_id`, `event_id`, `ts`, `lat`, `lon`, `kind`, `is_custom`,
`user_id` denormalized for the privacy filter), populated on ride
ingest, plus round-tripping the raw array in the stored ride JSON for
restore. Indexing can wait for the tile layer.

## Future (not in this handoff)

- Public tile layer for built-in kinds (per-kind filter akin to the
  brakes/close-calls layers).
- Per-kind stats on the ride page.
- Scoring interaction: none — other events do not affect scoring.

---

## Status: SHIPPED server-side (web, 2026-07-30)

Ingest, storage, and the privacy rule are live (migration 0018).
Re-verified end-to-end against the acceptance criteria on 2026-07-30.

### Storage

`other_events`: `ride_uuid`, `event_uuid`, `user_id` (denormalized),
`timestamp`, `latitude`, `longitude`, `kind`, `is_custom`,
`is_public_eligible`. Written on ride ingest with the same
wipe-and-replace + three-state semantics as close calls
(`rides.other_events_supported`: absent/null = ride predates the
feature, `[]` = supported but nothing logged).

### The two flags — why there are two

- **`is_custom`** stores the client's wire value **verbatim**. It is
  never "corrected" server-side, so a ride round-trips untouched on
  restore.
- **`is_public_eligible`** is computed server-side as
  `registry(kind) ∧ NOT isCustom`, and is the **only** flag public
  surfaces may filter on.

This split is what lets registry skew degrade toward privacy without
corrupting the round-trip: an `isCustom: false` event whose `kind` we
don't know (a built-in from a newer iOS than the server) is stored
with `is_custom = false` (wire truth, restored exactly) **and**
`is_public_eligible = false` (never published). Verified:
`future-kind-v9` + `isCustom:false` → stored `f` / eligible `f`.

### Caps

`kind` ≤ 40 chars, ≤ 20 distinct custom kinds per account (mirrors the
iOS cap; counted over wire-custom kinds only, so registry skew doesn't
consume a rider's label budget). Violations roll back the whole ride
upload with a 400.

### Public surfaces

None yet — no endpoint under `/api/public/` reads `other_events`, so
the "no custom kind ever served publicly" criterion holds by
construction. When the tile layer lands it must filter on
`is_public_eligible`, never on `kind` or `is_custom` directly.

### Round-trip (item 1 of the work order) — VERIFIED, no data loss

`GET /api/sync/ride/{id}` returns `otherEvents` key-complete and
value-exact, including the wire `isCustom` for skewed events. Also
verified through the server-canonical trim/split path added by the
ride editor: no payload, point, or event keys are dropped, and events
are conserved across a split (5 in → 3 + 2 out).

One documented normalization: timestamps come back as UTC ISO-8601
with milliseconds (`2026-07-28T10:01:00.000Z`) regardless of the
offset form uploaded (`+00:00`). Same instant, different spelling —
key-complete as the work order requires, not byte-identical.

### 2a — `lane-scout` is wired

The achievement counts rows with `is_public_eligible = true AND kind =
'blocked-lane'` per ride (so custom kinds and registry-skew events are
correctly excluded), tiers 1/3/5 → 100/200/400. Backfilled over
eligible rides by migration 0020 along with the rest of the registry.
Verified: a ride with 3 built-in reports + 1 custom + 1 skew awards
exactly 200.
