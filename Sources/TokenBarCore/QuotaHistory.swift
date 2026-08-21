import Foundation

/// Past quota windows, each joined to what was actually spent inside it.
///
/// The window card answers "this window"; this answers "the windows before
/// it", and the join is the point. Measured 2026-08-16 on live data, a
/// `claude/session.v1` window moved **1%** while 308M tokens and $535 of
/// API-equivalent value were recorded in the same five hours — because almost
/// all of it was `gpt-5.6-sol`, which is charged to a different subscription.
/// A history that showed either half alone would be actively misleading.

/// One recorded reset cycle, derived from the persisted quota curve alone.
public struct QuotaCycle: Equatable, Sendable {
    /// Reset instant in ms. Doubles as the cycle's identity — the engine groups
    /// its samples by exactly this value.
    public let resetAtMs: Int64
    public let startMs: Int64
    /// How much of the allowance this cycle consumed: the span between the
    /// lowest and highest reading in it, NOT the highest reading alone.
    ///
    /// The distinction is not cosmetic. Sampling starts whenever the app
    /// happens to be running, so a cycle first observed at 40% used would
    /// report 40% as its consumption when the app only witnessed the last few
    /// points of it. The span is what this app can honestly claim to have seen.
    ///
    /// Note the floor this leaves: `QuotaCurvePoint` rejects `usedPercent == 0`
    /// at decode, so a cycle's first reading is always above zero and the span
    /// necessarily omits whatever was consumed before it. That understates, and
    /// understating is the right direction — the alternative assumes the app
    /// witnessed a window it may have joined late.
    public let usedPercent: Double
    /// The highest absolute reading seen in this cycle.
    ///
    /// Separate from `usedPercent`, which is the observed SPAN. The two answer
    /// different questions and only coincide when the app watched the cycle
    /// from zero: a cycle first seen at 40% and last seen at 100% consumed 60
    /// points as far as this machine can tell, and reached the ceiling. Deriving
    /// "never ran out" from the span called that cycle a quiet one.
    public let peakUsedPercent: Double
    public let sampleCount: Int
    /// The instants of the first and last reading in this cycle.
    ///
    /// Carried because a ratio is only meaningful when its numerator and
    /// denominator cover the same interval, and the denominator is a span
    /// between two readings — not the whole window. Usage from a stretch the
    /// app was not running for would otherwise be counted against quota
    /// movement nobody observed. `WindowEquivalence.row` already had this
    /// right; the aggregate over cycles did not, and it cost 8 points of
    /// spread on live data (46% to 38%).
    public let firstSampleMs: Int64
    public let lastSampleMs: Int64

    /// How far back this cycle's evidence reaches — the earlier of where the
    /// window is computed to have started and where sampling actually began.
    ///
    /// Normally `startMs`, since the first reading lands after the window
    /// opens. They invert when the provider SHORTENS its reported duration
    /// mid-cycle: `startMs` is derived from the newest point's duration, so a
    /// window that went from seven days to five moves its own start forward,
    /// past readings already taken. Bounding a message scan at `startMs` would
    /// then drop usage from before it while `usedPercent` — the span between
    /// the first and last reading — still counts the movement those readings
    /// showed. Numerator short, denominator whole.
    public var evidenceStartMs: Int64 { min(startMs, firstSampleMs) }
    /// Fraction of the window the samples actually cover, 0...1. A cycle
    /// observed for eight minutes of five hours is not evidence about that
    /// cycle, and the UI has to be able to say so.
    public let observedFraction: Double

    public var durationMs: Int64 { resetAtMs - startMs }

    public init(
        resetAtMs: Int64, startMs: Int64, usedPercent: Double,
        sampleCount: Int, observedFraction: Double,
        firstSampleMs: Int64 = 0, lastSampleMs: Int64 = 0,
        peakUsedPercent: Double? = nil
    ) {
        self.peakUsedPercent = peakUsedPercent ?? usedPercent
        self.resetAtMs = resetAtMs
        self.startMs = startMs
        self.usedPercent = usedPercent
        self.sampleCount = sampleCount
        self.observedFraction = observedFraction
        self.firstSampleMs = firstSampleMs
        self.lastSampleMs = lastSampleMs
    }
}

