import Foundation

/// Post-hoc detector for hard-braking events on a saved `Ride`.
///
/// Runs after the ride is recorded — never during.  Detection is deterministic
/// and idempotent: feeding the same ride in always produces the same events.
/// Safe to re-run on any saved ride (e.g., after a trim/split that changes
/// the points array).
///
/// **Algorithm** — GPS-based candidate finding, accel-based magnitude refinement.
///
/// 1. **Smooth GPS speed** with a centered ±1 s moving average.  Raw
///    `RidePoint.speed` from `CLLocation` is noisy on a per-callback basis;
///    smoothing keeps the speed-derivative signal stable enough to detect
///    sustained deceleration without false-triggering on single-fix jitter.
///
/// 2. **Compute deceleration** via centered finite difference:
///    `(smoothedSpeed[i-1] - smoothedSpeed[i+1]) / (t[i+1] - t[i-1])`,
///    positive = slowing down.
///
/// 3. **Find runs** of indices where decel exceeds the threshold
///    (`decelThresholdMPS2`, ≈ 0.25 g) for at least `minDurationSeconds`.
///    Each run becomes a candidate event.
///
/// 4. **Refine peak magnitude using `horizontalAccel`** when v3 data is
///    available.  The GPS speed derivative is lagged and discretized to the
///    fix cadence; the per-point `horizontalAccel` value is a direct
///    instantaneous magnitude.  We take whichever is larger between the
///    GPS-derived peak decel and `(peakHorizontalAccel_g · 9.80665 · 0.8)`.
///    The 0.8 factor discounts the accel value because horizontal
///    acceleration includes braking + cornering + acceleration; it's not a
///    pure deceleration channel.  In practice this conservatively boosts
///    the GPS estimate when both signals agree the brake was hard, and
///    leaves GPS alone when accel data is weak (cornering-only, missing
///    field on legacy rides, etc.).
///
/// 5. **Collapse adjacent events** within `minSeparationSeconds` into a
///    single event keeping whichever had the higher peak.  This stops a
///    long brake-and-coast-and-brake-again maneuver from rendering as three
///    distinct dots stacked on the brake map.
///
/// **Legacy compatibility**: rides without `horizontalAccel` (schema v1/v2)
/// still get detected — they just skip step 4's refinement and use the GPS
/// peak as-is.  That's a graceful degradation, not a special case in the
/// code.
enum BrakeEventDetector {
    /// Deceleration must exceed this to start counting toward a brake event.
    /// 2.5 m/s² ≈ 0.25 g — firmly into "hard braking" for a cyclist.  A
    /// typical coast-and-roll deceleration on flat road is well under
    /// 1 m/s²; standard slowdowns at intersections are 1–2 m/s².
    static let decelThresholdMPS2: Double = 2.5

    /// A run shorter than this is treated as transient noise (a single
    /// dropped GPS fix can produce a brief apparent decel spike).
    /// 0.8 s is enough samples at ~2 Hz GPS that the smoothed-speed
    /// pipeline can produce a meaningful peak.
    static let minDurationSeconds: TimeInterval = 0.8

    /// Half-window for the centered speed-smoothing pass.
    static let smoothingHalfWindowSeconds: TimeInterval = 1.0

    /// Events closer than this in time are collapsed.  3 s captures the
    /// "brake → release for a beat → brake again" rhythm cyclists use at
    /// long traffic-controlled descents without inflating the event count.
    static let minSeparationSeconds: TimeInterval = 3.0

    /// Conversion + discount factor when boosting GPS peak with the
    /// horizontalAccel signal.  See step 4 in the algorithm doc.
    private static let accelRefinementGain: Double = 9.80665 * 0.8

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

    /// Contiguous index ranges where decel is above threshold and the run
    /// spans at least `minDurationSeconds`.
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

    /// Build a single `BrakeEvent` from a candidate run.  Returns `nil` if
    /// the run has zero non-zero decel samples (shouldn't happen given the
    /// findRuns filter but defended against).
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

        // Accel-based magnitude refinement.  Take the max horizontalAccel
        // within the same window — when it's high, it confirms the GPS
        // signal and gives a less-lagged peak estimate.  Discount + gravity
        // conversion is bundled into `accelRefinementGain`.
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
