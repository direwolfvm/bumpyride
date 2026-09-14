import Foundation
import CryptoKit
import MetricKit
import OSLog

/// v2.1 T6: field energy telemetry via MetricKit.
///
/// iOS aggregates per-app power and performance data on the device and
/// delivers it once a day as an `MXMetricPayload` covering the previous
/// 24 h.  The parts that matter for a GPS recorder are all in there:
///
/// - `locationActivityMetrics` — cumulative time the app had location
///   running at each accuracy tier (best-for-navigation, best, 10 m,
///   100 m, 1 km, 3 km).  This is the number that tells us whether
///   location is on when it shouldn't be.
/// - `applicationTimeMetrics` — foreground vs background runtime.
/// - `cpuMetrics`, `networkTransferMetrics`, `diskIOMetrics`.
///
/// Payloads are written verbatim (Apple's own JSON representation) to the
/// rides directory as `metrics-<date>-<hash>.json`, next to the ride files
/// and the debug-log sidecar, so they sync through iCloud and can be pulled
/// off the Mac for analysis.  Diagnostics (crashes, hangs, CPU exceptions)
/// land as `diagnostics-<date>-<hash>.json`.
///
/// **Why the content hash is in the filename.**  iOS can deliver several
/// payloads at once, and more than one can share a `timeStampEnd` date —
/// in particular a rich daily aggregate and a near-empty disk-only payload.
/// Keying the filename on the date alone let the empty one overwrite the
/// aggregate, which is exactly what happened to the 5–9 September payloads
/// on build 30: only the one-line digests in the session log survived.
/// Hashing the payload makes every distinct payload its own file and makes
/// a re-delivery of the same payload idempotent rather than duplicative.
///
/// Gated on the same Settings › Diagnostics toggle as the debug log:
/// nothing is written unless the rider has opted in.  Delivery only
/// happens on a real device — the simulator never produces payloads.
@MainActor
final class EnergyMetricsCollector: NSObject, MXMetricManagerSubscriber {
    private static let log = Logger(subsystem: "com.herbertindustries.BumpyRide", category: "metrics")
    private static let debug = DebugLog(category: "metrics")
    /// Payload files older than this are pruned on each delivery.
    private static let retentionDays = 60

    private let directory: URL

    init(directory: URL) {
        self.directory = directory
        super.init()
        MXMetricManager.shared.add(self)
        Self.log.info("subscribed; \(MXMetricManager.shared.pastPayloads.count) past payload(s) available")
    }

    // MXMetricManagerSubscriber callbacks arrive off the main thread.
    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        let items = payloads.map { ($0.timeStampEnd, $0.jsonRepresentation(), Self.summary(of: $0)) }
        Task { @MainActor in self.write(items, prefix: "metrics") }
    }

    /// Short content hash used to keep distinct payloads in distinct files.
    nonisolated private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let items = payloads.map { ($0.timeStampEnd, $0.jsonRepresentation(), "diagnostic payload") }
        Task { @MainActor in self.write(items, prefix: "diagnostics") }
    }

    private func write(_ items: [(Date, Data, String)], prefix: String) {
        guard DebugLogSink.enabled else {
            Self.log.info("\(items.count) \(prefix) payload(s) received; debug log off, not written")
            return
        }
        let dir = directory
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"; fmt.timeZone = .current
        for (end, data, summary) in items {
            let name = "\(prefix)-\(fmt.string(from: end))-\(Self.digest(data)).json"
            let url = dir.appendingPathComponent(name)
            // Re-delivery of an identical payload lands on the same path, so
            // this stays a no-op rather than piling up duplicates.
            if FileManager.default.fileExists(atPath: url.path) {
                Self.log.info("\(name) already stored; skipping")
                continue
            }
            Self.debug.info("\(prefix) payload → \(name): \(summary)")
            Task.detached(priority: .utility) {
                try? data.write(to: url, options: .atomic)
            }
        }
        Task.detached(priority: .utility) { Self.prune(in: dir) }
    }

    /// One-line digest for the debug log, so the sidecar shows the headline
    /// numbers without opening the JSON.
    nonisolated private static func summary(of p: MXMetricPayload) -> String {
        var parts: [String] = []
        if let t = p.applicationTimeMetrics {
            parts.append(String(format: "fg %.0fmin bg %.0fmin",
                                t.cumulativeForegroundTime.converted(to: .minutes).value,
                                t.cumulativeBackgroundTime.converted(to: .minutes).value))
        }
        if let l = p.locationActivityMetrics {
            parts.append(String(format: "loc best %.0fmin nav %.0fmin 10m %.0fmin 100m %.0fmin",
                                l.cumulativeBestAccuracyTime.converted(to: .minutes).value,
                                l.cumulativeBestAccuracyForNavigationTime.converted(to: .minutes).value,
                                l.cumulativeNearestTenMetersAccuracyTime.converted(to: .minutes).value,
                                l.cumulativeHundredMetersAccuracyTime.converted(to: .minutes).value))
        }
        if let c = p.cpuMetrics {
            parts.append(String(format: "cpu %.0fs", c.cumulativeCPUTime.converted(to: .seconds).value))
        }
        if let g = p.gpuMetrics {
            parts.append(String(format: "gpu %.0fs", g.cumulativeGPUTime.converted(to: .seconds).value))
        }
        if let m = p.memoryMetrics {
            // v2.1 U9: suspended memory matters more than the peak here.
            //
            // The peak is a foreground high-water mark; it has never produced a
            // foreground exit (zero across every payload so far) and it tracks
            // foreground time almost exactly — 344 MB on a 574 s day against
            // 558 MB on a 7840 s one — which is MapKit's tile cache growing
            // with how much map got panned, not our data. Background jetsam,
            // which is what has actually been killing the app (7 memory-pressure
            // exits over five days), is governed by the *suspended* footprint
            // instead. That is the figure worth watching for drift.
            parts.append(String(format: "peakMem %.0fMB suspendedMem %.0fMB",
                                m.peakMemoryUsage.converted(to: .megabytes).value,
                                m.averageSuspendedMemory.averageMeasurement.converted(to: .megabytes).value))
        }
        if let n = p.networkTransferMetrics {
            parts.append(String(format: "up cell %.0fMB wifi %.0fMB",
                                n.cumulativeCellularUpload.converted(to: .megabytes).value,
                                n.cumulativeWifiUpload.converted(to: .megabytes).value))
        }
        if let e = p.applicationExitMetrics?.backgroundExitData {
            let bad = e.cumulativeMemoryPressureExitCount + e.cumulativeAbnormalExitCount
                + e.cumulativeBadAccessExitCount + e.cumulativeIllegalInstructionExitCount
            if bad > 0 {
                parts.append("bgExits mem=\(e.cumulativeMemoryPressureExitCount) other=\(bad - e.cumulativeMemoryPressureExitCount)")
            }
        }
        parts.append("[\(p.timeStampBegin)→\(p.timeStampEnd)]")
        return parts.isEmpty ? "no headline metrics" : parts.joined(separator: " · ")
    }

    nonisolated private static func prune(in dir: URL) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        for u in urls where u.lastPathComponent.hasPrefix("metrics-") || u.lastPathComponent.hasPrefix("diagnostics-") {
            if let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, d < cutoff {
                try? fm.removeItem(at: u)
            }
        }
    }
}