/// A cycle plus what was spent inside it, split by whether it counted against
/// the subscription this history belongs to.
public struct QuotaHistoryRow: Equatable, Sendable, Identifiable {
    public let cycle: QuotaCycle
    /// Attributed to THIS subscription — the number the quota bar is about.
    public let mineTokens: Int64
    /// The same total with cache reads removed, which is what the quota
    /// equivalence divides by. `WindowEquivalence.row` already excludes them;
    /// carrying it here keeps the aggregate over many cycles on the same basis
    /// as the single-window figure rather than quietly using a fuller total.
    public let mineTokensExCacheRead: Int64
    public let mineCost: Double
    /// The same two quantities restricted to the cycle's OBSERVED span, which
    /// is the only interval the quota delta describes. The whole-window figures
    /// above are what the row displays — "this window cost me X" is a question
    /// about the window — while these are the only ones a ratio may divide.
    public let spanTokensExCacheRead: Int64
    public let spanCost: Double
    /// Everything else recorded in the same interval, summed. Not noise: it is
    /// the answer to "the window barely moved, so where did the work go".
    public let otherTokens: Int64
    public let otherCost: Double
    /// This subscription's models, largest first.
    public let models: [QuotaHistoryModel]

    public var id: Int64 { cycle.resetAtMs }
    public var hasUsage: Bool { mineTokens > 0 || otherTokens > 0 }
}

public struct QuotaHistoryModel: Equatable, Sendable, Identifiable {
    /// Carried alongside the model because `ModelColorMap.color` keys on the
    /// pair. Without it the segments here would be coloured by a different rule
    /// than the same models in the model breakdown and the usage chart, and one
    /// model would be two colours depending on which card you were looking at.
    public let providerId: String
    public let modelId: String
    public let tokens: Int64
    public let cost: Double

    public var id: String { "\(providerId)|\(modelId)" }
}

public enum QuotaHistoryFold {
    /// Grouping key for the model breakdown. The pair, not the model alone:
    /// the same model id reached through two providers is two rows everywhere
    /// else in this app, and collapsing them here would make this card the one
    /// place that disagrees.
    public struct ModelKey: Hashable {
        public let providerId: String
        public let modelId: String
        public init(providerId: String, modelId: String) {
            self.providerId = providerId
            self.modelId = modelId
        }
    }

    /// Groups curve points into cycles, newest first.
    ///
    /// `durationSeconds` is per point rather than per cycle, so the cycle's
    /// length is taken from its own newest point: a window whose provider changed
    /// its reported duration mid-cycle should be placed by what it reports now,
    /// not by what it reported when sampling began.
    /// Completed cycles only.
    ///
    /// `activeResetAt` names the group the window is still inside. Folding it
    /// in put the running cycle in a strip captioned "past windows", let a
    /// partially observed span stand beside completed ones, and let it count
    /// toward the three-cycle threshold the equivalence needs — an estimate
    /// that would then change under the reader as the cycle filled. Nil means
    /// the caller does not know, and then everything present is treated as
    /// finished, which is the old behaviour and the safe reading for a curve
    /// with no active group.
    public static func cycles(
        points: [QuotaCurvePoint], activeResetAt: Int64? = nil
    ) -> [QuotaCycle] {
        allCycles(points: points, activeResetAt: activeResetAt)
            .prefix(consideredCycles)
            .map { $0 }
    }

    private static func allCycles(
        points: [QuotaCurvePoint], activeResetAt: Int64?
    ) -> [QuotaCycle] {
        var grouped: [Int64: [QuotaCurvePoint]] = [:]
        for point in points where point.resetAt != activeResetAt {
            grouped[point.resetAt, default: []].append(point)
        }

        return grouped.compactMap { resetAt, raw -> QuotaCycle? in
            let sorted = raw.sorted { $0.sampledAt < $1.sampledAt }
            guard let last = sorted.last, let first = sorted.first,
                  last.durationSeconds > 0
            else { return nil }
            let used = sorted.map(\.usedPercent)
            let start = resetAt - last.durationSeconds
            return QuotaCycle(
                resetAtMs: resetAt * 1000,
                startMs: start * 1000,
                usedPercent: (used.max() ?? 0) - (used.min() ?? 0),
                sampleCount: sorted.count,
                observedFraction: min(1, max(0, Double(last.sampledAt - first.sampledAt)
                    / Double(last.durationSeconds))),
                firstSampleMs: first.sampledAt * 1000,
                lastSampleMs: last.sampledAt * 1000,
                peakUsedPercent: used.max() ?? 0)
        }
        .sorted { $0.resetAtMs > $1.resetAtMs }
    }

