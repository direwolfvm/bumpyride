# Release v2.1

Build **31**. MARKETING_VERSION `2.1`.

A maintenance release with one theme: energy. It began as five
reported issues, grew an instrumentation layer to answer "is this
actually better?", and then spent most of its length chasing what
that instrumentation found — including two fixes that measurably did
nothing, and one six-week-old sync bug that turned out to be ours.

> **Note on the doc**: the three sections below are what gets pasted
> into App Store Connect — release notes, product description, and
> App Review notes. Description and review notes are *cumulative*
> (complete text as of 2.1, not deltas). **The review notes fit App
> Store Connect's 4,000-character limit** — the block below measures
> **3899**, leaving ~101. Any addition needs a matching cut.
> Re-measure with:
> `python3 -c "s=open('docs/RELEASE_v2.1.md').read();i=s.index('ABOUT'+chr(10)*2+'BumpyRide records');print(len(s[i:s.index(chr(10)+'\`\`\`',i)]))"`

---

## 1. What's New

```
BumpyRide 2.1 is about battery, and about the map behaving
itself.

BATTERY
• Recording now costs about half what it did. Same ride, same
  route: roughly 21% of a charge per hour before, about 10% now,
  and the phone no longer gets warm doing it.
• A ride left running with no movement for 15 minutes pauses
  itself and switches GPS off. Tap Resume to carry on, or turn it
  off in Settings › Recording.
• Fixed a case where force-quitting mid-ride could leave iOS
  waking the app in the background for days afterwards.

MAPS
• The Bump Map opens where your riding actually is. One long trip
  no longer zooms it out so far that nothing draws.
• Stop a ride and the map stops following you and shows the whole
  route. Saved rides open the same way, without the location dot.
• The purple "I've been here" layer appears immediately instead
  of waiting for every past ride to be re-read.

SYNC
• Fixed a bug that could re-upload your entire ride library —
  repeatedly, over cellular. Backing up older rides now waits for
  Wi-Fi by default; rides you just finished still upload straight
  away.

ALSO
• Rides you've earned points for show them in the Saved list.
• Heart rate from your Apple Watch attaches to the Health workout
  properly. If you use it, re-authorise under Settings › Apple
  Health so the trace can attach.
```

---

## 2. Updated Description (cumulative)

```
BumpyRide is for cyclists who want to know which streets are
smooth and which aren't — and to flag what they run into along
the way.

During every ride, BumpyRide records vibration through your
phone's motion sensors and pairs each reading with your GPS
location. After the ride, see a colored route map showing exactly
where the road was smooth (green) and where it was rough (yellow
→ red → purple).

Ride enough and your personal Bump Map fills in — a permanent
heat map of every street you've ever ridden. Pick smoother routes
for your commute. Avoid the worst potholes on your favorite loop.

Features:
• Live recording with route, bumpiness, and weather overlay
• Elapsed time, current speed, and average speed while you ride
• Live wind readout — headwind, tailwind, or crosswind relative
  to the way you're heading
• Report close calls (vehicle / bike / pedestrian), blocked
  lanes, and your own custom event types
• Automatic hard-brake detection, taggable as safety, other, or
  a false trigger
• Reporting mode — collapse the map for oversized, no-look
  report buttons mid-ride
• Apple Watch app — start, pause, resume, stop, and log close
  calls from your wrist; heart rate added to your Health workout
• Personal heat map of every road you've ridden, plus an overlay
  of your coverage on the live map
• Achievements and scoring — bonus points for distance,
  exploration, smooth roads, and safety reporting, through the
  free bumpyride.me companion web app
• Ride editor — trim or split a saved ride
• Auto-pause — a ride left running without movement pauses
  itself and switches off GPS
• Share a summary photo of any ride
• Adjustable color thresholds — tune what "rough" means to you
• Pocket mode — filters out pedaling cadence so your cranks
  don't register as bumpiness
• Apple Health integration — rides appear in Fitness and credit
  your activity rings
• iCloud Drive backup, and server-side restore after a reinstall
  or a new phone
• Optional sync with bumpyride.me for storage, scoring, and
  community heat maps

Privacy: rides are stored on your phone and, optionally, your
iCloud Drive. Sync to bumpyride.me is opt-in and uses a pairing
code — no email, no password on the device. Custom event types
you define stay private to your own account and never appear on
community maps.
```

