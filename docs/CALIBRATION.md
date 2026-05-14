# Pocket-Mode Calibration Contract — `/api/me/calibration`

This document specifies the planned `GET` / `PUT` endpoints on [bumpyride-web](https://github.com/direwolfvm/bumpyride-web) that let an iOS device upload a per-rider pocket-mode calibration gain, so the server can apply the same correction the iOS app applies locally — for both the user's personal map and (optionally) the public aggregate.

The iOS side already computes and uses this calibration locally; nothing here is required for the iOS app to function. This contract describes what the server needs to support to extend the correction beyond a single device.

## Background

Pocket-mode rides systematically underreport bumpiness. Clothing and body mass act as a mechanical low-pass filter, so a 1.0 g pothole on the handlebars shows up as ~0.4–0.6 g in a pocket depending on the rider, pocket type, and pants. Mixing pocket and mounted data in any aggregate produces inconsistent per-cell colors.

BumpyRide iOS addresses this opportunistically: every time the user saves a ride, the app looks for grid cells they've ridden in **both** modes (cells where `≥3` samples accumulated in each mode), computes `mountedAvg / pocketAvg` per overlapping cell, takes the median of those ratios, clamps to `[0.5, 5.0]`, and stores it as `pocketGain`. Once `≥3` overlapping cells have qualified, the gain is applied to all pocket-mode samples before they enter the Bump Map's grid.

The wire-format contract below lets iOS push its computed `pocketGain` to the server so the server can do the same correction.

## Endpoint

### `GET /api/me/calibration` *(bearer or session)*

Read the current calibration value for the authenticated user.

**Response (200):**

```json
{
  "pocketGain": 1.42,
  "confidence": 17,
  "lastComputedAt": "2026-05-14T11:24:00Z"
}
```

| Field | Type | Notes |
|---|---|---|
| `pocketGain` | number | Multiplier to apply to a pocket-mode bumpiness sample to match the mounted scale. `1.0` if the rider has no calibration yet. Range `[0.5, 5.0]` (server should reject values outside this clamp). |
| `confidence` | integer | Count of grid cells the iOS algorithm used to derive the gain (cells with ≥ 3 samples in each mode). `0` if no calibration is in effect. The server should only apply the gain when `confidence ≥ 3`. |
| `lastComputedAt` | ISO-8601 string | When iOS last computed this gain. Useful for displaying "last calibrated …" in a future web UI; not used by the correction itself. May be `null` if no calibration has been computed. |

Default body for a user who has never uploaded:

```json
{ "pocketGain": 1.0, "confidence": 0, "lastComputedAt": null }
```

### `PUT /api/me/calibration` *(bearer or session)*

Write the calibration value. iOS pushes this whenever its local calibration meaningfully changes.

**Request body:**

```json
{
  "pocketGain": 1.42,
  "confidence": 17,
  "lastComputedAt": "2026-05-14T11:24:00Z"
}
```

**Validation:**
- `pocketGain` must be a finite number in `[0.5, 5.0]`. Out-of-range → `400`.
- `confidence` must be a non-negative integer. `< 0` → `400`.
- `lastComputedAt` must parse as ISO-8601 if present; may be omitted or `null`.

**Responses:**

| Code | Body | iOS action |
|---|---|---|
| 200 | `{ pocketGain, confidence, lastComputedAt }` | Apply the toggle, done |
| 400 | `{ error, issues? }` | Log + skip — bug in iOS export path |
| 401 | `{ error }` | Token revoked — same handling as `/api/sync/ride` 401 |

Idempotent: writing the same value twice is safe.

## Server-side application

When the server aggregates this user's pocket-mode ride points (for either the user's personal data or the public aggregate):

1. Look up the user's `pocketGain` and `confidence`.
2. If `confidence ≥ 3`, multiply each pocket-mode sample's `bumpiness` by `pocketGain` before adding to the cell-sum aggregate.
3. If `confidence < 3` or no calibration is stored, leave samples unchanged.

This is the same rule the iOS app uses in [`BumpMapStore.swift`](../BumpyRide/BumpMapStore.swift).

## Why this isn't on each `Ride` payload

The calibration is a **per-rider** property, not a per-ride one — it shouldn't change ride-to-ride and it shouldn't bloat every `POST /api/sync/ride` body with the same value. Keeping it on a separate endpoint also lets the server display "your current calibration" on a future settings page and lets the rider override it manually if they want (e.g., to reset after switching to a much looser jacket).

## Public-map integration

The current `/api/me/sharing` toggle lets a user opt into the public aggregate map. With calibration in place, the public map's aggregator should:

- For shared rides tagged `pocketMode: true`, apply that rider's `pocketGain` (if `confidence ≥ 3`) before contributing to the public cell-sum.
- For rides with `pocketMode: false` or `null`, contribute samples unchanged.

This makes the public map a consistent "mounted-equivalent" scale across all contributing users, regardless of where they kept their phone.

## iOS side, for reference

Computation, persistence, and local application live in [`BumpyRide/CalibrationStore.swift`](../BumpyRide/CalibrationStore.swift). The same algorithm and constants the server should mirror:

