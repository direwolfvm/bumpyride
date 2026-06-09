import Foundation
import CoreLocation
import Observation

/// The recording coordinator: owns a `LocationManager` and `MotionManager`, ingests
/// each location update by stamping it with the current bumpiness and accelerometer
/// window, and on `stop()` returns a `Ride` ready to be saved.
///
/// The returned ride has `pocketMode = nil` ("undetermined") and raw `bumpiness` /
/// raw `accelWindow` values.  `MountStyleDetector` decides pocketMode at save time,
/// and if pocket: `Ride.reprocessedWithPocketHPF()` retroactively recomputes
/// bumpiness through the 3 Hz HPF before the ride is persisted.
@Observable
final class RideRecorder {
    /// Lifecycle states.  Note `paused` is reachable only from `recording` and only
    /// via the explicit `pause()` API — there is no auto-pause on app backgrounding
    /// (the location entitlement covers that) or on motion stillness.
    enum State { case idle, recording, paused, finished }

    let location = LocationManager()
    let motion = MotionManager()
    let journal = RideJournal()

    /// Max horizontal accuracy (in meters) we'll accept for a fix.  Bumped from
    /// 50 m → 100 m to recover from a real bug: in pocket-mode rides, the GPS
    /// antenna is partially occluded by clothing/body and routinely reports
    /// 80–150 m accuracy.  The old 50 m floor silently dropped every one of
    /// those fixes mid-ride, producing a "GPS went quiet" symptom followed by a
    /// straight-line polyline jump when the user pulled the phone out to stop
    /// recording.  At 100 m a fix still places a sample inside the correct
    /// ~6 m bump-map cell's broader neighborhood — much better than nothing.
    /// See LocationManager's logging notes for how to verify on Console.app.
    private static let maxHorizontalAccuracyMeters: CLLocationAccuracy = 100

    /// Maximum age (in seconds) of a `CLLocation`'s `timestamp` relative to
    /// now.  Older than this and we treat it as a stale/cached delivery —
    /// not safe to pair with current motion-ring-buffer data, because the
    /// location is from "then" and the bumpiness reading is from "now."
    ///
    /// Matters during recovery from a mid-ride dropout: iOS may deliver
    /// cached fixes from before the gap when location resumes, with
    /// `timestamp`s from minutes ago.  Saving a `RidePoint` that pairs
    /// that stale lat/lon with the current bumpiness reading creates a
    /// corrupted data point — looks like a bump happened in a place the
    /// rider was minutes ago.
    ///
    /// 30 s threshold: loose enough that backgrounded-app batched
    /// deliveries (where iOS bundles several seconds' worth of fixes
    /// into one callback) all pass through, but still tight enough to
    /// reject genuinely-stale cached fixes from a multi-minute dropout
    /// recovery.  Was 5 s briefly, but with `LocationManager`'s
    /// full-bundle processing the older entries in a normal background
    /// batch were getting rejected and we ended up under-sampling.
    private static let maxLocationAgeSeconds: TimeInterval = 30.0

    private(set) var state: State = .idle
    private(set) var points: [RidePoint] = []
    /// User-initiated close-call events captured during this recording.  Each
    /// `logCloseCall()` appends one entry here and to the journal.  Empty
    /// at start; included in the `Ride` returned from `stop()`.
    private(set) var closeCalls: [CloseCall] = []
    /// v1.7 J2: user-supplied categorizations of brake events that were
    /// detected and acknowledged during live recording.  Keyed by the
    /// brake event's `timestamp` (the peak-decel moment) because the
    /// auto-generated UUIDs on `BrakeEvent` aren't stable across the
    /// 1 Hz re-runs of `BrakeEventDetector.detect` — but the timestamp
    /// of the peak doesn't drift across re-runs once enough trailing
    /// context exists.
    ///
    /// Applied to the final brake events at save time via
    /// `Ride.applyingBrakeCategorizations(_:)` (closest-timestamp
    /// match within a 5 s tolerance).  Reset on `reset()` along
    /// with the rest of the per-ride buffers.
    private(set) var brakeCategorizations: [Date: BrakeEventCategory] = [:]
    private(set) var startedAt: Date?
    private(set) var endedAt: Date?

    /// Incrementally-maintained ride totals.  Computed once per appended
    /// `RidePoint` and read in O(1) by views, instead of being recomputed
    /// from the full `points` array on every render.
    ///
    /// Earlier code had these as O(N) computed properties on RideView,
    /// which the per-second TimelineView refresh of the stats bar turned
    /// into a real lag source on long rides: 2N CLLocation allocations
    /// per render every second, scaling with ride length.  These cached
    /// values stay constant-time at the read site regardless.
    ///
    /// Reset to zero in `start()` and `reset()`.
    private(set) var totalDistanceMeters: Double = 0
    private(set) var maxRecordedBumpiness: Double = 0
    /// Stable ride id assigned at `start()` time and used by both the journal and
    /// the eventual `Ride` returned from `stop()`.  Lets us recover the exact same
    /// ride identity if the app dies and the user accepts recovery on relaunch.
    private var pendingRideId: UUID?

