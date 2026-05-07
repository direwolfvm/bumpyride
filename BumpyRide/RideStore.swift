import Foundation
import Observation

@Observable
final class RideStore {
    private(set) var rides: [Ride] = []

    private let directoryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        directoryURL = docs.appendingPathComponent("Rides", isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        load()
    }

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil))
            ?? []
        var loaded: [Ride] = []
        for url in files where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               let ride = try? decoder.decode(Ride.self, from: data) {
                loaded.append(ride)
            }
        }
        rides = loaded.sorted { $0.startedAt > $1.startedAt }
    }

    func save(_ ride: Ride) {
        let url = directoryURL.appendingPathComponent("\(ride.id.uuidString).json")
        do {
            let data = try encoder.encode(ride)
            try data.write(to: url, options: .atomic)
            if let idx = rides.firstIndex(where: { $0.id == ride.id }) {
                rides[idx] = ride
            } else {
                rides.insert(ride, at: 0)
                rides.sort { $0.startedAt > $1.startedAt }
            }
        } catch {
        }
    }

    func delete(_ ride: Ride) {
        let url = directoryURL.appendingPathComponent("\(ride.id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
        rides.removeAll { $0.id == ride.id }
    }

    func rename(_ ride: Ride, to title: String) {
        var updated = ride
        updated.title = title
        save(updated)
    }
}
