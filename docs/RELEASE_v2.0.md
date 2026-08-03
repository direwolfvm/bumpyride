# Release v2.0

Build **30**. MARKETING_VERSION `2.0`.

**This release goes 1.6 → 2.0 — version 1.7 was never shipped.** The
1.7 work (heart rate, WeatherKit, event categorization, the sharper
brake detector) was cut and documented but never submitted, so
everything in `RELEASE_v1.7.md` is folded in here. For the App Store,
2.0 is a single release covering everything since 1.6.

Why 2.0 rather than 1.8: the app grew a second data class this cycle.
It no longer just measures pavement — riders report what they
encounter (close calls with a type, hard brakes with a reason, blocked
lanes and custom event kinds), those reports feed community maps and
achievements, and rides became editable and multi-client. That's a
different product than 1.6.

> **Note on the doc**: the three sections below are what gets pasted
> into App Store Connect — release notes, product description, and
> App Review notes. Description and review notes are *cumulative*
> (complete text as of 2.0, not deltas). **The review notes are
> written to fit App Store Connect's 4,000-character limit** — keep
> any edits inside that budget.

---

## 1. What's New

```
BumpyRide 2.0 is a big one — a year of riding folded into one
release.

REPORT WHAT YOU ENCOUNTER
• Log Event joins Log Close Call on the ride screen. Report a
  blocked lane, or define your own event types in Settings —
  your custom types stay private to your account.
• Close calls can be tagged Vehicle, Bike, or Pedestrian; hard
  brakes as Safety, Other, or False trigger. Edit any of them
  later from the saved ride.
• Reporting mode: press and hold the stats bar mid-ride to
  collapse the map and blow the report buttons up to full size
  for no-look tapping.

HEART RATE AND WEATHER
• Heart rate from your Apple Watch, added to the ride's Apple
  Health workout — turn on "Open watch app with this app."
• Live weather on the recording map: temperature, wind speed,
  and whether you're fighting a headwind, riding a tailwind, or
  taking it across.

ACHIEVEMENTS
• Earn bonus points for standout rides and lifetime milestones —
  distance, exploration, smooth roads, safety reporting. New
  Achievements screen, and a banner when you earn one.
• Your score now lives behind the trophy on the Saved tab, with
  lifetime distance and ride time.

SEE MORE ON THE MAP
• A purple overlay of every cell you've ridden, with an opacity
  slider.
• Heading-up or north-up, recenter buttons, and route coloring
  that no longer hides isolated rough spots.
• Set your preferred map defaults in Settings.

EDIT AND SHARE RIDES
• A proper full-screen ride editor: trim a ride down or split
  one ride into two, with a live map preview.
• Share your ride summary photo to Messages, Mail, or social —
  saving to Photos is still one tap.

FASTER AND SMOOTHER
• Much faster launch, and rides no longer bog the app down as
  your library grows.
• Sync keeps running after you lock the screen or leave the app.
• Choose when the screen stays awake, and a higher-contrast
  interface for riding in direct sun.

Plus a long list of fixes: hard-brake detection through tunnels,
fewer false brake reports from potholes and GPS glitches, the
Apple Health heart-rate bug, and the categorization popup that
could get stuck.
```

---

## 2. Updated Description

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

## 3. App Review Information — Review Notes

