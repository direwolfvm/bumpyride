import SwiftUI

/// First-launch welcome / orientation sheet.  Presented once per install by
/// `ContentView`, gated on the `hasSeenIntro` AppStorage flag.
///
/// Deliberately short: three feature rows + a primary CTA.  The most important
/// row is the third one — telling the user up front that mounted recordings
/// produce the cleanest data is the single biggest predictor of whether they'll
/// end up with a useful Bump Map.  Without this nudge, many users default to
/// "phone in jersey pocket" and then wonder why their data looks attenuated.
///
/// We do *not* ask for permissions here — iOS will prompt for Location and
/// Motion the first time the user taps Start Ride.  Doing it preemptively in
/// onboarding tends to produce worse grant rates (no contextual reason yet).
struct IntroView: View {
    /// Called when the user dismisses the sheet.  ContentView wires this to
    /// flip `hasSeenIntro` so the sheet doesn't reappear on subsequent launches.
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 28) {
                    header

                    VStack(alignment: .leading, spacing: 24) {
                        FeatureRow(
                            icon: "waveform.path.ecg",
                            tint: .green,
                            title: "Measure your road",
                            subtitle: "BumpyRide samples GPS and your phone's accelerometer to capture how bumpy each stretch of road feels."
                        )
                        FeatureRow(
                            icon: "square.grid.3x3.fill",
                            tint: .blue,
                            title: "Build your Bump Map",
                            subtitle: "Every ride feeds a personal heat map you can use to find smoother routes — and avoid the rough ones."
                        )
                        FeatureRow(
                            icon: "bicycle",
                            tint: .orange,
                            title: "Mount your phone for best results",
                            subtitle: "BumpyRide works most accurately when your phone is mounted on the bike. Pocket and jersey-pouch recordings still work, but the readings are softened by your clothing and body."
                        )
                    }
                    .padding(.horizontal, 8)
                }
                .padding(.horizontal, 24)
                .padding(.top, 32)
                .padding(.bottom, 16)
            }

            Button(action: onContinue) {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        // Block swipe-to-dismiss — the only way out is the Get Started button,
        // which fires our completion handler.  Otherwise a casual swipe-down
        // would dismiss without flipping the AppStorage flag and the sheet
        // would reappear, looking buggy.
        .interactiveDismissDisabled(true)
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "bicycle.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)
            Text("Welcome to BumpyRide")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text("Map the bumpiness of every road you ride.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

/// Row used by `IntroView` to lay out an icon + title + multi-line subtitle.
/// Kept private to this file because it's intentionally onboarding-styled
/// (large icons, generous spacing) and doesn't fit anywhere else in the app.
private struct FeatureRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview {
    IntroView(onContinue: {})
}
