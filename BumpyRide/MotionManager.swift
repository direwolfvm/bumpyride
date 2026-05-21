import Foundation
import CoreMotion
import Observation

/// Wraps `CMMotionManager`.  Each device-motion sample is projected onto the gravity
/// unit vector to extract scalar vertical acceleration (orientation-agnostic) and
/// pushed into a 5 s ring buffer.  The published `currentBumpiness` is the RMS of
/// the most recent 1 s window.
///
/// No filtering happens here anymore — the signal is always raw vertical
/// acceleration.  Pocket-mode rides get a 3 Hz high-pass applied retroactively at
/// save time (`Ride.reprocessedWithPocketHPF()`), once `MountStyleDetector` decides
/// the recording was pocketed.  This means:
///
///   - We can decide the mode after seeing all the data, not before.
///   - The saved `accelWindow` is always raw, so a user retagging the ride later
///     can recompute bumpiness in either direction without information loss.
///   - The live seismograph and live bumpiness display the raw signal — which
///     looks cadence-inflated during pocket-mode recordings, but the user isn't
///     looking at the screen in that case anyway.
@Observable
final class MotionManager {
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.bumpyride.motion"
        q.qualityOfService = .userInitiated
        return q
    }()

    private let sampleRateHz: Double = 50.0
    private let displaySeconds: Double = 5.0
    private let rmsSeconds: Double = 1.0

    /// Ring buffer of raw vertical-accel samples.  Mutated on every motion
    /// callback (50 Hz).  `@ObservationIgnored` so the per-sample writes
    /// don't trigger SwiftUI invalidation cascades — the view binds to
    /// `latestSamples` / `currentBumpiness` instead, which are published
    /// at a throttled rate by `ingest`.
    @ObservationIgnored private var ringBuffer: [Float] = []
    @ObservationIgnored private var ringIndex: Int = 0
    @ObservationIgnored private var ringFilled: Bool = false

    /// Counts raw samples since start to drive the publishing throttle.
    /// Untracked — has no business invalidating views.
    @ObservationIgnored private var sampleSequence: Int = 0

    /// Publish the seismograph waveform + bumpiness number every Nth raw
    /// sample.  At 50 Hz raw and N = 3 the view sees updates at ~17 Hz —
    /// fast enough to read as smooth scrolling, slow enough that long
    /// rides don't pile up SwiftUI invalidation work on the main actor.
    /// Earlier behavior was N = 1, which was contributing to the "freeze
    /// and catch up" stutter on long rides.
    private static let publishEveryNSamples: Int = 3

    private(set) var latestSamples: [Float] = []
    private(set) var currentBumpiness: Double = 0

    /// Magnitude of the most recent user-acceleration vector projected onto
    /// the horizontal plane (the plane perpendicular to gravity at that
    /// instant), in g-units.  Captures braking, accelerating, and cornering
    /// independently of phone orientation.
    ///
    /// `nil` between samples (before the first `ingest`) and after `reset()`.
    /// `RideRecorder.handleLocation` snapshots this into each `RidePoint.horizontalAccel`
    /// so the post-hoc `BrakeEventDetector` can refine GPS-derived event
    /// peaks with a direct accel signal.
    ///
    /// `@ObservationIgnored` because it's read on the GPS-callback cadence
    /// (~2 Hz), not by any SwiftUI view directly — so the 50 Hz writes
    /// should not invalidate the view tree.
    @ObservationIgnored private(set) var currentHorizontalAccelG: Float?

    var windowCapacity: Int { Int(sampleRateHz * displaySeconds) }
    private var rmsSampleCount: Int { Int(sampleRateHz * rmsSeconds) }

    init() {
        manager.deviceMotionUpdateInterval = 1.0 / sampleRateHz
        ringBuffer = Array(repeating: 0, count: Int(sampleRateHz * displaySeconds))
    }

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        reset()
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let g = motion.gravity
            let gMag = sqrt(g.x * g.x + g.y * g.y + g.z * g.z)
            guard gMag > 0 else { return }
            let ua = motion.userAcceleration

            // Scalar projection of userAccel onto gravity direction.  Positive =
            // accel pointing roughly "down" (with gravity), negative = "up".
            // This is the value `bumpiness` is built on.
            let vertical = (ua.x * g.x + ua.y * g.y + ua.z * g.z) / gMag

            // Horizontal-plane magnitude.  Subtract the gravity-aligned
            // component from the full userAccel vector, then take the length.
            // Gravity unit vector is g / gMag, so the parallel component is
            // (vertical * g / gMag), and the orthogonal residual is what we
            // want.  All in g-units since CMDeviceMotion.userAcceleration
            // is reported in G's.
            let hx = ua.x - vertical * g.x / gMag
            let hy = ua.y - vertical * g.y / gMag
            let hz = ua.z - vertical * g.z / gMag
            let horizontal = Float(sqrt(hx * hx + hy * hy + hz * hz))

            let value = Float(vertical)
            Task { @MainActor in
                self.ingest(value, horizontalG: horizontal)
            }
        }
    }

    func stop() {
        if manager.isDeviceMotionActive {
            manager.stopDeviceMotionUpdates()
        }
    }

    func reset() {
        ringBuffer = Array(repeating: 0, count: windowCapacity)
        ringIndex = 0
        ringFilled = false
        sampleSequence = 0
        latestSamples = []
        currentBumpiness = 0
        currentHorizontalAccelG = nil
    }

    /// Called on the main actor for every 50 Hz device-motion callback.
    /// Hot path — keep cheap:
    ///   - Ring buffer write + index bump on every call (untracked storage,
    ///     no SwiftUI invalidation).
    ///   - `currentHorizontalAccelG` is also untracked, refreshed on every
    ///     call so the next GPS fix gets a current value.
    ///   - The two **observed** properties — `latestSamples` and
    ///     `currentBumpiness` — are only published every Nth raw sample,
    ///     throttling SwiftUI re-renders to ~17 Hz.  Visually smooth, no
    ///     per-sample render storm.
    private func ingest(_ vertical: Float, horizontalG: Float) {
        ringBuffer[ringIndex] = vertical
        ringIndex = (ringIndex + 1) % ringBuffer.count
        if ringIndex == 0 { ringFilled = true }
        currentHorizontalAccelG = horizontalG
        sampleSequence &+= 1
        if sampleSequence % Self.publishEveryNSamples == 0 {
            latestSamples = orderedSamples()
            currentBumpiness = computeRMS(recentSamples(count: rmsSampleCount))
        }
    }

    func snapshotWindow() -> [Float] { orderedSamples() }

    private func orderedSamples() -> [Float] {
        if ringFilled {
            return Array(ringBuffer[ringIndex..<ringBuffer.count]) + Array(ringBuffer[0..<ringIndex])
        } else {
            return Array(ringBuffer[0..<ringIndex])
        }
    }

    private func recentSamples(count: Int) -> [Float] {
        let all = orderedSamples()
        guard all.count > count else { return all }
        return Array(all.suffix(count))
    }

    private func computeRMS(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sumSq: Double = 0
        for s in samples { sumSq += Double(s) * Double(s) }
        return sqrt(sumSq / Double(samples.count))
    }
}