---

## 3. App Review Information — Review Notes (cumulative)

> Changed from 2.0: heart rate moved from read-only to a **write**
> type (it is needed to associate the watch's existing samples with
> the workout — see U5); the background-location section gains the
> 15-minute auto-pause and the launch-time SLC clear; diagnostics
> now discloses MetricKit payload storage. Paid for by tightening
> prose throughout — no substantive claim was dropped.

```
ABOUT

BumpyRide records cycling rides with the iPhone's accelerometer
and GPS, then shows where the road was rough or smooth and builds
a heat map across rides. Riders can also report close calls and
road events. An Apple Watch companion adds wrist controls and
heart rate.

BACKGROUND LOCATION — please read

Rides last 30+ minutes with the screen off or the phone in a
pocket, so location must continue in the background. We request
"When In Use" at first launch, then "Always" the first time a
recording starts.

"Always" is needed for one specific reason: Significant Location
Change only delivers to backgrounded apps holding Always, and we
use SLC purely to recover if iOS suspends our continuous updates
mid-ride. Without it, long rides develop unusable GPS gaps. We do
not track users when they aren't recording.

Recording is always explicitly started and stopped by the user,
on the Ride tab or the watch, and the system background-location
indicator is visible throughout.

Two 2.1 changes cut this further. A recording with no movement
for 15 minutes pauses itself, stopping location and motion until
the rider taps Resume. And every launch clears any SLC
registration left by a force-quit mid-ride. Outside an active
recording the app now holds no location registration at all.

MOTION

CMDeviceMotion at 50 Hz during recording only; the vertical
acceleration component gives bumpiness. Started and stopped with
the recording. No background-only access.

HEALTHKIT (optional, opt-in)

Enabled from Settings → Apple Health, which presents the standard
authorization sheet. Nothing is written unless the user opts in.

Write: HKWorkout (cycling/outdoor), workout route, cycling
distance, active energy, and heart rate — the last solely to
associate the watch's existing samples, never to write new ones.
Read: body mass (to estimate calories) and heart rate.

Heart rate detail: with "Open watch app with this app" on, the
watch runs an HKWorkoutSession so watchOS samples heart rate at
workout rate, then DISCARDS its own workout. Only the iPhone
writes an HKWorkout — one per ride, not two. Samples are
associated, never duplicated; each workout carries the ride's
UUID, so re-export is idempotent.

WEATHERKIT

The recording map shows temperature and wind, queried at most
once per ~15 minutes or ~2 miles of movement, from the ride's own
GPS fixes. "Apple Weather" attribution is always displayed.

USER-GENERATED CONTENT

Riders may define their own event type labels in Settings. These
stay private to the rider's account — never shown to other users,
never on community maps. Only a fixed, app-defined list
(currently "Blocked Lane") can feed public maps, and a public map
cell needs reports from at least three riders before anything is
shown.

DIAGNOSTICS

Settings → Diagnostics has an off-by-default "Write Debug Log"
toggle. With it on the app stores a plain-text log of its own
events, plus the daily MetricKit payloads iOS gives every app
about itself (power, memory, network), beside the rider's ride
files so they can send them to us. No personal data beyond the
rider's own ride identifiers; nothing goes to a third party. Logs
are deleted after 14 days, metrics after 60.

DATA, SYNC, AND ACCOUNTS

Rides are stored on-device, and in the user's own iCloud Drive if
enabled. Sync to our companion web app (bumpyride.me) is opt-in:
the user signs in through a secure web window and a token is
returned — no password is ever entered in the app. Users can
unpair, clear server data, or delete their account from
Settings.

No account is required to review the app. Recording, the bump
map, event reporting, ride editing, Apple Health and the watch
app all work fully offline and signed-out; an account only adds
backup, scoring and community maps. Hence no test credentials.

CONTACT

Happy to clarify anything — we respond within hours at the
contact email on this record.
```

