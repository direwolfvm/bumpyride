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

    private(set) var state: State = .idle
    private(set) var points: [RidePoint] = []
    private(set) var startedAt: Date?
    private(set) var endedAt: Date?
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
        let now = Date()
        startedAt = now
        endedAt = nil
        let rideId = UUID()
        pendingRideId = rideId
        // Open the crash-safe journal.  Failures are non-fatal — recording still
        // happens in memory, we just lose the ability to recover on force-quit.
        try? journal.start(rideId: rideId, startedAt: now, schemaVersion: 2)
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
            pocketMode: nil
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
        startedAt = nil
        endedAt = nil
        pendingRideId = nil
        state = .idle
    }

    private func handleLocation(_ loc: CLLocation) {
        guard state == .recording else { return }
        guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 50 else { return }
        let bumpiness = motion.currentBumpiness
        let window = motion.snapshotWindow()
        let point = RidePoint(
            timestamp: loc.timestamp,
            latitude: loc.coordinate.latitude,
            longitude: loc.coordinate.longitude,
            speed: max(0, loc.speed),
            bumpiness: bumpiness,
            accelWindow: window
        )
        points.append(point)
        // Persist immediately to the journal so a process kill in the next
        // microsecond doesn't lose this point.
        journal.append(point)
    }
}
