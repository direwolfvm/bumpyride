# Per-ride Score — Web Handoff

Companion to the existing [`/api/me/score` contract](https://github.com/direwolfvm/bumpyride-web/pull/39) shipping with iOS v1.5. Adds a per-ride score lookup so the saved-ride playback view can display "Points earned on this ride" — the same value the web's per-ride page header already shows.

## TL;DR

- One new endpoint: `GET /api/rides/{id}/score`.
- Returns the same `breakdown` shape `/api/me/score` does, but scoped to a single ride's `score_events` rows.
- Same bearer-auth pattern as `/api/me/score`. No new permission scopes.
- Read-only and idempotent. The data already exists in `score_events`; this just exposes it per-ride.

## What iOS does

1. **User opens a saved ride for playback**.
2. iOS calls `GET /api/rides/{id}/score` (lightweight, single-row aggregate query).
3. Displays a small "Points earned" stat near the existing per-ride brake/close-call counts.
4. Caches the value per ride id so scrubbing / view-toggling doesn't refetch.
5. If the user isn't sharing publicly or the ride was pocket-mode, the server returns `eligible: false` and iOS hides the stat.

## Endpoint

### `GET /api/rides/{id}/score`

**Request**:
```
Authorization: Bearer br_…    (or session cookie)
Accept: application/json
```

**Response** (200):
```jsonc
{
  "rideId": "036D3C25-0396-42EE-8026-0CC0098714DD",
  "totalPoints": 87,
  "breakdown": {
    "firstEver": 3,    // count of cells this ride was first-ever on
    "firstForYou": 7,  // count of first-for-this-user cells
    "repeat": 42       // count of repeat-visit cells
  },
  "eligible": true     // false when the ride didn't qualify for scoring
                       // (pocket-mode, or sharing was off when uploaded)
}
```

Shape mirrors `/api/me/score`'s `breakdown` field exactly so iOS can reuse the existing `ScoreBreakdown` type.

**Errors**:
- 401: token invalid
- 404: ride doesn't exist or doesn't belong to this user
- 200 with `eligible: false`: ride exists but didn't earn points (pocket-mode or sharing-off at sync time)

The 200-with-`eligible: false` pattern is intentional — it lets iOS distinguish "no rights to score" from "this specific ride didn't qualify" without throwing.

## Caveats / edge cases

- A ride uploaded while sharing was off, then enabled later: per the existing scoring docs, opt-in backfill doesn't retroactively re-score old rides. So `eligible` reflects the state at the time the ride was processed.
- A ride that was re-uploaded (iOS resync): `score_events` for that ride are wiped and recomputed on each `POST /api/sync/ride`, per PR #39. So this endpoint always returns the most-recent recomputation.
- A pocket-mode ride: `eligible: false`, `totalPoints: 0`, breakdown all zeros.

## What this does NOT do

- Doesn't return the cell-by-cell list of which 20-ft cells this ride scored on. Just aggregates.
- Doesn't include per-tier point totals — those are derived client-side from `breakdown × {10, 5, 1}` (matches what the `/api/me/score` view does).
- Doesn't affect `/api/me/score` totals; those continue to read from `user_scores`.

## Coordination check-in

When the endpoint is deployed:
- Ping me with confirmation and any rate limit info.
- iOS side adds a single `getRideScore(rideId:)` method and a small playback-view stat. Two-day turnaround on the iOS side after the endpoint is live.
- Worth deploying alongside `/api/sync/rides` (the restore endpoints) — they're both small, both read-only, and both unblock v1.5 iOS work.

Nothing blocks. Existing endpoints (including `/api/me/score`) are unaffected.
