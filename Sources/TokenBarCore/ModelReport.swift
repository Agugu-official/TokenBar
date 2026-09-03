import Foundation

// Per-model report (`ModelReport` in types.ts). Note: the wire key for
// throughput is `msPer1kTokens` (serde camelCase of ms_per_1k_tokens) —
// types.ts declares `msPer1KTokens` but the Rust serialization wins.

public struct ModelReportEntry: Decodable, Sendable {
    public let client: String
    public let model: String
    public let provider: String
    public let input: Int64
    public let output: Int64
    public let cacheRead: Int64
    public let cacheWrite: Int64
    public let reasoning: Int64
    public let total: Int64
    public let messageCount: Int
    public let cost: Double
    public let msPer1kTokens: Double?
    /// Set only when `cost` exceeds the local pricing estimate by an
    /// implausible multiple — a client that reports its own cost (OpenCode,
    /// MiMo Code) has that figure taken verbatim, so a unit error upstream
    /// reaches this row unchallenged. The value is that multiple. `nil` is the
    /// normal case and also covers rows the check could not evaluate (no
    /// cached pricing table, or a model the table cannot price at all). See
    /// `implausible_cost_ratio` in crates/tb_core_ffi/src/model_report.rs.
    ///
    /// Optional so a report serialized before this field existed still
    /// decodes.
    public let costRatio: Double?
}

public struct ModelReport: Decodable, Sendable {
    public let entries: [ModelReportEntry]
    public let totalInput: Int64
    public let totalOutput: Int64
    public let totalCacheRead: Int64
    public let totalCacheWrite: Int64
    public let totalMessages: Int
    public let totalCost: Double
    /// Unix-seconds time the LiteLLM pricing dataset was last fetched
    /// (drives the "Prices updated …" hint). Absent before the first fetch.
    public let pricingUpdatedAt: UInt64?
}

public extension ModelReport {
    /// Fold provider-split rows back to the model-level view used by the
    /// existing cards. Throughput is intentionally dropped when rows merge:
    /// tokscale only computes it honestly over the complete rollup.
    var modelLevelEntries: [ModelReportEntry] {
        var indices: [String: Int] = [:]
        var folded: [ModelReportEntry] = []

        for entry in entries {
            let key = "\(entry.client)\u{0}\(entry.model)"
            guard let index = indices[key] else {
                indices[key] = folded.count
                folded.append(entry)
                continue
            }

            let current = folded[index]
            let input = current.input.saturatingAdding(entry.input)
            let output = current.output.saturatingAdding(entry.output)
            let cacheRead = current.cacheRead.saturatingAdding(entry.cacheRead)
            let cacheWrite = current.cacheWrite.saturatingAdding(entry.cacheWrite)
            let reasoning = current.reasoning.saturatingAdding(entry.reasoning)
            let messageCount = current.messageCount.addingReportingOverflow(entry.messageCount)
            folded[index] = ModelReportEntry(
                client: current.client,
                model: current.model,
                provider: Self.mergedProviders(current.provider, entry.provider),
                input: input,
                output: output,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite,
                reasoning: reasoning,
                total: input
                    .saturatingAdding(output)
                    .saturatingAdding(cacheRead)
                    .saturatingAdding(cacheWrite)
                    .saturatingAdding(reasoning),
                messageCount: messageCount.overflow
                    ? Int.max
                    : messageCount.partialValue,
                cost: current.cost + entry.cost,
                msPer1kTokens: nil,
                // The merged cost is a sum across providers, so no single
                // ratio describes it any more. Keep the largest of the
                // contributing rows: the flag has to survive the fold (one
                // broken provider still makes the merged total wrong), and the
                // worst multiple is the honest thing to name when the row is
                // pointed at.
                costRatio: [current.costRatio, entry.costRatio].compactMap { $0 }.max()
            )
        }
        return folded
    }

    private static func mergedProviders(_ first: String, _ second: String) -> String {
        Set(([first, second].flatMap { $0.components(separatedBy: ", ") }))
            .sorted()
            .joined(separator: ", ")
    }
}
