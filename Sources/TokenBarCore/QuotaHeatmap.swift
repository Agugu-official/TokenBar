import Foundation

/// When a window's allowance actually gets consumed, as a weekday-by-hour grid.
///
/// Built from the persisted quota curve alone — no message scan — so it costs
/// the same ~2ms read the rest of this lens already pays. The question it
/// answers is not "when do I work", which the usage chart already covers, but
/// "when does the allowance move", and those differ: a long cheap session and a
/// short expensive one look the same in a message count and nothing alike here.
public struct QuotaHeatmap: Equatable, Sendable {
    /// `[weekday][hour]` in percentage points of the window's allowance.
    /// Weekday 0 = Monday, hour 0...23. Always 7 x 24; an idle slot is 0, not
    /// absent.
    public let cells: [[Double]]
    /// The heaviest slot, and therefore the top of the colour ramp. Zero means
    /// nothing was placed, which the card must read as "no data" rather than
    /// dividing by it.
    public let peak: Double
    /// Everything the grid accounts for.
    public let total: Double
    /// Consumption that was measured but could not be placed in time, because
    /// the gap between the two readings that bracket it is longer than
    /// `maximumGapSeconds`. Reported rather than dropped silently: a large
    /// value means the grid is understating, and the card says so.
    public let unplacedPercent: Double
    /// Distinct local calendar days carrying at least one reading. The honest
    /// denominator for "is this enough to read a weekly rhythm" — a 168-slot
    /// grid over four days is mostly white space.
    public let observedDays: Int

    public static let empty = QuotaHeatmap(
        cells: Array(repeating: Array(repeating: 0, count: 24), count: 7),
        peak: 0, total: 0, unplacedPercent: 0, observedDays: 0)

    public var isEmpty: Bool { total <= 0 }

    /// Whether the allowance moved at all, placed or not.
    ///
    /// NOT `!isEmpty`. `total` counts only what the grid could place, so a
    /// window whose every reading pair straddles more than `maximumGapSeconds`
    /// has `total == 0` while having consumed real allowance. Treating that as
    /// nothing dropped the window from the picker and made the card report "no
    /// allowance movement recorded yet" — the opposite of what happened, with
    /// the one line that explains it unreachable behind the same condition.
    ///
    /// Any positive value, not a full point. Curve readings are arbitrary
    /// finite percentages, so a pair of readings seven hours apart moving 0.5
    /// points is movement this fold recorded and a `>= 1` test would discard.
    /// The one-point threshold belongs to the footnote, which is a question
    /// about whether a line is worth drawing, not about whether anything
    /// happened.
    public var hasMovement: Bool { !isEmpty || unplacedPercent > 0 }
}

public enum QuotaHeatmapFold {
    /// Longer than this between two readings and the consumption between them
    /// is not placed at all.
    ///
    /// The provider reports a level, not an event, so all we ever know is that
    /// some amount was spent between two readings. Spreading that across a
    /// three-day gap would draw burn at 04:00 on days the machine was asleep —
    /// an invented pattern, and the grid exists to show a pattern. Six hours is
    /// long enough to cover a normal poll gap on a sparsely-sampled weekly
    /// window and short enough that a spread stays inside one working session.
    public static let maximumGapSeconds: Int64 = 6 * 3_600

    /// Consumption per weekday-hour slot.
    ///
    /// Deltas are taken WITHIN a reset cycle, never across one: a reset drops
    /// the reading back to near zero, and the difference across that boundary
    /// is the whole previous cycle inverted, not consumption. Cycles are keyed
    /// by `resetAt`, which is what `QuotaHistoryFold` groups on too.
    ///
    /// A delta is spread across the hours its interval covers, weighted by the
    /// time in each, rather than charged to the reading that observed it. On a
    /// window polled every minute the two are identical; on one polled hourly,
    /// charging the observing reading would pile a whole hour of work onto the
    /// minute it happened to be noticed.
    public static func build(
        points: [QuotaCurvePoint],
        calendar: Calendar = Calendar(identifier: .gregorian),
        timeZone: TimeZone = .current
    ) -> QuotaHeatmap {
        var local = calendar
        local.timeZone = timeZone

        var cells = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
        var unplaced = 0.0
        // Local days, not `sampledAt / 86_400`. That divides UTC seconds into
        // UTC dates, while every cell above is placed on the LOCAL weekday and
        // hour — so away from UTC the denominator counted a different calendar
        // from the grid it describes, splitting one local day either side of
        // UTC midnight in two and merging two into one.
        var days = Set<DateComponents>()

        for (_, cyclePoints) in Dictionary(grouping: points, by: \.resetAt) {
            let sorted = cyclePoints.sorted { $0.sampledAt < $1.sampledAt }
            for point in sorted {
                days.insert(local.dateComponents(
                    [.year, .month, .day],
                    from: Date(timeIntervalSince1970: Double(point.sampledAt))))
            }
            for (previous, current) in zip(sorted, sorted.dropFirst()) {
                let delta = current.usedPercent - previous.usedPercent
                // Negative means the reading went backwards inside one cycle —
                // a refill, or a provider correction. Not consumption, and not
                // something to subtract from a neighbouring slot either.
                guard delta > 0 else { continue }
                let span = current.sampledAt - previous.sampledAt
                guard span > 0 else { continue }
                guard span <= maximumGapSeconds else {
                    unplaced += delta
                    continue
                }
                var cursor = previous.sampledAt
                while cursor < current.sampledAt {
                    let date = Date(timeIntervalSince1970: Double(cursor))
                    let hourEnd = Int64(
                        (local.dateInterval(of: .hour, for: date)?.end
                            ?? date.addingTimeInterval(3_600)).timeIntervalSince1970)
                    // A calendar that cannot advance the cursor would spin
                    // forever; step a whole hour instead and keep going.
                    let segmentEnd = min(max(hourEnd, cursor + 1), current.sampledAt)
                    let slot = weekdayHour(date, calendar: local)
                    cells[slot.weekday][slot.hour] +=
                        delta * Double(segmentEnd - cursor) / Double(span)
                    cursor = segmentEnd
                }
            }
        }

        let flat = cells.flatMap { $0 }
        return QuotaHeatmap(
            cells: cells,
            peak: flat.max() ?? 0,
            total: flat.reduce(0, +),
            unplacedPercent: unplaced,
            observedDays: days.count)
    }

    /// Weekday 0 = Monday. `Calendar.weekday` runs 1 = Sunday through 7 =
    /// Saturday, so Sunday has to land at 6: a grid that starts on Sunday puts
    /// the two quietest days at opposite ends and hides the weekend as a block.
    static func weekdayHour(_ date: Date, calendar: Calendar)
        -> (weekday: Int, hour: Int)
    {
        ((calendar.component(.weekday, from: date) + 5) % 7,
         calendar.component(.hour, from: date))
    }
}
