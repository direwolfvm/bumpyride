import Foundation
import Observation

/// Diagnostic snapshot of the calibration algorithm's state, suitable for the
/// in-app Inspector view and for serialization (export / upload to server).
/// Computed on demand from a list of rides — not persisted.
struct CalibrationDiagnostics: Codable, Equatable {
    let computedAt: Date

    /// The currently-in-use, clamped gain stored in `CalibrationStore.calibration`.
    let currentGain: Double
    /// The matching confidence count.
    let currentConfidence: Int
    /// When the persisted value was last updated (`calibration.lastComputed`).
    let lastPersistedAt: Date?

    /// Median of the qualifying cell ratios before clamping to `[minGain, maxGain]`.
    /// `nil` when there aren't enough qualifying cells for a meaningful median.
    let unclampedMedian: Double?

    /// Min / max / mean / std-dev across qualifying cell ratios.  All `nil` when
    /// no cells qualify.
    let minRatio: Double?
    let maxRatio: Double?
    let meanRatio: Double?
    let stdDev: Double?

    /// Sample counts across all rides.
    let totalMountedSamples: Int
    let totalPocketSamples: Int

    /// Cells touched by at least one sample (any mode).
    let totalCellsTouched: Int
    /// Cells with at least 1 sample in each mode (no minimum-count filter).
    let cellsWithBothModes: Int
    /// Cells meeting `minSamplesPerMode` in both AND a non-degenerate pocket avg —
    /// the cells that actually contributed a ratio to the median.
    let qualifyingCells: Int

    /// Top contributors by total sample count, capped at 50 for payload size.
    let topCells: [CellEntry]

    /// Per-recent-ride detector results — last N rides newest-first.
    let recentDetections: [RideDetectionSnapshot]

    /// Algorithm constants in effect at compute time, for reproducibility.
    let thresholds: Thresholds

    struct CellEntry: Codable, Equatable {
        let ix: Int
        let iy: Int
        /// Cell center.  Useful for plotting on a map; revealing of routes when
        /// shared, but the user explicitly initiates the export.
        let latitude: Double
        let longitude: Double
        let mountedCount: Int
        let mountedAverage: Double
        let pocketCount: Int
        let pocketAverage: Double
        /// `nil` when the cell didn't qualify (insufficient samples / near-zero pocket).
        let ratio: Double?
        /// Did this cell's ratio contribute to the calibration's median?
        let qualifies: Bool
    }

    struct RideDetectionSnapshot: Codable, Equatable {
        let rideId: UUID
        let rideTitle: String
        let startedAt: Date
        let pocketMode: Bool?
        let schemaVersion: Int
        let detectorVerdict: MountStyleDetector.Verdict?
        let detectorRatio: Double?
        let cadenceRMS: Double?
        let bumpRMS: Double?
        let samplesAnalyzed: Int?
    }

