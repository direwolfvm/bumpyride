import Foundation
import OSLog
#if canImport(HealthKit)
import HealthKit
#endif

/// MET-based active-energy estimator for cycling rides.
///
/// **Why this exists**: HealthKit's calorie field (`activeEnergyBurned`)
/// is what credits the user's activity rings.  We don't measure energy
/// directly — no heart rate, no power meter — so we approximate using
/// the Compendium of Physical Activities (Ainsworth et al.), which
/// publishes MET values for cycling at various average speeds.
///
/// Formula: `kcal = METs × bodyMass(kg) × duration(hours)`.
///
/// One number per ride.  Per-segment estimation would be marginally
/// more accurate but adds complexity for negligible user-visible
/// benefit; Apple's own iPhone-only Workout estimates work the same
/// way.  The estimate is ±20% in normal cases — acceptable for an
/// approximation, and clearly framed to the user as such in the Apple
/// Health UI ("estimated active energy").
///
/// **Body mass lookup** reads the most recent `bodyMass` sample from
/// HealthKit once per process lifetime and caches it.  Body mass
/// changes on the timescale of days; refreshing on each export would
/// just burn a query.  Falls back to 75 kg if the user denied read
/// auth or has never logged a body-mass sample.
///
/// **Threading**: `@MainActor` matches the other writer-side state
/// (RestoreCoordinator, HealthKitExporter).  Body-mass query suspends
/// off main; no real-thread blocking.
@MainActor
final class HealthKitEnergyEstimator {
    // `Logger` is thread-safe by design; mark nonisolated so the
    // HealthKit completion closures (which are Sendable, not
    // MainActor-bound) can call it without an actor hop.
    nonisolated private static let log = Logger(subsystem: "com.herbertindustries.BumpyRide", category: "healthkit")

    /// Fallback body mass when HealthKit has no sample or the user
    /// denied read auth.  Roughly the global adult average; off by ±15 kg
    /// for most users but the resulting kcal error is bounded and
    /// dominated by the MET bucketing error anyway.
    static let defaultBodyMassKg: Double = 75.0

    #if canImport(HealthKit)
    private let store: HKHealthStore?
    #else
    private let store: AnyObject? = nil
    #endif

    /// Cached body-mass in kg.  Set on first `currentBodyMassKg()`
    /// call; persists for the process lifetime.  See class-level
    /// comment for rationale.
    private var cachedBodyMassKg: Double?

    #if canImport(HealthKit)
    init(store: HKHealthStore?) {
        self.store = store
    }
    #else
    init(store: AnyObject? = nil) {}
    #endif

    // MARK: - Public API

    /// Returns the user's most recent body mass in kg, or
    /// `defaultBodyMassKg` if no sample is available.  Cached after the
    /// first call.
    func currentBodyMassKg() async -> Double {
        if let cached = cachedBodyMassKg { return cached }
        let value = await fetchMostRecentBodyMassKg() ?? Self.defaultBodyMassKg
        cachedBodyMassKg = value
        Self.log.info("Body mass for energy estimate: \(value, format: .fixed(precision: 1), privacy: .public) kg")
        return value
    }

    /// Total estimated kcal for the ride.  Computed from average speed
    /// (= distance / duration), the cycling MET table, and the user's
    /// cached body mass.  Returns 0 if the ride has zero duration or
    /// zero distance — both indicate a degenerate ride for which any
    /// energy claim would be noise.
    func kcal(for ride: Ride) async -> Double {
        let duration = ride.duration
        let distance = ride.distanceMeters
        guard duration > 0, distance > 0 else { return 0 }
        let mass = await currentBodyMassKg()
        let avgSpeedMps = distance / duration
        let avgSpeedKmh = avgSpeedMps * 3.6
        let mets = Self.metsForCycling(averageSpeedKmh: avgSpeedKmh)
        return Self.kcal(mets: mets, bodyMassKg: mass, durationSeconds: duration)
    }

    // MARK: - Pure helpers (testable, no I/O)

    /// MET value for cycling at the given average speed.  Buckets from
    /// the Compendium of Physical Activities (Ainsworth 2011), rounded
    /// to single-tenth precision for stability — picking values not at
    /// bucket boundaries shouldn't make kcal estimates jitter on
    /// adjacent rides.
    ///
    /// Speed bucket → MET:
    /// - <16 km/h (slow leisure):           6.0
    /// - 16–<19 km/h (light):               8.0
    /// - 19–<22 km/h (moderate):           10.0
    /// - 22–<26 km/h (vigorous):           12.0
    /// - ≥26 km/h (very vigorous/racing):  14.0
    static func metsForCycling(averageSpeedKmh: Double) -> Double {
        switch averageSpeedKmh {
        case ..<16:    return 6.0
        case 16..<19:  return 8.0
        case 19..<22:  return 10.0
        case 22..<26:  return 12.0
        default:       return 14.0
        }
    }

    /// `kcal = METs × bodyMass(kg) × duration(hours)`.
    /// Pure: zero in → zero out, no I/O.
    static func kcal(mets: Double, bodyMassKg: Double, durationSeconds: TimeInterval) -> Double {
        let durationHours = durationSeconds / 3600.0
        return mets * bodyMassKg * durationHours
    }

    // MARK: - HealthKit query

    /// Fetches the most recent `bodyMass` sample from HealthKit.
    /// Returns nil if HealthKit is unavailable, read auth was denied,
    /// no sample exists, or the query errored.  Caller maps nil to
    /// `defaultBodyMassKg`.
    private func fetchMostRecentBodyMassKg() async -> Double? {
        #if canImport(HealthKit)
        guard let store else { return nil }
        guard let bodyMassType = HKQuantityType.quantityType(forIdentifier: .bodyMass) else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(
                sampleType: bodyMassType,
                predicate: nil,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    Self.log.error("Body mass query failed: \(String(describing: error), privacy: .public)")
                    continuation.resume(returning: nil)
                    return
                }
                guard let sample = samples?.first as? HKQuantitySample else {
                    continuation.resume(returning: nil)
                    return
                }
                let kg = sample.quantity.doubleValue(for: .gramUnit(with: .kilo))
                continuation.resume(returning: kg)
            }
            store.execute(query)
        }
        #else
        return nil
        #endif
    }
}
