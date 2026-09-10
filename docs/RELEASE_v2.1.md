# Release v2.1 — IN PROGRESS

**Not finalized.** Version and build are still `2.0` / `30`; the bump
happens at finalize time, as with 2.0. Add items to the sections below
as they land. Series letter for this cycle: **T**.

Follows the same shape as `RELEASE_v2.0.md`: §1 is pasted into App Store
Connect as-is; §2 and §3 are *deltas* to fold into the cumulative
description and review notes at finalize time (review notes budget is
4,000 characters — `RELEASE_v2.0.md` §3 measures 3,895, so anything
added there needs a matching cut).

---

## 1. What's New (draft)

```
BumpyRide 2.1 tidies up the map and takes better care of your battery.

MAPS
• The Bump Map opens where your riding actually is. One long trip no
  longer zooms the map out so far that nothing renders.
• When you stop a ride, the map stops following you and shows the
  whole route. Saved rides open the same way, without the location
  dot.
• The purple "I've been here" layer appears immediately instead of
  waiting for every past ride to be re-read.

BATTERY
• A ride left running with no movement for 15 minutes now pauses
  itself and turns GPS off. Tap Resume to carry on. Off switch in
  Settings › Recording.
• Fixed a case where, after the app was force-quit mid-ride, iOS
  could keep waking it in the background on every few blocks of
  movement.

SCORING
• Rides you've earned points for show them in the Saved list.
```

---

## 2. Description delta

Add to the feature list after the "Ride editor" bullet:

```
• Auto-pause — a ride left running without movement pauses itself
  and turns off GPS
```

---

## 3. Review notes delta

Fold into the BACKGROUND LOCATION section of the cumulative notes.
Suggested cut to stay under budget: trim the DIAGNOSTICS paragraph.

```
Two 2.1 changes reduce location use further. (1) If a recording sees
no movement for 15 minutes, the app pauses the ride and stops both
location updates and motion sampling; the rider must tap Resume.
(2) At every launch the app explicitly stops Significant Location
Change monitoring and clears the background-location opt-in, so a
registration left behind by a force-quit mid-ride cannot keep waking
the app afterwards. Outside an active recording the app now holds no
location registration of any kind.

DIAGNOSTICS addition: with the same off-by-default "Write Debug Log"
toggle on, the app also stores its own daily MetricKit payloads
(power and performance aggregates Apple provides to every app about
itself) alongside the ride files, for the rider's own battery
troubleshooting. No third party receives them.
```

---

## Changes since 2.0 (engineering index)

