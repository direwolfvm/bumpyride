import Foundation
import Observation
import OSLog

/// Resolves where rides should be stored on disk and migrates legacy data
/// into iCloud when it becomes available.
///
/// Two storage modes, chosen at init time based on what the OS will give us:
///
/// - **iCloud Documents** — the app's ubiquity container's `Documents/Rides/`
///   folder.  Visible to the user in Files app under iCloud Drive → BumpyRide.
///   Auto-syncs across the user's devices; survives app delete + reinstall
///   (the container persists; reinstalling the app re-attaches to it and the
///   data reappears).
/// - **Local Documents** — the app sandbox's `Documents/Rides/` folder.  Same
///   path BumpyRide has used since v1.0.  Used as a fallback when iCloud
///   isn't available (user signed out of iCloud, iCloud Drive off, no
///   ubiquity container entitlement, etc.).
///
/// The "Silent fallback to local" policy means we never refuse to save a
/// ride.  Worst case the user loses their backup story; the recording itself
/// always works.
///
/// **Migration** is automatic and one-shot per local file: on launch, if
/// iCloud is available *and* any rides exist in local Documents, they're
/// copied to iCloud and the local copies removed.  Safe to re-run — already-
/// migrated files are skipped via existence check, not a "migration done"
/// flag, so if the user briefly loses iCloud and saves locally, the next
/// iCloud-available launch picks those up too.
///
/// **Xcode setup required** before iCloud can actually be reached: in
/// project settings → Signing & Capabilities → + Capability → iCloud → check
/// iCloud Documents → add container `iCloud.com.herbertindustries.BumpyRide`.
/// Without that, `url(forUbiquityContainerIdentifier:)` returns nil and we
/// silently use local storage.
@Observable
@MainActor
final class CloudStorage {
    /// The container identifier registered with Apple Developer + checked in
    /// Xcode's iCloud capability.  Convention: `iCloud.<bundle-id>`.  Hard-
    /// coded rather than parameterized because we ship exactly one container.
    static let containerIdentifier = "iCloud.com.herbertindustries.BumpyRide"

    private static let log = Logger(subsystem: "com.herbertindustries.BumpyRide", category: "cloud")

    /// Where to read and write ride JSON.  Resolved once at init.  Callers
    /// (RideStore) should capture this and not re-read it — switching
    /// storage modes mid-session is not supported (a tab-bar tap shouldn't
    /// silently relocate the user's data).
    let ridesDirectoryURL: URL

    /// True when `ridesDirectoryURL` points at an iCloud ubiquity container.
    /// Drives the Settings backup-status row.
    let isCloudAvailable: Bool

    init() {
        // Resolution happens synchronously, which Apple discourages ("should
        // be called from a secondary thread because it can be slow") but in
        // practice the first call takes ~200 ms on a cold launch and is
        // cached thereafter.  Acceptable cost — we already do synchronous
        // ride loading in RideStore.init that's of similar magnitude.  If
        // this becomes a real perf problem we'll move to deferred resolution
        // with an explicit "store not ready" state, but that's a much bigger
        // refactor for a marginal win.
        let cloudURL = FileManager.default
            .url(forUbiquityContainerIdentifier: Self.containerIdentifier)?
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Rides", isDirectory: true)

        if let cloudURL {
            // Ensure the Rides subfolder exists.  Failures here are silently
            // ignored — the worst case is the subsequent save throws and the
            // user's first ride doesn't persist, which is the same failure
            // mode we've always had for local Documents.
            try? FileManager.default.createDirectory(at: cloudURL, withIntermediateDirectories: true)
            ridesDirectoryURL = cloudURL
            isCloudAvailable = true
            Self.log.info("Using iCloud Documents for ride storage")
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let localURL = docs.appendingPathComponent("Rides", isDirectory: true)
            try? FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
            ridesDirectoryURL = localURL
            isCloudAvailable = false
            Self.log.info("Using local Documents for ride storage (iCloud unavailable)")
        }
    }

    /// Copy any rides that still live in the legacy local Documents/Rides
    /// folder into iCloud, then delete the local copies.  No-op when iCloud
    /// isn't available, or when the local folder doesn't exist, or when it's
    /// the same folder we're writing to (i.e., we *are* in local-only mode).
    ///
    /// Idempotent and per-file: a ride that's already in iCloud (matching
    /// filename) is left alone; the local copy still gets removed so the
    /// next listing doesn't find it.  This means a partial migration can be
    /// resumed safely on the next launch.
    ///
    /// Errors per-file are logged and skipped — one bad file shouldn't
    /// abort the whole migration and strand other rides.
    func migrateLocalRidesIfNeeded() {
        guard isCloudAvailable else { return }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let localRides = docs.appendingPathComponent("Rides", isDirectory: true)

        // If we're already writing into local Documents (fallback mode), the
        // "local" and "iCloud" URLs are the same and there's nothing to
        // migrate.  This guard also handles the case where the local folder
        // simply doesn't exist (fresh install with iCloud available from the
        // start).
        guard localRides != ridesDirectoryURL else { return }
        guard FileManager.default.fileExists(atPath: localRides.path) else { return }

        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: localRides, includingPropertiesForKeys: nil)
        } catch {
            Self.log.error("Migration: failed to list local rides: \(error.localizedDescription, privacy: .public)")
            return
        }

        var copied = 0
        var skipped = 0
        var failed = 0
        for url in files where url.pathExtension == "json" {
            let dest = ridesDirectoryURL.appendingPathComponent(url.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    // Already in iCloud — just remove the local stragler.
                    // Don't overwrite, because the iCloud copy might have
                    // edits we'd lose.
                    skipped += 1
                } else {
                    try FileManager.default.copyItem(at: url, to: dest)
                    copied += 1
                }
                try FileManager.default.removeItem(at: url)
            } catch {
                failed += 1
                Self.log.error("Migration: \(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        if copied + skipped + failed > 0 {
            Self.log.notice("Migration complete: copied=\(copied, privacy: .public) skipped=\(skipped, privacy: .public) failed=\(failed, privacy: .public)")
        }
    }
}