    var liveSamples: [Float] { motion.latestSamples }
    var currentBumpiness: Double { motion.currentBumpiness }
    var currentLocation: CLLocation? { location.lastLocation }

    init() {
        location.onLocationUpdate = { [weak self] loc in
            self?.handleLocation(loc)
        }
    }

    func requestPermissions() {
        location.requestAuthorization()
    }

    func start() {
        // Reject from .recording (already going) and .paused (caller meant
        // resume(), not a new ride — silently starting over would discard their
        // in-progress points).  .idle and .finished are the legitimate entry
        // points for a fresh ride.
        guard state == .idle || state == .finished else { return }
        points = []
        closeCalls = []
        brakeCategorizations = [:]
        totalDistanceMeters = 0
        maxRecordedBumpiness = 0
        let now = Date()
        startedAt = now
        endedAt = nil
        let rideId = UUID()
        pendingRideId = rideId
        // Open the crash-safe journal.  Failures are non-fatal — recording still
        // happens in memory, we just lose the ability to recover on force-quit.
        // Schema version 3 matches Models.swift's default — new fields
        // (horizontalAccel, brakeEvents, closeCallEvents) are all additive
        // and optional, so v3 readers handle in-flight v3 records seamlessly.
        try? journal.start(rideId: rideId, startedAt: now, schemaVersion: 3)
        state = .recording
        motion.start()
        location.startUpdating()
    }

    /// Temporarily halt sampling without ending the ride.  Stops the GPS + motion
    /// streams (so battery isn't drained while the user is at a stoplight or taking
    /// a break) but leaves `points`, the journal, and `startedAt` intact so
    /// `resume()` picks up exactly where we left off.  Idempotent — repeated
    /// `pause()` calls from `.paused` are no-ops.
    func pause() {
        guard state == .recording else { return }
        location.stopUpdating()
        motion.stop()
        state = .paused
    }

    /// Resume sampling after a `pause()`.  Calling `motion.start()` resets the
    /// MotionManager's ring buffer + filter state, so the seismograph will look
    /// "empty" for ~1 s after resume while the window refills — that's a feature,
    /// not a bug (the pause discontinuity shouldn't be smeared through the filter).
    func resume() {
        guard state == .paused else { return }
        motion.start()
        location.startUpdating()
        state = .recording
    }

    func stop() -> Ride? {
        // Accept stop from either active or paused — users who tap Stop after a
        // pause expect the same save-sheet flow they get from a recording-state
        // stop.  No need to "re-start before stopping."
        guard state == .recording || state == .paused else { return nil }
        location.stopUpdating()
        motion.stop()
        endedAt = Date()
        state = .finished
        // Close the file handle but leave the journal on disk until the user
        // saves or discards.  If the user kills the app before resolving the
        // save sheet, recovery on next launch picks up where we left off.
        journal.close()
        guard let start = startedAt, let end = endedAt, !points.isEmpty else { return nil }
        // pocketMode is left nil here — the save flow runs `MountStyleDetector` and
        // decides.  Per Option C the recording is always raw; the mode label is a
        // post-hoc characterization, not a pre-flight setting.
        return Ride(
            id: pendingRideId ?? UUID(),
            title: Ride.defaultTitle(for: start),
            startedAt: start,
            endedAt: end,
            points: points,
            pocketMode: nil,
            closeCallEvents: closeCalls
        )
    }

    func reset() {
        motion.stop()
        location.stopUpdating()
        motion.reset()
        // Discard any in-progress journal as well.  Called from save / discard
        // paths in RideView, and from start-over flows.  Safe to call when no
        // journal exists.
        journal.clear()
        points = []
        closeCalls = []
        brakeCategorizations = [:]
        totalDistanceMeters = 0
        maxRecordedBumpiness = 0
        startedAt = nil
        endedAt = nil
        pendingRideId = nil
        state = .idle
    }

    // MARK: - Close calls

    /// `true` when a close-call log button tap will succeed.  False during
    /// `.idle` / `.finished` (no ride to attach the call to) and when we
    /// don't yet have a GPS fix (can't place the call on the map).  Both
    /// `.recording` and `.paused` are valid — a user can experience a close
    /// call while paused at a light, and tagging it there is legitimate.
    var canLogCloseCall: Bool {
        guard state == .recording || state == .paused else { return false }
        return location.lastLocation != nil
    }

