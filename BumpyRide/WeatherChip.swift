import SwiftUI
#if canImport(WeatherKit)
import WeatherKit
#endif

/// v1.8 weather overlay for the live-recording map.  Compact two-row
/// readout with temperature on top, wind speed + relative arrow
/// underneath, and a Headwind/Tailwind/Crosswind label tinted by
/// the wind relation when bike heading is known.
///
/// **Display rules**:
///
///   - Hidden entirely when `weather` is nil (cache empty / fetch
///     hasn't landed yet).  No placeholder; the user shouldn't see
///     a flicker.
///
///   - The relative arrow + relation label render only when
///     `bikeHeading` is non-nil.  A stationary rider sees temp +
///     wind speed + direction, but the headwind/tailwind label is
///     hidden because `CLLocation.course` is unreliable below ~3
///     m/s (caller's responsibility to gate).
///
///   - "Apple Weather" attribution at the bottom is required by
///     WeatherKit's terms of service.  Small but always present.
struct WeatherChip: View {
    #if canImport(WeatherKit)
    let weather: CurrentWeather
    #endif
    /// Bike's current compass heading in degrees, or nil if not
    /// reliable.  When nil, the headwind/tailwind label hides.
    let bikeHeading: Double?

    var body: some View {
        #if canImport(WeatherKit)
        VStack(alignment: .trailing, spacing: 4) {
            // Temperature
            HStack(spacing: 4) {
                Image(systemName: "thermometer.medium")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(formattedTemp)
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
            }

            // Wind speed + arrow
            HStack(spacing: 4) {
                if let bikeHeading {
                    // Arrow rotates so its tail points in the
                    // direction the wind is BLOWING TOWARD the
                    // rider (i.e., toward the bike's "down" when
                    // course is up).  A wind in the face has the
                    // arrow pointing down; tailwind points up.
                    //
                    // The arrow base ("arrow.down" pointing down)
                    // already corresponds to a headwind at 0°
                    // signed-relative-angle; rotate by the signed
                    // angle to express other cases.
                    Image(systemName: "arrow.down")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(
                            WindRelation.signedRelativeAngle(
                                windDirection: weather.wind.direction.value,
                                bikeHeading: bikeHeading
                            )
                        ))
                        .foregroundStyle(relationTint)
                } else {
                    Image(systemName: "wind")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(formattedWindSpeed)
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
            }

            // Relation label (headwind / tailwind / crosswind),
            // only when we have a heading.
            if let bikeHeading {
                let relation = WindRelation.classify(
                    windDirection: weather.wind.direction.value,
                    bikeHeading: bikeHeading
                )
                Text(relationLabel(for: relation))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(relationTint)
            }

            // Apple Weather attribution.  Required by WeatherKit
            // ToS.  Tiny + secondary so it doesn't crowd the
            // primary readouts but is always visible.
            Text("Apple Weather")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        #else
        EmptyView()
        #endif
    }

    #if canImport(WeatherKit)
    private var formattedTemp: String {
        // Imperial °F to match the rest of the app (we use mi/ft for
        // distance).  Round to whole degrees — wind chip is glance-
        // sized.
        let f = weather.temperature.converted(to: .fahrenheit).value
        return String(format: "%.0f°F", f)
    }

    private var formattedWindSpeed: String {
        let mph = weather.wind.speed.converted(to: .milesPerHour).value
        return String(format: "%.0f mph", mph)
    }

    /// Color tint for the relation arrow + label.  Tracks how
    /// favorable the wind is for the rider:
    ///   - tailwind: green (helpful)
    ///   - crosswind: orange (neutral-to-meddlesome)
    ///   - headwind: red (working against)
    private var relationTint: Color {
        guard let bikeHeading else { return .secondary }
        switch WindRelation.classify(
            windDirection: weather.wind.direction.value,
            bikeHeading: bikeHeading
        ) {
        case .tailwind: return .green
        case .crosswind: return .orange
        case .headwind: return .red
        }
    }

    private func relationLabel(for relation: WindRelation) -> String {
        switch relation {
        case .tailwind: return "Tailwind"
        case .crosswind: return "Crosswind"
        case .headwind: return "Headwind"
        }
    }
    #endif
}
