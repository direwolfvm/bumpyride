import SwiftUI

/// Detail view for the user's `/api/me/score` gamification state.  Pushed
/// from `WebAccountView`'s Score row.  Mirrors the web's `/score` page
/// layout — hero card, breakdown, rules, ladder — adapted to a SwiftUI
/// Form-style scrollable layout that feels native on iPhone.
///
/// Renders one of three states based on what `fetchScore` returns:
///
/// - **Loaded + eligible**: full hero/breakdown/rules/ladder.
/// - **Loaded + !eligible**: empty state with a callout linking back to
///   the Web Account view's sharing toggle.  The server still responds
///   200 in this case; we just hide the misleading "0 points" numbers.
/// - **Loading / failed**: spinner or error row.  Pull-to-refresh on
///   either to retry.
struct ScoreView: View {
    @Bindable var account: WebAccount

    @State private var data: WebSyncClient.ScoreData?
    @State private var isLoading: Bool = false
    @State private var loadError: String?

    var body: some View {
        Form {
            if let data {
                if data.eligible {
                    heroSection(for: data)
                    breakdownSection(for: data.breakdown)
                    rulesSection
                    ladderSection(for: data)
                } else {
                    notEligibleSection
                }
            } else if isLoading {
                Section {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("Loading score…")
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
        .navigationTitle("Score")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await refresh()
        }
        .task {
            // Initial load on appear.  Pull-to-refresh handles subsequent
            // manual refreshes; ContentView triggers a re-fetch after a
            // ride syncs (Phase C).
            await refresh()
        }
    }

    // MARK: - Sections

    /// Hero card at the top: level name + index, total points, progress
    /// bar toward the next level.  Modeled on the web's hero card but
    /// adapted to a Form section.
    private func heroSection(for data: WebSyncClient.ScoreData) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Level \(data.level.index)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(data.level.name)
                            .font(.title2.bold())
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Self.formattedPoints(data.totalPoints))
                            .font(.title.monospacedDigit().weight(.bold))
                            .foregroundStyle(.green)
                        Text("points")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                // Progress bar.  At max level the server sends progress=1.0
                // and nextThreshold==threshold; we show "Max level" instead
                // of pretending there's more to go.
                if data.level.nextThreshold > data.level.threshold {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: max(0, min(1, data.level.progress)))
                            .progressViewStyle(.linear)
                            .tint(.green)
                        HStack {
                            Text(Self.formattedPoints(data.totalPoints))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Self.formattedPoints(data.level.nextThreshold)) to next")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Label("Max level reached", systemImage: "crown.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Four tier rows, one per scoring rule.  Counts and computed
    /// points shown together so the user can see both the quantity of
    /// cells touched and the points contributed.  Ordered by
    /// descending multiplier (10 → 5 → 3 → 1) so the rarest /
    /// most-valuable contribution reads first.
    ///
    /// The "Refreshed" row is omitted entirely when the server returns
    /// no `staleRefresh` key (older deployments pre-migration 0016) —
    /// same nil-guarded pattern used by the per-ride disclosure in
    /// RideView so the rolling deploy window stays clean.
    private func breakdownSection(for breakdown: WebSyncClient.ScoreBreakdown) -> some View {
        Section {
            tierRow(
                title: "First ever",
                count: breakdown.firstEver,
                pointsPerEvent: 10,
                color: .purple,
                detail: "Cells you were the first to map"
            )
            tierRow(
                title: "First for you",
                count: breakdown.firstForYou,
                pointsPerEvent: 5,
                color: .blue,
                detail: "Cells others mapped before you"
            )
            if let staleRefresh = breakdown.staleRefresh {
                tierRow(
                    title: "Refreshed",
                    count: staleRefresh,
                    pointsPerEvent: 3,
                    color: .orange,
                    detail: "Cells you last rode more than 10 days ago"
                )
            }
            tierRow(
                title: "Repeat visits",
                count: breakdown.repeats,
                pointsPerEvent: 1,
                color: .gray,
                detail: "Re-rides of cells you've already mapped"
            )
        } header: {
            Text("Breakdown")
        }
    }

    private func tierRow(title: String, count: Int, pointsPerEvent: Int, color: Color, detail: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(count) × \(pointsPerEvent)pt")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(Self.formattedPoints(count * pointsPerEvent))
                    .font(.callout.monospacedDigit().weight(.bold))
                    .foregroundStyle(color)
            }
        }
        .padding(.vertical, 2)
    }

    /// Plain-language explanation of the scoring system.  Mirrors the
    /// rules card on the web's `/score` page.  Worth showing because
    /// without context the breakdown numbers don't explain themselves.
    private var rulesSection: some View {
        Section {
            ruleRow(symbol: "10", color: .purple, title: "First ever", body: "When you're the first person in the world to record bump data in a 20-ft cell, you earn 10 points.")
            ruleRow(symbol: "5", color: .blue, title: "First for you", body: "When you ride through a cell that other riders have already mapped, you earn 5 points the first time.")
            ruleRow(symbol: "3", color: .orange, title: "Refreshed", body: "When you re-ride a cell you've already mapped but haven't visited in over 10 days, you earn 3 points — rewards keeping your coverage current.")
            ruleRow(symbol: "1", color: .gray, title: "Repeat visits", body: "Every other ride through a cell you've already mapped earns 1 more point.")
        } header: {
            Text("How scoring works")
        } footer: {
            Text("You only earn points on rides where you're sharing publicly **and** the phone was mounted on the bike (not in your pocket). Toggle sharing in Settings → Web Account.")
        }
    }

    private func ruleRow(symbol: String, color: Color, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(symbol)
                .font(.title3.monospacedDigit().bold())
                .foregroundStyle(color)
                .frame(width: 32, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    /// Full 20-level ladder.  Current level is highlighted with the
    /// accent color and a checkmark; levels below are dimmed.  Future
    /// levels show the points threshold so the user knows what's coming.
    private func ladderSection(for data: WebSyncClient.ScoreData) -> some View {
        Section {
            ForEach(data.levels) { level in
                ladderRow(level: level, currentIndex: data.level.index)
            }
        } header: {
            Text("Level ladder")
        }
    }

    private func ladderRow(level: WebSyncClient.Level, currentIndex: Int) -> some View {
        let isCurrent = level.index == currentIndex
        let isPast = level.index < currentIndex
        return HStack(spacing: 12) {
            // Leading marker: checkmark for past/current, dot for future.
            if isPast {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green.opacity(0.6))
            } else if isCurrent {
                Image(systemName: "circle.inset.filled")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary.opacity(0.4))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(level.name)
                    .font(.callout.weight(isCurrent ? .bold : .regular))
                    .foregroundStyle(isCurrent ? .primary : (isPast ? .secondary : .primary))
                Text("Level \(level.index)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Self.formattedPoints(level.threshold))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }

    /// Shown when the user isn't currently sharing publicly.  Sharing is
    /// the prerequisite for the scoring system, so we explain that
    /// directly and avoid the empty hero / "0 points" trap.
    private var notEligibleSection: some View {
        Section {
            VStack(spacing: 16) {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text("Score isn't enabled")
                    .font(.title3.bold())
                Text("To start earning points, turn on **Share my rides on the public bump map** in Settings → Web Account. Pocket-mode rides don't count toward scoring even when sharing is on.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Refresh

    private func refresh() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            data = try await account.fetchScore()
        } catch WebSyncClient.ClientError.unauthorized {
            // WebAccount already transitioned to error state; parent view
            // will collapse the connected section.  No banner needed here.
            data = nil
        } catch WebSyncClient.ClientError.transport {
            loadError = "Couldn't reach bumpyride.me. Check your network and try again."
        } catch {
            loadError = "Couldn't load score. Try again later."
        }
    }

    // MARK: - Helpers

    /// Localized integer formatting with grouping separators
    /// ("12,345" instead of "12345").
    private static let pointsFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private static func formattedPoints(_ n: Int) -> String {
        pointsFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