---

## Changes since 2.0 (engineering index)

Two series. **T1-T6** are the reported issues plus the field energy
telemetry that T6 added. **U1-U12** are what that telemetry then found,
including the verification rounds that showed two of the fixes did
nothing measurable. Series letters match commit prefixes.

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

- **U6 - "Supported CoreLocation API call rate exceeded" (count 24001),
  taking the app's OSLog subsystem down with it.** That count is the
  *threshold* CoreLocation warns at, not a fingerprint, which is why it
  matches the 2023 auto-resume incident in `LocationManager`'s header
  exactly — two unrelated causes, one limit.
  Audited every CoreLocation call site the app owns: all are one-shot or
  rate-limited (`attemptResume` is capped at 30 s), and the reads in
  `RideView` hit our cached `authorizationStatus`, not the CLLocationManager
  property. Nothing of ours loops.
  One genuine flaw found and fixed: `BumpMapLocationHint` created a
  CLLocationManager, read `authorizationStatus` and fired `requestLocation()`
  from its `init`, while being constructed in a `@State` initializer
  (`BumpMapTabView.locationHint`). Swift evaluates that expression on every
  view-struct construction and SwiftUI keeps only the first instance, so each
  throwaway still made ~3 CoreLocation calls that nothing would read. The
  auto-request moved to the view's `.task`, which runs against the retained
  instance.
  Whether that accounts for 24,000 calls is unproven — it depends on how
  often `ContentView`'s body evaluates, which is not obviously high. So this
  also adds `CLCallAudit`: a per-call-site tally written to the per-ride
  sidecar at start, every 30 s, and at stop. The sidecar is a file, so it
  survives the OSLog quarantine that makes this bug hard to diagnose.
  **The audit is the deliverable here**; next ride tells us whether the
  volume is ours at all. If the totals come back low, the calls are MapKit's
  own manager behind `showsUserLocation` / `userTrackingMode` — invisible to
  our audit but charged to the same app-wide budget — which would tie this to
  U3 and make the heading-gating fix the relevant lever.

- **U7 - the map's GPU cost: route overlays were rebuilt from scratch on
  every GPS fix.** This is what U2 was looking for and missed.
  `LiveRouteMapView.updateUIView` removed *every* route overlay, recomputed
  the colour runs across the *entire* points array, allocated fresh
  `MKPolyline`s and re-added them all — each time a fix landed. Per-fix work
  therefore grew with the route, making the total quadratic in ride length.
  Measured on a route matching the 12 Sep ride (6339 points, 3.17 h):
  ~26 million polyline vertices handed to MapKit over the ride.
  Fix, in two parts:
  1. `RouteColoring.runs` takes a `from:` index and reports absolute
     `startIndex` values, so a caller can recompute just the tail. Points
     only append while recording, so every run before the last is final.
  2. `RouteColoring.maxRunPoints` (256) caps run length regardless of
     colour, so a smooth road can't collapse into one route-length run and
     defeat (1). Adjacent runs share their boundary vertex exactly as
     colour-change runs do, so the route still draws continuously.
  `updateUIView` now swaps only the last overlay. Per-fix cost is constant
  rather than O(route):

  | Route length | Vertices before | after | reduction |
  |---|---|---|---|
  | 500 pts | 166,195 | 2,669 | 62x |
  | 1,500 pts | 1,472,221 | 8,194 | 180x |
  | 3,000 pts | 5,829,249 | 17,176 | 339x |
  | 6,339 pts | 25,969,284 | 35,096 | **740x** |

  The reduction grows with ride length because the growth is now linear
  rather than quadratic — long rides were hurt worst and gain most.
  Verified by porting both `RouteColoring.runs` and the incremental update
  to Python and asserting the incremental result equals a full rebuild
  across 400 randomised routes including dropouts and band changes
  (`scratchpad/verify_runs.py`). Still to confirm against real MetricKit
  numbers on the next payloads.

