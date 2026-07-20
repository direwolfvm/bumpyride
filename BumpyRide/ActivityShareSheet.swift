import SwiftUI
import UIKit

/// v2.0 M5: item wrapper for the ride-photo share flow.  `UIImage`
/// isn't Identifiable, and `.sheet(item:)` wants identity so each
/// share presents fresh.
struct RidePhotoSharePayload: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// v2.0 M5: thin `UIActivityViewController` wrapper — the system share
/// sheet.  Used for the ride summary photo: one surface covers Save
/// Image (the old "Export to Photos" behavior, via the sheet's
/// built-in activity — `NSPhotoLibraryAddUsageDescription` is already
/// in the Info.plist), Messages, Mail, AirDrop, and whatever social
/// apps the user has installed.  SwiftUI's `ShareLink` was considered
/// but it wants the item up front; our image is rendered on demand
/// (map snapshot + composite takes a second or two), so presenting the
/// UIKit controller with the finished image via `.sheet(item:)` is the
/// cleaner fit.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
