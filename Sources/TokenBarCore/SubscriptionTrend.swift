import Foundation

/// Daily usage stacked by the subscription the user declared it against.
///
/// `AttributedDailySeries` already folds the graph's client rows into
/// (date, attribution state, model). This regroups that by subscription and
/// fills the calendar, which is what a trend chart needs and what a total does
/// not: `SubscriptionUsageFold` collapsed the same data to one number per
/// subscription and lost the axis this exists to draw.
public struct SubscriptionTrend: Equatable, Sendable {
    public struct Bucket: Equatable, Sendable {
        public var tokens: Int64 = 0
        public var cost: Double = 0
    }

    public struct Day: Equatable, Sendable {
        public let date: String
        /// Absent target means zero for that day. Callers must treat a missing
        /// key as zero rather than as "no data": the day is present precisely
        /// because the range covers it.
        public let byTarget: [String: Bucket]
        public let totalTokens: Int64
        public let totalCost: Double

        public var isEmpty: Bool { totalTokens == 0 && totalCost == 0 }
    }

    /// Every calendar day in the range, oldest first, gaps included as empty
    /// days. A chart that omitted idle days would compress time and draw a
    /// steady week and a burst-then-silence week identically.
    public let days: [Day]
    /// Targets present in the range, largest total cost first — the stacking
    /// order under the cost metric, so the biggest payer is the base of every
    /// column.
    public let targets: [String]
    /// The same targets ordered by token total.
    ///
    /// A separate order rather than a reuse. Cost and tokens do not rank the
    /// same subscriptions the same way — an unpriced or partly priced source
    /// can be the largest by tokens and near-last by cost — and the card
    /// applied the cost order to both views. The legend draws
    /// `targets.prefix(4)`, so under the Tokens metric the biggest token
    /// consumer could be stacked behind smaller bands and left out of the
    /// legend entirely, under a tooltip that says largest-first.
    public let targetsByTokens: [String]
    public let peakCost: Double
    public let peakTokens: Int64

    /// The order to stack and to list under the selected metric.
    ///
    /// A `Bool` rather than the view's `Metric`, which lives in the app module
    /// and cannot be named from here. The card resolves it once into a single
    /// property, so its four consumers — the stacking loop, the band loop, the
    /// legend, and the overflow count — cannot disagree about which order they
    /// are in.
    public func targets(byTokens: Bool) -> [String] {
        byTokens ? targetsByTokens : targets
    }

    public static let empty = SubscriptionTrend(
        days: [], targets: [], targetsByTokens: [], peakCost: 0, peakTokens: 0)
}

public enum SubscriptionTrendFold {
    /// Usage the user has not classified yet. Kept as its own stack segment
    /// rather than dropped: it is real spend, and hiding it would make the
    /// chart's total disagree with every other total in the app.
    public static let unassignedTarget = "__unassigned"

    /// `days` counts calendar days back from `today` inclusive, so 14 means
    /// today and the thirteen before it.
    ///
    /// Declared-excluded usage is dropped. That is the one omission the user
    /// asked for by declaring it, and it is not the same as unassigned.
    public static func build(
        points: [AttributedDailySeries.Point], today: String, days: Int
    ) -> SubscriptionTrend {
        guard days > 0, let range = calendarRange(endingAt: today, count: days) else {
            return .empty
        }
        let first = range[0]

        var byDate: [String: [String: SubscriptionTrend.Bucket]] = [:]
        var totals: [String: Double] = [:]
        var tokenTotals: [String: Int64] = [:]
        for point in points where point.date >= first && point.date <= today {
            let target: String
            switch point.state {
            case let .assigned(name): target = name
            case .unassigned: target = unassignedTarget
            case .excluded: continue
            }
            var day = byDate[point.date] ?? [:]
            var bucket = day[target] ?? SubscriptionTrend.Bucket()
            // Saturating for the reason `AttributedDailySeries` already
            // saturates the buckets this regroups: the counters originate in
            // local transcripts this app does not write.
            bucket.tokens = bucket.tokens.saturatingAdding(point.tokens)
            bucket.cost += point.cost
            day[target] = bucket
            byDate[point.date] = day
            totals[target, default: 0] += point.cost
            tokenTotals[target] = (tokenTotals[target] ?? 0).saturatingAdding(point.tokens)
        }

        let built = range.map { date -> SubscriptionTrend.Day in
            let buckets = byDate[date] ?? [:]
            return SubscriptionTrend.Day(
                date: date, byTarget: buckets,
                totalTokens: buckets.values.reduce(0) { $0.saturatingAdding($1.tokens) },
                totalCost: buckets.values.reduce(0) { $0 + $1.cost })
        }

        return SubscriptionTrend(
            days: built,
            // Ties broken by name so the stacking order is stable across
            // refreshes; an unstable order makes the chart reshuffle its bands
            // for no reason the user can see.
            targets: totals.keys.sorted {
                totals[$0] == totals[$1] ? $0 < $1 : totals[$0]! > totals[$1]!
            },
            // Same key set, same tie-break by name for the same reason: an
            // unstable order reshuffles the bands for no reason the user can
            // see. `totals` and `tokenTotals` gain their keys together, so
            // ordering the second by the first's key set would be equivalent
            // — it is written from `tokenTotals` anyway, because relying on
            // that coincidence is how the two fall out of step later.
            targetsByTokens: tokenTotals.keys.sorted {
                tokenTotals[$0] == tokenTotals[$1]
                    ? $0 < $1 : tokenTotals[$0]! > tokenTotals[$1]!
            },
            peakCost: built.map(\.totalCost).max() ?? 0,
            peakTokens: built.map(\.totalTokens).max() ?? 0)
    }

    /// `count` consecutive `yyyy-MM-dd` keys ending at `endingAt`, oldest first.
    ///
    /// Walked with `Calendar` rather than by subtracting 86_400 seconds: a DST
    /// transition makes one of those days 23 or 25 hours long, and the
    /// arithmetic version silently repeats or skips a date twice a year.
    public static func calendarRange(endingAt: String, count: Int) -> [String]? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        guard let end = formatter.date(from: endingAt) else { return nil }
        let calendar = Calendar.current
        return (0..<count).reversed().compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: end).map(formatter.string(from:))
        }
    }
}