    /// Capture a close call at the current GPS location and timestamp.
    /// Appends to the in-memory list and the journal.  Returns the created
    /// event so the UI can show a confirmation banner with an undo button
    /// referencing this specific call.  Returns `nil` if `canLogCloseCall`
    /// would be `false` (no recording, or no fix yet) — the caller should
    /// gate the button on `canLogCloseCall` to avoid silent no-ops, but
    /// returning nil rather than crashing here is the defensive choice.
    /// v1.7 J2: stash a user-supplied category for a brake event
    /// detected during live recording.  `timestamp` is the brake
    /// event's `timestamp` field (peak-decel moment).  Idempotent —
    /// re-calling with the same timestamp overwrites the prior
    /// category.  Applied to final detected events at save time
    /// via `Ride.applyingBrakeCategorizations`.
    func setBrakeCategory(_ category: BrakeEventCategory, at timestamp: Date) {
        brakeCategorizations[timestamp] = category
    }

    @discardableResult
    func logCloseCall() -> CloseCall? {
        guard canLogCloseCall, let loc = location.lastLocation else { return nil }
        let call = CloseCall(
            timestamp: Date(),
            latitude: loc.coordinate.latitude,
            longitude: loc.coordinate.longitude
        )
        closeCalls.append(call)
        journal.appendCloseCall(call)
        return call
    }

    /// Undo a specific close call by id — typically called from a brief
    /// post-tap banner with an Undo button.  Only the in-memory list is
    /// mutated; the journal's append-only file is untouched.  See
    /// `RideJournal`'s class doc for the trade-off (crash during the undo
    /// window would resurrect the call on recovery).
    ///
    /// Returns `true` if a matching call was removed, `false` if no such id
    /// is currently in the list (e.g., the banner stayed visible past
    /// reset() somehow).
    @discardableResult
    func undoCloseCall(id: UUID) -> Bool {
        guard let idx = closeCalls.firstIndex(where: { $0.id == id }) else { return false }
        closeCalls.remove(at: idx)
        return true
    }

    private func handleLocation(_ loc: CLLocation) {
        guard state == .recording else { return }
        // `horizontalAccuracy < 0` is CoreLocation's "no valid fix" sentinel.
        // All drop conditions are silent (no OSLog) — this method is on the
        // hot path (fires per location callback, ~2–3 Hz at cycling speed)
        // and an earlier per-drop log got the subsystem quarantined.  If you
        // need to see drop counts for debugging, attach Xcode.
        guard loc.horizontalAccuracy >= 0 else { return }
        guard loc.horizontalAccuracy < Self.maxHorizontalAccuracyMeters else { return }
        // Freshness gate.  iOS sometimes delivers a cached `CLLocation`
        // whose `timestamp` is from minutes ago — most commonly after a
        // mid-ride location dropout, when delivery first resumes with one
        // stale fix before fresh ones flow.  Pairing that stale lat/lon
        // with the current motion-ring-buffer bumpiness reading produces
        // a corrupted RidePoint: the bump shows up at a location the
        // rider was at minutes earlier, not where they are now.  Filter
        // these out — the next real fix will produce a clean point.
        guard abs(loc.timestamp.timeIntervalSinceNow) < Self.maxLocationAgeSeconds else { return }
        let bumpiness = motion.currentBumpiness
        let window = motion.snapshotWindow()
        // Snapshot the latest horizontal-plane accel magnitude for post-hoc
        // brake-event refinement.  `nil` if the motion stream hasn't yet
        // produced a sample (e.g., the very first GPS callback can fire
        // before the device-motion handler).  Optional storage means legacy
        // rides + transient gaps are both naturally represented.
        let horizontalAccel = motion.currentHorizontalAccelG
        let point = RidePoint(
            timestamp: loc.timestamp,
            latitude: loc.coordinate.latitude,
            longitude: loc.coordinate.longitude,
            speed: max(0, loc.speed),
            bumpiness: bumpiness,
            accelWindow: window,
            horizontalAccel: horizontalAccel
        )
        // Maintain the incremental ride totals BEFORE appending so we can
        // reference the previous-last point as the segment start.  The
        // totals become O(1) reads at the stats-bar render site instead
        // of O(N) recomputations every TimelineView tick.
        if let prev = points.last {
            let a = CLLocation(latitude: prev.latitude, longitude: prev.longitude)
            let b = CLLocation(latitude: point.latitude, longitude: point.longitude)
            totalDistanceMeters += b.distance(from: a)
        }
        if point.bumpiness > maxRecordedBumpiness {
            maxRecordedBumpiness = point.bumpiness
        }
        points.append(point)
        // Persist immediately to the journal so a process kill in the next
        // microsecond doesn't lose this point.
        journal.append(point)
    }
}