    /// The same fold without the cap. Exists for `--window-probe`, which has to
    /// be able to measure what the cap changed without depending on the cap.
    /// Not called from the shipping UI.
    public static func cyclesUncapped(
        points: [QuotaCurvePoint], activeResetAt: Int64? = nil
    ) -> [QuotaCycle] {
        allCycles(points: points, activeResetAt: activeResetAt)
    }

    /// How far back any cycle-derived surface reaches, in cycles.
    ///
    /// The engine retains 128 cycles per series and this fold used to return
    /// all of them, but nothing downstream wants that many: the history card
    /// draws 12 rows and the overview strip 16. The cost of the extra ones is
    /// not the list, it is that the OLDEST cycle sets where the message scan
    /// starts — `min(windowStart, cycles.last.startMs)` — so a 5-hour session
    /// window at 128 cycles asked for a 26-day scan to render twelve rows, and
    /// a weekly window walked that start backwards for ever. Capping the fold
    /// bounds the scan as a consequence, which is why the cap lives here and
    /// not at each consumer.
    ///
    /// 32, not the 16 the issue proposed. `--window-probe` swept the cap over
    /// this machine's real history on 2026-08-21 and the estimate collapses
    /// below 20 recorded cycles: at 20/24/28 the session window reports
    /// 651k-689k tokens per 10% with an 8-10% error bar, and at 8/12/16 it
    /// reports no figure at all, only a 242k-1054k spread. 16 is enough for the
    /// jackknife in principle and was not on the data — admitted cycles are a
    /// subset of recorded ones, so the pool empties faster than the count
    /// suggests. A cap that turns a point estimate into a range is a
    /// user-visible regression bought for a bound that 32 also provides.
    ///
    /// 32 does not bite on any window here today (the widest has 27), which is
    /// the point: it bounds the growth without moving a number anyone reads.
    /// It also stays comfortably above `QuotaOverviewFold.stripLength`, the
    /// widest surface drawn from these cycles — anything displaying more than
    /// the cap would silently show fewer, so a selftest asserts the fit.
    public static let consideredCycles = 32

    /// Joins each cycle to the messages inside it.
    ///
    /// `subscription` is the attribution target this history belongs to — the
    /// subscription whose quota the cycles measure. A message counts as "mine"
    /// only when the user's own declaration assigns it there; excluded and
    /// unassigned usage lands in the other column rather than being dropped,
    /// because an unclassified source still consumed real time in that window.
    public static func rows(
        cycles: [QuotaCycle], messages: [WindowMessage], subscription: String,
        confirmed: [UsageAttribution.Record]
    ) -> [QuotaHistoryRow] {
        // Sorted once, then each cycle takes a contiguous slice: the naive
        // filter-per-cycle is O(cycles x messages), and on live data that is
        // 15 x 45,844 walks of the whole array on the main actor.
        let sorted = messages.sorted { $0.timestamp < $1.timestamp }
        let stamps = sorted.map(\.timestamp)
        let spans = spanTotals(
            cycles: cycles, sorted: sorted, stamps: stamps,
            subscription: subscription, confirmed: confirmed)

        return zip(cycles, spans).map { cycle, span in
            // `[evidenceStart, reset)` — inclusive at the start, exclusive at
            // the reset. The start is `evidenceStartMs` rather than `startMs`
            // so this column cannot come out SMALLER than the span inside it
            // when a provider shortens its reported duration; a lengthened
            // duration still moves `startMs` backwards, which `min` leaves
            // alone and which no cycle boundary here has ever guarded. The reset instant is when the allowance refills, so work
            // stamped exactly there was charged to the cycle that instant
            // OPENS, not the one it closes. Adjacent cycles share that
            // boundary, so getting it wrong double counts rather than merely
            // misfiling.
            let lo = lowerBound(stamps, cycle.evidenceStartMs)
            let hi = lowerBound(stamps, cycle.resetAtMs)
            var mine = (tokens: Int64(0), exCacheRead: Int64(0), cost: 0.0)
            var other = (tokens: Int64(0), cost: 0.0)
            var byModel: [ModelKey: (tokens: Int64, cost: Double)] = [:]

            for message in sorted[lo..<max(lo, hi)] {
                let state = UsageAttribution.resolve(
                    client: message.client, provider: message.providerId,
                    model: message.modelId, records: confirmed)
                if case let .assigned(target) = state, target == subscription {
                    // `saturatingAdding`, like every other fold over these
                    // counters. Saturating per message is not enough: two rows
                    // that each saturate still trap when added together, and
                    // the accumulator is where a corrupt transcript would land.
                    let exCacheRead = message.tokensExCacheRead
                    mine.tokens = mine.tokens.saturatingAdding(message.tokens)
                    mine.exCacheRead = mine.exCacheRead.saturatingAdding(exCacheRead)
                    mine.cost += message.cost
                    let key = ModelKey(
                        providerId: message.providerId, modelId: message.modelId)
                    let current = byModel[key] ?? (0, 0)
                    byModel[key] = (
                        current.tokens.saturatingAdding(message.tokens),
                        current.cost + message.cost)
                } else {
                    other.tokens = other.tokens.saturatingAdding(message.tokens)
                    other.cost += message.cost
                }
            }

            return QuotaHistoryRow(
                cycle: cycle,
                mineTokens: mine.tokens, mineTokensExCacheRead: mine.exCacheRead,
                mineCost: mine.cost,
                spanTokensExCacheRead: span.exCacheRead, spanCost: span.cost,
                otherTokens: other.tokens, otherCost: other.cost,
                models: byModel
                    .map {
                        QuotaHistoryModel(
                            providerId: $0.key.providerId, modelId: $0.key.modelId,
                            tokens: $0.value.tokens, cost: $0.value.cost)
                    }
                    .sorted { $0.tokens > $1.tokens })
        }
    }

