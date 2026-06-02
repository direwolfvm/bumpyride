# Release v1.4

Build **24**. Tagged at `fa19c0f`.

The "gamification" release. Headline additions: earn points for every ride, with scoring done server-side by the bumpyride.me companion web app, plus several quality-of-life improvements to the live recording display.

> **Note on the doc itself**: the three sections below mirror what gets pasted into App Store Connect at submission time — release notes ("What's New"), the full product description, and the App Review Information notes. The description and review notes are *cumulative* — they reflect the complete text as of v1.4, not just deltas from v1.3.

---

## 1. What's New

```
• Earn points for every ride — the bumpyride.me companion web app
  scores each synced ride based on distance, smoothness, and
  consistency. See your total score grow in the web app.
• Live recording display now shows elapsed time, current GPS
  speed, and average ride speed alongside the route map.
• Close-call button is now purple to match the close-call marker
  style across the app.
• Smoother live display on long rides — capped trailing polyline
  and O(1) running stats keep the UI responsive even after hours
  of recording.
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
• Personal heat map of every road you've ridden
• Adjustable color thresholds — tune what "rough" means to you
• Pocket mode — automatic filter for pedaling cadence so the
  rhythm of your cranks doesn't register as bumpiness
• Close-call reporting — tap a button to flag a near-miss
• Hard-brake detection — see where you slowed sharply
• Ride scoring — earn points for distance, smoothness, and
  consistency through the bumpyride.me companion web app
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

RIDE SCORING (NEW IN v1.4)

Once a ride is synced to bumpyride.me, the server scores it based
on distance, smoothness, and consistency, and returns a per-ride
point total. The iOS app displays this score in the Saved tab and
in the playback view for each synced ride. Scoring is server-side
and is informational only — it does not affect ride storage or any
on-device behavior.

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
scoring flows. Credentials provided separately in the App Review
notes field.

CONTACT

If anything's unclear, please reach out at the contact email on
the App Store Connect record and we'll respond within hours.
```
