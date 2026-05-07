# BumpyRide

A SwiftUI iOS app that uses an iPhone's GPS and accelerometer to map road bumpiness along cycling routes.

While you ride, BumpyRide records your route and continuously measures vertical acceleration to assess pavement quality. Over many rides, the **Bump Map** tab aggregates everything into a heat-map at 20 ft resolution — useful for picking smoother routes or flagging streets to a city for repair.

## Features

- **Live recording** — GPS path + 50 Hz accelerometer, sampled every 10 ft of travel. Vertical-only filtering via gravity projection so the rider's pedal stroke and braking don't read as bumpiness.
- **Seismograph display** — real-time vertical-acceleration waveform with a current bumpiness readout (RMS over 1 s).
- **Color-coded route** — polyline shaded green → yellow → orange → red → purple by bumpiness, with user-tunable thresholds.
- **Saved rides** — editable titles, scrubbable playback with seismograph chart and zoom, trim and split, export-to-Photos.
- **Bump Map** — aggregates all rides into a sparse 20 ft grid, rendered as colored cells with a two-layer purple glow halo so sparse data stays visible at any zoom level.
- **Pocket Mode** — optional 3 Hz Butterworth high-pass that suppresses cadence-frequency body bob when the phone is on the rider's body. Each ride is tagged with its mode for future bump-map filtering.
- **Background recording** — continues recording when the screen is locked or the app is backgrounded, with the iOS background-location indicator visible the whole time.

## Build & Run

**Requirements**

- Xcode 26 or later
- iOS 26.2 deployment target
- An Apple Developer account (or change `DEVELOPMENT_TEAM` in the project settings)
- A real iPhone for actual riding — the simulator can fake GPS, but accelerometer data is meaningless there

**Steps**

1. Clone this repo
2. Open `BumpyRide.xcodeproj`
3. Select the `BumpyRide` scheme and your device
4. Build & run

On first launch the app will request:

- **Location While Using App** — for GPS path tracking; continues in the background while recording
- **Motion & Fitness** — for the accelerometer

The first time you lock the screen during a ride, iOS will show a one-time confirmation that the app wants to keep using location in the background. After approval, the green/blue location pill stays visible at the top of the screen for the rest of the ride.

## Architecture

```
Models       Ride, RidePoint, BumpGrid
Sensors      LocationManager, MotionManager, Biquad
Coordinator  RideRecorder
Persistence  RideStore (per-ride JSON files)
             BumpMapStore (rebuilt from rides on demand)
Settings     AppSettings (UserDefaults-backed thresholds + pocket toggle)
App state    AppState (selected tab, currently loaded ride)
Views        ContentView (TabView root)
             RideView, EditRideView, SavedRidesView, SettingsView
             SeismographView, SessionBumpinessChart, RouteMapView
             BumpMapView (UIViewRepresentable around MKMapView),
               BumpMapTileOverlay, BumpMapTabView
             RideImageExporter
```

### Sensor pipeline

1. CoreMotion delivers `CMDeviceMotion` at 50 Hz on a private `OperationQueue`.
2. `MotionManager` projects `userAcceleration` onto the gravity unit vector → scalar **vertical acceleration** (orientation-agnostic; works in any phone orientation).
3. Optional 3 Hz Butterworth biquad HPF (`Biquad.swift`) suppresses pedaling cadence — *Pocket Mode*.
4. Samples flow into a 5 s ring buffer; **bumpiness** = RMS of the most recent 1 s window.
5. CoreLocation delivers position whenever the rider has moved ≥ 3 m. Each location update emits a `RidePoint` with the current bumpiness, the recent 5 s accelerometer window (for playback), and the coordinate.
6. `RideRecorder` aggregates points; on stop, returns a `Ride` to be saved.

### Bump Map pipeline

1. Each ride's points are aggregated into `BumpGrid` — a sparse `[UInt64 → (sum, count)]` dictionary keyed by 20 ft lat/lon cells anchored to DC's reference latitude (~38.9°N, so `cellLatDeg` and `cellLonDeg` are constants accurate to <1% across a 20×20 mi envelope).
2. `BumpMapStore.rebuildIfNeeded(from:)` fingerprints the input rides by `id:pointCount` so re-rebuilds are no-ops when nothing changed.
3. `BumpMapTileOverlay` (an `MKTileOverlay` subclass) renders 256×256 PNG tiles asynchronously on demand:
   - Lat/lon bounds are computed from the standard web-mercator tile path (`z`, `x`, `y`).
   - Cells in the expanded query bbox are gathered (the bbox is widened by `maxGlowRadiusPx` worth of degrees so glow halos cross tile seams without gaps).
   - **Pass 1 — glow**: a single `CGMutablePath` of all cell rects is filled twice, once with a wide outer-aura shadow (22 px) and once with a tighter inner-core shadow (7 px), producing a "neon" purple halo around clusters.
   - **Pass 2 — color**: each cell rect is filled in its bumpiness-mapped color using `.copy` blend mode so the purple shadow under the cell's footprint is replaced by the actual color, leaving the halo only on the perimeter.
