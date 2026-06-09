import Foundation
import CoreLocation
import OSLog
#if canImport(HealthKit)
import HealthKit
#endif

/// Writes one `Ride` to HealthKit as an `HKWorkout` (cycling, outdoor)
/// with a route, distance, and estimated active-energy samples.
///
/// **Idempotency**: queries existing workouts by
/// `HKMetadataKeyExternalUUID == ride.id.uuidString` first.  If a
/// workout with the same id already exists, returns `.alreadyPresent`
/// with its UUID and writes nothing — protects against double-exports
/// from auto-export + backfill races, and lets the caller patch the
/// ride's `healthKitWorkoutUUID` either way.
///
/// **Builder pattern** (iOS 17+): uses `HKWorkoutBuilder` and
/// `HKWorkoutRouteBuilder` rather than the deprecated direct
/// `HKWorkout.init(...)` initializer.  Apple deprecated the direct
/// initializers in iOS 17 because they don't support attached
/// samples cleanly.
///
/// **Route batching**: GPS points are inserted in chunks of 100 via
/// `HKWorkoutRouteBuilder.insertRouteData(_:)`.  For a 50-minute ride
/// at ~1 Hz that's roughly 30 inserts, all awaited cooperatively so
/// the UI thread stays responsive during a backfill.
///
/// **Failure handling**: surfaces failures as throws.  Caller decides
/// whether to retry or skip — backfill (Phase F) treats individual
/// failures as skip-and-continue; auto-export (Phase D) silently logs
/// and leaves the user to retry via the per-ride button.
///
/// **Threading**: `@MainActor` matches the other writer-side state
/// objects.  HealthKit calls suspend off main; no real-thread blocking.
@MainActor
final class HealthKitExporter {
    // `DebugLog` wraps `Logger` and additionally fans out to a
    // sidecar log file in iCloud when the user has flipped the
    // Settings "Write Debug Log" toggle on.  Diagnosing real-world
    // export failures (the "log stops after HR sample count" bug we
    // chased in v1.8) needs this file because we can't read the
    // unified log stream from a phone without entitlement.  Both
    // the underlying os.Logger and DebugLogSink are thread-safe;
    // nonisolated lets HealthKit completion closures call through
    // without an actor hop.
    nonisolated private static let log = DebugLog(category: "healthkit")

    /// Outcome of an export attempt.  Distinguishes a fresh write from
    /// a no-op skip so the caller can update local state correctly in
    /// both cases.
    enum ExportResult: Equatable, Sendable {
        /// Workout was created on this attempt; UUID is the new
        /// `HKWorkout`'s uuid.  Caller should stamp the local Ride.
        case written(UUID)
        /// A workout with the same `HKMetadataKeyExternalUUID` already
        /// existed.  UUID is the existing workout's.  Caller should
        /// stamp the local Ride (idempotent — useful for backfills
        /// where the local stamp may have been lost).
        case alreadyPresent(UUID)
        /// HealthKit isn't available on this device.  Caller should
        /// hide the integration entirely.
        case unavailable
    }

    enum ExportError: Error {
        /// `beginCollection` / `endCollection` / `finishWorkout` failed.
        case workoutWriteFailed(underlying: Error)
        /// `insertRouteData` or `finishRoute` failed.  The workout may
        /// have already been saved at this point — caller cannot
        /// assume rollback.
        case routeWriteFailed(underlying: Error)
        /// `finishWorkout` returned nil (workout did not save).
        /// Treated as a write failure since we have no UUID to report.
        case workoutNotSaved
    }

    #if canImport(HealthKit)
    private let store: HKHealthStore?
    #else
    private let store: AnyObject? = nil
    #endif

    private let energyEstimator: HealthKitEnergyEstimator

    /// Maximum CLLocations per `insertRouteData` call.  HealthKit doesn't
    /// publish a hard limit, but Apple's sample code uses ~100 and that's
    /// what produces consistently fast acks on real devices.
    private static let routeBatchSize: Int = 100

    #if canImport(HealthKit)
    init(store: HKHealthStore?, energyEstimator: HealthKitEnergyEstimator) {
        self.store = store
        self.energyEstimator = energyEstimator
    }
    #else
    init(store: AnyObject? = nil, energyEstimator: HealthKitEnergyEstimator) {
        self.energyEstimator = energyEstimator
    }
    #endif

    // MARK: - Public API

