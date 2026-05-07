import SwiftUI
import Observation

/// User-tunable settings persisted in `UserDefaults`: the bumpiness color thresholds
/// (yellow / orange / red / purple breakpoints in g) and the Pocket Mode toggle.
/// Provides `color(for:)` / `uiColor(for:)` helpers used everywhere bumpiness is shown.
@Observable
final class AppSettings {
    private static let keyYellow = "bumpThresholdYellow"
    private static let keyOrange = "bumpThresholdOrange"
    private static let keyRed = "bumpThresholdRed"
    private static let keyPurple = "bumpThresholdPurple"
    private static let keyPocketMode = "pocketModeEnabled"

    var yellowG: Double = 0.5 {
        didSet { UserDefaults.standard.set(yellowG, forKey: Self.keyYellow) }
    }
    var orangeG: Double = 1.0 {
        didSet { UserDefaults.standard.set(orangeG, forKey: Self.keyOrange) }
    }
    var redG: Double = 1.5 {
        didSet { UserDefaults.standard.set(redG, forKey: Self.keyRed) }
    }
    var purpleG: Double = 2.0 {
        didSet { UserDefaults.standard.set(purpleG, forKey: Self.keyPurple) }
    }

    /// When the phone rides in a pocket (or anywhere on the rider's body), the rider's
    /// pedaling cadence shows up as a 1–2 Hz oscillation in vertical acceleration.  This
    /// toggle enables a 3 Hz Butterworth high-pass that suppresses that oscillation while
    /// preserving the higher-frequency bump signal.
    var pocketModeEnabled: Bool = false {
        didSet { UserDefaults.standard.set(pocketModeEnabled, forKey: Self.keyPocketMode) }
    }

    init() {
        let d = UserDefaults.standard
        if let v = d.object(forKey: Self.keyYellow) as? Double { yellowG = v }
        if let v = d.object(forKey: Self.keyOrange) as? Double { orangeG = v }
        if let v = d.object(forKey: Self.keyRed) as? Double { redG = v }
        if let v = d.object(forKey: Self.keyPurple) as? Double { purpleG = v }
        if let v = d.object(forKey: Self.keyPocketMode) as? Bool { pocketModeEnabled = v }
    }

    func resetToDefaults() {
        yellowG = 0.5
        orangeG = 1.0
        redG = 1.5
        purpleG = 2.0
        pocketModeEnabled = false
    }

    private struct Stop {
        let threshold: Double
        let r: Double
        let g: Double
        let b: Double
    }

    private var stops: [Stop] {
        [
            Stop(threshold: 0.0,     r: 0.20, g: 0.85, b: 0.35),
            Stop(threshold: yellowG, r: 0.95, g: 0.85, b: 0.20),
            Stop(threshold: orangeG, r: 0.98, g: 0.55, b: 0.15),
            Stop(threshold: redG,    r: 0.92, g: 0.20, b: 0.20),
            Stop(threshold: purpleG, r: 0.60, g: 0.25, b: 0.85)
        ]
    }

    var topG: Double { purpleG }

    func color(for bumpiness: Double) -> Color {
        let (r, g, b) = rgb(for: bumpiness)
        return Color(red: r, green: g, blue: b)
    }

    func uiColor(for bumpiness: Double) -> UIColor {
        let (r, g, b) = rgb(for: bumpiness)
        return UIColor(red: r, green: g, blue: b, alpha: 1)
    }

    private func rgb(for bumpiness: Double) -> (Double, Double, Double) {
        let sorted = stops
        let v = max(0, bumpiness)
        if v <= sorted.first!.threshold {
            let s = sorted.first!
            return (s.r, s.g, s.b)
        }
        if v >= sorted.last!.threshold {
            let s = sorted.last!
            return (s.r, s.g, s.b)
        }
        for i in 1..<sorted.count where v <= sorted[i].threshold {
            let lo = sorted[i - 1], hi = sorted[i]
            let span = max(0.0001, hi.threshold - lo.threshold)
            let t = (v - lo.threshold) / span
            return (
                lo.r + (hi.r - lo.r) * t,
                lo.g + (hi.g - lo.g) * t,
                lo.b + (hi.b - lo.b) * t
            )
        }
        let last = sorted.last!
        return (last.r, last.g, last.b)
    }
}