**Maps**
- T1 Bump Map opening frame: `BumpGrid.focusBounds` (2 %/98 % of
  sample weight per axis) → `BumpMapStore.focusRegion`; `BumpMapView`
  frames that instead of the full extent and clamps the span so the
  camera never opens below the overlay's `minimumZ` (`minOpeningZoom
  = 11.3`, computed from the view's actual size). Recenter uses the
  same framing. Root cause: full extent × 1.4 padding exceeded the
  zoom-11 tile floor once the library spanned more than one town.
- T2 Finished ride: `LiveRouteMapView.rideIsOver` — on `.finished`
  the live map drops `showsUserLocation`, sets tracking to `.none`,
  and `setVisibleMapRect` to the route's union bounding rect; recenter
  becomes "Fit route". `RouteMapView` renders `UserAnnotation` only
  when `followUser`, and its initial camera is `.automatic`.

**Battery**
- T3a `LocationManager.ensureIdle()` called from `RideRecorder.init`:
  `stopMonitoringSignificantLocationChanges` + `allowsBackground
  LocationUpdates = false` on a fresh manager at launch. SLC
  registration outlives the process; only `stopUpdating` ever cleared
  it, so a kill mid-ride left the app relaunching in the background on
  every ~500 m indefinitely.
- T3b Stillness auto-pause: `RideRecorder` tracks movement per fix
  (`speed ≥ 0.7 m/s` or `> 30 m` from the last movement anchor); a
  30 s timer pauses the ride after 15 min without it and sets
  `autoPausedAt` for the banner. Manual resume only. Setting
  `AppSettings.autoPauseWhenStill` (default on), read by the recorder
  via UserDefaults. Field data: the last eight rides all ended within
  ~1 min of the last fix with no stationary tail, so this is a safety
  net, not a fix for observed behaviour.

**Visited-cells overlay**
- T4 Disk cache for `BumpGrid`: `serialized()` / `init?(serialized:)`
  (24 B per cell, magic `BGR1`), stored in Caches as
  `bump-grid-<fnv1a(signature)>.bin`, up to four kept so filter and
  calibration variants don't thrash. `rebuildIfNeeded` loads the cache
  before folding; `noteRideSaved` folds a new ride in place (same
  calibration gain) and refreshes the cache, wired from
  `ContentView.onRideSaved`. Diagnosis: the overlay is fully local —
  the startup delay was the fold decoding every ride file (~1 GB).
  First launch on this build still does one full fold.

**Scoring**
- T5 Per-row score chip in `SavedRidesView` when `webAccount
  .isConnected`; rows call `RideScoreCache.requestScore` lazily via
  `.task(id:)`. `RideScoreCache` persists `.loaded` entries only to
  Caches (`ride-scores.json`, debounced 0.8 s) — `.ineligible` is not
  persisted because it also covers "not on the server yet".
  `ScoreView.formattedPoints` made non-private for reuse.

**Energy telemetry**
- T6 `EnergyMetricsCollector` subscribes to MetricKit at launch; each
  daily `MXMetricPayload` is written verbatim as
  `metrics-<date>.json` (diagnostics as `diagnostics-<date>.json`) in
  the rides directory, gated on the Diagnostics debug-log toggle, with
  a one-line digest (fg/bg minutes, location minutes per accuracy
  tier, CPU seconds) in the debug log; 60-day retention. Device only.
- T6a Payload filenames now carry a content hash
  (`metrics-<date>-<hash8>.json`). iOS delivers several payloads at once
  and more than one can share a `timeStampEnd` date; keying on the date
  alone let a near-empty disk-only payload overwrite the rich daily
  aggregate, which is what happened to the 5-9 Sep payloads — only the
  session-log digests survived. Identical re-deliveries are now skipped
  rather than rewritten. Digest also widened to carry GPU, peak memory,
  upload volume and background-exit counts.
- T6 Battery stamps: `RideRecorder` logs level / charging state / Low
  Power Mode / thermal state at start, pause, resume, stop, and a
  "ride battery cost: N % over H h (%/h)" line at stop.

**Energy & data findings, fixed (series U)**

First MetricKit data landed 8-10 Sep on build 30 (iPhone 18,1 / iOS 26.6.1)
and turned up four problems plus one unrelated bug. All five are fixed below;
each needs re-measuring on 2.1 once a few days of payloads accumulate.

- **U1 - 923 MB uploaded in one day, 873 MB of it cellular** (whole library
  is 688 MB / 231 files; only two rides, ~10 MB, were new that day).
  `ContentView` re-seeds every ride into the backfill queue on each launch,
  and the only thing keeping that from becoming a full re-upload was a
  server round-trip per ride; when those checks were slow or unavailable it
  degraded straight to uploading everything.
  Fix: new `SyncLedger` (`Sync/ledger.json`) records the SHA-256 of the body
  the server last accepted per ride. The drain now hashes queued backfill
  once, prunes locally against the ledger before any network call, and
  records into the ledger from both the batch and per-ride check paths. A
  steady-state launch now costs zero requests instead of 231. Ledger entries
  are dropped on ride save/delete and cleared on account disconnect.
  Also: backfill is held for Wi-Fi (`AppSettings.backfillOnWiFiOnly`,
  default on, Settings > Recording) via `NetworkReachability.isExpensive`,
  with `allowsExpensiveNetworkAccess = false` on the request as a backstop.
  Rides the user just saved always upload immediately.
- **U2 - GPU time ~2x foreground wall time** (7217 s vs 3659 s), which is
  what drove `thermal=serious` and much of the 20-40 %/h battery cost.
  Cause: `RideView` read `recorder.liveSamples` / `currentBumpiness` in its
  own body. `MotionManager` republishes those ~17 times a second, so every
  publish invalidated the entire ride screen — including
  `LiveRouteMapView`, whose `updateUIView` then ran at 17 Hz for the whole
  ride on top of MapKit's own follow-mode redraw.
  Fix: new `LiveSeismograph` wrapper reads the live buffers inside its own
  body, confining the 17 Hz invalidation to the waveform.
- **U3 - MapKit runs a second location manager at navigation accuracy**
  (40 min on 8 Sep) even though `LocationManager` never leaves
  `kCLLocationAccuracyBest`. It sits behind `showsUserLocation` +
  `userTrackingMode`.
  Fix: `.finished` already dropped the dot and tracking (T2); heading-up
  tracking is now additionally gated on an active recording
  (`headingTrackingAllowed`), so idle follows plain north-up.
  Deliberately *not* extended to hiding the dot at `.idle` — that was tried
  and left the map framing the whole continent instead of the rider.
  How much this actually cuts is unknown until the next payloads arrive.
- **U4 - 467 MB peak memory and 3 background memory-pressure kills.**
  `foldRides` and `contentHashes` loop over every ride in the library,
  decoding (and for hashes re-encoding) multi-MB files, with no
  `autoreleasepool` anywhere in the app — so Foundation temporaries
  accumulated until the whole loop finished.
  Fix: one pool per iteration in both loops, holding the peak to a single
  ride. Relevant to T3a too: a background memory kill mid-ride is exactly
  what orphans the SLC registration T3a clears at launch.
- **U5 - HealthKit heart-rate association failed on every export** since the
  feature shipped (`Code=4 "Not authorized"`, 3 Sep through 9 Sep), so
  workouts saved without the HR trace. `HKHealthStore.add(_:to:)` is a
  *write* against the sample types being added; the app only ever requested
  read access for heart rate. K4 in 2.0 fixed a different part of this path
  and left the authorization gap.
  Fix: heart rate added to `shareTypes`, and the exporter now checks
  `sharingAuthorized` before attempting, logging one explanatory line
  instead of a failure per ride. **Existing users are not re-prompted
  automatically** — they must re-authorize in Settings > Apple Health for
  the trace to attach. Cosmetic either way: Fitness shows heart rate for
  the workout's time window regardless of formal association.

**Confirmations from the same data**
- T3a is justified: on 5 Sep, with **no ride recorded**, the app spent
  18 min in the background and 10 min using location against 3 min of
  foreground use.
- T3b is not: the four rides logged were all stopped promptly, no
  stationary tail. Auto-pause remains a safety net, as noted above.

**Still open**
- Re-measure U1-U4 against 2.1 payloads before calling any of them closed;
  every number above is from build 30.
- Battery cost per ride (20-40 %/h, `thermal=serious` once) has no
  post-fix measurement yet. Screen-on time is a large uncontrolled term —
  `averagePixelLuminance` was 67 apl over 878k samples.
- Pre-existing Swift 6 warning at `BumpMapStore.swift:55` (MainActor
  default argument), untouched by this work.
