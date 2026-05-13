import Foundation
import Observation

/// Persistent record of which rides still need to be uploaded to bumpyride.me.
///
/// Kept deliberately small and orthogonal to the ride wire format: it's a flat list of
/// `Ride.id` UUIDs in `<Documents>/Sync/queue.json`.  The contents of each ride live in
/// `RideStore`; this just remembers which ones haven't been confirmed by the server yet.
///
/// Survives crashes, force-quits, and reboots — so pending uploads resume on the next
/// launch.  Writes are atomic per modification; volume is low enough (one write per
/// ride save / successful upload) that we don't need to debounce.
@Observable
final class SyncQueue {
    /// Snapshot of unsynced ride IDs.  Mutate via the methods below; setting this
    /// directly bypasses persistence.
    private(set) var ids: Set<UUID> = []

    private let fileURL: URL

    init(directory: URL = SyncQueue.defaultDirectory) {
        let dir = directory.appendingPathComponent("Sync", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("queue.json")
        load()
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }

    func contains(_ id: UUID) -> Bool { ids.contains(id) }

    func insert(_ id: UUID) {
        guard !ids.contains(id) else { return }
        ids.insert(id)
        persist()
    }

    func remove(_ id: UUID) {
        guard ids.contains(id) else { return }
        ids.remove(id)
        persist()
    }

    /// Snapshot of the queued IDs as an array, in arbitrary order.  Callers that want
    /// chronological ordering should look the rides up in `RideStore` and sort by
    /// `startedAt`.
    func all() -> [UUID] { Array(ids) }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([UUID].self, from: data) {
            ids = Set(decoded)
        }
    }

    private func persist() {
        let array = Array(ids)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(array) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
