import Foundation
import HealthKit
import Observation
import OSLog

/// Watch-side owner of the `HKWorkoutSession` + `HKLiveWorkoutBuilder`
/// pair that runs when iOS hands off a workout via `startWatchApp`.
///
/// Why we run a workout session at all: the iPhone is doing the
/// actual sensor recording (GPS, accelerometer) and writes the
/// canonical `HKWorkout` for the ride.  The watch session exists
/// purely so watchOS will engage its dedicated heart-rate hardware
/// at the high sampling rate it reserves for active workouts —
/// heart rate samples written by watchOS during the session land
/// in HealthKit's `heartRate` quantity type and the iPhone-side
/// HealthKitExporter can query them at ride-save time to enrich
/// the saved workout (Phase F+).
///
/// **Don't save the watch's workout.**  After `endCollection`, we
/// call `discardWorkout()` rather than `finishWorkout()` so no
/// separate `HKWorkout` is created from the watch — only the
/// individual heart-rate samples persist, attached to no parent.
/// The iPhone's saved cycling workout absorbs them via
/// time-window query.  This is what keeps Apple Health from
/// showing two workouts for one ride.
///
/// **Phase E scope**: start session on receipt of an
/// `HKWorkoutConfiguration`, expose a `stop()` method that ends +
/// discards.  Phase F will wire `stop()` to the iPhone's ride-stop
/// signal (via WCSession) so the session ends when the user
/// finishes a ride; for now the session runs until the watch app
/// is force-quit or the watch dies for memory reasons.
@Observable
@MainActor
final class WatchWorkoutManager: NSObject {
    nonisolated private static let log = Logger(
        subsystem: "com.herbertindustries.BumpyRide.watchkitapp",
        category: "watch"
    )

    enum State: Equatable, Sendable {
        case idle
        case running
        case ended
        case failed(message: String)
    }

    private(set) var state: State = .idle

    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?

    @ObservationIgnored private let healthStore: HKHealthStore

    override init() {
        self.healthStore = HKHealthStore()
        super.init()
    }

    /// Start an `HKWorkoutSession` with the given configuration.
    /// Idempotent — if a session is already running, this is a
    /// no-op.  Failure surfaces via `state = .failed(message:)`.
    ///
    /// Called from `BumpyRideWatchAppApp` when the
    /// `WatchAppDelegate` posts a new `pendingWorkoutConfiguration`.
    /// The configuration arrives via Apple's
    /// `startWatchApp(toHandle:)` handoff initiated from iOS.
    func start(with configuration: HKWorkoutConfiguration) {
        guard state != .running else {
            Self.log.notice("start(with:) ignored: session already running")
            return
        }
        guard HKHealthStore.isHealthDataAvailable() else {
            state = .failed(message: "HealthKit unavailable")
            return
        }

        do {
            let session = try HKWorkoutSession(
                healthStore: healthStore,
                configuration: configuration
            )
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: configuration
            )
            session.delegate = self
            // builder.delegate is left unset in Phase E.  Phase F
            // will set it so we can react to incoming heart-rate
            // samples and forward them to iOS via WCSession.

            let startDate = Date()
            session.startActivity(with: startDate)
            builder.beginCollection(withStart: startDate) { success, error in
                if !success {
                    Self.log.error("beginCollection failed: \(String(describing: error), privacy: .public)")
                }
            }

            self.session = session
            self.builder = builder
            self.state = .running
            Self.log.info("HKWorkoutSession started: activityType=\(configuration.activityType.rawValue, privacy: .public)")
        } catch {
            self.state = .failed(message: String(describing: error))
            Self.log.error("Failed to start HKWorkoutSession: \(String(describing: error), privacy: .public)")
        }
    }

    /// End the running session and discard the workout without
    /// saving an `HKWorkout` to HealthKit.  Heart-rate samples
    /// collected during the session window remain in HealthKit
    /// (saved by watchOS independently of the workout), so the
    /// iPhone can still query them at ride-save time.
    ///
    /// Phase E: callable from anywhere; not auto-wired to ride
    /// lifecycle.  Phase F connects it to the iPhone's stop
    /// signal so the session ends when the user finishes their
    /// ride.
    func stop() {
        guard let session, let builder else {
            state = .ended
            return
        }
        let endDate = Date()
        session.end()
        builder.endCollection(withEnd: endDate) { success, error in
            if !success {
                Self.log.error("endCollection failed: \(String(describing: error), privacy: .public)")
            }
            // Discard rather than finish — see class doc for why.
            builder.discardWorkout()
        }
        self.session = nil
        self.builder = nil
        state = .ended
        Self.log.info("HKWorkoutSession ended + discarded")
    }
}

extension WatchWorkoutManager: HKWorkoutSessionDelegate {
    // Delegate callbacks arrive on a background queue; nonisolated
    // matches the framework's protocol shape.  We log here and let
    // the session's own observable `state` lead UI updates.

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Self.log.info("HKWorkoutSession transitioned: \(fromState.rawValue, privacy: .public) → \(toState.rawValue, privacy: .public)")
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: any Error
    ) {
        Self.log.error("HKWorkoutSession failed: \(String(describing: error), privacy: .public)")
        let message = String(describing: error)
        Task { @MainActor in
            self.state = .failed(message: message)
        }
    }
}
