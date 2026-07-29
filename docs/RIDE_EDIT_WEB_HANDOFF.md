# Web handoff: ride editing (trim / split) + `editedAt`

**iOS side: shipped in v2.0.** The app has a dedicated ride editor
(trim a ride to a slice, or split one ride into two). No new endpoints
are required for the current iOS-only flow — everything is expressed
through the existing idempotent `POST /api/sync/ride`. This doc
formalizes the semantics the server should uphold, and specs the
`editedAt` conflict rule needed **before** a web-side editor ships.

## Edit semantics on the wire

### Trim

The ride **keeps its id** and re-uploads with new content:

- `points` is a contiguous slice; `startedAt`/`endedAt` move to the
  slice bounds.
- `closeCallEvents` / `otherEvents` contain only events inside the new
  time range (the client filters).
- `brakeEvents` are re-detected client-side on the new points.
- `healthKitWorkoutUUID` is cleared (device-local anyway).
- `editedAt` is stamped.

Server behavior: standard replace-on-same-id. Recompute derived stats,
update `content_hash`, rebuild tile contributions from the replaced
payload, **re-score the ride** (existing behavior), and re-award its
per-ride achievements (wipe + re-award, per
`ACHIEVEMENTS_IOS_HANDOFF.md`). Milestones stay monotonic — a trim
that drops lifetime miles below an earned rung never revokes it.

### Split

Two uploads, no ordering guarantee between them:

- **Part 1 keeps the original id** — a replace, exactly like trim
  (first slice of points, filtered events, `editedAt` stamped).
- **Part 2 arrives as a brand-new ride id** — a normal insert with the
  second slice. Title is derived ("… (part 2)").
- The point sets partition exactly (no overlap, no gap), and each
  user event lands in exactly one half — so cell contributions and
  event counts across the two halves equal the original. **No double
  counting by construction.**

Server behavior: nothing special — one replace + one insert. Note the
side effects are legitimate and expected: the ride-tally milestone
ladder sees one more eligible ride, and part 2's upload response
carries its per-ride achievement awards like any fresh insert.

## `editedAt` — the multi-client conflict rule

New additive-optional field on the ride payload (see `SCHEMA.md`):

```json
"editedAt": "2026-08-02T15:04:11Z"
```

- Stamped by iOS on every user **content edit** (trim, split, rename).
  `null` = never edited.
- Store and round-trip it today (restore must return it).

**Why it matters:** when the web app gets its own editor, both clients
can modify the same ride. The iOS sync path re-uploads local copies it
believes are newer (its checksum mismatch heuristic can't tell "local
is newer" from "server is newer") — without a rule, an iOS re-upload
would silently clobber a fresher web edit.

**The rule, once the web editor ships:**

1. On ingest of a ride the server already has: if the stored copy's
   `editedAt` is **newer** than the incoming payload's (treating
   `null` as older than any timestamp), **reject with a 409-style
   conflict** carrying the stored `editedAt`. The client then
   re-fetches the server copy instead of overwriting (iOS will add
   this handling when the web editor lands; today the situation cannot
   occur since only iOS edits).
2. Web-side edits must stamp `editedAt` server-side and bump
   `content_hash`, so the iOS batch check (`check-batch`) naturally
   reports a mismatch; iOS pulls the server copy via the existing
   restore path rather than re-uploading (client-side change, planned
   alongside the web editor).
3. Clock skew: server may clamp incoming `editedAt` values that are in
   the future relative to server time.

Until the web editor exists, rule 1 is inert (stored `editedAt` only
ever comes from the same client that's uploading), so it can be
implemented now at zero risk.

## Web editor parity (when built)

Same two operations, same semantics: trim = in-place edit of points +
event filtering + re-derive; split = in-place first half + new-id
second half. The server implementation should filter events and
re-detect brakes server-side (or accept the recomputed arrays from the
web client) — whichever, the invariants above hold: events partition,
points partition, ids behave as specified, `editedAt` stamps.
