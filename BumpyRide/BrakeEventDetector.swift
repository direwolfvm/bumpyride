import Foundation

/// Post-hoc detector for hard-braking events on a saved `Ride`.
///
/// Runs after the ride is recorded — never during.  Detection is deterministic
/// and idempotent: feeding the same ride in always produces the same events.
/// Safe to re-run on any saved ride (e.g., after a trim/split that changes
/// the points array).
///
/// **Algorithm — GPS-decel as gate, accel as magnitude refinement.**
///
/// Pipeline:
///
/// 1. **Smooth GPS speed** with a centered ±0.5 s moving average.  Kills
///    single-fix jitter without obliterating short-duration peaks.
///
/// 2. **Compute GPS-derived deceleration** via centered finite difference
///    on the smoothed signal.
///
/// 3. **Find runs** of indices where `gpsDecel > decelThresholdMPS2`
///    sustained at least `minDurationSeconds`.  GPS-decel is the *only*
///    gate — the rider's speed must actually drop for an event to count.
///    Pure cornering or lateral surface bumps don't reduce forward speed,
///    so they can't register as brakes regardless of what the
///    accelerometer reads.
///
/// 4. **Refine the peak magnitude using `horizontalAccel`** when v3 data
///    is available.  For each run, take the peak of the GPS-derived
///    decel curve, then `max()` it against the run's peak horizontalAccel
///    value scaled by `9.80665 · 0.8` (g→m/s² with a discount factor for
///    non-braking horizontal components).  This gives a less-lagged
///    estimate of the true peak when both signals agree the brake was
///    hard.  Legacy v1/v2 rides without `horizontalAccel` skip this step
///    and use the GPS peak directly.
///
/// 5. **Collapse adjacent events** within `minSeparationSeconds`,
///    keeping whichever peaked higher.
///
/// **Why GPS-as-gate matters.**  An earlier rev 2 attempt promoted
/// `horizontalAccel` to a co-equal trigger via a combined-signal `max()`.
/// That over-detected dramatically: horizontal accel spikes during
/// cornering at speed, on rough pavement, even during sprint starts —
/// none of which are brake events.  The only signal that uniquely
/// identifies a brake is "the forward speed dropped."  GPS-as-gate enforces
/// exactly that.
///
/// **Tuning history.**  Bump `revision` whenever the constants or
/// algorithm change such that previously-processed rides should be
/// re-detected on the next launch.  `ContentView` reads it against an
/// `@AppStorage` value and triggers a one-shot re-detection pass via
/// `BrakeReprocessor` when they don't match.
enum BrakeEventDetector {
    /// Bump when the detector's behavior changes enough that already-
    /// detected rides should be re-analyzed.  See the migration logic in
    /// `ContentView.task`.
    ///
    /// History:
    /// - rev 1 (1ed11ff): GPS-gate + accel-refine, 0.8 s minDuration,
    ///   ±1 s smoothing, 3 s minSeparation.  Missed nearly all real
    ///   brake events because the time-domain constants were tuned for
    ///   prolonged braking (cars) not cyclist panic stops.
    /// - rev 2 (33adbec): combined GPS+accel trigger, 0.3 s minDuration,
    ///   ±0.4 s smoothing, 1.5 s minSeparation.  Over-detected
    ///   dramatically — cornering and lateral bumps registered as brakes.
    /// - rev 3 (fae5d84): back to GPS-gate + accel-refine (rev 1's
    ///   correct structure), with split-the-difference tuning:
    ///   0.4 s minDuration, ±0.5 s smoothing, 2 s minSeparation.
    ///   Decel threshold stayed at 2.5 m/s² — still under-detected.
    /// - rev 4 (ab1d154): decel threshold 2.5 → 2.0 m/s² (≈ 0.2 g).
    ///   Same algorithm and time-domain tuning as rev 3.  Still
    ///   under-detected — likely the GPS speed signal is noisier or
    ///   more lagged in pocket mode than the textbook deceleration
    ///   curve, so the smoothed-and-differentiated peak undershoots
    ///   what the rider actually experienced.
    /// - rev 5 (this file): decel threshold 2.0 → 1.5 m/s² (≈ 0.15 g).
    ///   Crosses into "moderate brake" territory.  Routine slowdowns
    ///   at intersections may start appearing depending on rider
    ///   habits; the count vs. false-positive trade is now firmly on
    ///   the side of "show more, even if some are firm-not-hard."
    static let revision: Int = 5

