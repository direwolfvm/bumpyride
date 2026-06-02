# Release v1.3

Build **22**. Tagged in source control as the v1.3 ship.

This is the third major iOS release of BumpyRide. Headline additions: close-call reporting, post-hoc hard-brake detection, and a major reliability fix for background GPS during long rides.

> **Note on the doc itself**: the three sections below mirror what gets pasted into App Store Connect at submission time — release notes ("What's New"), the full product description, and the App Review Information notes. The description and review notes are *cumulative* — they reflect the complete text as of v1.3, not just deltas from v1.2.

---

## 1. What's New

```
• Log close calls with a single tap during a ride — mark spots
  where you had a near-miss to help build a community safety map.
• Hard-brake detection — after each ride, the app surfaces moments
  of sharp deceleration so you can spot trouble corners and bad
  intersections.
• Background recording reliability — long rides no longer drop GPS
  mid-route. The app now uses an incremental Always-location
  upgrade and Significant Location Change as a recovery wake path.
• Smoother live display and lower battery use on multi-hour rides.
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
• Personal heat map of every road you've ridden
• Adjustable color thresholds — tune what "rough" means to you
• Pocket mode — automatic filter for pedaling cadence so the
  rhythm of your cranks doesn't register as bumpiness
• Close-call reporting — tap a button to flag a near-miss
• Hard-brake detection — see where you slowed sharply
• iCloud Drive backup of every ride
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

CLOSE CALLS

Close calls are user-initiated. During a recording the user can
tap a "Log close call" button to flag their current GPS location.
The flag is stored alongside the ride data as a timestamp + lat/lon
tuple — no notes, no media, no severity, just the marker.

HARD BRAKE DETECTION

Hard brakes are detected automatically after each ride via analysis
of the GPS speed derivative. A sustained deceleration above ~1.5
m/s² (~0.15 g) for >0.4 s emits a "brake event" tagged with the
peak deceleration location. Brake events are descriptive metadata
only; they never trigger automated behavior.

TEST ACCOUNT

A demo bumpyride.me account is available for testing the sync /
restore flows. Credentials provided separately in the App Review
notes field.

CONTACT

If anything's unclear, please reach out at the contact email on
the App Store Connect record and we'll respond within hours.
```
