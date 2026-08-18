import Foundation

/// "10% of this subscription's quota is worth roughly this much local usage."
///
/// Computed live from the window's own samples every time. There is no
/// token-per-percent coefficient anywhere in this file, and there must never
/// be one: the same subscription measured 21x apart between its session window
/// and its weekly window on the same day.
public enum WindowEquivalence {
    /// The provider reports whole percents, so a measured Δ carries ±0.5.
    static let quantisationHalfStep = 0.5
    /// How much relative error the displayed ratio may carry.
    static let tolerance = 0.10
    /// Derived, not chosen: ±0.5/Δ ≤ tolerance ⇒ Δ ≥ 5.
    public static var minimumDelta: Double { quantisationHalfStep / tolerance }

    public enum Row: Equatable, Sendable {
        /// Tokens and cost equivalent to one tenth of the window's quota.
        case ratio(tokensPerTenth: Int64, costPerTenth: Double, errorPercent: Int)
        /// Quota moved, but not far enough to survive the 1% quantisation.
        /// `deltaPercent` is always > 0 here, so `errorPercent` is defined.
        case insufficient(deltaPercent: Double, errorPercent: Int)
        /// Two or more samples, but the reading never moved. Kept separate from
        /// `insufficient` because the error term is 0.5/delta — undefined here,
        /// and a caller that folded the two would divide by zero.
        case notMoved
        /// Quota moved and this machine saw none of it — a zero here would
        /// read as "1% is free", when it means "we cannot see it".
        case unaccounted(deltaPercent: Double)
        /// Fewer than two samples inside the window, so no Δ exists at all.
        case unavailable
        /// Nothing has been declared, so no usage can be charged to this
        /// subscription and the ratio has no numerator.
        ///
        /// Kept apart from `unaccounted`, which it would otherwise be
        /// indistinguishable from: that one says the quota moved and this
        /// machine recorded nothing, which for an undeclared user is false and
        /// alarming. The machine recorded plenty; the app has not been told
        /// whose it is. Most users never open that Settings page, so this is
        /// the common case, not an edge one.
        case undeclared
        /// The cycles disagree by more than the tolerance, so there is no
        /// single figure to give — only the span they cover.
        ///
        /// This is not a softer `insufficient`. That one means the readings are
        /// too coarse to measure; this means they were measured fine and the
        /// underlying rate genuinely moved. A plan change does exactly that,
        /// and the store keys its series on `(provider, account, window)` with
        /// no plan recorded, so a Plus-to-Pro upgrade lands in one series with
        /// the ratio changing partway and nothing marking where.
        case spread(lowPerTenth: Int64, highPerTenth: Int64,
                    lowCostPerTenth: Double, highCostPerTenth: Double)

        /// Whether an estimate was actually produced. Named so assertions can
        /// state the admission rule without re-deriving it from a pattern match.
        public var isRatio: Bool {
            if case .ratio = self { return true }
            return false
        }
    }

    /// The row as displayed. A pure function because the alternative — format
    /// strings inline in a SwiftUI body — has no seam to assert, and a literal
    /// `%` in one of them segfaulted the app: `String(format:)` read "10% of"
    /// as a `% o` octal conversion, ate the first argument, and sent a message
    /// to whatever the next `%@` found past the end of the argument list.
    public static func text(_ row: Row, tokens: (Int64) -> String,
                            money: (Double) -> String) -> String {
        switch row {
        case let .ratio(t, cost, error):
            return "10%% of quota ~ %@ · %@ API-equivalent, ±%@%%".localizedWindowRow(
                tokens(t), money(cost), String(error))
        case let .insufficient(delta, error):
            return "Quota moved only %@%% — too little to estimate (±%@%%)"
                .localizedWindowRow(String(Int(delta.rounded())), String(error))
        case .notMoved:
            return "Quota has not moved yet".localizedWindowRow()
        case let .unaccounted(delta):
            return "Quota moved %@%%, none of it recorded on this machine"
                .localizedWindowRow(String(Int(delta.rounded())))
        case .unavailable:
            return "Not enough quota readings yet".localizedWindowRow()
        case .undeclared:
            return "Classify your usage in Settings to see what this window is worth"
                .localizedWindowRow()
        case let .spread(low, high, lowCost, highCost):
            return "10%% of quota ~ %@-%@ · %@-%@ API-equivalent".localizedWindowRow(
                tokens(low), tokens(high), money(lowCost), money(highCost))
        }
    }