| Constant | Value | Used for |
|---|---|---|
| `minSamplesPerMode` | 3 | Cells need this many samples in each mode to qualify |
| `minOverlappingCells` | 3 | Total qualifying cells needed before any correction is applied |
| `minPocketAvg` | 0.02 | Cells with pocket average below this are skipped to avoid divide-by-near-zero |
| `minGain` / `maxGain` | 0.5 / 5.0 | Final clamp |

iOS recomputes on every ride save / delete (it's cheap — O(total points)). When the server endpoint is live, iOS will additionally PUT the new value when it meaningfully changes (rounded to 4 decimal places to avoid churn on no-op recomputes).

## Open items for the web side

1. **Decide on storage shape.** Per-user single row, presumably alongside `users.share_to_public_map`. Three columns: `pocket_gain DOUBLE`, `pocket_confidence INTEGER`, `pocket_calibration_at TIMESTAMPTZ`.
2. **Migration default**: existing users get `pocketGain = 1.0, confidence = 0`.
3. **Apply at aggregation time, not at ingest.** Ingest stores raw `bumpiness`; the correction lives in the aggregation SQL / pipeline. That way changing `pocketGain` doesn't require rewriting historical rows.
4. **Optional UX**: a web page at `/settings/calibration` that displays the current value with a "reset" button.

When the server side ships this contract, iOS will gain `WebSyncClient.getCalibration(token:)` and `setCalibration(_:token:)` methods, plus an automatic push of any calibration change through `WebAccount`. That work is scaffolded but currently dormant — coordinate with the iOS-side agent when you're ready.

## Future extension: diagnostic payload

The iOS app has an in-app **Calibration Inspector** ([`BumpyRide/CalibrationInspectorView.swift`](../BumpyRide/CalibrationInspectorView.swift)) that surfaces the math behind the single `pocketGain` number — distribution of per-cell ratios, top contributing cells, recent rides' detector results, algorithm constants in effect. The whole snapshot is a `CalibrationDiagnostics` struct in [`CalibrationStore.swift`](../BumpyRide/CalibrationStore.swift).

We'd like the web app to show a matching view at `/settings/calibration` (or similar) so a user can see the same diagnostic regardless of which surface they're on. **The iOS algorithm is the source of truth** — the server doesn't recompute, just stores and re-serves.

### Proposed payload shape

Extend `GET` / `PUT /api/me/calibration` to carry an optional `diagnostics` block alongside the existing scalar fields:

```json
{
  "pocketGain": 1.42,
  "confidence": 17,
  "lastComputedAt": "2026-05-14T11:24:00Z",
  "diagnostics": {
    "computedAt": "2026-05-14T11:24:00Z",
    "unclampedMedian": 1.452,
    "minRatio": 0.78,
    "maxRatio": 2.31,
    "meanRatio": 1.51,
    "stdDev": 0.42,
    "totalMountedSamples": 12450,
    "totalPocketSamples": 8200,
    "totalCellsTouched": 612,
    "cellsWithBothModes": 84,
    "qualifyingCells": 17,
    "topCells": [
      {
        "ix": -1094812, "iy": 710004,
        "latitude": 38.88012, "longitude": -77.04032,
        "mountedCount": 120, "mountedAverage": 0.42,
        "pocketCount": 45, "pocketAverage": 0.31,
        "ratio": 1.35, "qualifies": true
      }
    ],
    "recentDetections": [
      {
        "rideId": "55E9B0BB-...",
        "rideTitle": "Commute home",
        "startedAt": "2026-05-13T22:00:00Z",
        "pocketMode": true,
        "schemaVersion": 2,
        "detectorVerdict": "likelyPocket",
        "detectorRatio": 0.92,
        "cadenceRMS": 0.18, "bumpRMS": 0.19,
        "samplesAnalyzed": 4250
      }
    ],
    "thresholds": {
      "minSamplesPerMode": 3,
      "minOverlappingCells": 3,
      "minPocketAvg": 0.02,
      "minGain": 0.5, "maxGain": 5.0
    }
  }
}
```

### Storage suggestion

A single `users.calibration_diagnostics JSONB` column.  Don't try to normalize the nested structure into relational rows — iOS owns the shape and may evolve it, and the server treats the blob opaquely.

### Behavior

- **PUT** accepts a payload with or without `diagnostics`. When present, the server stores it verbatim.  When absent (older iOS versions), don't touch what was previously stored.
- **GET** returns `diagnostics` if any was previously stored; `null` otherwise.
- The server doesn't validate or interpret the diagnostics block. iOS may change shapes within minor versions — treat the blob as opaque key/value documents.

### Payload size

For an active user, the diagnostic blob is typically 30–100 KB.  Top cells are capped at 50; recent rides at 30. Server should reject payloads above 256 KB to defend against a malicious / buggy iOS client.

### Open items

Same iOS-side coordination model as the rest of `/api/me/calibration` — iOS will start sending `diagnostics` on the same hooks (launch, ride save, reachability return). Until the server accepts the field it will be silently dropped from PUTs and the iOS Inspector remains an offline-only feature. The two halves are deployable independently.
