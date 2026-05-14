import Foundation
import OSLog

/// On-disk append-only journal of an in-progress ride.  Defensive layer against
/// the case where the app gets force-killed (memory pressure, user force-quit,
/// crash) mid-recording — without this, the in-memory `RideRecorder.points`
/// array is lost the moment the process dies, and the user loses the whole ride.
///
/// Each `RidePoint` emitted by `RideRecorder.handleLocation` is also appended to
/// `<Documents>/Recording/points.ndjson` as a single JSON-encoded line.  At app
/// launch, `loadRecoverable()` checks for a non-empty journal and lets the user
/// decide whether to recover or discard.
///
/// One in-progress journal at a time.  `start(...)` wipes any previous journal.
/// `clear()` is called on successful save, discard, or `recorder.reset()`.
@MainActor
final class RideJournal {
    private static let log = Logger(subsystem: "com.herbertindustries.BumpyRide", category: "journal")

    private let directory: URL
    private let headerURL: URL
    private let pointsURL: URL

    private var fileHandle: FileHandle?
    private let encoder: JSONEncoder

    /// Header file content: ride identity + metadata that doesn't change during recording.
    struct Header: Codable {
        let rideId: UUID
        let startedAt: Date
        let schemaVersion: Int
    }

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.directory = docs.appendingPathComponent("Recording", isDirectory: true)
        self.headerURL = directory.appendingPathComponent("header.json")
        self.pointsURL = directory.appendingPathComponent("points.ndjson")
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
    }

    /// Open a fresh journal for a new recording.  Wipes any previous journal first.
    /// Errors thrown if the FS won't cooperate — caller should log but proceeding
    /// without a journal is acceptable (the recording still happens in memory).
    func start(rideId: UUID, startedAt: Date, schemaVersion: Int) throws {
        clear()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let header = Header(rideId: rideId, startedAt: startedAt, schemaVersion: schemaVersion)
        let headerData = try encoder.encode(header)
        try headerData.write(to: headerURL, options: .atomic)

        FileManager.default.createFile(atPath: pointsURL.path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: pointsURL)
        Self.log.info("Journal opened for ride \(rideId, privacy: .public)")
    }

    /// Append one point's JSON to the journal.  Best-effort — disk errors are
    /// logged but not propagated; the live in-memory recording is what matters.
    func append(_ point: RidePoint) {
        guard let fileHandle else { return }
        do {
            let data = try encoder.encode(point)
            try fileHandle.write(contentsOf: data)
            try fileHandle.write(contentsOf: Data([0x0A]))  // newline separator
        } catch {
            Self.log.error("Journal append failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Close the file handle.  Leaves the journal on disk so a `clear()` is still
    /// required to fully remove it.  Called from `RideRecorder.stop()` when the
    /// save sheet appears — the in-memory ride is now the source of truth.
    func close() {
        do {
            try fileHandle?.close()
        } catch {
            Self.log.error("Journal close failed: \(error.localizedDescription, privacy: .public)")
        }
        fileHandle = nil
    }

    /// Remove the journal entirely.  Called after save / discard / reset.  Safe
    /// to call when no journal exists.
    func clear() {
        close()
        if FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.removeItem(at: directory)
                Self.log.info("Journal cleared")
            } catch {
                Self.log.error("Journal clear failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Recovery (static, called from app launch)

    /// Result of a successful recovery: parsed header + non-empty points list.
    struct Recoverable {
        let header: Header
        let points: [RidePoint]
    }

    /// Check for a recoverable journal on disk.  Returns `nil` if no journal
    /// exists, if the header is unparseable, or if the points file is missing
    /// or empty.  Doesn't delete anything — caller decides via the recovery UX.
    static func loadRecoverable() -> Recoverable? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("Recording")
        let headerURL = dir.appendingPathComponent("header.json")
        let pointsURL = dir.appendingPathComponent("points.ndjson")

        guard let headerData = try? Data(contentsOf: headerURL) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let header = try? decoder.decode(Header.self, from: headerData) else {
            log.error("Found journal header but it didn't decode — leaving on disk for inspection")
            return nil
        }

        guard let pointsData = try? Data(contentsOf: pointsURL), !pointsData.isEmpty else {
            // Header but no points — barely-started ride, not worth recovering
            return nil
        }

        var points: [RidePoint] = []
        var failedLines = 0
        for line in pointsData.split(separator: 0x0A) where !line.isEmpty {
            if let point = try? decoder.decode(RidePoint.self, from: line) {
                points.append(point)
            } else {
                failedLines += 1
            }
        }

        if failedLines > 0 {
            log.error("Journal recovery: \(failedLines, privacy: .public) lines failed to decode, \(points.count, privacy: .public) recovered")
        } else {
            log.info("Journal recovery: \(points.count, privacy: .public) points loaded")
        }

        guard !points.isEmpty else { return nil }
        return Recoverable(header: header, points: points)
    }

    /// Delete any existing journal without going through the instance.  Used by
    /// `ContentView`'s recovery UI's Discard action when we don't want to spin
    /// up an instance just to clear.
    static func clearAny() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("Recording")
        if FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.removeItem(at: dir)
        }
    }
}
