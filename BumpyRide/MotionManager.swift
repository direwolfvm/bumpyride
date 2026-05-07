import Foundation
import CoreMotion
import Observation

/// Wraps `CMMotionManager`.  Each device-motion sample is projected onto the gravity
/// unit vector to extract scalar vertical acceleration (orientation-agnostic),
/// optionally high-pass filtered for Pocket Mode, and pushed into a 5 s ring buffer.
/// The published `currentBumpiness` is the RMS of the most recent 1 s window.
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
    /// Cutoff for the pocket-mode high-pass.  3 Hz attenuates a 90 RPM pedaling fundamental
    /// (1.5 Hz) by ~10 dB at this filter order, while passing real bump energy (5+ Hz)
    /// through with minimal effect.
    private let highPassCutoffHz: Double = 3.0

    private var ringBuffer: [Float] = []
    private var ringIndex: Int = 0
    private var ringFilled: Bool = false

    private(set) var latestSamples: [Float] = []
    private(set) var currentBumpiness: Double = 0

    /// When true, the vertical acceleration channel is run through a 2nd-order Butterworth
    /// high-pass filter before going into the bumpiness ring buffer.  Toggling resets the
    /// filter state to avoid feeding the ring buffer the filter's startup transient.
    var highPassEnabled: Bool = false {
        didSet {
            if oldValue != highPassEnabled { highPassFilter.reset() }
        }
    }
    private var highPassFilter: Biquad

    var windowCapacity: Int { Int(sampleRateHz * displaySeconds) }
    private var rmsSampleCount: Int { Int(sampleRateHz * rmsSeconds) }

    init() {
        manager.deviceMotionUpdateInterval = 1.0 / sampleRateHz
        highPassFilter = Biquad.butterworthHighPass(
            cutoffHz: highPassCutoffHz,
            sampleRateHz: sampleRateHz
        )
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
        highPassFilter.reset()
    }

    private func ingest(_ vertical: Float) {
        let processed: Float
        if highPassEnabled {
            processed = Float(highPassFilter.process(Double(vertical)))
        } else {
            processed = vertical
        }
        ringBuffer[ringIndex] = processed
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
