import Foundation

/// Static helpers for formatting human-readable distance, duration, and date/time
/// strings used throughout the UI.  Distance auto-switches between feet and miles;
/// duration omits the hours field when the ride is under an hour.
enum Formatters {
    static func distance(_ meters: Double) -> String {
        let miles = meters / 1609.344
        if miles >= 0.1 {
            return String(format: "%.2f mi", miles)
        }
        let feet = meters * 3.28084
        return String(format: "%.0f ft", feet)
    }

    /// Format speed from m/s as a "X.X mph" string for display.  US-units
    /// matches `distance(_:)`.  Returns "— mph" for a `nil` input so call
    /// sites with optional GPS speed can pass through directly.
    static func speed(_ metersPerSecond: Double?) -> String {
        guard let mps = metersPerSecond, mps >= 0 else { return "— mph" }
        let mph = mps * 2.23694
        return String(format: "%.1f mph", mph)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    static func dateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