    /// `messages` must already be filtered to this subscription's attributed
    /// usage. `samples` must be the ones inside the window, in time order.
    public static func row(
        samples: [QuotaSample], messages: [WindowMessage]
    ) -> Row {
        guard let first = samples.first, let last = samples.last,
              samples.count >= 2
        else { return .unavailable }

        let delta = last.usedPercent - first.usedPercent
        guard delta > 0 else { return .notMoved }

        // Numerator and denominator must cover the same interval or the ratio
        // means nothing — hence the span between samples, not the whole window.
        let inSpan = messages.filter {
            $0.timestamp > first.atMs && $0.timestamp <= last.atMs
        }
        let tokens = inSpan.reduce(Int64(0)) { $0 + $1.tokens - $1.cacheRead }
        let cost = inSpan.reduce(0.0) { $0 + $1.cost }
        let error = Int((quantisationHalfStep / delta * 100).rounded())

        guard tokens > 0 else { return .unaccounted(deltaPercent: delta) }
        guard delta >= minimumDelta else {
            return .insufficient(deltaPercent: delta, errorPercent: error)
        }
        return .ratio(
            tokensPerTenth: Int64((Double(tokens) / delta * 10).rounded()),
            costPerTenth: cost / delta * 10,
            errorPercent: error)
    }

    /// A cycle's contribution to the pooled estimate.
    public struct Cycle: Equatable, Sendable {
        public let deltaPercent: Double
        /// Restricted to the cycle's observed sample span — the only interval
        /// the delta describes.
        public let spanTokens: Int64
        public let spanCost: Double
        public let observedFraction: Double

        public init(
            deltaPercent: Double, spanTokens: Int64, spanCost: Double,
            observedFraction: Double
        ) {
            self.deltaPercent = deltaPercent
            self.spanTokens = spanTokens
            self.spanCost = spanCost
            self.observedFraction = observedFraction
        }
    }

    /// Below this the cycle was barely witnessed, so its delta describes a
    /// stretch the app mostly missed. `QuotaCycle` already carried the fraction
    /// and said so in its own comment; nothing was gating on it.
    public static let minimumObservedFraction = 0.5
    /// Fewer than this and the leave-one-out spread is not computable in any
    /// meaningful way.
    public static let minimumCycles = 3

    // Both gates above also exclude a one-sample cycle, and they do it
    // structurally rather than by where the numbers are set: such a cycle's
    // delta is `max - min` over a single reading and its observed fraction is
    // the span between first and last sample, so BOTH are exactly zero
    // (`QuotaHistory.swift:142,144`). Lowering either constant therefore does
    // not start admitting them — worth knowing before anyone assumes it does.

