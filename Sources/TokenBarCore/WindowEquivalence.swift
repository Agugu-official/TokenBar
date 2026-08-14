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
}


extension String {
    /// Same lookup-then-format as `localized(_:)`, named apart only so the
    /// window-card strings can be asserted from TokenBarCore's own test seam.
    func localizedWindowRow(_ arguments: any CVarArg...) -> String {
        String(format: localized, arguments: arguments)
    }
}
