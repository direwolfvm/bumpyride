import Foundation
import os.log

/// A thin façade over `os.Logger` that optionally fans out each line
/// to `DebugLogSink` (which writes to a sidecar file in iCloud).
///
/// Call sites use the same `subsystem`/`category` pair they'd use for
/// `Logger`, but make the calls through this type instead.  When the
/// user's "Write Debug Log" toggle is off, the overhead vs. a bare
/// `Logger` is one Bool read per call.  When it's on, an actor task
/// is enqueued to write the line — non-blocking on the calling
/// thread.
///
/// API choice: each method takes a plain `String` rather than a
/// `Logger`-style format string with `privacy:` annotations.  Plain
/// String fits our use case (no PII flows through these paths) and
/// gives us full control over what lands in the sidecar file.  The
/// underlying `Logger` call interpolates the message with
/// `privacy: .public` so Console.app still shows the full text.
///
/// **Why not just tap `OSLogStore`?**  iOS apps can't read the
/// unified log stream without the `com.apple.developer.os-log`
/// entitlement, which Apple doesn't grant to third-party apps.  So
/// the only way to capture log lines into a user-accessible file is
/// to intercept them at the call site — hence this façade.
struct DebugLog: Sendable {
    let logger: Logger
    let category: String

    // `nonisolated` so a `nonisolated private static let log = DebugLog(...)`
    // declaration in a `@MainActor`-bound class (like HealthKitExporter)
    // compiles without the "implicitly async cross-actor call" warning.
    // Logger's own init is nonisolated; we're just propagating that.
    nonisolated init(category: String) {
        self.logger = Logger(subsystem: "com.herbertindustries.BumpyRide", category: category)
        self.category = category
    }

    func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        if DebugLogSink.enabled {
            let cat = category
            Task { await DebugLogSink.shared.append(level: .debug, category: cat, message: message) }
        }
    }

    func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        if DebugLogSink.enabled {
            let cat = category
            Task { await DebugLogSink.shared.append(level: .info, category: cat, message: message) }
        }
    }

    func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        if DebugLogSink.enabled {
            let cat = category
            Task { await DebugLogSink.shared.append(level: .notice, category: cat, message: message) }
        }
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        if DebugLogSink.enabled {
            let cat = category
            Task { await DebugLogSink.shared.append(level: .error, category: cat, message: message) }
        }
    }
}
