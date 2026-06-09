import SwiftUI

/// v1.7 J2 live-recording categorization sheet for a freshly-
/// detected brake event.  Three buttons (Safety / Other / Error)
/// and a 20-second auto-dismiss countdown — if the rider can't
/// engage (phone in pocket, hands on bars), the modal closes
/// itself and the brake is left without a category (renders as
/// "Unknown" in playback).
///
/// **Caller contract**: `onCommit` fires exactly once, either:
///   - with a `.safety`, `.other`, or `.error` when the rider
///     taps a button, OR
///   - with `nil` when the 20 s timer expires untouched, OR
///   - with `.unknown` if the rider taps the explicit Dismiss
///     button (distinct from the timeout — we record the
///     intentional dismiss so analytics can tell the two apart).
///
/// SwiftUI's `.sheet(item:)` should rebind to nil after `onCommit`;
/// the parent view is responsible for popping the brake from its
/// pending queue.
struct BrakeCategorizationSheet: View {
    let brake: BrakeEvent
    let onCommit: (BrakeEventCategory?) -> Void

    /// Seconds before the modal auto-dismisses.  20 s gives the
    /// rider enough time to look down at the phone after coming
    /// to a stop or pulling off, without nagging if they can't.
    private static let timeoutSeconds: Double = 20

    /// Drives the linear-shrinking progress bar at the bottom of
    /// the sheet.  Animates from 1.0 → 0.0 over the timeout
    /// window.
    @State private var remainingFraction: Double = 1.0

    /// Auto-dismiss timer.  Spawned on appear, cancelled on
    /// disappear.  Fires `onCommit(nil)` if not cancelled first by
    /// a button tap.
    @State private var timeoutTask: Task<Void, Never>?

    /// Guard so the timer and a button tap can't both fire
    /// `onCommit`.  Whichever wins flips this; the other no-ops.
    @State private var committed: Bool = false

    var body: some View {
        VStack(spacing: 22) {
            // Header — visually loud so a glance recognizes it.
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(.red)

            VStack(spacing: 6) {
                Text("Hard Brake Detected")
                    .font(.title2.weight(.bold))
                Text("Why did you brake?")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                categoryButton(
                    title: "Safety",
                    systemImage: "shield.lefthalf.filled",
                    category: .safety,
                    tint: .red
                )
                categoryButton(
                    title: "Other",
                    systemImage: "arrow.triangle.turn.up.right.diamond.fill",
                    category: .other,
                    tint: .blue
                )
                categoryButton(
                    title: "False trigger",
                    systemImage: "xmark.circle.fill",
                    category: .error,
                    tint: .gray
                )
            }
            .padding(.horizontal, 8)

            // Subtle dismiss-without-categorizing.  Records as
            // .unknown so we can tell intentional dismissal from
            // the timer running out.
            Button("Skip") {
                commit(.unknown)
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            // Countdown bar — fills the sheet's full width at the
            // bottom so the rider can see at a glance how much
            // time they have left before auto-dismissal.
            VStack(spacing: 4) {
                ProgressView(value: remainingFraction)
                    .tint(.secondary)
                Text("Auto-dismisses in 20 s")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)
        }
        .padding()
        .interactiveDismissDisabled(true)
        .onAppear {
            // Kick the linear shrink animation immediately and the
            // auto-dismiss timer in parallel.
            withAnimation(.linear(duration: Self.timeoutSeconds)) {
                remainingFraction = 0
            }
            timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Self.timeoutSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                commit(nil)
            }
        }
        .onDisappear {
            timeoutTask?.cancel()
        }
    }

    /// Single button that fires `onCommit(category)` once and
    /// dismisses the sheet via the parent's item-binding pattern.
    private func categoryButton(
        title: String,
        systemImage: String,
        category: BrakeEventCategory,
        tint: Color
    ) -> some View {
        Button {
            commit(category)
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .controlSize(.large)
    }

    /// Single-shot commit gate.  Either the timer or a button
    /// reaches here first; the other path no-ops on the second
    /// call.
    private func commit(_ category: BrakeEventCategory?) {
        guard !committed else { return }
        committed = true
        timeoutTask?.cancel()
        onCommit(category)
    }
}
