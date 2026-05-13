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
    /// Wire-format schema version.  Currently always 1.  Records on disk that predate
    /// the version field decode as `1` via the custom `init(from:)`.  When a future
    /// version makes a breaking change to the JSON shape, bump this and add a migration
    /// path in `init(from:)` that handles the older version.
    var schemaVersion: Int

    init(
        id: UUID = UUID(),
        title: String,
        startedAt: Date,
        endedAt: Date,
        points: [RidePoint],
        pocketMode: Bool? = nil,
        schemaVersion: Int = 1
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
}
