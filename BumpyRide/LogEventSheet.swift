import SwiftUI

/// v2.0 M2: kind picker presented by the live-recording "Log Event"
/// button.  Lists the built-in registry (Blocked Lane, prominent
/// orange) followed by the rider's custom kinds from Settings →
/// Reportable Events (bordered blue — visually "yours" vs the shared
/// built-ins).  Tapping a kind logs immediately at the current GPS
/// location and dismisses; there's no timeout — unlike the brake
/// categorization sheet this is rider-initiated, so it waits.
///
/// Button sizing follows the L5 conventions (60 pt rows, title3
/// semibold) — these get tapped mid-ride, often gloved.
struct LogEventSheet: View {
    let customKinds: [String]
    let onSelect: (_ kind: String, _ isCustom: Bool) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "flag.fill")
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(.orange)

            VStack(spacing: 6) {
                Text("Log an Event")
                    .font(.title2.weight(.bold))
                Text("What did you encounter?")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // Scrolls when the rider has defined many custom kinds
            // (cap is 20) — built-ins stay on top so the common case
            // is always the first tap.
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(OtherEvent.builtinKinds, id: \.kind) { builtin in
                        eventButton(title: builtin.displayName, prominent: true) {
                            onSelect(builtin.kind, false)
                        }
                    }
                    ForEach(customKinds, id: \.self) { kind in
                        eventButton(title: kind, prominent: false) {
                            onSelect(kind, true)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }

            Button {
                onCancel()
            } label: {
                Text("Cancel")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func eventButton(title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 60)
        }
        .buttonStyle(.borderedProminent)
        .tint(prominent ? .orange : .blue)
    }
}
