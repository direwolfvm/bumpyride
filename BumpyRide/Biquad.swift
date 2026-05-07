import Foundation

/// Stateful 2nd-order IIR biquad filter (Direct Form I).  Used to high-pass the vertical
/// acceleration channel when the phone is on the rider's body — the cyclical 1–1.7 Hz
/// pedaling-bob is suppressed, while bump energy above ~5 Hz passes through cleanly.
struct Biquad {
    let b0: Double
    let b1: Double
    let b2: Double
    let a1: Double
    let a2: Double

    private var x1: Double = 0
    private var x2: Double = 0
    private var y1: Double = 0
    private var y2: Double = 0

    mutating func process(_ input: Double) -> Double {
        let y = b0 * input + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = input
        y2 = y1
        y1 = y
        return y
    }

    mutating func reset() {
        x1 = 0; x2 = 0
        y1 = 0; y2 = 0
    }

    /// Butterworth high-pass coefficients via the RBJ Audio EQ Cookbook formulation.
    /// Q = 1/√2 produces a maximally flat (Butterworth) response.
    static func butterworthHighPass(cutoffHz: Double, sampleRateHz: Double) -> Biquad {
        let q = 1.0 / sqrt(2.0)
        let omega = 2.0 * .pi * cutoffHz / sampleRateHz
        let cosOmega = cos(omega)
        let alpha = sin(omega) / (2.0 * q)

        let b0 = (1.0 + cosOmega) / 2.0
        let b1 = -(1.0 + cosOmega)
        let b2 = (1.0 + cosOmega) / 2.0
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cosOmega
        let a2 = 1.0 - alpha

        return Biquad(
            b0: b0 / a0,
            b1: b1 / a0,
            b2: b2 / a0,
            a1: a1 / a0,
            a2: a2 / a0
        )
    }
}
