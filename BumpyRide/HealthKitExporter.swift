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
    // `Logger` is thread-safe by design; mark nonisolated so the
    // HealthKit completion closures (which are Sendable, not
    // MainActor-bound) can call it without an actor hop.
    nonisolated private static let log = Logger(subsystem: "com.herbertindustries.BumpyRide", category: "healthkit")

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
        if let existing = await existingWorkoutUUID(for: ride.id, store: store) {
            Self.log.info("Skip export \(ride.id, privacy: .public): already in HealthKit")
            return .alreadyPresent(existing)
        }

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
            try await builder.beginCollection(at: startDate)

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
            let kcal = await energyEstimator.kcal(for: ride)
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
            if !samples.isEmpty {
                try await builder.addSamples(samples)
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
            try await builder.addMetadata(metadata)

            try await builder.endCollection(at: endDate)

            guard let workout = try await builder.finishWorkout() else {
                Self.log.error("Export \(ride.id, privacy: .public): finishWorkout returned nil")
                throw ExportError.workoutNotSaved
            }

            // Attach the GPS route, if any.  Failures here don't roll
            // back the workout (HealthKit doesn't support that) — we
            // log and continue.  The workout still credits the rings
            // and shows up in Fitness, just without a map.
            if !ride.points.isEmpty {
                do {
                    try await writeRoute(for: ride, attachingTo: workout, store: store)
                } catch {
                    Self.log.error("Export \(ride.id, privacy: .public): route attach failed: \(String(describing: error), privacy: .public)")
                    // Don't rethrow — workout is saved, route is just
                    // a nice-to-have.
                }
            }

            Self.log.info("Exported \(ride.id, privacy: .public) as HK workout \(workout.uuid, privacy: .public)")
            return .written(workout.uuid)
        } catch let error as ExportError {
            throw error
        } catch {
            Self.log.error("Export \(ride.id, privacy: .public): workout write failed: \(String(describing: error), privacy: .public)")
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
                    Self.log.notice("Idempotency query failed: \(String(describing: error), privacy: .public)")
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
