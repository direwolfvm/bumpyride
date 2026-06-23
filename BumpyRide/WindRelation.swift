import Foundation

/// Pure helper for the v1.7 weather chip's wind-relative-to-bike
/// label.  Given the wind's compass direction (where it's coming
/// FROM) and the bike's compass heading (where it's going TO),
/// computes whether the rider is fighting it, riding with it, or
/// catching it sideways.
///
/// **Convention**: Apple's `Wind.direction` and `CLLocation.course`
/// both use compass degrees (0 = north, 90 = east).  Wind direction
/// is documented as "the direction the wind is coming from."  So
/// if the bike is heading north (course = 0) and the wind is from
/// the north (direction = 0), the wind is in the rider's face →
/// headwind.
///
/// **Math**: relative = (windDirection - bikeHeading) mod 360,
/// normalized to (-180, 180] for symmetric thresholds.  Then:
///
///   abs(relative) ≤ 60°       → headwind  (within ±60° of head-on)
///   abs(relative) ≥ 120°      → tailwind  (within ±60° of behind)
///   else                       → crosswind
///
/// The ±60° thresholds are standard cycling convention — narrow
/// enough that "headwind" actually feels like one, wide enough to
/// not flip-flop on small course wobble.  Crosswind covers the
/// middle ground (60–120° in either direction) where the wind has
/// significant but mixed effect.
enum WindRelation: Equatable, Sendable {
    case headwind
    case tailwind
    case crosswind

    /// Threshold for "head-on" — wind within this many degrees of
    /// the bike's heading counts as a headwind.  Symmetric: also
    /// applies on the tailwind side as `180° - threshold`.
    static let thresholdDegrees: Double = 60

    /// Classify the wind relative to the bike's heading.
    ///
    /// - Parameters:
    ///   - windDirection: degrees clockwise from north, where the
    ///     wind is coming FROM (Apple's convention).
    ///   - bikeHeading: degrees clockwise from north, where the
    ///     bike is heading TO (`CLLocation.course`).
    static func classify(
        windDirection: Double,
        bikeHeading: Double
    ) -> WindRelation {
        let signed = signedRelativeAngle(
            windDirection: windDirection,
            bikeHeading: bikeHeading
        )
        let abs = Swift.abs(signed)
        if abs <= thresholdDegrees {
            return .headwind
        } else if abs >= 180 - thresholdDegrees {
            return .tailwind
        } else {
            return .crosswind
        }
    }

    /// 8-point compass label for a bearing in degrees (0 = N, clockwise
    /// through NE / E / SE / S / SW / W / NW).  Used by the weather
    /// chip's *absolute* wind-direction readout when no bike heading is
    /// available — so a stationary rider still sees which way the wind
    /// is from, just in compass terms instead of head/tail/cross.
    static func cardinal(_ degrees: Double) -> String {
        let dirs = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let normalized = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let idx = Int((normalized + 22.5).truncatingRemainder(dividingBy: 360) / 45) % 8
        return dirs[idx]
    }

    /// Signed relative angle in (-180, 180]: positive values mean
    /// the wind is coming from the bike's right-front quadrant,
    /// negative from the left-front quadrant.  Used for the chip's
    /// arrow rotation so the arrow's tail points in the direction
    /// the wind is blowing toward the rider.
    static func signedRelativeAngle(
        windDirection: Double,
        bikeHeading: Double
    ) -> Double {
        let raw = (windDirection - bikeHeading).truncatingRemainder(dividingBy: 360)
        // Normalize to (-180, 180].  truncatingRemainder gives
        // results in (-360, 360); fold into the canonical range.
        if raw > 180 {
            return raw - 360
        } else if raw <= -180 {
            return raw + 360
        } else {
            return raw
        }
    }
}