4. `BumpMapView` (UIViewRepresentable wrapping `MKMapView`) attaches the overlay over a `MKStandardMapConfiguration(emphasisStyle: .muted)` basemap and animates a fit-to-data setRegion the first time the rebuild produces a non-empty bounding box.

### Storage format

Each ride is a single JSON file at `<Documents>/Rides/<UUID>.json`:

```jsonc
{
  "id": "...",
  "title": "Ride Apr 23, 3:09 PM",
  "startedAt": "2026-04-23T19:09:00Z",
  "endedAt": "2026-04-23T19:34:00Z",
  "pocketMode": false,
  "points": [
    {
      "id": "...",
      "timestamp": "...",
      "latitude": 38.880,
      "longitude": -77.040,
      "speed": 5.2,
      "bumpiness": 0.31,
      "accelWindow": [...]
    },
    ...
  ]
}
```

`pocketMode` is `Optional<Bool>`; rides recorded before the field was added decode as `nil`.

The `BumpGrid` is **not** persisted — it's rebuilt from the rides on demand, which takes tens of milliseconds even for years of riding data. Cheaper than keeping an incremental index in sync.

## Project layout

```
BumpyRide/
├── BumpyRide.xcodeproj/
├── BumpyRide/
│   ├── BumpyRideApp.swift            # @main entry
│   ├── ContentView.swift             # TabView root
│   ├── AppState.swift                # selected tab, loaded ride
│   ├── AppSettings.swift             # color thresholds + pocket mode toggle
│   ├── Models.swift                  # Ride, RidePoint
│   │
│   ├── LocationManager.swift         # CLLocationManager wrapper
│   ├── MotionManager.swift           # CMMotionManager wrapper + bumpiness RMS
│   ├── Biquad.swift                  # 2nd-order IIR HPF (Butterworth)
│   ├── RideRecorder.swift            # location + motion → Ride
│   ├── RideStore.swift               # per-ride JSON persistence
│   │
│   ├── RideView.swift                # live recording + playback
│   ├── EditRideView.swift            # trim & split
│   ├── SavedRidesView.swift          # rides list
│   ├── RideImageExporter.swift       # render a ride for Photos export
│   ├── SettingsView.swift            # thresholds + pocket toggle
│   │
│   ├── SeismographView.swift         # live waveform
│   ├── SessionBumpinessChart.swift   # historic chart w/ scrubber + zoom
│   ├── RouteMapView.swift            # SwiftUI Map with colored polyline
│   │
│   ├── BumpGrid.swift                # sparse 20 ft cell grid
│   ├── BumpMapStore.swift            # aggregates rides → grid
│   ├── BumpMapTileOverlay.swift      # MKTileOverlay renderer
│   ├── BumpMapView.swift             # UIViewRepresentable MKMapView
│   ├── BumpMapTabView.swift          # tab content
│   │
│   ├── Formatters.swift              # distance / duration helpers
│   ├── Assets.xcassets/              # app icon + accent color
│   └── ...
└── README.md
```

## Info.plist permissions

Set via `INFOPLIST_KEY_*` build settings in the Xcode project (no separate Info.plist file):

| Key | Why |
|-----|-----|
| `NSLocationWhenInUseUsageDescription` | GPS path tracking during rides |
| `NSLocationAlwaysAndWhenInUseUsageDescription` | Background recording when screen locks |
| `NSMotionUsageDescription` | Accelerometer access for bumpiness |
| `UIBackgroundModes = location` | Keeps the app process alive while recording in background |

At runtime, `LocationManager` sets `allowsBackgroundLocationUpdates = true` and `showsBackgroundLocationIndicator = true` for the duration of a ride, then drops both at stop.

## Bumpiness color thresholds

Defaults (all in g, where 1 g ≈ Earth gravity):

| Color  | Default at |
|--------|-----------|
| Green  | 0.0 g      |
| Yellow | 0.5 g      |
| Orange | 1.0 g      |
| Red    | 1.5 g      |
| Purple | 2.0 g      |

Linearly interpolated between stops. Tune in **Settings** — sliders are constrained so each threshold stays ordered relative to its neighbors.

## Status

Active development. Not yet released. No automated tests — a future improvement.

---

🤖 Built with assistance from [Claude Code](https://claude.com/claude-code).