    /// Export a single ride.  Idempotent — repeated calls for the same
    /// ride id return `.alreadyPresent(existingUUID)` after the first
    /// successful write.
    ///
    /// May throw `ExportError` on failure; caller decides what to do.
    func export(_ ride: Ride) async throws -> ExportResult {
        #if canImport(HealthKit)
        guard let store else { return .unavailable }

        // Idempotency check.  Best-effort: a failure here doesn't
        // abort the write (a transient query error shouldn't block a
        // legitimate export).  If we miss an existing workout, the
        // attempted write will land as a duplicate — bad but rare.
        Self.log.info("Export \(ride.id) start: checking idempotency")
        if let existing = await existingWorkoutUUID(for: ride.id, store: store) {
            Self.log.info("Skip export \(ride.id): already in HealthKit as \(existing)")
            return .alreadyPresent(existing)
        }
        Self.log.info("Export \(ride.id): no existing workout, building")

        // Configure as outdoor cycling.  The location type is what
        // determines whether HealthKit treats the workout as a
        // GPS-trackable activity for the Fitness app's "Workouts"
        // view.  Indoor cycling would not show a route map.
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .cycling
        configuration.locationType = .outdoor

        let builder = HKWorkoutBuilder(
            healthStore: store,
            configuration: configuration,
            device: .local()
        )

        let startDate = ride.startedAt
        let endDate = ride.endedAt

        do {
            // Each HKWorkoutBuilder await below is an opaque suspension
            // — the framework can hang for seconds (or longer in
            // pathological auth states).  Bracket every one with a
            // before/after log so a sidecar file from a stuck export
            // tells us exactly which stage stopped advancing.
            Self.log.info("Export \(ride.id): beginCollection at \(startDate)")
            try await builder.beginCollection(at: startDate)
            Self.log.info("Export \(ride.id): beginCollection returned")

            // Build and add the quantity samples we have data for.
            // Distance is mandatory; energy is "we estimated it,"
            // marked accordingly via the metadata key so consumers
            // know it's not measured.
            var samples: [HKSample] = []
            if ride.distanceMeters > 0 {
                let distanceSample = HKQuantitySample(
                    type: HKQuantityType.quantityType(forIdentifier: .distanceCycling)!,
                    quantity: HKQuantity(unit: .meter(), doubleValue: ride.distanceMeters),
                    start: startDate,
                    end: endDate
                )
                samples.append(distanceSample)
            }
            Self.log.info("Export \(ride.id): kcal estimate")
            let kcal = await energyEstimator.kcal(for: ride)
            Self.log.info("Export \(ride.id): kcal=\(kcal)")
            if kcal > 0 {
                let energySample = HKQuantitySample(
                    type: HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!,
                    quantity: HKQuantity(unit: .kilocalorie(), doubleValue: kcal),
                    start: startDate,
                    end: endDate,
                    metadata: [HKMetadataKeyWasUserEntered: false]
                )
                samples.append(energySample)
            }
            // v1.7 heart-rate enrichment.  If the watch's
            // HKWorkoutSession was running during the ride (via the
            // startWatchApp handoff), watchOS recorded heart rate
            // samples directly into HealthKit's heartRate quantity
            // type.  Query for any in this ride's window and
            // associate them with our HKWorkout so the user sees a
            // heart-rate trace in Apple Fitness alongside the route.
            //
            // Returns [] if HR read auth was denied or the watch
            // session never ran for this ride — both are silent
            // fall-through cases; the workout is still saved with
            // distance + energy + route as before.
            Self.log.info("Export \(ride.id): fetchHeartRateSamples")
            let heartRateSamples = await fetchHeartRateSamples(
                start: startDate,
                end: endDate,
                store: store
            )
            samples.append(contentsOf: heartRateSamples)
            Self.log.info("Export \(ride.id): \(heartRateSamples.count) HR sample(s); total samples \(samples.count)")
            if !samples.isEmpty {
                Self.log.info("Export \(ride.id): addSamples (count=\(samples.count))")
                try await builder.addSamples(samples)
                Self.log.info("Export \(ride.id): addSamples returned")
            }

            // Workout-level metadata: external UUID for idempotency,
            // plus a couple of bumpiness fields useful for future
            // debugging (not surfaced in any Apple UI).
            var metadata: [String: Any] = [
                HKMetadataKeyExternalUUID: ride.id.uuidString,
                HKMetadataKeyWasUserEntered: false,
            ]
            metadata[Self.metadataKeyMaxBumpiness] = ride.maxBumpiness
            metadata[Self.metadataKeyAvgBumpiness] = ride.averageBumpiness
            Self.log.info("Export \(ride.id): addMetadata")
            try await builder.addMetadata(metadata)
            Self.log.info("Export \(ride.id): addMetadata returned")

            Self.log.info("Export \(ride.id): endCollection at \(endDate)")
            try await builder.endCollection(at: endDate)
            Self.log.info("Export \(ride.id): endCollection returned")

            Self.log.info("Export \(ride.id): finishWorkout")
            guard let workout = try await builder.finishWorkout() else {
                Self.log.error("Export \(ride.id): finishWorkout returned nil")
                throw ExportError.workoutNotSaved
            }
            Self.log.info("Export \(ride.id): finishWorkout returned uuid=\(workout.uuid)")

            // Attach the GPS route, if any.  Failures here don't roll
            // back the workout (HealthKit doesn't support that) — we
            // log and continue.  The workout still credits the rings
            // and shows up in Fitness, just without a map.
            if !ride.points.isEmpty {
                Self.log.info("Export \(ride.id): writeRoute (\(ride.points.count) points)")
                do {
                    try await writeRoute(for: ride, attachingTo: workout, store: store)
                    Self.log.info("Export \(ride.id): writeRoute returned")
                } catch {
                    Self.log.error("Export \(ride.id): route attach failed: \(String(describing: error))")
                    // Don't rethrow — workout is saved, route is just
                    // a nice-to-have.
                }
            }

            Self.log.info("Exported \(ride.id) as HK workout \(workout.uuid)")
            return .written(workout.uuid)
        } catch let error as ExportError {
            Self.log.error("Export \(ride.id): rethrowing ExportError \(String(describing: error))")
            throw error
        } catch {
            Self.log.error("Export \(ride.id): workout write failed: \(String(describing: error))")
            throw ExportError.workoutWriteFailed(underlying: error)
        }
        #else
        return .unavailable
        #endif
    }

