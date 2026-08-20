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
    /// Fraction of the window the samples actually cover, 0...1. A cycle
    /// observed for eight minutes of five hours is not evidence about that
    /// cycle, and the UI has to be able to say so.
    public let observedFraction: Double

    public var durationMs: Int64 { resetAtMs - startMs }

    public init(
        resetAtMs: Int64, startMs: Int64, usedPercent: Double,
        sampleCount: Int, observedFraction: Double,
        firstSampleMs: Int64 = 0, lastSampleMs: Int64 = 0
    ) {
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
    public static func cycles(points: [QuotaCurvePoint]) -> [QuotaCycle] {
        var grouped: [Int64: [QuotaCurvePoint]] = [:]
        for point in points { grouped[point.resetAt, default: []].append(point) }

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
                lastSampleMs: last.sampledAt * 1000)
        }
        .sorted { $0.resetAtMs > $1.resetAtMs }
    }

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

        return cycles.map { cycle in
            // `[start, reset)` — inclusive at the start, exclusive at the
            // reset. The reset instant is when the allowance refills, so work
            // stamped exactly there was charged to the cycle that instant
            // OPENS, not the one it closes. Adjacent cycles share that
            // boundary, so getting it wrong double counts rather than merely
            // misfiling.
            let lo = lowerBound(stamps, cycle.startMs)
            let hi = lowerBound(stamps, cycle.resetAtMs)
            var mine = (tokens: Int64(0), exCacheRead: Int64(0), cost: 0.0)
            var span = (exCacheRead: Int64(0), cost: 0.0)
            var other = (tokens: Int64(0), cost: 0.0)
            var byModel: [ModelKey: (tokens: Int64, cost: Double)] = [:]

            for message in sorted[lo..<max(lo, hi)] {
                let state = UsageAttribution.resolve(
                    client: message.client, provider: message.providerId,
                    model: message.modelId, records: confirmed)
                if case let .assigned(target) = state, target == subscription {
                    mine.tokens += message.tokens
                    mine.exCacheRead += message.tokens - message.cacheRead
                    mine.cost += message.cost
                    if message.timestamp > cycle.firstSampleMs,
                       message.timestamp <= cycle.lastSampleMs
                    {
                        span.exCacheRead += message.tokens - message.cacheRead
                        span.cost += message.cost
                    }
                    let key = ModelKey(
                        providerId: message.providerId, modelId: message.modelId)
                    let current = byModel[key] ?? (0, 0)
                    byModel[key] = (
                        current.tokens + message.tokens, current.cost + message.cost)
                } else {
                    other.tokens += message.tokens
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
    public static func lowerBound(_ values: [Int64], _ value: Int64) -> Int {
        var low = 0, high = values.count
        while low < high {
            let mid = (low + high) / 2
            if values[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
