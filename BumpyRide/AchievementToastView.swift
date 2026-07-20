import SwiftUI

/// v2.0 N4: identity wrapper for the post-sync achievement toast —
/// fresh id per showing so replacement animates.
struct AchievementToastPayload: Identifiable, Equatable {
    let id = UUID()
    let awards: [WebSyncClient.AwardedAchievement]

    var totalPoints: Int { awards.reduce(0) { $0 + $1.points } }
}

/// v2.0 N4: compact banner shown at the top of the app for ~6 s when
/// a synced ride earns achievements (`achievementsAwarded` in the sync
/// response).  One award shows its name; several collapse to a count.
/// Tap anywhere to dismiss.  Solid background per the L6 sunlight
/// rules — this appears right after rides, i.e. plausibly outdoors.
struct AchievementToastView: View {
    let payload: AchievementToastPayload
    let onDismiss: () -> Void

    var body: some View {
        Button(action: onDismiss) {
            HStack(spacing: 12) {
                Image(systemName: payload.awards.count == 1 && payload.awards[0].milestone
                      ? "flag.checkered" : "rosette")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("+\(payload.totalPoints)")
                    .font(.title3.monospacedDigit().weight(.bold))
                    .foregroundStyle(.orange)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.orange.opacity(0.5)))
            .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(payload.totalPoints) points. Tap to dismiss.")
    }

    private var title: String {
        if payload.awards.count == 1 {
            return payload.awards[0].name
        }
        return "\(payload.awards.count) achievements"
    }

    private var subtitle: String {
        if payload.awards.count == 1 {
            return payload.awards[0].milestone ? "Milestone reached" : "Achievement earned"
        }
        // Name the first couple so the toast is informative even
        // when collapsed.
        return payload.awards.map(\.name).prefix(3).joined(separator: ", ")
    }
}