    // MARK: - Internal: idempotency

    #if canImport(HealthKit)
    /// Query HealthKit for an existing workout with our external-UUID
    /// metadata key matching this ride's id.  Returns the workout's
    /// `HKObject.uuid` if found, nil otherwise.  Errors map to nil —
    /// the caller treats them as "no match," and the write attempt
    /// that follows will surface real auth/transport problems.
    private func existingWorkoutUUID(for rideId: UUID, store: HKHealthStore) async -> UUID? {
        let predicate = HKQuery.predicateForObjects(
            withMetadataKey: HKMetadataKeyExternalUUID,
            allowedValues: [rideId.uuidString]
        )
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    Self.log.notice("Idempotency query failed: \(String(describing: error))")
                    continuation.resume(returning: nil)
                    return
                }
                if let workout = samples?.first as? HKWorkout {
                    continuation.resume(returning: workout.uuid)
                } else {
                    continuation.resume(returning: nil)
                }
            }
            store.execute(query)
        }
    }
    #endif

    // MARK: - Internal: heart-rate sample query

    #if canImport(HealthKit)
    /// Query HealthKit for heart-rate samples in `[start, end]`.
    /// Used by v1.7 to enrich the cycling HKWorkout with HR data
    /// the watch's HKWorkoutSession collected during the ride.
    ///
    /// Returns `[]` on any failure (auth denied, no samples in
    /// range, query error) — the caller treats an empty result as
    /// "no HR data to embed" rather than an export failure, so
    /// rides export normally even when HR collection wasn't
    /// running.
    ///
    /// `.strictStartDate` predicate so a sample that started
    /// before the ride and ended during it doesn't get pulled in
    /// — HR samples have effectively-instantaneous timestamps
    /// anyway, but being strict matches the semantics we'd want
    /// for any future per-sample association.
    private func fetchHeartRateSamples(
        start: Date,
        end: Date,
        store: HKHealthStore
    ) async -> [HKQuantitySample] {
        guard let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
            return []
        }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: heartRateType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, error in
                if let error {
                    Self.log.notice("HR sample query failed: \(String(describing: error))")
                    continuation.resume(returning: [])
                    return
                }
                continuation.resume(returning: (samples as? [HKQuantitySample]) ?? [])
            }
            store.execute(query)
        }
    }
    #endif

    // MARK: - Internal: route

    #if canImport(HealthKit)
    /// Build and attach the GPS route to a freshly-saved workout.
    /// Points are converted to `CLLocation`s and inserted in
    /// `routeBatchSize`-sized chunks.
    private func writeRoute(
        for ride: Ride,
        attachingTo workout: HKWorkout,
        store: HKHealthStore
    ) async throws {
        let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: .local())
        let locations = ride.points.map { p in
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude),
                altitude: 0,
                // Our recorder uses kCLLocationAccuracyBest; we don't
                // persist per-point accuracy.  5 m is a reasonable
                // best-effort claim for outdoor cycling fixes.
                horizontalAccuracy: 5.0,
                // -1 for fields we don't have data for; HealthKit
                // treats negative accuracies as "absent."
                verticalAccuracy: -1,
                course: -1,
                speed: p.speed,
                timestamp: p.timestamp
            )
        }

        do {
            var index = 0
            while index < locations.count {
                let upper = min(index + Self.routeBatchSize, locations.count)
                let batch = Array(locations[index..<upper])
                try await routeBuilder.insertRouteData(batch)
                index = upper
            }
            _ = try await routeBuilder.finishRoute(with: workout, metadata: nil)
        } catch {
            throw ExportError.routeWriteFailed(underlying: error)
        }
    }
    #endif

    // MARK: - Constants

    /// Custom metadata key for the ride's peak per-point bumpiness in g.
    /// Not displayed by Apple's apps; useful for debugging via the
    /// HealthKit data browser.  Reverse-DNS prefix per Apple guidance.
    private static let metadataKeyMaxBumpiness = "com.herbertindustries.BumpyRide.maxBumpiness"

    /// Custom metadata key for the ride's average per-point bumpiness
    /// in g.  Same treatment as `metadataKeyMaxBumpiness`.
    private static let metadataKeyAvgBumpiness = "com.herbertindustries.BumpyRide.avgBumpiness"
}