- **U8 - sync logging moved to the sidecar, and the location-hint churn
  fixed.** Two gaps the 13-14 Sep rides exposed.
  (a) Cellular upload went 873 MB -> 6 MB -> 22 MB -> **151 MB (13 Sep)**,
  on a day with one 1 MB ride and no rewritten ride files. Unexplainable,
  because every drain/ledger line went to OSLog — the subsystem CoreLocation
  quarantines, and one that never reaches the rider's debug bundle.
  `SyncCoordinator` now writes the same story to the ride sidecar via
  `DebugLog`: drain start (queue split, metered-path state, Wi-Fi setting),
  ledger prune counts, Wi-Fi holds, server batch-check results, per-ride
  upload size, and a drain-complete total. A handful of lines per drain.
  (b) `hint.requestLocation.authChange` reached 58 during the 17-minute
  13 Sep ride (~3/min). Two causes, both fixed: `BumpMapLocationHint` was
  constructed in `BumpMapTabView`'s `@State` initializer, which Swift
  evaluates on every rebuild of that view struct — it is now owned by
  `ContentView` and passed in; and CoreLocation's initial
  `didChangeAuthorization` callback (fired merely for assigning the
  delegate) was being treated as a grant and answered with a
  `requestLocation()`, on top of the one the view's `.task` already issues.
  Expected steady state is ~1 per launch, and only when the Bump Map tab is
  actually opened.

**Verification against post-fix telemetry (12 Sep)**

New build was running from the evening of 10 Sep, so 11 Sep is the first
full day on it. Payload naming: `metrics-<date>` covers the *previous* day.

| Measure | 9 Sep (pre) | 10 Sep (mixed) | 11 Sep (post) |
|---|---|---|---|
| Cellular upload | 873 MB | 544 MB | **6 MB** (+62 MB Wi-Fi) |
| GPU time | 7217 s | 7215 s | 7460 s |
| GPU / foreground | 1.97x | 1.77x | **2.54x** |
| Location, nav accuracy | 14 min | 38 min | 37 min |
| Peak memory | 467 MB | 552 MB | 544 MB |
| Background memory kills | 3 | 1 | **0** |

- **U1 confirmed fixed.** 873 MB -> 6 MB of cellular upload, with the
  traffic moved to Wi-Fi. The ledger plus the metered-path hold work.
- **U6 answered.** `CLCallAudit` reports 7-60 calls per ride (60 on a
  3.17 h / 43 km ride), so the 24,001 was never ours — it is MapKit's own
  manager. The hint fix was still correct but was not the cause.
  Side observation: `hint.requestLocation.authChange` reached 33 on that
  ride, i.e. `BumpMapTabView`'s struct is rebuilt ~33 times during a ride
  and each rebuild constructs a CLLocationManager. Harmless at that volume,
  but it confirms the `@State` initializer pattern is live.
- **U4 partially.** Peak memory did **not** drop (544 MB vs 467 MB), but
  background memory-pressure kills went 3 -> 1 -> 0. The pools appear to
  have changed the outcome without lowering the peak, so whatever holds
  ~500 MB is still unidentified.
- **U2 and U3 not confirmed.** GPU time is flat in absolute terms and
  *worse* per foreground second; navigation-accuracy location time is
  unchanged at ~37 min. Isolating the seismograph did cut `updateUIView`
  from ~17 Hz to the GPS rate, but that is evidently not what the GPU cost
  was made of. See U7.

