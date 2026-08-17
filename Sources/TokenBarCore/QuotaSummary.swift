import Foundation

/// The one-line answer the all-agent Overview owes the user: of everything you
/// are subscribed to, what is closest to running out.
///
/// A per-client window card cannot answer this — it only ever sees one
/// subscription — which is why the cross-subscription surface needs its own
/// statement rather than a smaller copy of that card.
public struct QuotaSummary: Equatable, Sendable {
    public let tightestClient: String
    /// The provider's own label for the window, untranslated. Display code
    /// localizes it; the raw value stays comparable.
    public let tightestLabel: String
    public let remainingPercent: Double
    public let resetsAt: String?
    /// Windows other than the tightest that carry a usable reading.
    public let otherWindows: Int
    /// How many of those sit at or above `comfortablePercent`. Reported rather
    /// than derived in the view so "4 others, all comfortable" and "4 others,
    /// two of them tight" cannot render the same.
    public let othersComfortable: Int

    /// The window furthest past its expected burn line, if any is.
    ///
    /// A second question, not a restatement of the first. "Tightest" is a
    /// level; this is a rate. A window at 61% consumed twice as fast as its
    /// schedule allows will run out before one sitting at 18% that nobody has
    /// touched since morning, and only this line can say so.
    public let burning: BurnWarning?

    public var allOthersComfortable: Bool {
        otherWindows > 0 && othersComfortable == otherWindows
    }
}

public struct BurnWarning: Equatable, Sendable {
    public let clientId: String
    public let label: String
    /// Actual used percent minus the expected one. Always positive here —
    /// a window running under its schedule is not a warning.
    public let aheadPercent: Double
    /// Borrowed verbatim from `UsagePace.presentation`, the same strings the
    /// Agent-limits card shows, so the summary cannot phrase a projection
    /// differently from the card the user opens to check it.
    public let etaText: String?
    public let riskText: String?
}

public enum QuotaSummaryFold {
    /// The line between "worth mentioning" and "fine". Not a warning
    /// threshold — `AgentLimitsCard` already owns those at 25% and 10% — just
    /// the point past which a window is not worth a sentence on the landing
    /// tab.
    public static let comfortablePercent: Double = 60

    /// Reuses `QuotaResolver` for the tightest window rather than re-deriving
    /// it, so this sentence and the menu bar can never name different
    /// subscriptions. The remaining counts are computed against the same
    /// eligibility rule the resolver applies: a client with an error is not
    /// evidence, and a non-finite percentage is not a reading.
    public static func build(
        payload: AgentUsagePayload?, excluding: Set<String> = [],
        paceMode: PaceMode = .historical, now: Date = Date()
    ) -> QuotaSummary? {
        guard let payload,
              let tightest = QuotaResolver.resolve(
                  payload: payload, selection: QuotaResolver.auto, excluding: excluding)
        else { return nil }

        var others: [Double] = []
        var burning: BurnWarning?
        for agent in payload.agents
        where agent.error == nil && !excluding.contains(agent.clientId) {
            for window in agent.uniqueCardWindows where window.remainingPercent.isFinite {
                // The burn check covers EVERY eligible window including the
                // tightest, because the tightest one may also be the fastest
                // and skipping it would drop the most urgent case.
                if let pace = UsagePace.compute(window: window, mode: paceMode, now: now),
                   pace.stage.isDeficit,
                   pace.deltaPercent > (burning?.aheadPercent ?? 0)
                {
                    let shown = UsagePace.presentation(
                        window: window, mode: paceMode, pace: pace)
                    burning = BurnWarning(
                        clientId: agent.clientId, label: window.label,
                        aheadPercent: pace.deltaPercent,
                        etaText: shown.etaText, riskText: shown.riskText)
                }
                // Identity is the pair, not the label: two subscriptions can
                // both call a window "Weekly", and counting by label alone
                // would drop one of them from the tally.
                if agent.clientId == tightest.clientId,
                   window.cardId == tightest.window.cardId { continue }
                others.append(window.remainingPercent)
            }
        }

        return QuotaSummary(
            tightestClient: tightest.clientId,
            tightestLabel: tightest.window.label,
            remainingPercent: tightest.window.remainingPercent,
            resetsAt: tightest.window.resetsAt,
            otherWindows: others.count,
            othersComfortable: others.filter { $0 >= comfortablePercent }.count,
            burning: burning)
    }
}
