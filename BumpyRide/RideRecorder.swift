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
    enum State { case idle, recording, finished }

    let location = LocationManager()
    let motion = MotionManager()

    private(set) var state: State = .idle
    private(set) var points: [RidePoint] = []
    private(set) var startedAt: Date?
    private(set) var endedAt: Date?

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
        guard state != .recording else { return }
        points = []
        startedAt = Date()
        endedAt = nil
        state = .recording
        motion.start()
        location.startUpdating()
    }

    func stop() -> Ride? {
        guard state == .recording else { return nil }
        location.stopUpdating()
        motion.stop()
        endedAt = Date()
        state = .finished
        guard let start = startedAt, let end = endedAt, !points.isEmpty else { return nil }
        // pocketMode is left nil here — the save flow runs `MountStyleDetector` and
        // decides.  Per Option C the recording is always raw; the mode label is a
        // post-hoc characterization, not a pre-flight setting.
        return Ride(
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
        points = []
        startedAt = nil
        endedAt = nil
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
    }
}
