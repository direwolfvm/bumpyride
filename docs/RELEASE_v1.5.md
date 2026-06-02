# Release v1.5

Build **25**. MARKETING_VERSION bumped at `debf9d3`.

Headline additions: Apple Health integration (rides become cycling workouts that credit activity rings), one-tap restore of your full ride history from bumpyride.me, per-ride score visibility in playback, and live brake + close-call markers on the recording map.

> **Note on the doc itself**: the three sections below mirror what gets pasted into App Store Connect at submission time — release notes ("What's New"), the full product description, and the App Review Information notes. The description and review notes are *cumulative* — they reflect the complete text as of v1.5, not just deltas from v1.4.

---

## 1. What's New

```
• Apple Health integration — your rides now appear in the Fitness
  app as cycling workouts and count toward your activity rings.
  Auto-export new rides, manually add older ones, or use the new
  Settings backfill button to sync your full ride history in one
  tap.
• Server-side restore — re-download every ride from bumpyride.me
  after reinstalling the app or moving to a new phone. Find it
  under Settings → Web Account → "Restore my rides."
• Per-ride scores now appear in the ride playback view alongside
  the route and stats.
• Hard-brake pins and close-call diamonds now appear on the live
  recording map as they happen during a ride — you no longer have
  to wait until after the ride to see them.
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
across all rides.

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
starts and stops via explicit Start/Stop buttons on the Ride tab.

MOTION

Motion access is used to read CMDeviceMotion at 50 Hz during a
recording. The vertical-acceleration component is the data we
care about. Motion is only requested when recording starts, and
stops when recording stops. No background-only motion access.

APPLE HEALTH (NEW IN v1.5)

HealthKit integration is opt-in. Settings → Apple Health → "Add
new rides to Apple Health" presents the standard HealthKit
authorization sheet on first enable. No prompt otherwise.

Write types: HKWorkout (activity type: cycling, location type:
outdoor), HKWorkoutRoute, distanceCycling, activeEnergyBurned.

Read types: bodyMass — used to estimate active energy via the
standard Compendium of Physical Activities MET tables for cycling
at the ride's average speed. If body mass read is denied or no
sample exists, the estimate falls back to a default body mass
(~75 kg). Active energy is explicitly framed in the app footer
as an estimate, not a measurement.

Idempotency: each HKWorkout written is tagged with the
HKMetadataKeyExternalUUID key set to the Ride's UUID. Re-export
attempts skip via this key — no duplicate workouts.

A "Sync past rides to Apple Health" button in Settings runs a
one-shot backfill of all locally-stored rides that haven't been
exported. The user can cancel mid-backfill; already-exported rides
are kept.

NSHealthUpdateUsageDescription and NSHealthShareUsageDescription
are set in Info.plist with concrete, single-purpose copy: "saves
your cycling rides to Apple Health so they appear in the Fitness
app and count toward your activity rings" and "reads your weight
from Apple Health to estimate calories burned for each ride."

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

SERVER-SIDE RESTORE (NEW IN v1.5)

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
tap a "Log close call" button to flag their current GPS location.
The flag is stored alongside the ride data as a timestamp + lat/lon
tuple — no notes, no media, no severity, just the marker. As of
v1.5, close-call markers appear on the live recording map as they
are logged.

HARD BRAKE DETECTION

Hard brakes are detected automatically via analysis of the GPS
speed derivative. A sustained deceleration above ~1.5 m/s² (~0.15
g) for >0.4 s emits a "brake event" tagged with the peak
deceleration location. Brake events are descriptive metadata only;
they never trigger automated behavior. As of v1.5, the same
detector runs at 1 Hz during recording so brake pins appear on the
live map ~1.5 s after the brake (the centered-finite-difference
detector needs trailing context to resolve).

TEST ACCOUNT

A demo bumpyride.me account is available for testing the sync,
restore, and scoring flows. Credentials provided separately in the
App Review notes field.

CONTACT

If anything's unclear, please reach out at the contact email on
the App Store Connect record and we'll respond within hours.
```
