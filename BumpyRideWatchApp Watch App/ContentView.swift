import SwiftUI

/// **Phase A placeholder.**  The watch app target exists, builds, and
/// launches — but doesn't talk to the iPhone yet.  Phase B adds the
/// `WatchSessionManager`, real connectivity status, and a "Phone
/// connected ✓ / ✗" indicator.  Phase G replaces this entirely with
/// the paged `TabView` containing the close-call button, controls,
/// and stats pages.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "bicycle")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("BumpyRide")
                .font(.headline)
            Text("Phase A")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
