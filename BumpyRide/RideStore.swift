import Foundation
import Observation
import OSLog

/// On-disk persistence for saved rides: one ISO-8601 JSON file per ride at
/// `<Documents>/Rides/<UUID>.json`.  Loads everything into memory at init (rides are
/// small; thousands fit comfortably) and keeps `rides` sorted newest-first for the UI.
@Observable
final class RideStore {
    private(set) var rides: [Ride] = []

    /// Fired after every successful `save(_:)` write — whether for a brand-new ride or
    /// an in-place update from rename / trim / split.  `ContentView` wires this to
    /// `SyncCoordinator.enqueue(_:)` + `kick()` so the upload path doesn't have to
    /// reach into `RideStore` itself.
    var onRideSaved: ((Ride) -> Void)?

    /// Fired after `delete(_:)` removes a ride from disk.  Wired to
    /// `SyncCoordinator.remove(_:)` so we don't waste a network round trip uploading
    /// something the user already deleted locally.
    var onRideDeleted: ((UUID) -> Void)?

    /// Fired when `save(_:)` fails to write the ride to disk.  Unwired by default —
    /// callers (typically the view that just initiated the save) can attach a
    /// handler to surface an alert.  Failure is rare (disk full, IO error, sandbox
    /// permission revoked) but historically silent; this hook makes it actionable.
    var onSaveFailed: ((Ride, any Error) -> Void)?

    private static let log = Logger(subsystem: "com.herbertindustries.BumpyRide", category: "ridestore")

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
            onRideSaved?(ride)
        } catch {
            // Silent save failure has historically been the worst failure mode of
            // this app — the ride looks saved but isn't on disk.  Log loudly via
            // OSLog (visible in Console.app) and surface to whoever wired up
            // onSaveFailed, so future versions can show a banner.  The in-memory
            // rides array is left unchanged so the rest of the app behaves
            // consistently with disk state.
            Self.log.error("Failed to save ride \(ride.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            onSaveFailed?(ride, error)
        }
    }

    func delete(_ ride: Ride) {
        let url = directoryURL.appendingPathComponent("\(ride.id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
        rides.removeAll { $0.id == ride.id }
        onRideDeleted?(ride.id)
    }

    func rename(_ ride: Ride, to title: String) {
        var updated = ride
        updated.title = title
        save(updated)
    }
}