    /// One estimate pooled over several cycles.
    ///
    /// Sum the deltas, sum the spend, divide ONCE. Not the average of per-cycle
    /// ratios: quantisation is an absolute ±0.5 on each delta, so a cycle's
    /// relative noise runs as 1/delta, and pooling weights each cycle by the
    /// evidence it carries while averaging gives a 5-point cycle the same say
    /// as a 98-point one.
    ///
    /// That distinction is the whole feature. Measured 2026-08-17 on 14 live
    /// cycles: the per-cycle ratios spread 2.7x (38% half-range), while the
    /// pooled estimate agreed to 1% between independent halves and carries a
    /// jackknife standard error of 5%. Reporting the per-cycle spread as the
    /// estimate's error — which this function used to do — overstated it by
    /// most of an order of magnitude and made a usable number look unusable.
    ///
    /// Denominated in money. Tokens are also returned, but cost is the steadier
    /// of the two here (5% against 7%), which is consistent with providers
    /// metering on something closer to cost than to a token count.
    /// `declared` is whether the user has classified ANY source. It belongs
    /// here rather than at the call site because the distinction it makes is
    /// this type's own: with nothing declared every message resolves to
    /// unassigned, so every cycle arrives carrying zero spend, and the rules
    /// below would report that as "the quota moved and none of it was recorded
    /// on this machine". That sentence describes a data failure. The actual
    /// state is a missing declaration, and it is the state most users are in.
    public static func aggregate(declared: Bool = true, cycles: [Cycle]) -> Row {
        guard declared else { return .undeclared }
        let admitted = cycles.filter {
            $0.deltaPercent >= minimumDelta
                && $0.observedFraction >= minimumObservedFraction
                && $0.spanCost > 0
        }
        guard !admitted.isEmpty else {
            let anyMovement = cycles.reduce(0.0) { $0 + $1.deltaPercent }
            if cycles.isEmpty { return .unavailable }
            if anyMovement <= 0 { return .notMoved }
            if cycles.allSatisfy({ $0.spanCost <= 0 }) {
                return .unaccounted(deltaPercent: anyMovement)
            }
            return .insufficient(
                deltaPercent: anyMovement,
                errorPercent: Int((quantisationHalfStep * Double(cycles.count)
                    / anyMovement * 100).rounded()))
        }
        guard admitted.count >= minimumCycles else {
            let delta = admitted.reduce(0.0) { $0 + $1.deltaPercent }
            return .insufficient(
                deltaPercent: delta,
                errorPercent: Int((quantisationHalfStep * Double(admitted.count)
                    / delta * 100).rounded()))
        }

        func pooled(_ set: [Cycle], _ pick: (Cycle) -> Double) -> Double {
            let delta = set.reduce(0.0) { $0 + $1.deltaPercent }
            return delta > 0 ? set.reduce(0.0) { $0 + pick($1) } / delta : 0
        }
        let costRatio = pooled(admitted) { $0.spanCost }
        let tokenRatio = pooled(admitted) { Double($0.spanTokens) }

        // Jackknife: recompute the pooled estimate with each cycle left out and
        // take the spread of those. It measures the ESTIMATE's stability rather
        // than the observations' scatter, and it needs nothing beyond what is
        // already stored.
        //
        // It does NOT catch a plan change, and this comment used to claim it
        // did. The user's own history contains a Pro-to-Plus downgrade and the
        // jackknife still reported 5%. That is structural, not bad luck: this
        // statistic reads how much the cycles disagree with each other, while a
        // plan change alters the UNIT each cycle's `deltaPercent` is denominated
        // in — 3% of a Pro allowance and 3% of a Plus one are different absolute
        // quantities. The unit moves, the dispersion does not, and an error bar
        // built on dispersion cannot see it.
        //
        // So do not build anything else on the assumption that a widening error
        // bar will flag a regime change. The fix is to record the plan on each
        // sample and refuse to pool across two of them; that field is landing
        // with the account-scope schema bump, and `Cycle` gains a `planKey` to
        // partition on. Until it does, an estimate spanning a plan change is
        // silently wrong and nothing here can tell.
        let n = Double(admitted.count)
        var leaveOneOut: [Double] = []
        for index in admitted.indices {
            var rest = admitted
            rest.remove(at: index)
            leaveOneOut.append(pooled(rest) { $0.spanCost })
        }
        let mean = leaveOneOut.reduce(0, +) / n
        let variance = (n - 1) / n
            * leaveOneOut.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
        let standardError = variance.squareRoot()
        let relativeError = costRatio > 0 ? standardError / costRatio : .infinity

        guard relativeError <= tolerance else {
            let ratios = admitted.map { $0.spanCost / $0.deltaPercent * 10 }
            let tokens = admitted.map { Double($0.spanTokens) / $0.deltaPercent * 10 }
            return .spread(
                lowPerTenth: Int64((tokens.min() ?? 0).rounded()),
                highPerTenth: Int64((tokens.max() ?? 0).rounded()),
                lowCostPerTenth: ratios.min() ?? 0,
                highCostPerTenth: ratios.max() ?? 0)
        }
        return .ratio(
            tokensPerTenth: Int64((tokenRatio * 10).rounded()),
            costPerTenth: costRatio * 10,
            errorPercent: max(1, Int((relativeError * 100).rounded())))
    }

}


extension String {
    /// Same lookup-then-format as `localized(_:)`, named apart only so the
    /// window-card strings can be asserted from TokenBarCore's own test seam.
    func localizedWindowRow(_ arguments: any CVarArg...) -> String {
        String(format: localized, arguments: arguments)
    }
}
