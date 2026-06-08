# Release v1.7

Build **27**. MARKETING_VERSION bumped at `8e8b99b`.

Headline addition: **heart rate monitoring during rides** via a new "Open watch app with this app" toggle that auto-launches the BumpyRide watch app from the iPhone, runs a `HKWorkoutSession` on the watch to engage the watch's heart-rate sensor at workout sampling rate, and embeds those heart-rate samples into the saved ride's Apple Health workout.

Also includes a sharper hard-brake detector (rev 6 catches brakes-into-stops that earlier revisions missed when GPS sampling went irregular at the moment of stopping), and a polish pass on the watch UI (solid orange Pause button for direct-sunlight readability, smaller Close Call label).

> **Note on the doc itself**: the three sections below mirror what gets pasted into App Store Connect at submission time — release notes ("What's New"), the full product description, and the App Review Information notes. The description and review notes are *cumulative* — they reflect the complete text as of v1.7, not just deltas from v1.6.

---

## 1. What's New

```
• Heart rate on every ride — new "Open watch app with this app"
  toggle in Settings → Apple Watch.  When on, opening BumpyRide
  on your iPhone also opens the watch app and starts heart-rate
  monitoring through the watch's sensor.  Heart rate is added to
  your ride's Apple Health workout, so you'll see the trace in
  the Fitness app alongside the route and distance.
• Improved hard-brake detection — sharper brakes into stops are
  now reliably caught.  Previous versions could miss them when
  GPS sampling went irregular at the moment of stopping; the new
  detector handles that asymmetry correctly.  All existing rides
  are re-analyzed on first launch to surface any previously-
  missed events.
• Watch polish: solid orange Pause button (was washing out in
  direct sunlight), and the on-watch app name now reads
  "BumpyRide" to match the iPhone app.
```

---

## 2. Updated Description

```
BumpyRide is for cyclists who want to know which streets are
smooth and which aren't.

During every ride, BumpyRide records vibration through your phone's
motion sensors and pairs each reading with your GPS location. After
the ride, see a colored route map showing exactly where the road
was smooth (green) and where it was rough (yellow → red → purple).

Ride enough and your personal Bump Map fills in — a permanent heat
map of every street you've ever ridden, color-coded by average
roughness. Pick smoother routes for your commute. Avoid the worst
potholes on your favorite loop.

Features:
• Live recording with route + bumpiness overlay
• Elapsed time, current speed, and average speed displayed during
  recording
• Live hard-brake and close-call markers on the recording map
• Apple Watch app — start/pause/resume/stop your ride from the
  wrist; log close calls with one tap; see live time, distance,
  and bumpiness on three swipeable pages
• Heart rate monitoring through the Apple Watch — opens the watch
  app automatically when you open BumpyRide, runs a HealthKit
  workout session in the background, and adds the heart rate trace
  to your saved ride's Apple Health workout
• Personal heat map of every road you've ridden
• Adjustable color thresholds — tune what "rough" means to you
• Pocket mode — automatic filter for pedaling cadence so the
  rhythm of your cranks doesn't register as bumpiness
• Close-call reporting — tap a button to flag a near-miss
• Hard-brake detection — see where you slowed sharply
• Ride scoring — earn points for distance, smoothness, and
  consistency through the bumpyride.me companion web app
• Apple Health integration — rides appear in the Fitness app and
  credit your activity rings; sync new rides automatically or
  backfill your full history in one tap
• iCloud Drive backup of every ride
• Server-side restore — re-download every ride from bumpyride.me
  after reinstalling or switching phones
• Optional sync with bumpyride.me — a free companion web app for
  longer-term storage, scoring, and community heat maps

Privacy: rides are stored on your phone (and optionally in your
iCloud Drive). Sync to bumpyride.me is opt-in and uses a pairing
code — no email, no password.
```

---

## 3. App Review Information — Review Notes

