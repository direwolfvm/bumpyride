//
//  BumpyRideApp.swift
//  BumpyRide
//
//  Created by Jordan Eccles on 4/21/26.
//

import SwiftUI
import UIKit

/// v1.8 L2: minimal UIKit app delegate, present for exactly one job —
/// receiving `handleEventsForBackgroundURLSession` when iOS relaunches
/// the app because background ride uploads finished.  The completion
/// handler is stashed on `BackgroundUploadClient` and called after the
/// session delegate drains its queued events (per Apple's contract).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundUploadClient.sessionIdentifier else {
            completionHandler()
            return
        }
        // Touching `.shared` recreates the session with our delegate so
        // the pending events have somewhere to be delivered.
        BackgroundUploadClient.shared.backgroundCompletionHandler = completionHandler
    }
}

@main
struct BumpyRideApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
