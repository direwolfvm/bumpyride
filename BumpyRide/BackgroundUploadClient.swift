import Foundation
import OSLog

/// v1.8 L2: ride uploads through a **background URLSessionConfiguration**,
/// so multi-MB transfers keep running after the user locks the screen or
/// leaves the app.  Field motivation: the v1.7 detector-revision bump
/// re-enqueued ~75 rides and the rider had to keep the app open with the
/// screen unlocked until the whole drain finished.
///
/// **How the drain keeps moving in the background**: uploads in a
/// background session run in the system's `nsurlsessiond` daemon,
/// independent of our process.  `SyncCoordinator.drain` still awaits
/// uploads one at a time — when the app suspends mid-drain, the
/// in-flight transfer continues in the daemon; on completion iOS
/// relaunches/resumes the app in the background
/// (`sessionSendsLaunchEvents`), our delegate resumes the awaiting
/// continuation, the loop enqueues the next ride, and the app suspends
/// again.  The queue advances task-by-task across background wakes
/// without the screen on.
///
/// **Process-death recovery**: if iOS kills the app mid-drain, the
/// in-flight transfer still completes in the daemon, but the awaiting
/// continuation is gone with the process — so the queue entry survives
/// even though the server got the ride.  That's converged on the next
/// launch: the drain's batch check (L1) sees the server's matching
/// content hash and prunes the entry without re-uploading.  Temp body
/// files are deleted in the completion delegate regardless of whether a
/// continuation is still around.
///
/// Background sessions require **file-based** uploads and **delegate**
/// callbacks (completion-handler / async APIs are unsupported for
/// background configurations) — hence the temp file + continuation
/// bridge instead of `session.data(for:)`.
@MainActor
final class BackgroundUploadClient: NSObject {
    static let shared = BackgroundUploadClient()

    /// Session identifier — also matched by `AppDelegate`'s
    /// `handleEventsForBackgroundURLSession` to route relaunch events
    /// back to this instance.
    static let sessionIdentifier = "com.herbertindustries.BumpyRide.upload"

    nonisolated private static let log = DebugLog(category: "bg-upload")

    /// Stored by `AppDelegate` when iOS relaunches us for background
    /// session events; called after the delegate finishes processing
    /// them so the system can snapshot + re-suspend the app.
    var backgroundCompletionHandler: (() -> Void)?

    private var session: URLSession!

    /// Awaiting continuations keyed by `taskIdentifier`.  Resumed with
    /// the HTTP status code + response body on completion, or thrown
    /// `WebSyncClient.ClientError.transport` on a transport error.
    private var continuations: [Int: CheckedContinuation<(status: Int, body: Data), Error>] = [:]

    /// v2.0 N1: response bodies accumulated per task.  The sync
    /// response now carries `achievementsAwarded`, so bodies are worth
    /// keeping.  Entries are removed in `finish` (all paths).
    private var responseBuffers: [Int: Data] = [:]

    override private init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        // Not discretionary — the user is actively waiting on sync;
        // don't let the system defer transfers to overnight charging.
        config.isDiscretionary = false
        // Relaunch the app in the background when transfers finish so
        // the drain loop can advance to the next ride.
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForRequest = 120
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// Upload `bodyFile` with `request` through the background session.
    /// Returns the HTTP status code + response body; throws
    /// `WebSyncClient.ClientError.transport` on transport failure.  The
    /// temp file is deleted by the completion delegate in all cases.
    func upload(request: URLRequest, bodyFile: URL) async throws -> (status: Int, body: Data) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.uploadTask(with: request, fromFile: bodyFile)
            // Stash the file path on the task so the completion
            // delegate can clean up even after a process relaunch
            // (when this dictionary no longer has the entry).
            task.taskDescription = bodyFile.path
            continuations[task.taskIdentifier] = continuation
            task.resume()
        }
    }

    /// Delegate completions hop here (MainActor) with pre-extracted
    /// Sendable values.
    /// v2.0 N1: append a chunk of response body for a task.
    private func bufferResponse(taskIdentifier: Int, chunk: Data) {
        responseBuffers[taskIdentifier, default: Data()].append(chunk)
    }

    private func finish(taskIdentifier: Int, status: Int?, transportFailed: Bool, bodyFilePath: String?) {
        if let path = bodyFilePath {
            try? FileManager.default.removeItem(atPath: path)
        }
        let body = responseBuffers.removeValue(forKey: taskIdentifier) ?? Data()
        guard let continuation = continuations.removeValue(forKey: taskIdentifier) else {
            // Process was relaunched after the awaiting drain died —
            // the queue entry reconciles via the next drain's batch
            // check.  Nothing to resume; the file cleanup above is the
            // useful work.
            Self.log.notice("Background upload task \(taskIdentifier) completed with no awaiting continuation (relaunch) — status \(status.map(String.init) ?? "n/a")")
            return
        }
        if transportFailed || status == nil {
            continuation.resume(throwing: WebSyncClient.ClientError.transport)
        } else {
            continuation.resume(returning: (status: status!, body: body))
        }
    }
}

extension BackgroundUploadClient: URLSessionTaskDelegate, URLSessionDataDelegate, URLSessionDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        // v2.0 N1: upload tasks deliver their response body here.
        // Extract Sendable values, hop, accumulate.
        let id = dataTask.taskIdentifier
        Task { @MainActor in
            self.bufferResponse(taskIdentifier: id, chunk: data)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        // Extract Sendable values before hopping to the MainActor.
        let id = task.taskIdentifier
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let failed = error != nil
        let filePath = task.taskDescription
        if let error {
            Self.log.notice("Background upload task \(id) transport error: \(String(describing: error))")
        }
        Task { @MainActor in
            self.finish(taskIdentifier: id, status: status, transportFailed: failed, bodyFilePath: filePath)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // All queued events for a background relaunch have been
        // delivered — tell the system we're done so it can snapshot
        // and re-suspend.  Must be called on the main thread.
        Task { @MainActor in
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}
