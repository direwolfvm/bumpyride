import Foundation
import Observation
import OSLog
#if canImport(HealthKit)
import HealthKit
#endif

/// Single source of truth for HealthKit authorization across the app.
///
/// **Why this exists**: HealthKit's authorization model is unusually
/// opaque.  Apple deliberately does not expose write-authorization status
/// (`HKHealthStore.authorizationStatus(for:)` returns `.notDetermined`
/// for write-only types even after the user has granted) so apps can't
/// fingerprint user choices.  That means we can't poll "has the user
/// said yes yet" — we have to remember it ourselves, or attempt a write
/// and react to the failure.
///
/// The compromise: we treat `.granted` as "the user has been through the
/// authorization sheet at least once."  Whether they actually ticked the
/// boxes we asked for is discovered on first write attempt.  This is the
/// pattern Apple's own sample code uses.
///
/// **State machine**:
///
///   .unknown ──(checkOnLaunch)──▶ .unavailable / .notRequested
///   .notRequested ──(requestAuthorization)──▶ .requesting
///   .requesting ──(success)──▶ .granted
///   .requesting ──(failure)──▶ .denied
///
/// The UI reads `state` directly and uses helper computed booleans
/// (`shouldOfferEnable`, `isUsable`) for the common questions.
///
/// **Threading**: `@MainActor` because the UI reads observable state.
/// All HealthKit calls hop off-main via the framework's own async APIs;
/// we only mutate `state` back on the main actor.
@Observable
@MainActor
final class HealthKitAuthManager {
    /// Coarse-grained authorization state.  Internal layout chosen to be
    /// trivially renderable as a Settings row description string.
    enum State: Equatable, Sendable {
        /// Initial value before `checkOnLaunch()` has run.  UI should
        /// generally not see this — `BumpyRideApp` calls `checkOnLaunch`
        /// during scene setup.  Treated as "loading" if it leaks.
        case unknown
        /// HealthKit isn't available on this device (e.g. iPad without
        /// HealthKit, or unsupported region).  All write paths become
        /// no-ops; UI hides the integration entirely.
        case unavailable
        /// Available but the user hasn't been through the auth sheet
        /// yet.  Toggling the Settings switch will trigger the prompt.
        case notRequested
        /// Authorization sheet is currently displayed.  UI shows a
        /// spinner on the toggle.
        case requesting
        /// User has been through the auth sheet at least once.  Note:
        /// this does NOT guarantee the specific types we asked for were
        /// granted — Apple's privacy model hides per-type write status.
        /// Failures surface on actual write attempts.
        case granted
        /// The request itself errored out (rare — typically only happens
        /// if the entitlement is missing or `HKHealthStore` can't be
        /// constructed).  UI shows a generic "couldn't enable" message.
        case denied
    }

    private static let log = Logger(subsystem: "com.herbertindustries.BumpyRide", category: "healthkit")

    private(set) var state: State = .unknown

    /// The single `HKHealthStore` instance for the app.  Apple guidance
    /// is to share one across the process — it's lightweight but holds
    /// observer-query state that gets confused if multiple stores
    /// coexist.  Exposed for the writer/backfill to share, not for UI.
    #if canImport(HealthKit)
    let store: HKHealthStore?
    #else
    let store: AnyObject? = nil
    #endif

    init() {
        #if canImport(HealthKit)
        if HKHealthStore.isHealthDataAvailable() {
            self.store = HKHealthStore()
        } else {
            self.store = nil
        }
        #endif
    }

    // MARK: - Lifecycle

