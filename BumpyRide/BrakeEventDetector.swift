import Foundation

/// Post-hoc detector for hard-braking events on a saved `Ride`.
///
/// Runs after the ride is recorded — never during.  Detection is deterministic
/// and idempotent: feeding the same ride in always produces the same events.
/// Safe to re-run on any saved ride (e.g., after a trim/split that changes
/// the points array).
///
/// **Algorithm — combined GPS + accel signal.**
///
/// Real-world hard braking on a bike is often *short*: a cyclist's panic
/// stop or sudden slowdown for a car can peak at 4–6 m/s² for 0.2–0.6 s,
/// then taper rapidly.  An earlier version of this detector used GPS-decel
/// alone as the trigger, with a 0.8 s sustained-above-threshold filter
/// and ±1 s smoothing.  That combination silently rejected every real
/// brake event in field testing — the smoothing was burying short peaks
/// and the duration filter then refused what was left.
///
/// The current pipeline:
///
/// 1. **Smooth GPS speed** with a centered ±0.4 s moving average.  Kills
///    single-fix jitter without obliterating short-duration peaks.
///
/// 2. **Compute GPS-derived deceleration** via centered finite difference
///    on the smoothed signal.
///
/// 3. **Build a combined signal** at each sample as
///    `max(gpsDecel, horizontalAccel · 9.80665 · 0.8)`.  GPS-decel and
///    accel-derived decel are co-equal triggers, not GPS-primary with
///    accel as refinement.  The 0.8 factor discounts the accel value
///    because horizontal acceleration includes braking + cornering +
///    accelerating, not pure deceleration.  Legacy v1/v2 rides with
///    `horizontalAccel == nil` degrade gracefully to GPS-only.
///
/// 4. **Find runs** of indices where the combined signal exceeds
///    `decelThresholdMPS2` for at least `minDurationSeconds`.  0.3 s is
///    short enough to catch real panic stops without false-positives on
///    single noisy samples.
///
/// 5. **Emit each run** with peak magnitude + timestamp taken from where
///    the combined signal is highest in the window.
///
/// 6. **Collapse adjacent events** within `minSeparationSeconds`,
///    keeping whichever peaked higher.
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
    /// - rev 1 (1ed11ff…b130748): GPS-only trigger, 0.8 s minDuration,
    ///   ±1 s smoothing.  Missed nearly all real brake events in the field.
    /// - rev 2 (this file): combined GPS + accel trigger, 0.3 s minDuration,
    ///   ±0.4 s smoothing.  Tuned against actual rides where peaks were
    ///   < 1 s long.
    static let revision: Int = 2

    /// Deceleration must exceed this to start counting toward a brake event.
    /// 2.5 m/s² ≈ 0.25 g.  Normal coasting on flat road is well under
    /// 1 m/s²; routine slowdowns at intersections are 1–2 m/s²; a hard
    /// brake at speed easily hits 4–6 m/s².
    static let decelThresholdMPS2: Double = 2.5

    /// A run shorter than this is treated as transient noise.  0.3 s is
    /// long enough to require ~1 confirming sample at typical 2–3 Hz GPS
    /// + accel cadence, but short enough to catch real panic stops that
    /// peak briefly and decay.  Previous default was 0.8 s; that turned
    /// out to be longer than typical real-world hard-brake events.
    static let minDurationSeconds: TimeInterval = 0.3

    /// Half-window for the centered speed-smoothing pass.  Tight enough
    /// (±0.4 s = 0.8 s total) that a 0.3 s peak isn't smoothed away,
    /// wide enough to ignore single-fix GPS-derivative noise.  Previous
    /// default was ±1.0 s; that was actively destroying the signal we
    /// were trying to detect.
    static let smoothingHalfWindowSeconds: TimeInterval = 0.4

    /// Events closer than this in time are collapsed.  1.5 s catches
    /// "brake → release → brake again" sequences without inflating the
    /// event count, while leaving room for two genuinely-separate brakes
    /// at the same intersection ~2 s apart.  Previous default was 3.0 s,
    /// which collapsed too aggressively given the new sensitivity.
    static let minSeparationSeconds: TimeInterval = 1.5

    /// Gain applied to the horizontalAccel signal when building the
    /// combined trigger.  9.80665 converts g → m/s², 0.8 discounts the
    /// accel value because horizontal acceleration includes non-braking
    /// components (cornering, accelerating, surface bumps).  Tuned so
    /// that a 0.4 g horizontal-accel event registers as ≈ 3.1 m/s² in
    /// the combined signal, above the threshold.
    private static let accelTriggerGain: Double = 9.80665 * 0.8

    /// Find every brake event in a ride.  Returns `[]` if the ride is too
    /// short to compute a derivative or has no points above threshold.
    /// Never returns `nil` — `Ride.brakeEvents == nil` means "detection
    /// hasn't run," and the convention is to switch that to `[]` after a
    /// successful empty pass.
    static func detect(in ride: Ride) -> [BrakeEvent] {
        let points = ride.points
        // Need at least 3 points for the centered finite difference.
        guard points.count >= 3 else { return [] }

        let smoothedSpeeds = smoothSpeeds(in: points)
        let gpsDecel = decelerations(from: smoothedSpeeds, points: points)
        let signal = combinedSignal(gpsDecel: gpsDecel, points: points)
        let runs = findRuns(signal: signal, points: points)
        let events = runs.compactMap { emit(run: $0, points: points, signal: signal) }
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

    /// Per-sample trigger signal — max of GPS-derived decel and
    /// horizontalAccel-derived decel (with the discount gain).  This is
    /// what drives both the run-finding and the per-event peak.  Legacy
    /// rides without `horizontalAccel` default that contribution to 0,
    /// so the signal degrades to GPS-decel — the old algorithm's
    /// behavior, minus the destructive over-smoothing.
    private static func combinedSignal(gpsDecel: [Double], points: [RidePoint]) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(points.count)
        for (i, p) in points.enumerated() {
            let accelDecel = Double(p.horizontalAccel ?? 0) * accelTriggerGain
            out.append(max(gpsDecel[i], accelDecel))
        }
        return out
    }

    /// Contiguous index ranges where the signal is above threshold and
    /// the run spans at least `minDurationSeconds`.
    private static func findRuns(signal: [Double], points: [RidePoint]) -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        var runStart: Int? = nil
        for i in signal.indices {
            if signal[i] > decelThresholdMPS2 {
                if runStart == nil { runStart = i }
            } else if let s = runStart {
                if isLongEnough(start: s, end: i - 1, points: points) {
                    runs.append(s...(i - 1))
                }
                runStart = nil
            }
        }
        if let s = runStart {
            let last = signal.count - 1
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

    /// Build a single `BrakeEvent` from a candidate run.  Peak is the
    /// max of the combined signal within the run; that's already the
    /// max of GPS + accel-derived, so no separate refinement step.
    private static func emit(run: ClosedRange<Int>, points: [RidePoint], signal: [Double]) -> BrakeEvent? {
        var peakIdx = run.lowerBound
        var peakVal = signal[run.lowerBound]
        for i in run {
            if signal[i] > peakVal {
                peakVal = signal[i]
                peakIdx = i
            }
        }
        guard peakVal > 0 else { return nil }

        let peakPoint = points[peakIdx]
        let duration = points[run.upperBound].timestamp.timeIntervalSince(points[run.lowerBound].timestamp)
        return BrakeEvent(
            timestamp: peakPoint.timestamp,
            latitude: peakPoint.latitude,
            longitude: peakPoint.longitude,
            peakDecelerationMPS2: peakVal,
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
