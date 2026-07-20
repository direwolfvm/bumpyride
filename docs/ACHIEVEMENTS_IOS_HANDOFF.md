# iOS handoff: achievements

**Web side: shipped.** The server awards achievements at sync time and
exposes them via the endpoints below. This doc is the contract for
building the iOS surface (achievements screen, post-sync toasts, and
the score-screen adjustments).

## What they are

Point bonuses layered on top of cell-discovery scoring, at three fixed
tiers: **100, 200, 400 points**. Calibrated against a real 150-ride /
90-day / 833-mile corpus (~600k discovery points) so that achievements
contribute **roughly 10%** of a normal rider's combined total
(measured 9.2% on the calibration corpus).

Two shapes:

- **Per-ride** — repeatable. Every qualifying ride earns the highest
  tier it meets per achievement. Recomputed deterministically if the
  ride re-syncs (same stats in → same award out).
- **Milestone** — one-time rungs on lifetime ladders. Monotonic: once
  a rung is earned it is never revoked, even if later edits drop the
  cumulative below the rung.

**Eligibility matches scoring exactly**: public sharing ON,
mounted-or-legacy rides only. Achievements share the score lifecycle —
opting out of sharing wipes them; opting back in backfills them.

## Level ladder now runs on the combined total

`level` in `GET /api/me/score` is computed from
**`totalPoints + achievementPoints`** (exposed as `combinedPoints`).
`totalPoints` remains discovery-only for backward compatibility. If
the iOS score screen shows "X pts to next level", switch its input to
`combinedPoints`.

## Registry — per-ride achievements

Award the highest tier met. `id` is wire format, append-only, never
renamed.

| `id` | Name | Category | Metric | 100 pts | 200 pts | 400 pts | Notes |
|------|------|----------|--------|---------|---------|---------|-------|
| `long-haul` | Long Haul | ride | distance (mi) | ≥ 5 | ≥ 10 | ≥ 15 | |
| `endurance` | Endurance | ride | duration (min) | ≥ 30 | ≥ 45 | ≥ 90 | rides > 600 min excluded (forgotten-recording guard) |
| `trailblazer` | Trailblazer | exploration | new cells this ride | ≥ 250 | ≥ 750 | ≥ 1500 | "new" = score tiers 10 + 5 |
| `big-haul` | Big Haul | exploration | discovery points this ride | ≥ 4000 | ≥ 8000 | ≥ 15000 | |
| `groundskeeper` | Groundskeeper | exploration | revisited cells this ride | ≥ 750 | ≥ 1250 | ≥ 1750 | "revisit" = score tiers 1 + 3 |
| `rough-rider` | Rough Rider | surface | samples ≥ 1.5 g this ride | ≥ 3 | ≥ 8 | ≥ 15 | |
| `big-hit` | Big Hit | surface | max bumpiness (g) | ≥ 1.8 | ≥ 2.3 | ≥ 2.8 | |
| `silk-road` | Silk Road | surface | avg bumpiness (g), lower is better | ≤ 0.25 | ≤ 0.20 | ≤ 0.15 | requires ride ≥ 2 mi |
| `survivor` | Survivor | safety | close calls logged this ride | ≥ 1 | ≥ 2 | ≥ 4 | |
| `lane-scout` | Lane Scout | safety | blocked-lane reports this ride | ≥ 1 | ≥ 3 | ≥ 5 | built-in (`isCustom: false`) `blocked-lane` other events only |

## Registry — milestone ladders

Every rung crossed is awarded (cumulatively, over eligible rides).

| `id` | Name | Metric | Rungs (threshold → points) |
|------|------|--------|-----------------------------|
| `odometer` | Odometer | lifetime miles | 25→100, 50→100, 100→200, 200→200, 400→400, 800→400, 1600→400, 3200→400 |
| `ride-tally` | Ride Tally | lifetime eligible rides | 10→100, 25→100, 50→200, 100→200, 250→400, 500→400, 1000→400 |
| `atlas` | Atlas | lifetime distinct cells | 1000→100, 5000→100, 10000→200, 25000→400, 50000→400, 100000→400 |
| `saddle-time` | Saddle Time | lifetime hours | 10→100, 25→200, 50→400, 100→400, 250→400 |

## API

### `POST /api/sync/ride` — response addition

The sync response now includes the awards newly earned by that upload
(per-ride awards for this ride + any milestone rungs it crossed).
Perfect for a post-sync toast/confetti moment:

```json
{
  "id": "…",
  "updated": false,
  "pointCount": 1500,
  "distanceM": 12345.6,
  "avgBumpiness": 0.38,
  "maxBumpiness": 1.62,
  "achievementsAwarded": [
    { "achievementId": "long-haul", "name": "Long Haul", "points": 200,
      "threshold": 10, "milestone": false },
    { "achievementId": "odometer", "name": "Odometer", "points": 400,
      "threshold": 400, "milestone": true }
  ]
}
```

Notes:
- A **re-upload** of an unchanged ride re-reports its per-ride awards
  (they're wiped + re-awarded). If you want toast-once behavior, key
  toasts on (rideId, achievementId) locally, or only toast on
  `updated: false`.
- Empty array when nothing was earned (including ineligible rides).

### `GET /api/me/score` — additions

```json
{
  "totalPoints": 601234,          // discovery only (unchanged meaning)
  "achievementPoints": 55600,     // NEW
  "combinedPoints": 656834,       // NEW — drives `level`
  "breakdown": { … },
  "level": { … },                 // now computed from combinedPoints
  "levels": [ … ],
  "eligible": true
}
```

### `GET /api/me/achievements` — new

Session or bearer auth (same token as sync). Returns the full
registry with the caller's earned rollups, plus a recent-awards feed:

```json
{
  "totalPoints": 55600,
  "totalAwards": 302,
  "registry": [
    {
      "id": "long-haul", "name": "Long Haul", "category": "ride",
      "kind": "per-ride",
      "description": "Cover serious distance in a single ride.",
      "tiers": [ { "threshold": 5, "points": 100 }, … ],
      "earnedCount": 85, "earnedPoints": 9400
    },
    …
  ],
  "recent": [
    { "achievementId": "long-haul", "points": 200, "threshold": 10,
      "rideId": "…", "earnedAt": "2026-07-20T14:31:02.000Z" },
    …
  ]
}
```

- `registry` includes **unearned** achievements (`earnedCount: 0`) so
  the client can render locked entries.
- `kind` is `per-ride` or `milestone`; milestone entries have
  `category: "milestone"`.
- `recent` is capped at 50, newest first, ordered by **ride time**
  (not sync time). `rideId` is null for milestone rungs.

## Semantics the client should not re-implement

The server is the source of truth for awards — iOS should **display**,
not recompute. Reasons: per-ride cell stats (new vs revisit) depend on
the server's global score state, and eligibility/backfill/wipe flows
all live server-side. The tier thresholds in this doc are for display
copy (e.g. "next tier at 10 mi"), not for local awarding.

## Suggested iOS scope

1. Score screen: show combined total; use `combinedPoints` for the
   level progress bar.
2. Achievements screen fed by `GET /api/me/achievements`: registry
   grid with earned counts, locked states, per-tier thresholds.
3. Post-sync toast for `achievementsAwarded` (dedupe re-uploads).
4. No wire-format changes to the ride payload — nothing to do on the
   recording/sync side.
