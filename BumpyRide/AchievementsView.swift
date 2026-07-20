import SwiftUI

/// v2.0 N3: the achievements screen, fed by `GET /api/me/achievements`
/// (see `docs/ACHIEVEMENTS_IOS_HANDOFF.md`).  Pushed from ScoreView's
/// Achievements row.  Pure display — the server is the source of truth
/// for awards; thresholds shown here are copy, not local awarding
/// logic.
///
/// Layout: summary tiles (achievement points + total awards), the
/// registry grouped by category with locked states for unearned
/// entries, then the recent-awards feed (server-capped at 50, newest
/// first, ordered by ride time).
struct AchievementsView: View {
    @Bindable var account: WebAccount

    @State private var data: WebSyncClient.AchievementsData?
    @State private var isLoading: Bool = false
    @State private var loadError: String?

    /// Category display order + names.  Unknown categories (future
    /// server additions) append after the known ones so nothing is
    /// silently dropped.
    private static let categoryOrder: [(id: String, name: String)] = [
        ("ride", "Ride"),
        ("exploration", "Exploration"),
        ("surface", "Surface"),
        ("safety", "Safety"),
        ("milestone", "Milestones"),
    ]

    var body: some View {
        Form {
            if let data {
                summarySection(for: data)
                registrySections(for: data)
                recentSection(for: data)
            } else if isLoading {
                Section {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("Loading achievements…")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Button("Try again") {
                        Task { await refresh() }
                    }
                }
            }
        }
        .navigationTitle("Achievements")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
        .task { await refresh() }
    }

    // MARK: - Sections

    private func summarySection(for data: WebSyncClient.AchievementsData) -> some View {
        Section {
            HStack(spacing: 0) {
                summaryStat(
                    icon: "rosette",
                    value: Self.formattedPoints(data.totalPoints),
                    label: "Achievement points"
                )
                Divider().frame(height: 44)
                summaryStat(
                    icon: "number",
                    value: "\(data.totalAwards)",
                    label: "Awards earned"
                )
            }
        }
    }

    private func summaryStat(icon: String, value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.orange)
            Text(value)
                .font(.title3.monospacedDigit().weight(.bold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func registrySections(for data: WebSyncClient.AchievementsData) -> some View {
        let grouped = Dictionary(grouping: data.registry, by: \.category)
        let knownIds = Self.categoryOrder.map(\.id)
        let unknown = grouped.keys.filter { !knownIds.contains($0) }.sorted()

        ForEach(Self.categoryOrder, id: \.id) { category in
            if let entries = grouped[category.id], !entries.isEmpty {
                Section(category.name) {
                    ForEach(entries) { entry in
                        registryRow(entry)
                    }
                }
            }
        }
        ForEach(unknown, id: \.self) { category in
            if let entries = grouped[category] {
                Section(category.capitalized) {
                    ForEach(entries) { entry in
                        registryRow(entry)
                    }
                }
            }
        }
    }

    private func registryRow(_ entry: WebSyncClient.AchievementRegistryEntry) -> some View {
        let locked = entry.earnedCount == 0
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: locked ? "lock.fill" : Self.icon(for: entry.category))
                .font(.title3)
                .foregroundStyle(locked ? Color.secondary.opacity(0.5) : .orange)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(locked ? .secondary : .primary)
                Text(entry.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Tier ladder as display copy ("next tier at…" context).
                // Direction-neutral formatting — silk-road's thresholds
                // are lower-is-better, so no ≥/≤ symbols.
                Text(entry.tiers.map { "\(Self.formattedThreshold($0.threshold)) → \($0.points)" }
                    .joined(separator: "  ·  "))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            Spacer()
            if !locked {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("×\(entry.earnedCount)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                    Text("\(Self.formattedPoints(entry.earnedPoints)) pts")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func recentSection(for data: WebSyncClient.AchievementsData) -> some View {
        if !data.recent.isEmpty {
            let names = Dictionary(uniqueKeysWithValues: data.registry.map { ($0.id, $0.name) })
            Section {
                ForEach(Array(data.recent.enumerated()), id: \.offset) { _, award in
                    HStack(spacing: 12) {
                        Image(systemName: award.rideId == nil ? "flag.checkered" : "rosette")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(names[award.achievementId] ?? award.achievementId)
                                .font(.callout.weight(.medium))
                            Text(Formatters.dateTime(award.earnedAt))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("+\(award.points)")
                            .font(.callout.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Recent")
            } footer: {
                Text("Newest first, by ride time. Milestone rungs show a checkered flag.")
            }
        }
    }

    // MARK: - Refresh

    private func refresh() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            data = try await account.fetchAchievements()
        } catch WebSyncClient.ClientError.unauthorized {
            data = nil
        } catch WebSyncClient.ClientError.http(let status) where status == 404 {
            loadError = "Achievements aren't available on the server yet."
        } catch WebSyncClient.ClientError.transport {
            loadError = "Couldn't reach bumpyride.me. Check your network and try again."
        } catch {
            loadError = "Couldn't load achievements. Try again later."
        }
    }

    // MARK: - Helpers

    private static func icon(for category: String) -> String {
        switch category {
        case "ride": return "bicycle"
        case "exploration": return "map.fill"
        case "surface": return "waveform.path"
        case "safety": return "shield.fill"
        case "milestone": return "flag.checkered"
        default: return "rosette"
        }
    }

    /// "5" not "5.0", but "0.25" keeps its fraction.
    private static func formattedThreshold(_ t: Double) -> String {
        t == t.rounded() ? String(Int(t)) : String(format: "%.2f", t)
    }

    private static let pointsFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private static func formattedPoints(_ n: Int) -> String {
        pointsFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
