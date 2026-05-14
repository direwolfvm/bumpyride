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

    private var ringBuffer: [Float] = []
    private var ringIndex: Int = 0
    private var ringFilled: Bool = false

    private(set) var latestSamples: [Float] = []
    private(set) var currentBumpiness: Double = 0

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
            let vertical = (ua.x * g.x + ua.y * g.y + ua.z * g.z) / gMag
            let value = Float(vertical)
            Task { @MainActor in
                self.ingest(value)
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
        latestSamples = []
        currentBumpiness = 0
    }

    private func ingest(_ vertical: Float) {
        ringBuffer[ringIndex] = vertical
        ringIndex = (ringIndex + 1) % ringBuffer.count
        if ringIndex == 0 { ringFilled = true }
        latestSamples = orderedSamples()
        currentBumpiness = computeRMS(recentSamples(count: rmsSampleCount))
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
