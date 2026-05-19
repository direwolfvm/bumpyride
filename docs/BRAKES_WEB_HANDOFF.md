# Brake Events — Web Handoff

This is the bumpyride-web handoff for the hard-braking feature shipping in iOS v1.3. iOS detects brake events on-device and uploads them as part of the existing ride payload — the web side needs to ingest the new fields, display per-ride event lists, and (in v1.4 or later) add a public brake map alongside the public bump map.

## TL;DR

- **Schema is v3 now**, additive only. `Ride` gains `brakeEvents` (optional array). `RidePoint` gains `horizontalAccel` (optional number, g-units).
- **`POST /api/sync/ride` is unchanged in shape** — the same endpoint, the same idempotent-on-`Ride.id` behavior. If you ignore unknown JSON keys today, the new fields just land in your JSONB blob and your existing tooling continues to work.
- **Nothing to do urgently.** iOS ships v1.3 with the web side stubbed. Pick this up when you're ready for a v1.4 web release with brake display.

## What changed in the ride payload

Every field is optional and backward-compatible. See [`SCHEMA.md`](./SCHEMA.md) for the canonical reference; here's the diff.

### New top-level field on `Ride`

```jsonc
{
  "id": "…",
  "title": "…",
  "startedAt": "…",
  "endedAt": "…",
  "points": [ … ],
  "pocketMode": false,
  "schemaVersion": 3,
  "brakeEvents": [                       // ← NEW in v3
    {
      "id": "…",
      "timestamp": "2026-05-19T09:14:32Z",
      "latitude": 38.9072,
      "longitude": -77.0369,
      "peakDecelerationMPS2": 3.41,
      "durationSeconds": 1.2
    }
  ]
}
```

| `brakeEvents` shape | Semantics |
|---|---|
| Missing / `null` | Brake detection hasn't run yet on this ride.  Treat as "unknown."  iOS reprocesses these in the background and re-uploads, so they'll resolve to one of the next two states on a subsequent sync. |
| `[]` | Detection ran and found nothing — the ride was free of hard brakes.  **Different from null** — confidently empty. |
| `[ … ]` | One or more events.  Typical ride: 0–10 entries.  Sorted by `timestamp` ascending. |

### New per-point field on `RidePoint`

```jsonc
{
  "id": "…",
  "timestamp": "…",
  "latitude": 38.9,
  "longitude": -77.0,
  "speed": 6.2,
  "bumpiness": 0.32,
  "accelWindow": [ … ],
  "horizontalAccel": 0.18                // ← NEW in v3 (g-units, optional)
}
```

Magnitude of user acceleration projected onto the plane perpendicular to gravity, in g-units. Captures braking, accelerating, and cornering independently of phone orientation. Used by the iOS brake detector as a refinement signal; not strictly needed server-side, but stored so future server-side re-detection can run on the same input data the device used.

## What iOS does

So you know what you're receiving:

1. **Detection runs post-hoc at save time.** A `BrakeEventDetector` scans the saved points array:
   - Smooths GPS speed with a centered ±1 s moving average.
   - Computes deceleration via centered finite difference.
   - Finds contiguous runs > 2.5 m/s² (≈ 0.25 g) sustained ≥ 0.8 s.
   - Refines peak magnitude using `horizontalAccel` when present: `max(GPS-derived peak, peak horizontalAccel · 9.80665 · 0.8)`.
   - Collapses adjacent events within 3 s into a single higher-peak event.
2. **Legacy rides get auto-reprocessed on launch.** Any ride with `brakeEvents == null` runs through the detector, gets re-saved, and re-uploads as backfill (no badge inflation on iOS).
3. **Live recording UI doesn't surface brakes.** Users don't see brake state during a ride — only on saved-ride playback and the Bump Map tab's Brakes view.

## What bumpyride-web v1.4 should pick up

In priority order. Items 1–2 are the minimum to ship the feature visibly; 3+ are nice-to-haves.

### 1. Accept v3 payloads gracefully (probably already working)

If `POST /api/sync/ride` stores the full payload in a JSONB column and `schemaVersion` is read but not validated against an allow-list, you're already done. Verify by uploading a v3 sample and checking the row's JSON contains `brakeEvents`.

If `schemaVersion` is strictly checked, add `3` to the accepted list. Refusal of v3 would block iOS upload on v1.3.

### 2. Per-ride brake event display

On the existing per-ride view page (the one users see when they click into one of their synced rides), add a brakes section under the bumpiness chart. Matches the iOS playback UI:

