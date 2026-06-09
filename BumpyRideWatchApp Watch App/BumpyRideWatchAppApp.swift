import SwiftUI

/// Watch app entry.  The auto-generated struct name keeps Xcode's
/// disambiguation suffix (`Watch_AppApp`) because renaming it would
/// touch the `@main` plumbing for marginal cosmetic value.
///
/// Owns the long-lived state for the watch app:
///   - `WatchSessionManager` for WatchConnectivity (v1.6 Phase B+)
///   - `WatchAppDelegate` for the iOS → watch HKWorkoutConfiguration
///     handoff via `@WKApplicationDelegateAdaptor` (v1.7 Phase D)
///
/// Activation of the WC session is kicked off in a `.task` rather
/// than in `init` so the App-conformance bootstrap stays fast.
@main
struct BumpyRideWatchApp_Watch_AppApp: App {
    /// System-managed `WKApplicationDelegate` instance.  Created and
    /// retained by `@WKApplicationDelegateAdaptor` for the lifetime
    /// of the app.  Its `pendingWorkoutConfiguration` is the only
    /// way the v1.7 iOS-triggered workout handoff reaches our code.
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate

    @State private var session = WatchSessionManager()

    /// HKWorkoutSession owner for the v1.7 watch HealthKit handoff.
    /// Starts a session when `appDelegate.pendingWorkoutConfiguration`
    /// is set (handled by the `.onChange` below).  Phase F will wire
    /// its `stop()` to the iPhone's ride-stop signal.
    @State private var workoutManager = WatchWorkoutManager()

    var body: some Scene {
        WindowGroup {
            ContentView(session: session)
                .task {
                    session.activate()
                }
                .onChange(of: appDelegate.pendingWorkoutConfiguration) { _, config in
                    // v1.7 Phase E: receive the workout configuration
                    // from the delegate and spin up the HKWorkoutSession.
                    // Clear the delegate's stash after consumption so a
                    // subsequent startWatchApp from iOS is treated as a
                    // fresh event rather than a state-comparison no-op.
                    guard let config else { return }
                    workoutManager.start(with: config)
                    appDelegate.pendingWorkoutConfiguration = nil
                }
                .onChange(of: session.lastSnapshot.state) { oldState, newState in
                    // v1.7 Phase F / v1.8 K8: end the watch's
                    // HKWorkoutSession when the iPhone's recorder
                    // transitions OUT of an active state.  Heart-rate
                    // samples stay in HealthKit (watchOS saves them
                    // independently); the iPhone-side HealthKitExporter
                    // queries them back at ride-save time and embeds
                    // them in the canonical cycling HKWorkout.
                    //
                    // .recording → .paused doesn't trigger stop; a
                    // paused ride is still in flight and we want HR
                    // collection to keep going so the iPhone's
                    // post-save query catches all of it.
                    //
                    // **K8 fix**: only stop when transitioning FROM
                    // an active state.  The previous version stopped
                    // on `newState == .idle` regardless of `oldState`,
                    // which fired immediately at app launch — the
                    // first snapshot from the iPhone (which is in
                    // .idle until the user taps Start) ended the
                    // workout session we'd JUST started via the
                    // startWatchApp handoff.  Without an active
                    // HKWorkoutSession the watch app gets suspended
                    // within ~30s of wrist-drop, which is exactly the
                    // "doesn't last long on the wrist" symptom we
                    // were seeing.
                    let wasActive = (oldState == .recording || oldState == .paused)
                    let nowInactive = (newState == .idle || newState == .finished)
                    if wasActive && nowInactive {
                        workoutManager.stop()
                    }
                }
        }
    }
}
