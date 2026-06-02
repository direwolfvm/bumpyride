# Server-side Ride Restore — Web Handoff

This is the bumpyride-web handoff for the ride-restore feature shipping in iOS v1.5. Closes the data-loss gap from the v1.2 iCloud work: if a user deletes the app and reinstalls, their synced rides currently can't be downloaded back. Pairs with the existing upload path (`POST /api/sync/ride`).

## TL;DR

- Two endpoints needed on the server side.
- Same bearer-auth pattern as `/api/me/sharing` and `/api/me/score`.
- Nothing destructive. The server's existing data is what we're reading back.
- iOS handles dedup, progress, and UI. The server just needs to list rides and serve individual ones on demand.

## What iOS does

Quick context for what you're enabling:

1. **User taps "Restore my rides"** in Settings → Web Account.
2. iOS calls `GET /api/sync/rides` to list everything the user has on the server.
3. iOS compares the returned IDs to its local rides. Computes the set of "to download."
4. For each missing ride, iOS calls `GET /api/sync/ride/{id}` and saves it locally (iCloud Documents if available, else local Documents).
5. Progress sheet shows "Restoring N of M..." with a cancel button.
6. When complete, the Saved tab + Bump Map reflect the recovered rides.

Existing rides with the same ID are overwritten (server-wins by user choice).

## Endpoints to add

### `GET /api/sync/rides`

List the user's rides — IDs + minimal metadata, paginated.

**Request**:
```
Authorization: Bearer br_…    (or session cookie)
Accept: application/json
```

**Query params**:
| Param | Required | Notes |
|---|---|---|
| `limit` | no | Page size. Default 100, max 500. |
| `cursor` | no | Opaque pagination cursor from a previous response. Omit for first page. |

**Response** (200):
```jsonc
{
  "rides": [
    {
      "id": "036D3C25-0396-42EE-8026-0CC0098714DD",
      "title": "Ride May 9, 2026 at 4:05 PM",
      "startedAt": "2026-05-09T20:05:00Z",
      "endedAt": "2026-05-09T20:30:00Z",
      "pointCount": 1364,
      "sizeBytes": 4668700
    }
    // …
  ],
  "nextCursor": "eyJpZCI6IjAzN…",   // or null when no more pages
  "totalCount": 247               // total across all pages
}
```

iOS uses `totalCount` for progress display and `sizeBytes` for a "this will download ~X MB" warning before starting.

**Errors**: 401 (token revoked or expired) is the only expected one. Server errors fall through as transport-level failures iOS surfaces generically.

### `GET /api/sync/ride/{id}`

Return one full ride payload — same JSON shape iOS uploads via `POST /api/sync/ride`. May already exist; if so, just confirm the shape.

**Request**:
```
Authorization: Bearer br_…    (or session cookie)
Accept: application/json
```

**Response** (200): the full Ride JSON as documented in [`SCHEMA.md`](./SCHEMA.md). Same shape iOS originally uploaded — schemaVersion preserved (v1, v2, or v3 depending on when the ride was recorded).

**Errors**:
- 401: token invalid
- 404: ride doesn't exist or doesn't belong to this user
- 500: server failure — iOS retries with backoff

## Pagination semantics

- Cursor-based, not offset-based, so concurrent writes don't shift the listing.
- Cursor opacity is fine — iOS treats it as a token to echo back.
- Order: any consistent order works. Suggest `startedAt DESC` so the first page is the user's most recent rides (most likely to be the ones they care about).

## Rate limiting

iOS will hit `GET /api/sync/ride/{id}` once per ride being restored. For a user with 500 rides that's 500 sequential GETs.

- iOS paces them with a 100 ms gap between requests by default — adjustable based on what your server can tolerate.
- If you implement rate limiting, please return 429 with `Retry-After` and iOS will back off and resume.
- Each ride is independent; if one 5xxs, iOS continues and reports the partial restore at the end.

## Auth note

Same bearer pattern as `/api/me/sharing` and `/api/me/score`. No new permission scopes needed — the user is reading back their own rides, which they had read access to all along.

If you have multiple bearer scope levels (separate read vs write tokens), both endpoints are read-only and can use whichever is more restrictive.

## Privacy

No public-aggregate effect. This reads the user's private ride records back to them. Doesn't touch `bump_cells`, `score_events`, or any shared table.

## iOS expectations on payload integrity

- Server preserves the exact JSON iOS uploaded. We round-trip it through our decoder.
- If a ride was edited server-side (renamed, trimmed via some web UI you might add later), the server's version is the source of truth — that's what iOS adopts on restore.
- If `schemaVersion` is anything 1–3, iOS handles it via the existing additive-decode path. No special migration needed at the wire layer.

## What this does NOT do

- Not a continuous-sync mechanism. iOS won't poll for changes. This is an explicit user-initiated restore.
- Doesn't restore `bump_cells` aggregates or `score_events` — those are computed server-side from rides, so restoring the rides re-creates them.
- Doesn't restore calibration data — that's stored separately and already has its own GET endpoint.
- Doesn't handle multi-device "merge" — if user has rides on Device A and different rides on Device B, both will sync to the server, and a restore on Device C will get everything. No per-device awareness.

## Test plan for the web side (suggested)

- Empty account: returns `{rides: [], nextCursor: null, totalCount: 0}`
- One page: returns full list, `nextCursor: null`
- Paginated: returns first N, valid cursor; cursor returns next page
- Stale cursor: 400 with clear error message
- Token revoked mid-pagination: 401
- Single-ride GET: returns valid JSON matching the upload schema
- Wrong owner: 404
- Bad UUID: 400 or 404
- Large library smoke test: 1000+ rides paginates cleanly without timeout

## Coordination check-in

When the endpoints are deployed:
- Ping me with the base URL pattern and any pagination tuning.
- iOS side can be built against a mock today and switched to the real endpoints once they're up.
- Recommend deploying to a staging environment first so we can do a full end-to-end restore test with a real account before this hits any user.

Nothing else blocks. The user's existing rides and the upload path are unchanged.