- **List** of brake events, ordered by timestamp. Each row: time-into-ride, peak deceleration (in g or m/s² — pick the convention you already use elsewhere), duration.
- **Map markers**: render brake events as red incident pins on the route polyline.
- **Empty states**: distinguish `brakeEvents == null` ("Detection still running on this ride — check back soon") from `brakeEvents == []` ("No hard brakes detected on this ride").

### 3. Public brake map (separate page, parallel to public bump map)

This is the equivalent of the public bump map but for brake events. New page `/brake-map` (or whatever your existing convention is for `/map`).

**Aggregation**: count of brake events per 20 ft cell, same cell math as the bump map. iOS uses `BumpGrid.cellLatDeg` / `cellLonDeg` constants — a cell key at any given lat/lon should be identical between the two maps so a future "show me bumps AND brakes" overlay is straightforward.

**Color scale**: count-based, hardcoded thresholds (matching what the iOS app uses):
- 1 event → yellow
- 2–3 events → orange
- 4–5 events → red
- 6+ events → purple

**Privacy gate**: same `publicMapEager` / 3-distinct-rider threshold the bump map uses ([from the `/api/me/sharing` contract](#)). A cell with brake events from only 1 or 2 riders shouldn't render publicly unless those riders have `publicMapEager = true`. A solo cyclist's only-they-go-here corner stays hidden by default.

**Rendering**: filled circles, not squares — brake events are discrete incidents, not a continuous heat field. (See `BrakeMapTileOverlay.swift` for the iOS rendering choice.)

### 4. CSV export

If the existing per-ride CSV export emits one row per `RidePoint`, consider also emitting a `brakeEvents` CSV (or a second sheet, or appending columns). Useful for the analytics-minded user who wants to graph their braking habits in Excel.

## Backward-compat notes

- **Old iOS clients (≤ v1.2)** continue to emit v1 or v2 payloads. Your existing handling for those is unchanged.
- **Mixed-version users** (one device on v1.2, another on v1.3 with the same account) will produce a mix of ride records — some with `brakeEvents`, some without. Treat missing/`null` as "unknown" everywhere in the UI.
- **Re-uploads** are common with v1.3: iOS reprocesses every legacy ride on launch and re-syncs it. Server-side dedup on `Ride.id` already handles this — the payload just contains a populated `brakeEvents` field this time.

## Server-side re-detection (optional, future)

Because `RidePoint.horizontalAccel` is preserved in the wire format, the server has everything it needs to re-run detection. Not necessary today — iOS detects and uploads results — but useful if:

- You want to ship a tuned detector with different thresholds without waiting for iOS users to update.
- You add a "per-rider brake sensitivity" slider on the web side.
- You want a public brake map aggregating across users with a different threshold than the per-rider iOS view uses.

The detector logic is small enough to port to TypeScript directly from [`BrakeEventDetector.swift`](../BumpyRide/BrakeEventDetector.swift) — under 200 lines of mostly arithmetic.

## API additions (sketches, non-binding)

Suggested shapes for new endpoints the iOS app doesn't currently need but the web v1.4 work might want:

### `GET /api/me/brake-events`

List the authenticated user's brake events across all their rides. Useful for a "my dangerous corners" personal analytics view.

```jsonc
// 200 OK
{
  "events": [
    {
      "id": "…",
      "rideId": "…",
      "timestamp": "…",
      "latitude": 38.9,
      "longitude": -77.0,
      "peakDecelerationMPS2": 3.4,
      "durationSeconds": 1.2
    }
  ]
}
```

Paginated if needed; a typical user generates 0–10 per ride × N rides, so likely <1000 lifetime entries.

### `GET /api/public/brake-map?bbox=…&z=…`

Tile-style or bbox-style aggregated brake counts for the public map. Same auth pattern as your existing public bump-map endpoint. Should respect the `publicMapEager` threshold per the calibration contract.

```jsonc
// 200 OK
{
  "cells": [
    { "lat": 38.9072, "lon": -77.0369, "count": 4 }
  ]
}
```

## Coordination check-in

When you're ready to implement, ping the iOS side and we'll:
- Generate fresh `sample-ride.json` fixtures including `brakeEvents` for your tests.
- Tune the detector thresholds together if your real-world data shows the current `2.5 m/s², 0.8 s` is too tight or too loose.
- Decide whether the public brake map uses iOS-computed events as-is or re-detects server-side with a fixed canonical algorithm (the latter avoids per-version drift but adds compute load).

Nothing is blocking today. Take this whenever there's a window.
