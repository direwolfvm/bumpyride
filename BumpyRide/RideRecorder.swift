import Foundation
import CoreLocation
import Observation

@Observable
final class RideRecorder {
    enum State { case idle, recording, finished }

    let location = LocationManager()
    let motion = MotionManager()

    private(set) var state: State = .idle
    private(set) var points: [RidePoint] = []
    private(set) var startedAt: Date?
    private(set) var endedAt: Date?
    /// Snapshot of `motion.highPassEnabled` at ride start time — gets stamped onto the
    /// saved Ride so the bump map can later filter by sensing mode.
    private var startedInPocketMode: Bool = false

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
        startedInPocketMode = motion.highPassEnabled
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
        return Ride(
            title: Ride.defaultTitle(for: start),
            startedAt: start,
            endedAt: end,
            points: points,
            pocketMode: startedInPocketMode
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
