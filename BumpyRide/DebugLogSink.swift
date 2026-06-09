import Foundation
import os.log

/// On-disk sidecar for our debug logs.  When `AppSettings.debugLogEnabled`
/// is on, every `DebugLog` call writes its line to a plain-text file in
/// the iCloud Rides directory in addition to the normal `os.Logger`
/// stream.  Reading the file off the user's iCloud Drive lets us
/// diagnose field issues without needing the device wired to a Mac
/// running Console.app.
///
/// Two file scopes, switched by `bindRide(_:)` / `unbindRide()`:
///
///   • **Per-ride file** — `<rideId>-debug.log` lives next to
///     `<rideId>.json`.  Captures everything from `RideRecorder.start`
///     to `RideRecorder.stop`/`reset` (and the export immediately after,
///     since callers can keep the binding through save).
///
///   • **Session file** — `session-YYYY-MM-DD.log` in the same folder.
///     Captures events outside an active recording: app launch,
///     sync drains, "Add to Fitness" on a saved ride, edits in the
///     viewer, settings changes.
///
/// The sink is a serial actor so concurrent log calls don't interleave
/// mid-line; each `append` hops to the actor before touching the file
/// handle.  `Self.enabled` is a `nonisolated` snapshot of the toggle
/// state checked on the caller's thread first, so logging from a hot
/// path (e.g., per-GPS-fix) is a near-zero-cost no-op when the toggle
/// is off.
///
/// At `configure(directory:)` time we also garbage-collect log files
/// older than 14 days from the directory — keeps the user's iCloud
/// from drifting toward unbounded growth if they leave the toggle
/// on for months.
actor DebugLogSink {
    static let shared = DebugLogSink()

    /// Mirror of `AppSettings.debugLogEnabled`.  Updated by AppSettings's
    /// `didSet`.  Lives outside the actor so callers can short-circuit
    /// without an actor hop — the per-append cost when the toggle is
    /// off is a single atomic Bool read.
    ///
    /// `nonisolated(unsafe)` is correct here: it's a single Bool that
    /// flips at most a handful of times per app session (the user
    /// toggling the setting), and torn reads on a Bool aren't a
    /// hazard.  Doing the actor-isolated dance would force every
    /// log site into a Task boundary, which defeats the point of
    /// "near-zero cost when off."
    nonisolated(unsafe) static var enabled: Bool = false

    /// Log severity levels — same buckets as `os.Logger`.  Each maps
    /// to a 3-char tag in the file format so lines stay grep-friendly:
    /// `2026-06-09T13:01:23.412Z [INF] [healthkit-export] Starting export of ride …`.
    enum Level: String {
        case debug = "DBG"
        case info = "INF"
        case notice = "NOT"
        case error = "ERR"
    }

    private var directory: URL?
    private var activeRideId: UUID?
    private var fileHandle: FileHandle?
    private var currentFilename: String?

    /// Used for the leading timestamp on every line.  ISO 8601 with
    /// fractional seconds gives both human-readable ordering and
    /// enough precision to align with `os.Logger` Console output if
    /// the user cross-references.
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Set the directory to write logs into.  Called once at app
    /// startup after `CloudStorage` resolves its `ridesDirectoryURL`.
    /// Safe to call again later (e.g., if iCloud comes online mid-
    /// session) — closes the existing file and reopens against the
    /// new directory.
    ///
    /// Also runs a one-shot garbage collection of `.log` files older
    /// than 14 days in that directory.
    func configure(directory: URL) {
        self.directory = directory
        garbageCollectOldLogs(in: directory)
        rotate()
    }

    /// Switch the sink to per-ride mode for the given ride.  Subsequent
    /// `append`s land in `<rideId>-debug.log`.  Called from
    /// `RideRecorder.start` with the freshly-minted ride id.
    func bindRide(_ id: UUID) {
        activeRideId = id
        rotate()
    }

    /// Switch back to session mode.  Called from `RideRecorder.stop`
    /// and `reset`.  After this, lines land in `session-YYYY-MM-DD.log`
    /// until the next `bindRide`.
    func unbindRide() {
        activeRideId = nil
        rotate()
    }

    /// Append one line to the active file.  Called via the `DebugLog`
    /// façade.  No-op when `Self.enabled` is false — the caller already
    /// short-circuited at the call site, so reaching here means the
    /// toggle was on at append time.
    func append(level: Level, category: String, message: String) {
        guard let fileHandle else { return }
        let ts = Self.isoFormatter.string(from: Date())
        let line = "\(ts) [\(level.rawValue)] [\(category)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        do {
            try fileHandle.write(contentsOf: data)
        } catch {
            // Can't log a logger failure (would recurse).  Swallow —
            // the os.Logger side of DebugLog still captured the
            // message, and reopening on the next rotate() is the
            // self-heal path.
        }
    }

    // MARK: - Internals

    /// Close the active handle and (re)open the file dictated by the
    /// current `activeRideId` / `directory` state.  Idempotent.  Safe
    /// when `directory` is nil — leaves the handle nil, so subsequent
    /// appends become no-ops until `configure` lands a directory.
    private func rotate() {
        try? fileHandle?.close()
        fileHandle = nil
        currentFilename = nil
        guard let directory else { return }
        let filename: String
        if let id = activeRideId {
            filename = "\(id.uuidString)-debug.log"
        } else {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            filename = "session-\(f.string(from: Date())).log"
        }
        let url = directory.appendingPathComponent(filename)
        // Create the file if it doesn't exist (FileHandle(forWritingTo:)
        // requires an existing path; "" gives us an empty 0-byte file).
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            fileHandle = handle
            currentFilename = filename
        } catch {
            // Can't open the file — sink degrades to os.Logger-only,
            // which is still useful.  No log of the failure (would
            // recurse).
        }
    }

    /// Delete any `.log` files older than 14 days from `directory`.
    /// Per-ride logs accumulate one per ride; session logs accumulate
    /// one per day.  At several hundred KB each, a year of unbounded
    /// growth would chew through iCloud storage for no diagnostic
    /// benefit (we never look at week-old logs in practice).
    ///
    /// Best-effort: errors per file are silently skipped so one
    /// permission-weird file doesn't block the rest.
    private func garbageCollectOldLogs(in directory: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-14 * 24 * 60 * 60)
        for url in contents where url.pathExtension == "log" {
            let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            guard let modified = resourceValues?.contentModificationDate, modified < cutoff else { continue }
            try? fm.removeItem(at: url)
        }
    }
}
