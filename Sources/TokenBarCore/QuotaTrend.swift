import Foundation

/// Per-row recent-trend indicator for a quota window: which way the curve is
/// moving right now, and where that rate lands the window by reset.
///
/// Deliberately NOT a cross-window ranking. A 5-hour window and a 31-day
/// window have no shared rate scale, and every normalisation that would put
/// them on one needs a parameter chosen by taste. A per-row indicator needs
/// no cross-window comparison, so none of those parameters exist here, and it
/// works for any vendor that reports a window duration with no hardcoded list.
public struct QuotaTrend: Equatable, Sendable {
    public enum Direction: Equatable, Sendable {
        case rising, falling, flat
    }

    public let direction: Direction
    /// What percentage of the allowance this window will have consumed at
    /// reset if the recent rate continues. Deliberately the same 0...100(+)
    /// scale every window already shows — not a ratio, an index, or a
    /// per-hour rate. A raw %/hour was rejected because it is biased by
    /// window length: a 5h window must burn ~20%/h to use its allowance, a
    /// 7d window only ~0.6%/h, so %/hour always names the shortest window as
    /// "burning fastest" regardless of actual behavior. May exceed 100 — that
    /// is the one actionable state here (on course to run out early).
    public let projectedUsedPercent: Double
    /// Percentage points of the allowance the recent rate will consume between
    /// now and reset — `projectedUsedPercent` minus the reading it was
    /// projected from. This is the figure the row prints, and it is a different
    /// quantity from the pace delta beside it: pace compares the level against
    /// the window's usual pattern *so far*, this says what the current slope
    /// costs *from here on*. On live data the two disagreed on 3 of 7 windows
    /// with both correct, so they must not be printed as if interchangeable.
    ///
    /// Not a %/hour rate, for the reason given above. This is normalised by the
    /// window's own remaining time, so a 5h and a 31d window compare directly.
    public let projectedDeltaPercent: Double

    /// Whether the recent rate spends the whole allowance before the window
    /// resets.
    ///
    /// Lives here rather than in the row that draws it because it decides what
    /// that row may say: past this point the delta is larger than the axis has
    /// room for, and printing it produces a drop bigger than the amount that
    /// exists. The row names the state instead.
    public var runsOutEarly: Bool { projectedUsedPercent > 100 }
}

public enum QuotaTrendFold {
    /// Trailing fraction of the window's own duration used to measure recent
    /// slope, back from the newest sample.
    ///
    /// Measured 2026-08-17 on live data, normalised slope over the trailing
    /// 25%:
    ///
    ///   codex  main.weekly.v1    4 samples   slope 0.45
    ///   claude session.v1       48 samples   slope 0.69
    ///   claude weekly.v1        34 samples   slope 0.47
    ///   grok   billing.weekly   42 samples   slope 0.00  (used 63%, elapsed
    ///                                                     88%, flat recently)
    ///
    /// 25% produced a usable slope for every window that had a curve at all —
    /// even codex weekly, whose entire recorded history is 4 samples. A
    /// shorter lookback was tried and rejected: at 10% the answer for
    /// `claude weekly.v1` flipped relative to `claude session.v1` purely
    /// because of sampling density (session is polled far more often, so a
    /// narrower time slice still holds enough points while weekly's does
    /// not), and sparsely-sampled windows fall below the 2-sample floor
    /// entirely at that width.
    public static let lookbackFraction = 0.25

    /// Below this many samples inside the lookback span, a slope would be
    /// invented from a single point (or nothing). No indicator, not a zero.
    public static let minimumSamples = 2

    /// Slope magnitude at or under this reads as "not moving recently"
    /// rather than a direction — this is the grok case: lifetime-average
    /// ratio 0.72 (the highest of the four measured windows above) while the
    /// recent slope is 0.00, because it stopped being used days ago. Any
    /// implementation whose grok row reads as "burning" is wrong. The
    /// threshold sits an order of magnitude below the smallest genuine
    /// measured slope (0.45) so a real burn is never muted, and comfortably
    /// above float noise from two adjacent quota readings.
    public static let flatThreshold = 0.05

    /// Samples, window bounds and `now` in → slope-derived direction and
    /// projection, or nil when there is not enough recent data to say
    /// anything. `usedPercent` is the window's own current reading (not
    /// necessarily the last curve sample — the two can lag each other by a
    /// poll interval), because the projection is defined relative to the
    /// value the rest of the row already displays.
    public static func trend(
        usedPercent: Double, windowStartMs: Int64, windowEndMs: Int64, nowMs: Int64,
        samples: [QuotaSample]
    ) -> QuotaTrend? {
        let durationMs = windowEndMs - windowStartMs
        guard durationMs > 0, nowMs > windowStartMs else { return nil }

        let inside = samples
            .filter { $0.atMs >= windowStartMs && $0.atMs <= nowMs }
            .sorted { $0.atMs < $1.atMs }
        guard let newest = inside.last else { return nil }

        let spanStartMs = newest.atMs - Int64((Double(durationMs) * lookbackFraction).rounded())
        let span = inside.filter { $0.atMs >= spanStartMs }
        guard span.count >= minimumSamples,
              let first = span.first, let last = span.last, last.atMs > first.atMs
        else { return nil }

        // Normalised: usedPercent moved per 100 percentage-points of the
        // WINDOW elapsed (not per unit of wall time), so a 5h window and a
        // 31d window read on the same scale here even though this value never
        // leaves the fold.
        let elapsedFraction = Double(last.atMs - first.atMs) / Double(durationMs)
        let recentSlope = (last.usedPercent - first.usedPercent) / (elapsedFraction * 100)

        let windowElapsedFraction = min(1, max(0, Double(nowMs - windowStartMs) / Double(durationMs)))
        let remainingElapsedFraction = 1 - windowElapsedFraction
        let rawDelta = recentSlope * remainingElapsedFraction * 100
        // Floor only, and deliberately not a ceiling. A provider correction can
        // make the recent samples fall steeply enough that `rawDelta` is more
        // negative than the meter has to give, projecting a window to "-190%
        // used" and a drop larger than the amount that exists — the mirror of
        // the overshoot `runsOutEarly` exists for, with no state to name.
        //
        // The ceiling is NOT clamped, because `runsOutEarly` is exactly
        // `projectedUsedPercent > 100`: capping there would delete the signal
        // the row uses to stop printing an impossible delta. The asymmetry is
        // the point — one saturation has a name, the other does not.
        //
        // The delta is recomputed from the clamped projection rather than kept
        // raw, so the two cannot disagree: a reader adding the delta to the
        // current reading must land on the projection beside it.
        let projected = max(0, usedPercent + rawDelta)
        let delta = projected - usedPercent

        let direction: QuotaTrend.Direction = abs(recentSlope) <= flatThreshold
            ? .flat : (recentSlope > 0 ? .rising : .falling)

        return QuotaTrend(
            direction: direction, projectedUsedPercent: projected,
            projectedDeltaPercent: delta)
    }
}
