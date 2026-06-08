import SwiftUI

/// v1.7 H3 celebration sheet.  Presented when a user-initiated ride
/// upload pushes the user's total points across a level threshold
/// (see `LevelProgressionMonitor.checkAfterRideUpload`).
///
/// Visual: a softly animated `sparkles` SF Symbol over the new
/// level's name, with a short "previous → new" transition line.
/// Lightweight enough not to feel cheesy on a quick glance, just
/// celebratory enough that you notice it.
struct LevelUpCelebrationSheet: View {
    let celebration: LevelProgressionMonitor.PendingCelebration

    @Environment(\.dismiss) private var dismiss

    /// Drives the sparkles wiggle.  Kicked once on appear; uses
    /// `repeatForever(autoreverses:)` so the animation stays alive
    /// the whole time the sheet is on screen.
    @State private var sparkleScale: CGFloat = 1.0
    @State private var sparkleRotation: Double = 0

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 96, weight: .bold))
                .foregroundStyle(.yellow)
                .scaleEffect(sparkleScale)
                .rotationEffect(.degrees(sparkleRotation))
                .shadow(color: .yellow.opacity(0.5), radius: 12)

            VStack(spacing: 8) {
                Text("Level Up!")
                    .font(.largeTitle.weight(.bold))

                Text("Welcome to")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Text(celebration.newLevel.name)
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(.blue)
                    .multilineTextAlignment(.center)
            }

            // Transition line — small, secondary, gives the moment
            // some context ("you came from X").
            Text("\(celebration.previousLevelName) → \(celebration.newLevel.name)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()

            Button {
                dismiss()
            } label: {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 32)
        }
        .padding()
        .onAppear {
            withAnimation(.spring(response: 0.9, dampingFraction: 0.5).repeatForever(autoreverses: true)) {
                sparkleScale = 1.18
                sparkleRotation = 8
            }
        }
    }
}
