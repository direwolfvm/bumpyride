import SwiftUI

/// v1.7 J3 live-recording categorization sheet for a freshly-logged
/// close call.  Three buttons (Vehicle / Bike / Pedestrian) and a
/// 20-second auto-dismiss countdown.  Different from
/// `BrakeCategorizationSheet` in two ways:
///
///   1. **Default on timeout is `.vehicle`**, not nil.  Close calls
///      with vehicles are by far the most common case on shared
///      roadways — auto-stamping `.vehicle` when the rider can't
///      engage gives the right answer for most actual close calls.
///      Riders who got close-called by a bike or pedestrian will
///      have a moment to specify.
///
///   2. **No `.unknown` case** in `CloseCallCategory`.  The rider
///      tapped the close-call button — they know what they're
///      reporting.  We don't preserve "user dismissed without
///      choosing" as a distinct state; that just becomes the
///      default `.vehicle`.
///
/// **Caller contract**: `onCommit` fires exactly once with the
/// chosen category.  The parent view is responsible for popping
/// the sheet via its item-binding.
struct CloseCallCategorizationSheet: View {
    let closeCall: CloseCall
    let onCommit: (CloseCallCategory) -> Void

    private static let timeoutSeconds: Double = 20

    @State private var remainingFraction: Double = 1.0
    @State private var timeoutTask: Task<Void, Never>?
    @State private var committed: Bool = false

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(.purple)

            VStack(spacing: 6) {
                Text("Close Call Logged")
                    .font(.title2.weight(.bold))
                Text("What kind?")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                categoryButton(
                    title: "Vehicle",
                    systemImage: "car.fill",
                    category: .vehicle,
                    tint: .red
                )
                categoryButton(
                    title: "Bike",
                    systemImage: "bicycle",
                    category: .bike,
                    tint: .blue
                )
                categoryButton(
                    title: "Pedestrian",
                    systemImage: "figure.walk",
                    category: .pedestrian,
                    tint: .green
                )
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 8)

            VStack(spacing: 4) {
                ProgressView(value: remainingFraction)
                    .tint(.secondary)
                Text("Defaults to Vehicle in 20 s")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)
        }
        .padding()
        .interactiveDismissDisabled(true)
        .onAppear {
            withAnimation(.linear(duration: Self.timeoutSeconds)) {
                remainingFraction = 0
            }
            timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Self.timeoutSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                // Timeout default is .vehicle per the v1.7 J3 spec.
                commit(.vehicle)
            }
        }
        .onDisappear {
            timeoutTask?.cancel()
        }
    }

    private func categoryButton(
        title: String,
        systemImage: String,
        category: CloseCallCategory,
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

    private func commit(_ category: CloseCallCategory) {
        guard !committed else { return }
        committed = true
        timeoutTask?.cancel()
        onCommit(category)
    }
}