```
ABOUT THE APP

BumpyRide records cycling rides using the iPhone's accelerometer
and GPS. After each ride, it shows the rider where the road was
rough and where it was smooth, and accumulates a personal heat map
across all rides.  An Apple Watch companion app lets the user
control the ride from the wrist and adds heart rate monitoring to
the saved Apple Health workout via the standard HKWorkoutSession
handoff.

BACKGROUND LOCATION

Rides typically last 30+ minutes with the screen off or the phone
in a pocket. The app requests "When In Use" location at first
launch and incrementally upgrades to "Always" the first time the
user starts a recording. The upgrade is required for one reason:
the Significant Location Change service only delivers events to
backgrounded apps that hold Always — and we use SLC as a recovery
wake path if iOS suspends our continuous location updates during a
long ride. Without it, mid-ride GPS gaps render rides unusable.

The "background location" indicator (green/blue pill) is shown to
the user during active recording. The user controls when recording
starts and stops via explicit Start/Stop buttons on the Ride tab
of the iPhone app, or via the equivalent controls on the Apple
Watch companion.

MOTION

Motion access is used to read CMDeviceMotion at 50 Hz during a
recording. The vertical-acceleration component is the data we
care about. Motion is only requested when recording starts, and
stops when recording stops. No background-only motion access.

APPLE WATCH COMPANION

The bundled Apple Watch app is a thin remote control + display
layer over the iPhone's RideRecorder.  All sensors, GPS, storage,
and ride processing remain on the iPhone; the watch sends commands
(start / pause / resume / stop & save / close-call) and receives
state snapshots (~1 Hz).

Communication uses WatchConnectivity:
  - sendMessage for real-time commands when both apps are reachable.
  - transferUserInfo as a queued fallback for offline-replay of
    close-call / pause / resume / stop events (so the close-call
    safety affordance never silently fails).
  - The Start command is NOT queued — only sent when iOS is
    reachable in real time — to avoid a recording firing hours
    after the tap.
  - updateApplicationContext for the iOS → Watch state stream.

WATCH HEALTHKIT HANDOFF (NEW IN v1.7)

A new Settings → Apple Watch → "Open watch app with this app"
toggle (default OFF, opt-in) makes the iPhone app call
HKHealthStore.startWatchApp(toHandle: HKWorkoutConfiguration)
each time it enters the foreground, on the cold-start path and on
.onChange(of: scenePhase) → .active.  iOS hands the watch a
cycling/outdoor workout configuration; watchOS launches the
companion watch app and delivers the configuration via
WKApplicationDelegate.handle(_ workoutConfiguration:).

The watch app then creates an HKWorkoutSession + HKLiveWorkoutBuilder
using that configuration.  Purpose: HealthKit-related rather than
WatchConnectivity-related.  watchOS engages the watch's heart-rate
sensor at the high sampling rate it reserves for active workout
sessions; samples land in HealthKit's heartRate quantity type
owned by watchOS independently.

The watch's session is intentionally DISCARDED at ride end (not
finishWorkout, just discardWorkout) — no HKWorkout is saved from
watchOS.  The single canonical workout for the ride is still the
cycling HKWorkout written by the iPhone via the v1.5 HealthKit
exporter.  After saving, the iPhone-side exporter queries
HealthKit for heart-rate samples in [ride.startedAt, ride.endedAt]
and adds them to that workout via HKWorkoutBuilder.addSamples,
associating the existing watchOS-owned samples with the workout
without duplicating them.  Net result: one cycling workout in the
Fitness app per ride, with full route + distance + energy + heart
rate trace.

Watch target additions for the handoff:
  - com.apple.developer.healthkit entitlement
    (BumpyRideWatchApp.entitlements).
  - WKBackgroundModes = workout-processing so the workout session
    stays alive across screen-off / wrist-down.
  - NSHealthShareUsageDescription on the watch target:
    "BumpyRide reads your heart rate during a ride so it can be
    added to your Apple Health workout."

iOS side adds heartRate to HealthKitAuthManager.readTypes; the
Settings v1.7 toggle re-triggers requestAuthorization on enable
so the user is prompted for HR access at the moment of opt-in.
If the user dismisses without granting, the watch session still
runs — there's just no HR data to query at save time.  The watch
session ends when the iPhone's snapshot.state transitions to
.idle or .finished (i.e. ride stops), via SwiftUI .onChange on
the watch side.

APPLE HEALTH

HealthKit integration is opt-in. Settings → Apple Health → "Add
new rides to Apple Health" presents the standard HealthKit
authorization sheet on first enable. No prompt otherwise.

Write types: HKWorkout (activity type: cycling, location type:
outdoor), HKWorkoutRoute, distanceCycling, activeEnergyBurned.

Read types: bodyMass (active-energy MET estimation, fall-back
default 75 kg) and heartRate (workout enrichment via the
watch session handoff above; defaults to "no HR samples
embedded" if read auth is denied).

Idempotency: each HKWorkout written is tagged with the
HKMetadataKeyExternalUUID key set to the Ride's UUID. Re-export
attempts skip via this key — no duplicate workouts.

A "Sync past rides to Apple Health" button in Settings runs a
one-shot backfill of all locally-stored rides that haven't been
exported.

NSHealthUpdateUsageDescription and NSHealthShareUsageDescription
are set on the iOS Info.plist with concrete, single-purpose copy:
"saves your cycling rides to Apple Health so they appear in the
Fitness app and count toward your activity rings" and "reads your
weight and heart rate from Apple Health to estimate calories
burned for each ride and embed your heart rate trace in the saved
workout."

DATA STORAGE AND SYNC

Rides are stored on-device by default. iCloud Drive backup uses
the standard NSUbiquitousContainer setup; rides appear in Files
under "BumpyRide" if the user has iCloud Drive enabled.

Sync to the bumpyride.me web app is opt-in via Settings → Web
Account. Pairing uses a six-character code shown by the web app
that the user enters into the iOS app — no email or password is
ever entered on the device. The pairing code exchanges for a
long-lived bearer token stored in the iOS Keychain. The user can
unpair or clear all server-side data from Settings at any time.

SERVER-SIDE RESTORE

A "Restore my rides" button in Settings → Web Account lets a paired
user re-download all of their rides from bumpyride.me. Typical use
case: after reinstalling the app or moving to a new phone. The
restore flow is server-wins on conflicts (downloaded rides
overwrite local copies with the same ID). The user sees a
confirmation preview ("X rides available, ~Y MB to download") and
can cancel mid-restore.

RIDE SCORING

Once a ride is synced to bumpyride.me, the server scores it based
on distance, smoothness, and consistency, and returns a per-ride
point total. The iOS app displays this score in the Saved tab and
the playback view. Scoring is server-side and is informational
only — it does not affect ride storage or any on-device behavior.

CLOSE CALLS

Close calls are user-initiated. During a recording the user can
tap a "Log close call" button — on the iPhone or on the Apple Watch
app — to flag their current GPS location.  The flag is stored
alongside the ride data as a timestamp + lat/lon tuple — no notes,
no media, no severity, just the marker.  Close-call markers appear
on the live recording map as they are logged.

HARD BRAKE DETECTION

Hard brakes are detected automatically via analysis of the GPS
speed derivative. A sustained deceleration above ~1.3 m/s² (~0.13
g) for >0.4 s emits a "brake event" tagged with the peak
deceleration location. Brake events are descriptive metadata only;
they never trigger automated behavior. The same detector runs at
1 Hz during recording so brake pins appear on the live map ~1.5 s
after the brake (the finite-difference detector needs trailing
context to resolve).  v1.7 sharpens the algorithm to catch sharper
brakes-into-stops that earlier revisions missed when GPS sampling
became irregular at the moment of stopping; the launch-time
reprocessor re-analyzes existing rides on first run after upgrade.

TEST ACCOUNT

A demo bumpyride.me account is available for testing the sync,
restore, and scoring flows. Credentials provided separately in the
App Review notes field.

CONTACT

If anything's unclear, please reach out at the contact email on
the App Store Connect record and we'll respond within hours.
```
