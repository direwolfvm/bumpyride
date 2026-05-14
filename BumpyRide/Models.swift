import Foundation
import CoreLocation

/// A single sample emitted while recording a ride: GPS position, the current
/// bumpiness RMS at the time of sampling, and a snapshot of the recent vertical
/// acceleration window (used to redraw the seismograph during playback).
///
/// The JSON wire-format keys are locked via the explicit `CodingKeys` enum so
/// downstream consumers (server, exports) don't break if a Swift property is
/// renamed during a refactor.  See `docs/SCHEMA.md` for the field-by-field spec.
struct RidePoint: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var timestamp: Date
    var latitude: Double
    var longitude: Double
    var speed: Double
    var bumpiness: Double
    var accelWindow: [Float]

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case latitude
        case longitude
        case speed
        case bumpiness
        case accelWindow
    }
}

/// A complete saved ride: title, time bounds, ordered points, and the sensing mode
/// that was active when it was recorded.  Provides derived metrics (distance, max
/// and average bumpiness) plus pure-functional `trimmed` and `split` helpers used
/// by the editor.
///
/// The JSON wire-format keys are locked via the explicit `CodingKeys` enum, and the
/// custom `init(from:)` supplies sensible defaults for fields that didn't exist in
/// earlier on-disk records (`schemaVersion` → 1, `pocketMode` → nil), so old files
/// keep decoding after schema additions.  See `docs/SCHEMA.md`.
struct Ride: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var startedAt: Date
    var endedAt: Date
    var points: [RidePoint]
    /// Whether the high-pass "pocket mode" filter was active when this ride was recorded.
    /// `nil` for rides recorded before the field existed.  Trim/split ops preserve the
    /// tag because they copy the whole struct (`var copy = self`).
    var pocketMode: Bool?
    /// Wire-format schema version.  Records on disk that predate the version field
    /// decode as `1` via the custom `init(from:)`.
    ///
    /// `1` — `accelWindow` was post-filter when `pocketMode == true` (the high-pass
    /// ran live during recording); raw otherwise.  `bumpiness` was RMS of the same.
    ///
    /// `2` — `accelWindow` is always raw vertical acceleration.  `bumpiness` is the
    /// raw RMS at recording time, but is recomputed via `reprocessedWithPocketHPF()`
    /// at save time / on retag when `pocketMode == true`, applying the HPF to the
    /// raw window before taking RMS.  Lets us decide mode after the fact and retag
    /// either direction without information loss.
    var schemaVersion: Int

    init(
        id: UUID = UUID(),
        title: String,
        startedAt: Date,
        endedAt: Date,
        points: [RidePoint],
        pocketMode: Bool? = nil,
        schemaVersion: Int = 2
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.points = points
        self.pocketMode = pocketMode
        self.schemaVersion = schemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case startedAt
        case endedAt
        case points
        case pocketMode
        case schemaVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.startedAt = try c.decode(Date.self, forKey: .startedAt)
        self.endedAt = try c.decode(Date.self, forKey: .endedAt)
        self.points = try c.decode([RidePoint].self, forKey: .points)
        self.pocketMode = try c.decodeIfPresent(Bool.self, forKey: .pocketMode)
        // Records written before schemaVersion existed are treated as v1 — the format
        // they were emitted in.
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    }

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    var distanceMeters: Double {
        guard points.count > 1 else { return 0 }
        var total: Double = 0
        for i in 1..<points.count {
            let a = CLLocation(latitude: points[i-1].latitude, longitude: points[i-1].longitude)
            let b = CLLocation(latitude: points[i].latitude, longitude: points[i].longitude)
            total += b.distance(from: a)
        }
        return total
    }

    var maxBumpiness: Double {
        points.map(\.bumpiness).max() ?? 0
    }

    var averageBumpiness: Double {
        guard !points.isEmpty else { return 0 }
        return points.map(\.bumpiness).reduce(0, +) / Double(points.count)
    }

    static func defaultTitle(for date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return "Ride \(f.string(from: date))"
    }

    func trimmed(startIndex: Int, endIndex: Int) -> Ride {
        let lo = max(0, min(points.count - 1, startIndex))
        let hi = max(lo, min(points.count - 1, endIndex))
        let slice = Array(points[lo...hi])
        var copy = self
        copy.points = slice
        copy.startedAt = slice.first?.timestamp ?? startedAt
        copy.endedAt = slice.last?.timestamp ?? endedAt
        return copy
    }

    func split(at index: Int) -> (first: Ride, second: Ride)? {
        guard index > 0, index < points.count - 1 else { return nil }
        var first = self
        first.points = Array(points[0..<index])
        first.endedAt = first.points.last?.timestamp ?? endedAt

        var second = self
        second.id = UUID()
        second.points = Array(points[index..<points.count])
        second.startedAt = second.points.first?.timestamp ?? startedAt
        second.endedAt = second.points.last?.timestamp ?? endedAt
        second.title = title + " (part 2)"
        first.title = title + " (part 1)"
        return (first, second)
    }

    /// Return a copy of this Ride with each point's `bumpiness` recomputed as the
    /// RMS of the last 1 s of an HPF'd version of its `accelWindow`.  This is the
    /// pocket-mode bumpiness — what the value would have been if the 3 Hz HPF had
    /// run live during recording.
    ///
    /// Safe for **v2** rides where `accelWindow` is raw.  For **v1** rides where
    /// `accelWindow` was already filtered at recording time (when `pocketMode` was
    /// true), this re-filters already-filtered data and is a slight distortion —
    /// callers should gate on `schemaVersion >= 2` before applying.
    ///
    /// Doesn't touch `accelWindow` itself, so the raw signal is preserved on disk
    /// for any future re-tagging in either direction.
    func reprocessedWithPocketHPF() -> Ride {
        let sampleRateHz: Double = 50.0
        let cutoffHz: Double = 3.0
        let rmsTailSamples: Int = 50  // last 1 s — matches live computation in MotionManager

        var copy = self
        for i in copy.points.indices {
            let window = copy.points[i].accelWindow
            guard !window.isEmpty else { continue }
            var filter = Biquad.butterworthHighPass(cutoffHz: cutoffHz, sampleRateHz: sampleRateHz)
            var filtered: [Float] = []
            filtered.reserveCapacity(window.count)
            for s in window {
                filtered.append(Float(filter.process(Double(s))))
            }
            let tail = filtered.suffix(rmsTailSamples)
            var sumSq: Double = 0
            for s in tail { sumSq += Double(s) * Double(s) }
            let rms = sqrt(sumSq / Double(max(tail.count, 1)))
            copy.points[i].bumpiness = rms
        }
        return copy
    }

    /// Inverse of `reprocessedWithPocketHPF` — recompute `bumpiness` as the raw RMS
    /// of each `accelWindow` (no filtering).  Used when retagging a v2 ride from
    /// pocket back to mounted.  No-op for v1 rides since their `accelWindow` was
    /// already filtered (we can't undo that); callers should gate on `schemaVersion >= 2`.
    func reprocessedAsMounted() -> Ride {
        let rmsTailSamples: Int = 50
        var copy = self
        for i in copy.points.indices {
            let window = copy.points[i].accelWindow
            guard !window.isEmpty else { continue }
            let tail = window.suffix(rmsTailSamples)
            var sumSq: Double = 0
            for s in tail { sumSq += Double(s) * Double(s) }
            let rms = sqrt(sumSq / Double(max(tail.count, 1)))
            copy.points[i].bumpiness = rms
        }
        return copy
    }
}