    /// Called once during app setup.  Resolves `.unknown` to either
    /// `.unavailable` (device doesn't support HealthKit) or
    /// `.notRequested` (we haven't asked yet).  We don't try to detect
    /// "previously granted" here because of Apple's write-status
    /// opacity; instead we persist our own flag and read it.
    func checkOnLaunch() {
        #if canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable(), store != nil else {
            state = .unavailable
            Self.log.info("HealthKit unavailable on this device")
            return
        }
        // We can't ask HealthKit "did the user already grant write?" —
        // it lies to us by design.  Persist our own bit instead, set
        // when `requestAuthorization()` returns successfully at least
        // once.  Worst case: user revokes via Settings → Privacy →
        // Health, our flag is stale, the next write fails and the UI
        // can re-prompt.
        if UserDefaults.standard.bool(forKey: Self.keyHasRequested) {
            state = .granted
            Self.log.info("HealthKit auth: granted (per persisted flag)")
        } else {
            state = .notRequested
            Self.log.info("HealthKit auth: not yet requested")
        }
        #else
        state = .unavailable
        #endif
    }

    /// Present the HealthKit authorization sheet to the user.  The
    /// sheet itself is presented by iOS; this method just kicks it
    /// off and awaits completion.
    ///
    /// **Returns** true if the request completed successfully (which
    /// means the user dismissed the sheet — they may have ticked all,
    /// some, or none of the boxes).  Returns false if HealthKit isn't
    /// available or the request errored.
    ///
    /// Re-entry safe: if already `.requesting` returns immediately.
    @discardableResult
    func requestAuthorization() async -> Bool {
        #if canImport(HealthKit)
        guard let store else {
            state = .unavailable
            return false
        }
        if case .requesting = state { return false }
        state = .requesting

        let typesToShare: Set<HKSampleType> = Self.shareTypes
        let typesToRead: Set<HKObjectType> = Self.readTypes

        do {
            try await store.requestAuthorization(toShare: typesToShare, read: typesToRead)
            UserDefaults.standard.set(true, forKey: Self.keyHasRequested)
            state = .granted
            Self.log.info("HealthKit auth: request completed")
            return true
        } catch {
            // Most common cause: the HealthKit entitlement isn't actually
            // present on the build.  Less common: process crash mid-sheet.
            Self.log.error("HealthKit auth: request failed: \(String(describing: error), privacy: .public)")
            state = .denied
            return false
        }
        #else
        state = .unavailable
        return false
        #endif
    }

    // MARK: - Convenience for downstream phases

    /// True if the UI should offer the user a way to enable / use
    /// HealthKit features.  False when the device can't do HealthKit
    /// at all — UI should hide the integration entirely in that case
    /// rather than showing a disabled toggle.
    var isAvailable: Bool {
        switch state {
        case .unavailable: return false
        case .unknown, .notRequested, .requesting, .granted, .denied: return true
        }
    }

    /// True if a write is worth attempting.  Phase D's auto-export and
    /// Phase E's per-ride button both gate on this.
    var canWrite: Bool {
        if case .granted = state { return true }
        return false
    }

    /// True if the user has never been asked.  Used by Settings to
    /// distinguish "first-time enable" (show explanatory footer) from
    /// "re-enable after revoke" (show "Open Settings" hint).
    var hasNeverBeenAsked: Bool {
        if case .notRequested = state { return true }
        return false
    }

    // MARK: - Constants

    /// UserDefaults key tracking whether we've ever completed a
    /// `requestAuthorization` call.  See `checkOnLaunch` for why this
    /// has to be persisted rather than queried.
    private static let keyHasRequested = "healthKitHasRequestedAuthorization"

    #if canImport(HealthKit)
    /// Write types: cycling workouts (and their attached route +
    /// distance + energy samples).  Adding new types here will require
    /// the user to re-authorize.
    static var shareTypes: Set<HKSampleType> {
        [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
            HKQuantityType.quantityType(forIdentifier: .distanceCycling)!,
            HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!,
        ]
    }

    /// Read types: body mass for the energy estimator (v1.5) plus
    /// heart rate (v1.7) so the iOS `HealthKitExporter` can query for
    /// heart-rate samples in the ride's date range and embed them in
    /// the cycling workout it writes.  Heart-rate samples themselves
    /// are written to HealthKit by watchOS while the watch's
    /// `HKWorkoutSession` is active (see `WatchWorkoutManager`); we
    /// just need read access to query them.
    static var readTypes: Set<HKObjectType> {
        var set: Set<HKObjectType> = []
        if let bodyMass = HKQuantityType.quantityType(forIdentifier: .bodyMass) {
            set.insert(bodyMass)
        }
        if let heartRate = HKQuantityType.quantityType(forIdentifier: .heartRate) {
            set.insert(heartRate)
        }
        return set
    }
    #endif
}
