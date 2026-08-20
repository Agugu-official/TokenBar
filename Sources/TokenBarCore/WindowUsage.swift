import Foundation

/// Usage inside one quota window: the per-message rows the quota lens folds.
///
/// One row per message, not per bucket: a quota window is a small slice of
/// history, so the curve's resolution stays a UI choice instead of a wire
/// contract. Attribution is applied here, on this side, because it is the
/// user's declaration — the engine never sees it.
public struct WindowMessage: Decodable, Sendable {
    public let timestamp: Int64
    public let client: String
    public let providerId: String
    public let modelId: String
    public let input: Int64
    public let output: Int64
    public let cacheRead: Int64
    public let cacheWrite: Int64
    public let reasoning: Int64
    public let cost: Double
    public let isTurnStart: Bool

    /// Saturating, like the graph and report totals that fold the same
    /// untrusted counters. These come from local session files this app does
    /// not write; a corrupt row summing past `Int64.max` would trap, and a
    /// malformed line in someone's transcript must not be able to terminate
    /// the UI.
    /// Everything except cache reads, summed from the components rather than
    /// subtracted from the saturated total.
    ///
    /// `tokens - cacheRead` is wrong twice over on a corrupt row: when both
    /// saturate it reports zero non-cache tokens although the input alone was
    /// enormous, and an overflowing subtraction can wrap negative, which then
    /// flows into a ratio as a negative numerator. Neither is a crash, which is
    /// what makes them worse than one.
    public var tokensExCacheRead: Int64 {
        [output, cacheWrite, reasoning].reduce(input) {
            $0.addingReportingOverflow($1).overflow ? Int64.max : $0 + $1
        }
    }

    public var tokens: Int64 {
        [output, cacheRead, cacheWrite, reasoning].reduce(input) {
            $0.addingReportingOverflow($1).overflow ? Int64.max : $0 + $1
        }
    }
}

public struct WindowUsage: Decodable, Sendable {
    public let messages: [WindowMessage]
    /// Messages with no usable timestamp. Counted, never silently dropped —
    /// a window total that quietly omits rows is worse than one that says so.
    public let undatedCount: Int
    public let processingTimeMs: Int

    /// For sources that answer without the engine — the demo path and the
    /// default protocol implementation.
    public init(messages: [WindowMessage], undatedCount: Int, processingTimeMs: Int) {
        self.messages = messages
        self.undatedCount = undatedCount
        self.processingTimeMs = processingTimeMs
    }
}

public extension WindowUsage {
    struct SubscriptionTotal: Sendable, Equatable {
        public let target: String
        public let tokens: Int64
        public let cost: Double
    }

    /// Fold the window into per-subscription totals using the user's confirmed
    /// declarations. Rows with no declaration land in `unassigned` rather than
    /// being folded into either side.
    func totals(confirmed: [UsageAttribution.Record]) -> (
        assigned: [SubscriptionTotal], excluded: SubscriptionTotal, unassigned: SubscriptionTotal
    ) {
        var byTarget: [String: (Int64, Double)] = [:]
        var excluded: (Int64, Double) = (0, 0)
        var unassigned: (Int64, Double) = (0, 0)

        for m in messages {
            let state = UsageAttribution.resolve(
                client: m.client, provider: m.providerId, model: m.modelId,
                records: confirmed)
            switch state {
            case let .assigned(target):
                let cur = byTarget[target] ?? (0, 0)
                byTarget[target] = (cur.0 + m.tokens, cur.1 + m.cost)
            case .excluded:
                excluded = (excluded.0 + m.tokens, excluded.1 + m.cost)
            case .unassigned:
                unassigned = (unassigned.0 + m.tokens, unassigned.1 + m.cost)
            }
        }

        return (
            byTarget
                .map { SubscriptionTotal(target: $0.key, tokens: $0.value.0, cost: $0.value.1) }
                .sorted { $0.tokens > $1.tokens },
            SubscriptionTotal(target: "excluded", tokens: excluded.0, cost: excluded.1),
            SubscriptionTotal(target: "unassigned", tokens: unassigned.0, cost: unassigned.1)
        )
    }

    /// Bucket the window for the trend curve. Resolution is a caller choice —
    /// no round trip, because the rows are already here.
    func buckets(from: Int64, bucketMs: Int64, count: Int) -> [Int64] {
        var out = [Int64](repeating: 0, count: max(count, 0))
        guard bucketMs > 0, count > 0 else { return out }
        for m in messages {
            let idx = Int((m.timestamp - from) / bucketMs)
            if idx >= 0 && idx < count { out[idx] += m.tokens }
        }
        return out
    }
}
