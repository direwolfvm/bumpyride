import Foundation
import Observation

/// Opportunistic per-rider calibration for the systematic damping difference between
/// pocket-mode and mounted recordings.  Clothing + body mass attenuate the
/// high-frequency vibration content that BumpyRide measures, so a 1.0 g handlebar
/// reading might show up as 0.5 g in a pocket.  This store mines the rider's own
/// data for spatial overlap between modes and derives a scalar gain `k` such that
/// `bumpiness_corrected = bumpiness_raw * k` for pocket-mode points.
///
/// Algorithm:
///
///   1. Bucket every `RidePoint` from every ride into `BumpGrid` cells, separately
///      per mode (treating `pocketMode == nil` as mounted — legacy data is most
///      likely from a fixed mount).
///   2. For each cell with at least `minSamplesPerMode` samples in *both* modes,
///      compute `mountedAvg / pocketAvg`.  Skip cells where the pocket average is
///      under `minPocketAvg` — dividing by ~0 explodes the ratio for no reason.
///   3. Take the **median** of those ratios.  More robust than the mean against
///      a single pothole that happened to land in one mode only.
///   4. Clamp to `[minGain, maxGain]` so even a pathological dataset can't produce
///      a wildly incorrect correction.
///   5. If fewer than `minOverlap` cells qualify, fall back to `k = 1.0` (no
///      correction) and a confidence of 0 — the user-facing UI uses this to decide
///      whether to show calibration status.
///
/// Recomputation is O(total points) per call, which on real data is sub-millisecond
/// and fine to run synchronously on every ride save.  The result is persisted to
/// `<Documents>/calibration.json` so it survives launches.
@Observable
final class CalibrationStore {
    /// A single user-wide calibration value.  Per-rider variance dominates (loose-pocket
    /// jeans damp differently than tight running shorts), but we have no way to
    /// detect different pocket configurations within one user — so a single scalar
    /// is the best we can do without explicit user input.
    struct PocketCalibration: Codable, Equatable {
        /// Multiplier to apply to pocket-mode bumpiness samples to match mounted scale.
        /// `1.0` means no correction has been computed yet.
        var pocketGain: Double = 1.0
        /// Number of overlapping cells used to derive `pocketGain`.  Higher = more
        /// trustworthy.  `0` means the algorithm didn't have enough data and is
        /// using the default `1.0` gain.
        var confidence: Int = 0
        /// When the calibration was last recomputed.  Used for the wire-format upload
        /// and for the Settings UI status line.
        var lastComputed: Date?
    }

    private(set) var calibration: PocketCalibration = PocketCalibration()

    // Tuning constants — exposed as static so tests / debugging can reference them.
    static let minSamplesPerMode: Int = 3
    static let minOverlappingCells: Int = 3
    static let minPocketAvg: Double = 0.02
    static let minGain: Double = 0.5
    static let maxGain: Double = 5.0

    private let fileURL: URL

    init(directory: URL = CalibrationStore.defaultDirectory) {
        self.fileURL = directory.appendingPathComponent("calibration.json")
        load()
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    /// Whether we have a real (non-default) calibration derived from data.  Views use
    /// this to decide whether to surface the gain to the user.
    var hasCalibration: Bool {
        calibration.confidence >= Self.minOverlappingCells
    }

    /// Convenience: the gain to apply to a ride based on its mode.
    func gain(forPocketMode pocketMode: Bool?) -> Double {
        guard pocketMode == true, hasCalibration else { return 1.0 }
        return calibration.pocketGain
    }

    /// Mine the given rides for paired-cell data and update `calibration` if a
    /// meaningfully different value emerges.  Safe to call on every ride save —
    /// the work is bounded by total point count, which for a year of daily commutes
    /// is on the order of 10⁵ points → low single-digit milliseconds.
    func recompute(from rides: [Ride]) {
        var mounted: [UInt64: (sum: Double, count: Int)] = [:]
        var pocket: [UInt64: (sum: Double, count: Int)] = [:]

        for ride in rides {
            let isPocket = ride.pocketMode == true
            for point in ride.points {
                let (ix, iy) = BumpGrid.gridIndex(lat: point.latitude, lon: point.longitude)
                let key = BumpGrid.key(ix: ix, iy: iy)
                if isPocket {
                    let existing = pocket[key] ?? (0, 0)
                    pocket[key] = (existing.sum + point.bumpiness, existing.count + 1)
                } else {
                    let existing = mounted[key] ?? (0, 0)
                    mounted[key] = (existing.sum + point.bumpiness, existing.count + 1)
                }
            }
        }

        var ratios: [Double] = []
        ratios.reserveCapacity(min(mounted.count, pocket.count))
        for (key, m) in mounted {
            guard m.count >= Self.minSamplesPerMode else { continue }
            guard let p = pocket[key], p.count >= Self.minSamplesPerMode else { continue }
            let mAvg = m.sum / Double(m.count)
            let pAvg = p.sum / Double(p.count)
            guard pAvg >= Self.minPocketAvg else { continue }
            ratios.append(mAvg / pAvg)
        }

        let next: PocketCalibration
        if ratios.count >= Self.minOverlappingCells {
            let median = ratios.sorted()[ratios.count / 2]
            let clamped = min(max(median, Self.minGain), Self.maxGain)
            next = PocketCalibration(
                pocketGain: clamped,
                confidence: ratios.count,
                lastComputed: Date()
            )
        } else {
            // Not enough overlap yet — leave gain at 1.0 so pocket data flows through
            // uncorrected, but record that we tried so the UI doesn't claim we never
            // ran.
            next = PocketCalibration(
                pocketGain: 1.0,
                confidence: 0,
                lastComputed: Date()
            )
        }

        if next != calibration {
            calibration = next
            persist()
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode(PocketCalibration.self, from: data) {
            calibration = decoded
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(calibration) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
