# BumpyRide Ride Schema

This document is the canonical wire-format specification for a BumpyRide ride record. The iOS app's on-disk storage format (one JSON file per ride at `<Documents>/Rides/<UUID>.json`) is identical to what a future server should expect to receive over the network.

Implementations in any language can target this spec without depending on the Swift source.

The Swift source of truth lives in [`BumpyRide/Models.swift`](../BumpyRide/Models.swift). The JSON keys are locked via explicit `CodingKeys`, so they will not silently change if a Swift property is renamed during a refactor.

## File-level conventions

| Aspect | Value |
|--------|-------|
| Encoding | UTF-8 JSON |
| Top-level | Single object — one ride per file/payload |
| Dates | ISO-8601 strings with timezone, e.g. `"2026-04-23T19:09:00Z"` |
| UUIDs | Uppercase canonical form, e.g. `"55E9B0BB-7CBE-4F23-9E0A-1D2C3F4A5B6C"` |
| Numbers | JSON numbers; coordinates and bumpiness are decimal, point counts are integer |
| Unknown fields | Consumers MUST ignore fields they don't recognize |
| Missing optional fields | Treat as the documented default; do not error |

## Versioning

Each `Ride` carries a `schemaVersion` integer. The current emitted value is `2`. Records written before the field existed decode as `1` via the iOS `init(from:)` shim.

Consumers should be prepared to accept **both `1` and `2`** concurrently — old iOS installs that haven't updated yet continue to emit `1`, and edited / re-uploaded historical rides still carry their original version.

### What's different between v1 and v2

The semantics of `accelWindow` and `bumpiness` differ depending on the recording-time pocket-mode setting:

| Version | `accelWindow` content | `bumpiness` |
|---|---|---|
| `1`, `pocketMode == true` | post-3 Hz-HPF vertical samples (cadence band stripped at record time) | RMS of the last 1 s of the same post-HPF signal |
| `1`, `pocketMode != true` | raw vertical samples | RMS of the last 1 s of raw |
| `2`, **any pocketMode** | **always raw vertical samples** | for `pocketMode == true`: RMS of the same window passed through a 3 Hz HPF at save time; for `pocketMode != true`: RMS of the raw window |

So in v2, the `accelWindow` always represents what the sensor actually saw, regardless of the user's pocket-mode tag, and `bumpiness` is a derived value that consumes the appropriate slice of frequency spectrum based on the tag. This lets the user retag a ride later in either direction without information loss — re-running `Ride.reprocessedWithPocketHPF()` or `Ride.reprocessedAsMounted()` on iOS recomputes `bumpiness` correctly from the preserved raw window.

For aggregation on the server side, this distinction mostly doesn't matter: the server reads `bumpiness` directly and applies the per-user `pocketGain` from `/api/me/calibration`. The `accelWindow` value is stored but not currently used in any server-side calculation.

Non-breaking additions (adding a new optional field, adding a new enum case) do NOT bump `schemaVersion`. Consumers should be tolerant of fields they don't recognize.

## `Ride` object

The top-level object.

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `schemaVersion` | integer | no¹ | Wire-format version. New rides emit `2`; legacy on-disk records are `1`. Missing → treat as `1`. |
| `id` | UUID string | yes | Stable identity. Persists across edits (trim/split changes the second half's id). |
| `title` | string | yes | Human-readable. Default for new rides: `"Ride <date>"`. User-editable. |
| `startedAt` | ISO-8601 date | yes | When recording began (or, after a trim, the timestamp of the first kept point). |
| `endedAt` | ISO-8601 date | yes | When recording ended. `endedAt >= startedAt`. |
| `points` | array of `RidePoint` | yes | Ordered chronologically. May be empty for a discarded recording, but typically ≥1 element. |
| `pocketMode` | boolean | no² | `true` = phone was on the rider's body; `false` = phone was on a fixed bike mount; `null`/missing = mode not determined (legacy or undecided). Set at save time by `MountStyleDetector`, user-overridable. See the "Versioning" section for what this affects in `accelWindow` and `bumpiness`. |

¹ Default: `1` for records lacking the field. ² Default: `null` (unknown).

### Derived values (NOT in the wire format)

The iOS app computes these on the fly; do not emit them:

- `duration` = `endedAt - startedAt`
- `distanceMeters` = sum of great-circle distances between consecutive `points` (`CLLocation.distance` in iOS)
- `maxBumpiness` / `averageBumpiness` = aggregates over `points[*].bumpiness`

A server doing aggregation may want to compute its own versions and store them.

## `RidePoint` object

One entry per emitted sample. The iOS app emits a sample each time CoreLocation reports the device has moved at least 3 m (≈10 ft) since the previous point — so spacing varies with rider speed.

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `id` | UUID string | yes | Stable per-point id, distinct from `Ride.id`. |
| `timestamp` | ISO-8601 date | yes | CoreLocation fix timestamp. Monotonically non-decreasing within a ride. |
| `latitude` | number | yes | Degrees, WGS-84. Range `[-90, 90]`. |
| `longitude` | number | yes | Degrees, WGS-84. Range `[-180, 180]`. |
| `speed` | number | yes | Meters per second. Always `>= 0` (CoreLocation's `-1` "unknown" is clamped to `0` on emit). |
| `bumpiness` | number | yes | RMS of vertical acceleration over the trailing 1.0 s window. Units: g (1 g ≈ 9.81 m/s²). Always `>= 0`. Typical observed range on a road bike: `0.05`–`2.5`. |
| `accelWindow` | array of numbers | yes | Recent vertical-acceleration samples used to redraw the seismograph in playback. See "accelWindow encoding" below. |

### `accelWindow` encoding

- **Units:** g, signed (positive = upward in world frame).
- **Source:** scalar projection of `CMDeviceMotion.userAcceleration` onto the gravity unit vector.
  - In `schemaVersion 2`: **always raw** — no filtering at record time.
  - In `schemaVersion 1` with `pocketMode == true`: the raw signal was passed through a 3 Hz Butterworth HPF before storage.
  - In `schemaVersion 1` with `pocketMode != true`: raw (same as v2).
- **Order:** chronological, oldest-first / most-recent-last.
- **Length:** typically `250` (5 s × 50 Hz sample rate). May be shorter (`< 250`) at the very start of a ride, before the ring buffer has filled. Server consumers should not assume a fixed length.
- **Values:** finite numbers, typically in `[-1.5, 1.5]`. Outliers may exceed this — do not clamp on ingest.

This array is intentionally redundant with `bumpiness`. It exists so playback can redraw the seismograph waveform at any scrubbed point in a saved ride, and so the iOS app can retroactively recompute `bumpiness` if the user retags the ride (in v2, the raw signal is preserved, so retag in either direction is lossless).

## Sample

See [`sample-ride.json`](./sample-ride.json) for a minimal but representative example a server-side parser can use as a fixture.

## Forward-compatibility expectations for consumers

A server / aggregator implementation that accepts data from multiple iOS-app versions should:

1. **Always check `schemaVersion`.** Refuse versions you don't know how to read. Don't silently accept v2 records if you only understand v1.
2. **Tolerate missing optional fields.** `pocketMode` may be absent. Future versions may add more optional fields.
3. **Ignore unknown fields.** Forward-compat freebie — a client one version ahead may include keys you've never seen.
4. **Validate ranges but be permissive.** A bumpiness of `5.0 g` is plausible for an extreme pothole; a latitude of `100` is corrupt data and should be rejected.
5. **Treat `Ride.id` as the dedup key for re-uploads.** A given UUID names the same logical ride forever; receiving it twice should be idempotent.