    /// Deceleration must exceed this to start counting toward a brake event.
    /// 1.5 m/s² ≈ 0.15 g.  Below the 2 m/s² typical-firm-stop threshold;
    /// above coast-down on flat road (~0.5 m/s²) and gentle braking into
    /// a roll (~1 m/s²).  Chosen empirically after rev 1's 2.5 m/s² and
    /// rev 4's 2.0 m/s² both under-detected against real rides.
    static let decelThresholdMPS2: Double = 1.5

    /// A run shorter than this is treated as transient noise.  0.4 s is
    /// long enough to require multiple confirming samples at typical
    /// 2–3 Hz GPS cadence, short enough to catch real panic stops that
    /// peak briefly and decay.  Sits between rev 1's overly-strict 0.8 s
    /// (missed everything) and rev 2's permissive 0.3 s (let noise
    /// through).
    static let minDurationSeconds: TimeInterval = 0.4

    /// Half-window for the centered speed-smoothing pass.  ±0.5 s = 1 s
    /// total.  Wide enough to suppress single-fix jitter, tight enough
    /// to preserve sub-second real peaks.  Rev 1's ±1.0 s buried short
    /// peaks; rev 2's ±0.4 s let single-fix noise through unfiltered.
    static let smoothingHalfWindowSeconds: TimeInterval = 0.5

    /// Events closer than this in time are collapsed.  2 s leaves room
    /// for two genuinely-separate brakes at the same intersection without
    /// inflating the count from "brake → release → brake again" patterns.
    /// Sits between rev 1's overly-eager 3 s and rev 2's 1.5 s.
    static let minSeparationSeconds: TimeInterval = 2.0

    /// Gain applied to the horizontalAccel signal during peak refinement
    /// (NOT as a trigger).  9.80665 converts g → m/s², 0.8 discounts the
    /// accel value because horizontal acceleration includes non-braking
    /// components (cornering, accelerating, surface bumps).  Used only
    /// to refine the peak magnitude of an event the GPS-decel signal
    /// already identified.
    private static let accelRefinementGain: Double = 9.80665 * 0.8

    /// Find every brake event in a ride.  Returns `[]` if the ride is too
    /// short to compute a derivative or has no points above threshold.
    /// Never returns `nil` — `Ride.brakeEvents == nil` means "detection
    /// hasn't run," and the convention is to switch that to `[]` after a
    /// successful empty pass.
    static func detect(in ride: Ride) -> [BrakeEvent] {
        detect(in: ride.points)
    }

    /// Overload taking the points array directly.  Used by the live
    /// recording UI (Ride tab) to surface brake markers as they emerge
    /// during the ride, without having to wrap the in-progress points
    /// in a synthetic `Ride`.  Output is identical to passing through
    /// `detect(in: Ride)` with the same points — the detector only
    /// reads `points` from the ride anyway.
    ///
    /// Idempotent and pure: callers can re-invoke as more points
    /// arrive (e.g. once per second during recording) and the result
    /// will converge to the same set the post-hoc detector would emit
    /// at save time.  The tail few seconds may flicker as the centered
    /// finite difference resolves — that's an inherent property of
    /// GPS-derivative-based detection, not a freshness bug.
    static func detect(in points: [RidePoint]) -> [BrakeEvent] {
        // Need at least 3 points for the centered finite difference.
        guard points.count >= 3 else { return [] }

        let smoothedSpeeds = smoothSpeeds(in: points)
        let decel = decelerations(from: smoothedSpeeds, points: points)
        let runs = findRuns(decel: decel, points: points)
        let events = runs.compactMap { emit(run: $0, points: points, decel: decel) }
        return collapseAdjacent(events)
    }

    // MARK: - Pipeline steps

    /// Centered moving average of speed over a ±`smoothingHalfWindowSeconds`
    /// window.  Linear time because points are timestamp-ordered and we
    /// short-circuit once the right edge passes the window.
    private static func smoothSpeeds(in points: [RidePoint]) -> [Double] {
        var smoothed: [Double] = []
        smoothed.reserveCapacity(points.count)
        for i in points.indices {
            let center = points[i].timestamp
            var sum: Double = 0
            var count: Int = 0
            // Walk leftward from i.
            var j = i
            while j >= 0 {
                let dt = center.timeIntervalSince(points[j].timestamp)
                if dt > smoothingHalfWindowSeconds { break }
                sum += points[j].speed
                count += 1
                j -= 1
            }
            // Walk rightward from i+1.
            j = i + 1
            while j < points.count {
                let dt = points[j].timestamp.timeIntervalSince(center)
                if dt > smoothingHalfWindowSeconds { break }
                sum += points[j].speed
                count += 1
                j += 1
            }
            smoothed.append(count > 0 ? sum / Double(count) : points[i].speed)
        }
        return smoothed
    }

