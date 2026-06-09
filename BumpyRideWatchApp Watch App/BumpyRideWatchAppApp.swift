import SwiftUI
import HealthKit

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
///
/// **v1.8 K13** changed when the `HKWorkoutSession` starts.  See
/// `pendingConfig` and the state-transition onChange for the
/// "session matches iPhone .recording" contract.
@main
struct BumpyRideWatchApp_Watch_AppApp: App {
    /// System-managed `WKApplicationDelegate` instance.  Created and
    /// retained by `@WKApplicationDelegateAdaptor` for the lifetime
    /// of the app.  Its `pendingWorkoutConfiguration` is the only
    /// way the v1.7 iOS-triggered workout handoff reaches our code.
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate

    @State private var session = WatchSessionManager()

    /// HKWorkoutSession owner.  Lifecycle is driven by iPhone state
    /// transitions in the .onChange below — start when the user
    /// actually begins riding, stop when they finish.
    @State private var workoutManager = WatchWorkoutManager()

    /// Stashed workout configuration from a previous
    /// `startWatchApp(toHandle:)` call, used at the moment we
    /// actually start the session.  See K13 rationale below.
    ///
    /// Falls back to a default cycling/outdoor config if the watch
    /// app was launched by some other path (manual tap, complication)
    /// — `start(with:)` always wants a configuration.
    @State private var pendingConfig: HKWorkoutConfiguration?

    var body: some Scene {
        WindowGroup {
            ContentView(session: session)
                .task {
                    session.activate()
                }
                .onChange(of: appDelegate.pendingWorkoutConfiguration) { _, config in
                    // **K13 change** (v1.8): no longer starts the
                    // HKWorkoutSession on receipt of the config.
                    // Just stash it for later use.
                    //
                    // The previous design (v1.7 Phase E) started the
                    // session immediately when iPhone called
                    // startWatchApp(toHandle:), which meant the watch's
                    // "now playing"-style workout card began showing a
                    // counting-up timer before the user had tapped
                    // Start on the iPhone — and kept counting if the
                    // user dismissed the watch app or the iPhone went
                    // to background.  Confusing UX: the rider sees a
                    // workout timer for a ride that hasn't begun yet.
                    //
                    // New contract: the workout session lifecycle
                    // mirrors iPhone's recorder state.  When iPhone
                    // transitions into .recording, we start the
                    // session.  When it transitions out, we stop.
                    // See the state-transition onChange below.
                    guard let config else { return }
                    pendingConfig = config
                    appDelegate.pendingWorkoutConfiguration = nil
                }
                .onChange(of: session.lastSnapshot.state) { oldState, newState in
                    // **K13 + K8 + Phase F** combined lifecycle:
                    // mirror iPhone's recorder state exactly.
                    //
                    //   .idle/.finished → .recording: start session
                    //   .recording/.paused → .idle/.finished: stop session
                    //   .recording ↔ .paused: leave session running
                    //     (HR collection should continue across pauses;
                    //     iPhone-side post-save query catches everything)
                    //
                    // K8's bug was stopping on EVERY transition to
                    // .idle, including the first snapshot at app
                    // launch.  K13 supersedes that by gating BOTH
                    // start and stop on "was inactive / was active"
                    // — the initial idle→idle landing is now neither
                    // and triggers nothing.
                    let wasInactive = (oldState == .idle || oldState == .finished)
                    let nowActive = (newState == .recording || newState == .paused)
                    let wasActive = (oldState == .recording || oldState == .paused)
                    let nowInactive = (newState == .idle || newState == .finished)

                    if wasInactive && nowActive {
                        // Pull the iPhone-sent config or build a
                        // default — either way the user has just
                        // tapped Start, so spin up the session.
                        let config = pendingConfig ?? defaultWorkoutConfig()
                        workoutManager.start(with: config)
                    }
                    if wasActive && nowInactive {
                        workoutManager.stop()
                    }
                }
        }
    }

    /// Cycling/outdoor configuration used when the watch app starts
    /// a workout session without having received a config from
    /// iPhone via startWatchApp — e.g., the user opened the watch
    /// app manually from the watch face and then tapped Start on
    /// the iPhone.  Matches the activity type the iPhone-side
    /// HealthKitExporter writes, so HR collection lands in the
    /// right shape for the post-save association query.
    private func defaultWorkoutConfig() -> HKWorkoutConfiguration {
        let config = HKWorkoutConfiguration()
        config.activityType = .cycling
        config.locationType = .outdoor
        return config
    }
}