    struct Thresholds: Codable, Equatable {
        let minSamplesPerMode: Int
        let minOverlappingCells: Int
        let minPocketAvg: Double
        let minGain: Double
        let maxGain: Double
    }
}

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

    // MARK: - Diagnostics

    /// Run the calibration algorithm with full bookkeeping and return a snapshot
    /// suitable for inspection / export.  Doesn't mutate `calibration` — that's
    /// only updated by `recompute(from:)` on save / delete.  Roughly O(total points)
    /// like `recompute` itself, with a bit of extra overhead for the per-cell
    /// breakdown.  Sub-millisecond on typical ride collections.
    func computeDiagnostics(from rides: [Ride], recentRidesLimit: Int = 30) -> CalibrationDiagnostics {
        var mounted: [UInt64: (sum: Double, count: Int)] = [:]
        var pocket: [UInt64: (sum: Double, count: Int)] = [:]
        var totalMountedSamples = 0
        var totalPocketSamples = 0

        for ride in rides {
            let isPocket = ride.pocketMode == true
            for point in ride.points {
                let (ix, iy) = BumpGrid.gridIndex(lat: point.latitude, lon: point.longitude)
                let key = BumpGrid.key(ix: ix, iy: iy)
                if isPocket {
                    let existing = pocket[key] ?? (0, 0)
                    pocket[key] = (existing.sum + point.bumpiness, existing.count + 1)
                    totalPocketSamples += 1
                } else {
                    let existing = mounted[key] ?? (0, 0)
                    mounted[key] = (existing.sum + point.bumpiness, existing.count + 1)
                    totalMountedSamples += 1
                }
            }
        }

        let allKeys = Set(mounted.keys).union(pocket.keys)
        let cellsWithBothModes = allKeys.filter { mounted[$0] != nil && pocket[$0] != nil }.count

        var allEntries: [CalibrationDiagnostics.CellEntry] = []
        var ratios: [Double] = []
        for key in allKeys {
            let m = mounted[key] ?? (0, 0)
            let p = pocket[key] ?? (0, 0)
            guard m.count > 0 || p.count > 0 else { continue }
            let mAvg = m.count > 0 ? m.sum / Double(m.count) : 0
            let pAvg = p.count > 0 ? p.sum / Double(p.count) : 0
            let ratio: Double?
            if m.count >= Self.minSamplesPerMode,
               p.count >= Self.minSamplesPerMode,
               pAvg >= Self.minPocketAvg {
                ratio = mAvg / pAvg
                ratios.append(mAvg / pAvg)
            } else {
                ratio = nil
            }
            let (ix, iy) = BumpGrid.unpack(key)
            let (cellLat, cellLon) = BumpGrid.cellOrigin(ix: ix, iy: iy)
            allEntries.append(CalibrationDiagnostics.CellEntry(
                ix: ix,
                iy: iy,
                latitude: cellLat + BumpGrid.cellLatDeg / 2,
                longitude: cellLon + BumpGrid.cellLonDeg / 2,
                mountedCount: m.count,
                mountedAverage: mAvg,
                pocketCount: p.count,
                pocketAverage: pAvg,
                ratio: ratio,
                qualifies: ratio != nil
            ))
        }

        // Top N cells by total sample count, descending — these are the most
        // statistically reliable comparison points.
        let topCells = allEntries
            .sorted { ($0.mountedCount + $0.pocketCount) > ($1.mountedCount + $1.pocketCount) }
            .prefix(50)
            .map { $0 }

        // Distribution stats across the *qualifying* cell ratios.
        let sortedRatios = ratios.sorted()
        let median = sortedRatios.isEmpty ? 1.0 : sortedRatios[sortedRatios.count / 2]
        let minR = sortedRatios.first ?? 0
        let maxR = sortedRatios.last ?? 0
        let mean = sortedRatios.isEmpty ? 0 : sortedRatios.reduce(0, +) / Double(sortedRatios.count)
        let variance = sortedRatios.isEmpty ? 0 :
            sortedRatios.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(sortedRatios.count)
        let stdDev = sqrt(variance)

        // Per-ride detector snapshots for the N most-recent rides.  `rides` is
        // expected newest-first from RideStore.  Skipping empty-points rides.
        var recentDetections: [CalibrationDiagnostics.RideDetectionSnapshot] = []
        for ride in rides.prefix(recentRidesLimit) {
            let result = MountStyleDetector.analyze(ride)
            recentDetections.append(CalibrationDiagnostics.RideDetectionSnapshot(
                rideId: ride.id,
                rideTitle: ride.title,
                startedAt: ride.startedAt,
                pocketMode: ride.pocketMode,
                schemaVersion: ride.schemaVersion,
                detectorVerdict: result?.verdict,
                detectorRatio: result?.ratio,
                cadenceRMS: result?.cadenceRMS,
                bumpRMS: result?.bumpRMS,
                samplesAnalyzed: result?.samplesAnalyzed
            ))
        }

        return CalibrationDiagnostics(
            computedAt: Date(),
            currentGain: calibration.pocketGain,
            currentConfidence: calibration.confidence,
            lastPersistedAt: calibration.lastComputed,
            unclampedMedian: ratios.count >= Self.minOverlappingCells ? median : nil,
            minRatio: ratios.isEmpty ? nil : minR,
            maxRatio: ratios.isEmpty ? nil : maxR,
            meanRatio: ratios.isEmpty ? nil : mean,
            stdDev: ratios.isEmpty ? nil : stdDev,
            totalMountedSamples: totalMountedSamples,
            totalPocketSamples: totalPocketSamples,
            totalCellsTouched: allKeys.count,
            cellsWithBothModes: cellsWithBothModes,
            qualifyingCells: ratios.count,
            topCells: topCells,
            recentDetections: recentDetections,
            thresholds: CalibrationDiagnostics.Thresholds(
                minSamplesPerMode: Self.minSamplesPerMode,
                minOverlappingCells: Self.minOverlappingCells,
                minPocketAvg: Self.minPocketAvg,
                minGain: Self.minGain,
                maxGain: Self.maxGain
            )
        )
    }

    // MARK: - Server sync

    /// If the server has a calibration backed by more overlapping cells than ours,
    /// adopt it.  This is the multi-device backfill path: a fresh install on an
    /// already-paired account starts with `confidence = 0`, so the server's value
    /// (set by another device) wins and bootstraps the new device.  When local has
    /// more confidence (because the user has accumulated more data on this device),
    /// the local value stays — our next push will update the server.
    ///
    /// Uses strict `>` so equal-confidence values keep local — avoids a thrash
    /// between two devices that have identical overlap counts but slightly different
    /// medians.
    func applyRemoteIfBetter(_ remote: WebSyncClient.ServerCalibration) {
        guard remote.confidence > calibration.confidence else { return }
        let adopted = PocketCalibration(
            pocketGain: remote.pocketGain,
            confidence: remote.confidence,
            lastComputed: remote.lastComputedAt
        )
        guard adopted != calibration else { return }
        calibration = adopted
        persist()
    }

    /// Snapshot the local calibration as the wire-format type — suitable for handing
    /// to `WebAccount.setCalibration`.
    func toServerCalibration() -> WebSyncClient.ServerCalibration {
        WebSyncClient.ServerCalibration(
            pocketGain: calibration.pocketGain,
            confidence: calibration.confidence,
            lastComputedAt: calibration.lastComputed
        )
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
