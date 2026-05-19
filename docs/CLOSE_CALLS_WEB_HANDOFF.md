# Close Call Reporting — Web Handoff

Companion to [`BRAKES_WEB_HANDOFF.md`](./BRAKES_WEB_HANDOFF.md). Both features ship in iOS v1.3 under the same schema (v3); they're documented separately because the *capture* mechanism is fundamentally different and the privacy posture differs accordingly.

## TL;DR

- **Same schema (v3)**. `Ride` gains another optional array field, `closeCallEvents`. No deeper schema change.
- **User-initiated**, not detected. iOS users tap a "Log Close Call" button during recording to flag a near-miss. There's no equivalent of a `BrakeEventDetector` to port.
- **`POST /api/sync/ride` unchanged.** Same endpoint, same idempotency. If you ignore unknown JSON keys, the new field lands in your JSONB blob without code changes.
- **Nothing blocking.** iOS ships v1.3 with the web side stubbed.

## What changed in the ride payload

```jsonc
{
  "id": "…",
  "title": "…",
  // …existing v3 fields…
  "brakeEvents": [ … ],
  "closeCallEvents": [                       // ← NEW
    {
      "id": "…",
      "timestamp": "2026-05-19T09:14:32Z",
      "latitude": 38.9072,
      "longitude": -77.0369
    }
  ]
}
```

| `closeCallEvents` shape | Semantics |
|---|---|
| Missing / `null` | The ride predates the close-call feature.  **No backfill is possible** — the data simply wasn't capturable for these rides.  Treat as `[]` for rendering. |
| `[]` | Ride was recorded with the feature available, but the user didn't tap the button. |
| `[ … ]` | One or more close calls.  Typical ride: 0–5 entries.  Sorted by `timestamp` ascending. |

### `CloseCall` object

Intentionally minimal. The v1.0 design goal is one-handed, no-look tap-to-log while riding — anything richer than ID + time + location would have required an interaction model (sheet, slider, text field) that's hostile in mid-ride conditions.

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `id` | UUID string | yes | Stable per-event id. |
| `timestamp` | ISO-8601 date | yes | `Date()` at the moment of the tap. |
| `latitude` | number | yes | Location at tap time. WGS-84. |
| `longitude` | number | yes | Location at tap time. WGS-84. |

No severity, category, or notes. Those are deferred to a future feature release (likely v1.4+) once we see real usage and have a clearer sense of what users would actually want to record.

## What iOS does

Context for what you're receiving:

1. **Captured live during recording.** When the user taps the "Log Close Call" button, iOS snapshots `CLLocationManager.lastLocation` and `Date()` and appends a `CloseCall` to the in-progress recording. Persisted to the crash-safe journal immediately, alongside the points file.
2. **5-second undo window.** After each tap, a banner with an Undo button appears for 5 seconds. Undo removes the call from the in-memory list (journal is append-only — a crash during the undo window would resurrect the call, but normal flow loses it cleanly).
3. **Post-hoc deletion from saved-ride view.** Long-press a close-call row in the saved-ride playback view to get a Delete option. Re-saves the ride; sync picks up the updated payload.
4. **No reprocessing for legacy rides.** Unlike brake events, there's nothing to backfill — pre-v1.3 rides have `closeCallEvents == null` and stay that way.

## What bumpyride-web v1.4 should pick up

Priority order — items 1–3 are the minimum to ship visibility; 4+ are nice-to-have.

### 1. Accept v3 payloads gracefully

Same check as the brakes handoff. If `POST /api/sync/ride` already stores the full body as JSONB and `schemaVersion` is read but not allow-list-validated, you're done. Re-uploaded rides (e.g., after a user deletes a close call on iOS) will overwrite the existing record by `Ride.id` — your existing dedup behavior handles this correctly.

### 2. Per-ride close call display

On the per-ride view page, add a close-calls section. Suggested layout:

- **List** of close calls ordered by timestamp, one row per event.  Each row: time-into-ride, a small violet diamond glyph for visual identity (matches iOS).
- **Map markers**: violet diamonds (or any shape that's clearly distinct from your brake-event marker) on the route polyline.
- **Empty states**:
  - `closeCallEvents == null` → "This ride predates close-call reporting."
  - `closeCallEvents == []` → "No close calls logged."

The visual color iOS uses is `#8C40D9` (mid violet) — feel free to match for cross-platform consistency, or use whatever your existing palette has at the "warning-but-not-emergency" tier.

### 3. Public close-call map

Same shape as the public brake map: per-cell counts, hardcoded color thresholds. Use the same 20 ft cell grid (`BumpGrid.cellLatDeg` / `cellLonDeg` constants) so all three public maps (bumps, brakes, close calls) align if you ever want to layer them.

**Privacy gate is critical here.**  Same as bump + brake maps: respect `shareToPublicMap` and the 3-distinct-rider threshold from `/api/me/sharing`.  A close call typically marks a specific dangerous intersection — without the privacy gate, a solo rider's close-call locations could be inferred trivially.  The `publicMapEager` opt-in remains the explicit knob for users who *want* their data published immediately.

Per-feature visibility: a user who's set `shareToPublicMap = true` shares brakes AND close calls AND bumpiness collectively — there's no per-feature opt-out. Worth flagging in your privacy copy.

### 4. CSV export

If you export per-ride CSVs today, consider a `close_calls.csv` per ride (or a third sheet) with the timestamp + lat + lon columns. Useful for users who want to overlay close-call locations on third-party tools.

### 5. Heatmap layer hooks

Eventually you'll likely want a combined "safety map" overlay that shows brakes + close calls in one view, color-coded. Not urgent, but the cell-key alignment between the three grids on the iOS side means a join is trivial server-side (group by cell key, sum counts per type).

## Privacy considerations

This data is more sensitive than bumpiness or brake events because:

1. **A close call is, semantically, "the user felt unsafe here."** Aggregating exposes patterns about which riders frequent which corners.
2. **Sparse data is harder to anonymize.** A single close call at a quiet intersection in a small town effectively names the user. The 3-distinct-rider threshold is what saves us; without it, the data shouldn't be public.

iOS surfaces no public-sharing UI specific to close calls — the existing `shareToPublicMap` toggle in Settings → Web Account governs the whole bucket (bumps, brakes, close calls).  Web v1.4's `/map` page should display the policy clearly so users with sharing on understand what they're contributing.

## Coordination check-in

When you're ready to implement, ping the iOS side and we'll:
- Generate fresh `sample-ride.json` fixtures with both `brakeEvents` and `closeCallEvents` for your tests.
- Sync up on close-call marker color/shape so iOS and web don't drift visually.
- Decide whether close-call deletion from iOS should be soft (tombstone, server keeps history) or hard (overwrite-only). Today it's hard — the re-upload contains the updated array with the call gone. Soft delete would require an API change.

Nothing is blocking iOS v1.3 ship. Take this whenever there's a window.
