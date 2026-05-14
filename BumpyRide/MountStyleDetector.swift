import Foundation

/// Heuristic detector that decides whether a saved Ride's vibration signature looks
/// like a pocket recording vs. a handlebar/frame recording.  Used at save time to
/// auto-tag the recording, and on demand to flag mistagged saved rides.
///
/// **The physics:** pedaling at 60–110 RPM produces a 1.0–1.83 Hz vertical body bob
/// that dominates a phone in a pocket but is barely visible on a fixed bike mount
/// (the bike's mass damps it out at the bars).  Bumps from pavement produce
/// broadband energy above ~5 Hz.  Ratio of cadence-band RMS to bump-band RMS is a
/// strong tell:
///
///   - **Mounted**: ratio is low (≪ 1) — most of the signal is in the bump band.
///   - **Pocket**:  ratio is high (≳ 1) — cadence body bob dominates.
///
/// **schemaVersion sensitivity:** on v2 rides the `accelWindow` is always raw, so
/// detection is reliable in both directions.  On v1 rides where `pocketMode == true`,
/// the cadence content was filtered out at recording time and detection would
/// incorrectly read as mounted — callers should gate on `schemaVersion >= 2` or
/// `pocketMode != true` before using the verdict.
struct MountStyleDetector {
    enum Verdict: String, Codable, Equatable {
        case likelyMounted
        case likelyPocket
        case ambiguous
    }

    struct Result: Equatable {
        let verdict: Verdict
        /// `cadenceRMS / bumpRMS`.  Bigger means more pocket-like.
        let ratio: Double
        /// Raw cadence-band RMS (1–3 Hz), in g.
        let cadenceRMS: Double
        /// Raw bump-band RMS (3+ Hz), in g.
        let bumpRMS: Double
        /// Number of samples that survived the warmup and contributed to the RMS sums.
        /// Lower → less confidence.
        let samplesAnalyzed: Int
    }

    // Thresholds — tune with real data.  Starting conservative on `likelyPocket`
    // so we don't flag handlebar rides that happen to have any cadence content
    // (e.g., from a flexy stem) as pocket.
    static let likelyPocketThreshold: Double = 0.6
    static let likelyMountedThreshold: Double = 0.2

    /// Run the detector on a saved Ride.  Returns `nil` when detection isn't
    /// possible — too little stored `accelWindow` data, or a `schemaVersion 1` ride
    /// with `pocketMode == true` (HPF stripped the cadence band at record time).
    static func analyze(_ ride: Ride) -> Result? {
        // v1 pocket-tagged rides have the cadence band already stripped; we can't
        // tell pocket from mounted in that case.  v2 rides always have raw
        // accelWindow so detection works regardless of the current tag.
        if ride.pocketMode == true, ride.schemaVersion < 2 { return nil }
        guard !ride.points.isEmpty else { return nil }

        let sampleRateHz: Double = 50.0
        let analysisCap: Int = 30  // ~30 windows is plenty
        let warmup: Int = 25       // 0.5 s for the filter state to settle

        // Stride RidePoints far enough apart that consecutive accelWindows don't
        // overlap.  Each window is 5 s; at the 3 m distanceFilter that's typically
        // ~17 RidePoints' worth of motion at 10 mph.  We pick a stride that caps
        // total analyzed windows at `analysisCap` for a long ride.
        let stride = max(20, ride.points.count / analysisCap)

        var cadenceSumSq: Double = 0
        var bumpSumSq: Double = 0
        var totalCount: Int = 0

        var i = 0
        while i < ride.points.count {
            let window = ride.points[i].accelWindow
            if window.count > warmup + 25 {  // need at least 0.5 s of post-warmup signal
                var cadenceFilter = Biquad.butterworthBandPass(centerHz: 2.0, q: 1.0, sampleRateHz: sampleRateHz)
                var bumpFilter = Biquad.butterworthHighPass(cutoffHz: 3.0, sampleRateHz: sampleRateHz)
                for (idx, sample) in window.enumerated() {
                    let c = cadenceFilter.process(Double(sample))
                    let b = bumpFilter.process(Double(sample))
                    if idx >= warmup {
                        cadenceSumSq += c * c
                        bumpSumSq += b * b
                        totalCount += 1
                    }
                }
            }
            i += stride
        }

        // Require at least 1 second of analyzed signal across all windows.
        guard totalCount >= 50 else { return nil }

        let cadenceRMS = sqrt(cadenceSumSq / Double(totalCount))
        let bumpRMS = sqrt(bumpSumSq / Double(totalCount))

        // Floor bumpRMS to avoid div-by-near-zero when on a flat indoor surface
        // (treadmill / parking garage), where both bands could be near silent.
        let safeBumpRMS = max(bumpRMS, 0.005)
        let ratio = cadenceRMS / safeBumpRMS

        let verdict: Verdict
        if ratio >= likelyPocketThreshold {
            verdict = .likelyPocket
        } else if ratio <= likelyMountedThreshold {
            verdict = .likelyMounted
        } else {
            verdict = .ambiguous
        }

        return Result(
            verdict: verdict,
            ratio: ratio,
            cadenceRMS: cadenceRMS,
            bumpRMS: bumpRMS,
            samplesAnalyzed: totalCount
        )
    }
}
