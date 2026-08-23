import Foundation

/// What the recorded cycles say about a window, without needing a message scan.
///
/// The per-window history card answers this for one subscription and pays 4.6s
/// for the join to local usage. Everything here comes from the persisted quota
/// curve alone — a ~2ms read — so the all-subscription lens can carry it.
public struct QuotaWindowSummary: Equatable, Sendable, Identifiable {
    public let clientId: String
    /// Nil for the primary account. Part of `id` because two accounts of one
    /// client can offer identically-carded windows, and this id is both the
    /// `Identifiable` key of a rendered list and the lookup into the grids
    /// `DashboardModel` stores per account.
    public let accountKey: String?
    public let cardId: String
    public let windowLabel: String
    /// Consumption of each recorded cycle, oldest first. Drawn as a strip, so
    /// the reader compares the latest bar against the ones before it rather
    /// than against a number.
    public let recent: [Double]
    /// The highest absolute reading of each cycle in `recent`, same order.
    /// The bars draw consumption; only this can say whether a cycle ran out.
    public let recentPeaks: [Double]
    /// The heaviest cycle ever recorded for this window.
    public let peakPercent: Double
    /// True when no recorded cycle reached the ceiling. Stated positively
    /// because on real data it is the answer, and "you have never run out" is
    /// worth more than a gauge that is 90% full of nothing.
    public let neverExhausted: Bool
    public let cycleCount: Int

    public var id: String {
        AccountIdentity(clientId: clientId, accountKey: accountKey).windowKey(cardId: cardId)
    }
}

/// A window the heatmap can draw, whether or not it has completed a cycle yet.
///
/// Deliberately not `QuotaWindowSummary`: that one exists only for windows with
/// recorded HISTORY, and the heatmap is built from the raw curve. A window whose
/// only movement is in the cycle currently running has a grid and no summary, so
/// keying the picker on summaries made that grid unreachable and the card
/// announced "no allowance movement recorded yet" until the first cycle
/// completed — days, on a weekly window.
public struct QuotaHeatmapWindow: Equatable, Sendable, Identifiable {
    public let clientId: String
    public let cardId: String
    public let windowLabel: String
    /// Everything the grid accounts for, used to order the picker so the window
    /// worth looking at leads.
    public let total: Double

    /// See `QuotaWindowSummary.accountKey`.
    public let accountKey: String?

    public var id: String {
        AccountIdentity(clientId: clientId, accountKey: accountKey).windowKey(cardId: cardId)
    }

    public init(
        clientId: String, accountKey: String? = nil, cardId: String, windowLabel: String,
        total: Double
    ) {
        self.clientId = clientId
        self.accountKey = accountKey
        self.cardId = cardId
        self.windowLabel = windowLabel
        self.total = total
    }
}

public enum QuotaOverviewFold {
    /// A cycle at or above this counts as having reached the ceiling. Not 100:
    /// providers report whole percents and stop updating once the allowance is
    /// spent, so an exhausted window is observed at 99 or 100 depending on when
    /// the last sample landed.
    public static let exhaustedPercent: Double = 99

    /// How many cycles a strip shows. Enough to read a rhythm at popover width
    /// without each bar becoming a hairline.
    public static let stripLength = 16

    /// One summary per window that has at least one recorded cycle. Windows
    /// with no history are omitted rather than shown empty: the Agent-limits
    /// card already states their current position, and a row saying "no history
    /// yet" repeated across every fresh install is noise.
    public static func summaries(
        windows: [(
            clientId: String, accountKey: String?, cardId: String, label: String,
            cycles: [QuotaCycle]
        )]
    ) -> [QuotaWindowSummary] {
        windows.compactMap { window -> QuotaWindowSummary? in
            guard !window.cycles.isEmpty else { return nil }
            // `cycles` arrives newest first from `QuotaHistoryFold`; a strip
            // reads left to right in time.
            let ordered = window.cycles.prefix(stripLength).reversed()
            let consumption = ordered.map(\.usedPercent)
            let peaks = ordered.map(\.peakUsedPercent)
            // Consumption for the strip, absolute reading for the ceiling.
            // `usedPercent` is a span, so a cycle first observed at 40% and
            // last at 100% has a span of 60 and would have been called quiet.
            let peak = window.cycles.map(\.peakUsedPercent).max() ?? 0
            return QuotaWindowSummary(
                clientId: window.clientId, accountKey: window.accountKey,
                cardId: window.cardId,
                windowLabel: window.label,
                recent: Array(consumption),
                recentPeaks: Array(peaks),
                peakPercent: peak,
                neverExhausted: peak < exhaustedPercent,
                cycleCount: window.cycles.count)
        }
        // Heaviest peak first: the window most worth looking at leads.
        .sorted { $0.peakPercent > $1.peakPercent }
    }
}