> **Budget: 4,000 characters** (App Store Connect's hard limit).
> The block below measures **3,756** — 244 to spare. Re-measure if
> you edit it:
> `python3 -c "import re,sys;print(len(re.findall(r'\`\`\`\n(.*?)\n\`\`\`',open('docs/RELEASE_v2.0.md').read().split('## 3.')[1],re.S)[0]))"`
>
> Written around what review actually adjudicates — permission
> justifications, the HealthKit no-duplicate-workout story, and the
> custom-content privacy rule. The deep architecture notes from the
> unshipped 1.7 draft (WatchConnectivity message types, detector
> internals) were cut to fit; they're in `RELEASE_v1.7.md` if a
> reviewer ever asks for more depth.

```
ABOUT

BumpyRide records cycling rides with the iPhone's accelerometer
and GPS, then shows the rider where the road was rough or smooth
and builds a heat map across rides. Riders can also report close
calls and road events. An Apple Watch companion adds wrist
controls and heart rate.

BACKGROUND LOCATION — please read

Rides last 30+ minutes with the screen off or the phone in a
pocket, so location must continue in the background. We request
"When In Use" at first launch and incrementally request "Always"
the first time the user starts a recording.

"Always" is needed for one specific reason: the Significant
Location Change service only delivers to backgrounded apps that
hold Always, and we use SLC purely as a recovery path if iOS
suspends our continuous location updates mid-ride. Without it,
long rides develop unusable GPS gaps. We do not track users when
they aren't recording.

Recording is always explicitly started and stopped by the user
(Start/Stop on the Ride tab, or the equivalent on the watch), and
the system background-location indicator is visible throughout.

MOTION

CMDeviceMotion at 50 Hz during recording only; we use the
vertical acceleration component to compute bumpiness. Started and
stopped with the recording. No background-only motion access.

HEALTHKIT (optional, opt-in)

Enabled from Settings → Apple Health, which presents the standard
authorization sheet. Nothing is written unless the user opts in.

Write: HKWorkout (cycling/outdoor), workout route, cycling
distance, active energy.
Read: body mass (to estimate calories) and heart rate (to attach
the trace to the ride's workout).

Heart rate detail: with the optional "Open watch app with this
app" setting on, the iPhone calls startWatchApp(toHandle:) with a
cycling configuration. The watch app runs an HKWorkoutSession so
watchOS samples heart rate at workout rate, then DISCARDS its own
workout — only the iPhone writes an HKWorkout, so the user sees
one workout per ride, not two. The iPhone associates the existing
heart-rate samples with that workout; it does not duplicate them.
Each workout is tagged with the ride's UUID for idempotency, so
re-export never creates duplicates.

WEATHERKIT

The recording map shows temperature and wind. Queried at most
once per ~15 minutes or ~2 miles of movement. Uses only the
ride's own GPS fixes. "Apple Weather" attribution is always
displayed, per WeatherKit's terms.

USER-GENERATED CONTENT

Riders may define their own event type labels (e.g. "Broken
glass") in Settings. These are private to the rider's account:
they are never shown to other users and never appear on community
maps. Only a fixed, app-defined list (currently "Blocked Lane")
can contribute to public maps, and public map cells require
reports from at least three different riders before anything is
shown.

DIAGNOSTICS

Settings → Diagnostics has an off-by-default "Write Debug Log"
toggle that writes a plain-text log of the app's own events
alongside the rider's ride files, for troubleshooting field
issues. No personal data beyond the rider's own ride identifiers;
files older than 14 days are deleted automatically.

DATA, SYNC, AND ACCOUNTS

Rides are stored on-device, and in the user's own iCloud Drive if
they have it enabled. Sync to our companion web app
(bumpyride.me) is opt-in: the user signs in through a secure web
window and a token is returned to the app — no password is ever
entered in the app. Users can unpair, clear all server data, or
delete their account from Settings.

TEST ACCOUNT

A demo bumpyride.me account for testing sync, restore, scoring,
and achievements is provided in the App Review credentials
fields.

CONTACT

Happy to clarify anything — we respond within hours at the
contact email on this record.
```

---

## Changes since 1.6 (engineering index)

Grouped by area, for anyone tracing a behavior back to its change.
Series letters match commit prefixes.

**Recording & detection**
- Hard-brake detector rev 6→8: `max(forward, backward)` finite
  difference, GPS-gap attribution for tunnels/underpasses,
  accelerometer-spike magnitude cap, GPS-glitch rejection (J5, J6, K23)
- Brake + close-call categorization, live and post-hoc (J1–J4)
- "Other" event reporting: Blocked Lane + private custom kinds (M1–M4)
- Reporting mode for no-look logging (N6)

**Watch & Health**
- Watch HKWorkoutSession handoff for heart rate (Phases D–F)
- Watch launch/lifecycle fixes: WKBackgroundModes, session survival,
  launch gating (K6–K8, K10, K11, K13)
- Apple Health HR enrichment fix — `store.add(_:to:)` instead of
  `addSamples` (K4)

**Maps & UI**
- WeatherKit chip with wind relation (I1–I4, K17, K25)
- Visited-cells overlay, heading-up, recenter, banded max-per-segment
  coloring (K16, K18, K19, K21)
- Sunlight contrast pass (L6); map defaults + opacity (L7)
- Scrollable ride viewer (L4); two-handle chart window (S1, S2)
- Ride photo → share sheet (M5)
- Launch screen refresh (K26)

**Score & achievements**
- Level-up celebration, breakdown disclosure (H3, H4)
- Score moved to Saved tab, lifetime stats, stale-refresh tier
  (K12, K20, K5, L8)
- Achievements: data layer, screen, combined points, toast (N1–N4)

**Sync & storage**
- Batch status check (L1); background URLSession uploads (L2)
- Checksum backfill skip (H5); user-initiated priority (H1)
- Ride editor + `editedAt` conflict rule + pull-on-conflict (Q1–Q3, R1)

**Performance**
- Async off-main ride loading — fixed a 10–15 s startup freeze (O1)
- Sync encode/hash off-main (O2)
- Metadata-eager / points-lazy store — ~1 GB resident → a few MB,
  with a summary cache for near-instant relaunch (P1)

**Diagnostics**
- Debug-log sidecar + instrumentation across HealthKit, watch launch,
  weather, recording, brake sheet (K2, K3, K9, S3)
