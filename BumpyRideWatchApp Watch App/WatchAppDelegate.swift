import Foundation
import WatchKit
import HealthKit
import Observation
import OSLog

/// Watch-side `WKApplicationDelegate` that catches the
/// `HKWorkoutConfiguration` handed off from the iPhone via
/// `HKHealthStore.startWatchApp(toHandle:)`.
///
/// Modern watchOS apps that want to participate in the workout
/// handoff flow MUST implement `handle(_ workoutConfiguration:)` —
/// it's the only way the system tells us "the iPhone wants us
/// running with these workout parameters."  After a successful
/// `startWatchApp` call from iOS, the system relays the
/// configuration to this method (usually within 1–2 seconds of
/// app launch).
///
/// **Phase D scope**: just stash the configuration on
/// `pendingWorkoutConfiguration` and let downstream code react.
/// `BumpyRideWatchAppApp` observes this property and routes it to
/// `WatchWorkoutManager` (Phase E), which is what actually creates
/// the `HKWorkoutSession`.  Decoupling the receiver from the
/// session manager keeps the delegate trivially testable and lets
/// us swap the session-creation strategy without changing the
/// system-facing API.
///
/// **Lifecycle**: `@WKApplicationDelegateAdaptor` creates the
/// delegate instance during scene setup and keeps it alive for the
/// entire app lifetime.  Marked `@Observable` so SwiftUI's
/// `.onChange(of: appDelegate.pendingWorkoutConfiguration)` fires
/// when a new configuration arrives.
@Observable
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    nonisolated private static let log = Logger(
        subsystem: "com.herbertindustries.BumpyRide.watchkitapp",
        category: "watch"
    )

    /// Most recent `HKWorkoutConfiguration` received from iOS.
    /// Cleared by the consumer (`BumpyRideWatchAppApp` in Phase E)
    /// after it's been routed into a workout session, so a
    /// subsequent `startWatchApp` call from iOS is treated as a
    /// fresh event rather than a state-comparison no-op.
    var pendingWorkoutConfiguration: HKWorkoutConfiguration?

    /// System callback when iPhone has called `startWatchApp` and
    /// the configuration is being handed to us.  Modern watchOS
    /// version of the iconic "workout handoff" entry point.
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        Self.log.info("Received HKWorkoutConfiguration via startWatchApp (activityType=\(workoutConfiguration.activityType.rawValue, privacy: .public))")
        pendingWorkoutConfiguration = workoutConfiguration
    }
}
