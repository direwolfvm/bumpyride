import Foundation
import CoreLocation

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
}

struct Ride: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var startedAt: Date
    var endedAt: Date
    var points: [RidePoint]
    /// Whether the high-pass "pocket mode" filter was active when this ride was recorded.
    /// Optional so older saved rides (recorded before the field existed) decode cleanly as
    /// `nil`, which we treat as "unknown / pre-filter".  Trim/split ops preserve the tag
    /// because they copy the whole struct (`var copy = self`).
    var pocketMode: Bool? = nil

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
