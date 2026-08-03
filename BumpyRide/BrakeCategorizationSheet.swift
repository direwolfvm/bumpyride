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

    /// v2.0 S3 instrumentation — same category as the parent's
    /// lifecycle logging so one grep shows the whole interaction.
    nonisolated private static let log = DebugLog(category: "brake-sheet")

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
            // v1.8 L5: full 44 pt minimum tap height so the skip
            // affordance is reachable mid-ride too, while staying
            // visually subordinate to the category buttons.
            Button {
                commit(.unknown)
            } label: {
                Text("Skip")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)

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
        // S3: swipe-to-dismiss is no longer disabled.  It was blocked
        // so a bump couldn't dismiss the prompt mid-ride, but that
        // also meant a sheet in a bad state had NO exit — the reported
        // recovery was force-killing the app mid-ride.  A deliberate
        // swipe is a fine "leave it uncategorized", and the safety
        // net matters more than the stray-gesture risk.
        .interactiveDismissDisabled(false)
        .onAppear {
            // S3: `committed` surviving from a previous brake (view
            // reuse) is the stuck-sheet failure mode — the parent's
            // .id() should prevent it, but log if it ever happens so
            // the sidecar names the culprit instead of us guessing.
            if committed {
                Self.log.error("appeared with committed=true — stale view reused for brake \(brake.id); resetting")
                committed = false
            }
            Self.log.info("sheet appeared for brake \(brake.id)")
            // Kick the linear shrink animation immediately and the
            // auto-dismiss timer in parallel.
            withAnimation(.linear(duration: Self.timeoutSeconds)) {
                remainingFraction = 0
            }
            timeoutTask?.cancel()
            timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Self.timeoutSeconds * 1_000_000_000))
                guard !Task.isCancelled else {
                    Self.log.debug("timeout task cancelled for brake \(brake.id)")
                    return
                }
                Self.log.info("timeout fired for brake \(brake.id)")
                commit(nil)
            }
        }
        .onDisappear {
            Self.log.info("sheet disappeared for brake \(brake.id) (committed=\(committed))")
            timeoutTask?.cancel()
            // Swipe-dismiss path: the sheet is gone but nothing has
            // told the parent, so it would sit in the settling window
            // with a queue it never drains.  Commit as uncategorized
            // (same outcome as the timeout) to close the loop.
            if !committed {
                Self.log.info("dismissed without a choice for brake \(brake.id) — recording as uncategorized")
                commit(nil)
            }
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
            // v1.8 L5: taller tap target + heavier type.  These get
            // pressed mid-ride, often gloved or with the phone on a
            // mount — 60 pt rows and title3 text are far easier to
            // hit than the default large-control height.
            Label(title, systemImage: systemImage)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 60)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
    }

    /// Single-shot commit gate.  Either the timer or a button
    /// reaches here first; the other path no-ops on the second
    /// call.
    private func commit(_ category: BrakeEventCategory?) {
        guard !committed else {
            // S3: if this ever logs on a *tap*, the sheet on screen is
            // stale — exactly the reported "pressed Other and nothing
            // happened."  Naming it here beats inferring it later.
            Self.log.error("commit ignored (already committed) for brake \(brake.id) — sheet is stale")
            return
        }
        committed = true
        timeoutTask?.cancel()
        onCommit(category)
    }
}