    /// Centered finite difference on smoothed speeds.  Endpoints get 0
    /// (no valid neighbors).
    private static func decelerations(from speeds: [Double], points: [RidePoint]) -> [Double] {
        var decel = Array(repeating: 0.0, count: points.count)
        guard points.count >= 3 else { return decel }
        for i in 1..<(points.count - 1) {
            let dt = points[i + 1].timestamp.timeIntervalSince(points[i - 1].timestamp)
            // Avoid divide-by-near-zero on duplicate or near-duplicate timestamps.
            guard dt > 0.05 else { continue }
            decel[i] = (speeds[i - 1] - speeds[i + 1]) / dt
        }
        return decel
    }

    /// Contiguous index ranges where GPS-decel is above threshold and
    /// the run spans at least `minDurationSeconds`.  GPS-decel is the
    /// only gate; horizontalAccel only participates later (peak refine).
    private static func findRuns(decel: [Double], points: [RidePoint]) -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        var runStart: Int? = nil
        for i in decel.indices {
            if decel[i] > decelThresholdMPS2 {
                if runStart == nil { runStart = i }
            } else if let s = runStart {
                if isLongEnough(start: s, end: i - 1, points: points) {
                    runs.append(s...(i - 1))
                }
                runStart = nil
            }
        }
        if let s = runStart {
            let last = decel.count - 1
            if isLongEnough(start: s, end: last, points: points) {
                runs.append(s...last)
            }
        }
        return runs
    }

    private static func isLongEnough(start: Int, end: Int, points: [RidePoint]) -> Bool {
        guard start <= end else { return false }
        return points[end].timestamp.timeIntervalSince(points[start].timestamp) >= minDurationSeconds
    }

    /// Build a single `BrakeEvent` from a candidate run.  Peak magnitude
    /// is `max(GPS-decel peak, peakHorizontalAccel · 9.80665 · 0.8)` so
    /// the accel signal can boost the magnitude estimate when it's
    /// present and high, but cannot create an event on its own
    /// (run-finding already gated on GPS-decel).  Returns `nil` if the
    /// run has no positive decel samples (defended against; shouldn't
    /// happen given `findRuns`'s filter).
    private static func emit(run: ClosedRange<Int>, points: [RidePoint], decel: [Double]) -> BrakeEvent? {
        var peakIdx = run.lowerBound
        var gpsPeak = decel[run.lowerBound]
        for i in run {
            if decel[i] > gpsPeak {
                gpsPeak = decel[i]
                peakIdx = i
            }
        }
        guard gpsPeak > 0 else { return nil }

        // Peak refinement: when the run also contains a high
        // horizontalAccel sample, use it (scaled + discounted) as a
        // less-lagged estimate of the true peak.  GPS-decel here is
        // smoothed and lagged; horizontalAccel is per-sample direct.
        let accelPeakG = run.compactMap { points[$0].horizontalAccel }.map(Double.init).max()
        let accelDecel = (accelPeakG ?? 0) * accelRefinementGain
        let refinedPeak = max(gpsPeak, accelDecel)

        let peakPoint = points[peakIdx]
        let duration = points[run.upperBound].timestamp.timeIntervalSince(points[run.lowerBound].timestamp)
        return BrakeEvent(
            timestamp: peakPoint.timestamp,
            latitude: peakPoint.latitude,
            longitude: peakPoint.longitude,
            peakDecelerationMPS2: refinedPeak,
            durationSeconds: duration
        )
    }

    /// Merge events whose peaks are within `minSeparationSeconds` of each
    /// other into a single event, keeping the higher-peak one.  Linear
    /// pass; events come in chronological order from `detect`.
    private static func collapseAdjacent(_ events: [BrakeEvent]) -> [BrakeEvent] {
        guard events.count > 1 else { return events }
        var result: [BrakeEvent] = [events[0]]
        for next in events.dropFirst() {
            let last = result[result.count - 1]
            let gap = next.timestamp.timeIntervalSince(last.timestamp)
            if gap < minSeparationSeconds {
                if next.peakDecelerationMPS2 > last.peakDecelerationMPS2 {
                    result[result.count - 1] = next
                }
                // else: keep `last`, ignore `next`
            } else {
                result.append(next)
            }
        }
        return result
    }
}

extension Ride {
    /// Run `BrakeEventDetector` on this ride and return a copy with
    /// `brakeEvents` populated.  Always sets the field (even to `[]`) — the
    /// distinction between `nil` (never run) and `[]` (ran, no events) is
    /// what drives the reprocessor's "needs detection" predicate.
    func withDetectedBrakeEvents() -> Ride {
        var copy = self
        copy.brakeEvents = BrakeEventDetector.detect(in: self)
        return copy
    }
}