- **U12 — the content-hash mystery: our wire encoding was
  non-deterministic.** `JSONEncoder` guarantees no key order and Swift
  seeds dictionary hashing per process, so re-encoding an unchanged ride
  produced a different byte sequence every time: identical length,
  100,045 of 106,983 byte positions reordered, measured on a real ride
  file across two decodes in one process. Every content hash we computed
  was effectively random, which is why `/check-batch` returned 100 %
  `needed` forever and why the library kept re-uploading.
  Fix: one canonical `RideStore.wireEncoder()` with `.sortedKeys`, shared
  by the upload body and the hash so they cannot drift. Verified stable
  across three separate processes.
  Consequence: every stored server hash and ledger entry is stale, so
  expect one more full re-upload — held for Wi-Fi — after which the
  endpoint prunes for the first time.
  Note both hypotheses in our report to the web side were wrong, and our
  own byte-stability test had been arranged in the one way that hides
  this (two encodes of a single decoded value inside one process).

**Third verification round (16 Sep)**

| Covers | GPU / foreground | nav-accuracy loc | cell upload | battery (unplugged, 12.5 km) |
|---|---|---|---|---|
| 9 Sep (pre) | 1.97x | 14 of 61 min | 873 MB | 21.3 %/h (8 Sep) |
| 14 Sep (post-U7) | 2.34x | 78 of 78 min | 7 MB | 0.0 %/h* |
| 15 Sep (post-U8) | 2.05x | 82 of 85 min | **519 MB** | 10.1 / 10.3 %/h |
| 16 Sep | — | — | — | 11.1 %/h |

\* quantisation luck; steady state is ~10-11 %/h.

- **Battery confirmed.** Four unplugged rides on the same route now read
  10.1, 10.3, 11.1 %/h with `thermal=nominal` throughout, against a
  21.3 %/h pre-fix baseline that reached `fair`. Halved, and stable.
- **U7 did not work.** GPU per foreground minute is unchanged
  (pre 1.76-2.54x, post 2.05-2.34x). The quadratic rebuild was real and the
  180x vertex reduction is real, but vertex upload is not what the GPU time
  is made of — MapKit's own continuous rendering in follow mode is, and
  nothing here touches it. The 12 Sep spike (3.28x) was a 131-minute
  foreground day, not the quadratic biting. The change is still a correct
  optimisation and stays, but it is not an energy fix.
- **Navigation-accuracy location is now ~100 % of foreground** (78/78,
  82/85), up from partial. This is MapKit's manager and is the main
  remaining energy lever.
- **U9 confirmed** — `suspendedMem 159MB` now appears in the digest.

- **U10 — U1 was not working, and U8's logging found why.** Every drain
  reported `ledger: 0/237 already current` and `server batch check: 0/237
  already on server`, then uploaded **453 MB in a single pass**.
  Root cause: `SyncCoordinator` calls `webAccount.invalidate()` on any 401,
  which flips `isConnected` false, which ran `syncLedger.clear()`. One
  expired token therefore discarded the entire ledger and the next drain
  re-uploaded the library. Ruled out first, by direct test: the `[UUID:
  String]` persistence round-trips correctly and `encode(decode(file))` is
  byte-stable across independent loads, so neither storage nor hash
  stability was at fault.
  Fix: the ledger is now **scoped to an account**. It records the owning
  email (the same identity `TokenStorage` keys on) and clears only on a
  genuine account switch, so a transient auth failure costs nothing.
  Disconnect no longer clears it. The old bare-dictionary file is still
  read, and its entries are adopted by the current account rather than
  discarded.
  Also fixed: **the Wi-Fi hold was decided once at drain start.** The
  15 Sep drain began on Wi-Fi at 12:36, the ride started at 12:38, and it
  followed the rider onto cellular for the next half hour. It is now
  re-checked before every ride. The per-request
  `allowsExpensiveNetworkAccess` flags are a hint only — on a *background*
  URLSession the session-level policy governs — so the drain-loop check is
  the real control; the comment now says so.
  Diagnostics kept: drain start logs `ledgerEntries`, and a ledger miss
  logs computed-vs-stored hash for the first few rides, which separates
  "never recorded" from "hash unstable" without guesswork.

  The server batch check returning 0/237 is a **separate, still-open**
  issue: the server's stored hash apparently never matches ours, so that
  guard has never pruned anything. The ledger is what makes steady state
  cheap regardless; worth raising with the web side.

