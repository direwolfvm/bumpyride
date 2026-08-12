import SwiftUI

/// v2.0 M2/N5: kind picker presented by the live-recording "Log Event"
/// button.  Lists the built-in registry (Blocked Lane, filled blue)
/// followed by the rider's custom kinds from Settings → Reportable
/// Events (outlined blue — hierarchy via fill weight, one hue for the
/// whole event feature).  Tapping a kind logs immediately at the
/// current GPS location and dismisses; there's no timeout — unlike the
/// brake categorization sheet this is rider-initiated, so it waits.
///
/// **v2.0 S4 — big mode.** When the ride screen is in reporting mode
/// (N6), the picker matches it: the header shrinks to buy vertical
/// space and the kind buttons grow to fill what's left, so the flow
/// stays no-look end to end.  Previously the buttons stayed 60 pt even
/// in reporting mode, which meant the *entry* button was huge and the
/// actual choice was back to small targets.
///
/// Sizing rule: buttons split the available height evenly, clamped to
/// `[bigMinHeight, bigMaxHeight]`.  One or two kinds → very large.
/// Many kinds → they squish to the floor and the list scrolls, which
/// is the right trade at the cap of 20 custom kinds.
struct LogEventSheet: View {
    let customKinds: [String]
    /// `true` while the ride screen is in reporting mode — see the
    /// type doc's "big mode".
    var bigButtons: Bool = false
    let onSelect: (_ kind: String, _ isCustom: Bool) -> Void
    let onCancel: () -> Void

    /// Standard (non-big) row height — the L5 tap-target convention.
    private static let normalHeight: CGFloat = 60
    /// Big mode floor: below this the "no-look" premise breaks, so we
    /// scroll instead of shrinking further.
    private static let bigMinHeight: CGFloat = 76
    /// Big mode ceiling: past this a lone button looks absurd and the
    /// travel to reach it gets long.
    private static let bigMaxHeight: CGFloat = 132
    private static let rowSpacing: CGFloat = 12

    private var totalKindCount: Int {
        OtherEvent.builtinKinds.count + customKinds.count
    }

    var body: some View {
        VStack(spacing: bigButtons ? 12 : 22) {
            if bigButtons {
                // Compact header: every point saved here goes to the
                // buttons.  Title only — the rider is mid-ride and
                // already knows why the sheet is up.
                Text("Log an Event")
                    .font(.title2.weight(.bold))
            } else {
                Image(systemName: "flag.fill")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(.blue)

                VStack(spacing: 6) {
                    Text("Log an Event")
                        .font(.title2.weight(.bold))
                    Text("What did you encounter?")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            // GeometryReader claims the space left after the header and
            // Cancel, so the rows can be sized against what's actually
            // available rather than a guess.
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: Self.rowSpacing) {
                        ForEach(OtherEvent.builtinKinds, id: \.kind) { builtin in
                            eventButton(
                                title: builtin.displayName,
                                prominent: true,
                                height: rowHeight(available: geo.size.height)
                            ) {
                                onSelect(builtin.kind, false)
                            }
                        }
                        ForEach(customKinds, id: \.self) { kind in
                            eventButton(
                                title: kind,
                                prominent: false,
                                height: rowHeight(available: geo.size.height)
                            ) {
                                onSelect(kind, true)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    // Center a short list in big mode instead of
                    // stranding it at the top under a lot of dead space.
                    .frame(minHeight: bigButtons ? geo.size.height : 0)
                }
            }

            Button {
                onCancel()
            } label: {
                Text("Cancel")
                    .font(bigButtons ? .title3 : .body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: bigButtons ? 56 : 44)
            }
            .buttonStyle(.plain)
        }
        .padding()
        // Big mode wants every available point; normal mode keeps the
        // half-height option so the map stays partly visible.
        .presentationDetents(bigButtons ? [.large] : [.medium, .large])
    }

    /// Split the available height across the rows, clamped.  Falls back
    /// to the fixed L5 height outside big mode.
    private func rowHeight(available: CGFloat) -> CGFloat {
        guard bigButtons, totalKindCount > 0 else { return Self.normalHeight }
        let spacing = Self.rowSpacing * CGFloat(max(0, totalKindCount - 1))
        let fit = (available - spacing) / CGFloat(totalKindCount)
        return min(Self.bigMaxHeight, max(Self.bigMinHeight, fit))
    }

    @ViewBuilder
    private func eventButton(
        title: String,
        prominent: Bool,
        height: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        // N5: single blue hue for the event feature; built-ins get the
        // filled style, custom kinds the outlined one.
        let label = Text(title)
            .font(bigButtons ? .title2.weight(.bold) : .title3.weight(.semibold))
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, minHeight: height)

        if prominent {
            Button(action: action) { label }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
        } else {
            Button(action: action) { label }
                .buttonStyle(.bordered)
                .tint(.blue)
        }
    }
}