    /// First index whose value is >= `value`.
    /// What this subscription spent inside each cycle's OBSERVED span —
    /// `(firstSampleMs, lastSampleMs]`, the interval between the two readings
    /// the cycle's `usedPercent` is the difference of.
    ///
    /// One statement of that rule, for the two surfaces that need it: the
    /// history card's per-cycle numbers and the equivalence estimate's
    /// numerators. It was written twice, and the second copy re-filtered the
    /// whole message array per cycle on the main actor — the same
    /// O(cycles x messages) shape the comment in `rows` documents having
    /// removed, reintroduced by a second implementation of the same fold.
    ///
    /// Returned parallel to `cycles`, one entry each, so a caller that already
    /// has the sorted array pays no second sort.
    public static func spans(
        cycles: [QuotaCycle], messages: [WindowMessage], subscription: String,
        confirmed: [UsageAttribution.Record]
    ) -> [(exCacheRead: Int64, cost: Double)] {
        let sorted = messages.sorted { $0.timestamp < $1.timestamp }
        return spanTotals(
            cycles: cycles, sorted: sorted, stamps: sorted.map(\.timestamp),
            subscription: subscription, confirmed: confirmed)
    }

    private static func spanTotals(
        cycles: [QuotaCycle], sorted: [WindowMessage], stamps: [Int64],
        subscription: String, confirmed: [UsageAttribution.Record]
    ) -> [(exCacheRead: Int64, cost: Double)] {
        cycles.map { cycle in
            // Bounded by the SPAN, not by `[start, reset)`. The span is what
            // the denominator measures, and it is not always inside the cycle:
            // see `evidenceStartMs`. The slice is a superset — the `where`
            // below states the actual rule — so the bounds only have to be
            // safe, and `saturatingAdding` keeps the exclusive upper edge from
            // overflowing on a corrupt timestamp.
            let lo = lowerBound(stamps, cycle.firstSampleMs)
            let hi = lowerBound(stamps, cycle.lastSampleMs.saturatingAdding(1))
            var span = (exCacheRead: Int64(0), cost: 0.0)
            for message in sorted[lo..<max(lo, hi)]
            where message.timestamp > cycle.firstSampleMs
                && message.timestamp <= cycle.lastSampleMs
            {
                guard case let .assigned(target) = UsageAttribution.resolve(
                    client: message.client, provider: message.providerId,
                    model: message.modelId, records: confirmed), target == subscription
                else { continue }
                span.exCacheRead = span.exCacheRead.saturatingAdding(
                    message.tokensExCacheRead)
                span.cost += message.cost
            }
            return span
        }
    }

    public static func lowerBound(_ values: [Int64], _ value: Int64) -> Int {
        var low = 0, high = values.count
        while low < high {
            let mid = (low + high) / 2
            if values[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