**Second verification round (14 Sep) — the unplugged measurement**

Two unplugged rides finally landed. 14 Sep is a clean match for the 8 Sep
pre-fix baseline: both unplugged, both 12.5 km.

| | 8 Sep (pre) | 14 Sep (current) |
|---|---|---|
| Drain | 21.3 %/h | **10.6 %/h** |
| Active-recording portion | 35.2 %/h | 10.6 %/h (no mid-ride pause) |
| Thermal | reached `fair` | `nominal` throughout |

Battery reports in 5 % steps, so a 5 % drop puts the true rate somewhere
between ~5 and ~16 %/h; even the pessimistic end beats the baseline. The
13 Sep ride is not usable for this — 2 km with 11 of its 17 minutes paused,
so the quantum dominates.

**U7's diagnosis confirmed, the fix not yet.** The 3.17 h ride on 12 Sep —
the last before U7 — recorded **25,685 s of GPU**, 3.4x the worst previous
day, at 3.27x foreground. The longest ride produced by far the worst GPU,
which is what quadratic route rebuilding predicts and a constant per-fix
cost would not. The only post-U7 payload covers 13 Sep, whose ride was
2 km — too short to exercise the quadratic path. The 14 Sep payload is the
real test.

**CoreLocation settled.** 9-15 calls across the 14 Sep ride; the audit's own
"volume is low" line fired. The 24,001 was never ours.

**Memory: reassessed, and U4 was aimed at the wrong number.**

| Covers | Foreground | Peak | Suspended | bg kills | fg exits |
|---|---|---|---|---|---|
| 9 Sep | 3659 s | 468 MB | 163 MB | 3 | 0 |
| 10 Sep | 4097 s | 552 MB | 199 MB | 1 | 0 |
| 11 Sep | 2935 s | 544 MB | 155 MB | 0 | 0 |
| 12 Sep | 7840 s | 558 MB | 186 MB | 1 | 0 |
| 13 Sep | 574 s | 344 MB | 138 MB | 2 | 0 |

The peak is a *foreground* high-water mark and is not a problem: zero
foreground exits across every payload, and it tracks foreground time almost
exactly (344 MB on a 574 s day vs 558 MB on a 7840 s one), which is MapKit's
tile cache growing with how much map was panned rather than our data.

Background jetsam — the 7 memory-pressure exits — is governed by the
*suspended* footprint (138-199 MB), which was never being reported. The
consequences are also largely absorbed by design: background uploads survive
process death on a background `URLSession`, T3a clears the orphaned SLC
registration at launch, an active recording holds a location assertion and
has journal recovery, and cold start is ~350 ms. Counts are noisy with no
trend (3, 1, 0, 1, 2) and partly reflect system-wide pressure.

**U4 shows no measurable effect** — it targeted the peak, and the peak did
not move. The pools remain correct for those library-wide loops but should
not be counted as a fix.

- **U9** adds `suspendedMem` to the metrics digest so drift in the figure
  that actually governs background survival would be visible. No further
  memory work is warranted on current evidence.

**Thermal and battery**

Thermal genuinely improved, comparing like for like on charging state: a
27 min ride on 9 Sep reached `thermal=serious` while charging; the 3.17 h /
43 km ride on 12 Sep stayed `nominal` throughout, also charging.

Battery is **not yet measured**. Every post-fix ride so far was on a
charger, and the only unplugged ride in the dataset is 8 Sep (pre-fix, at
21.3 %/h). A 3.17 h ride holding at 100 % while plugged in is suggestive —
the pre-fix build lost 15 % in 27 min while charging — but it is not a
like-for-like result. **One unplugged post-fix ride would settle it.**

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
