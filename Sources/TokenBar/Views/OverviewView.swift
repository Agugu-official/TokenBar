import SwiftUI
import TokenBarCore

/// The usage stack. Leads with the chart, then the live-session trace and the
/// model breakdown.
///
/// Quota lives in its own lens as of 2026-08-17 — the window card and the
/// Agent-limits card answer one question at two scales, and keeping them here
/// while the window history sat elsewhere split one subject across two places.
struct OverviewView: View {
    let payload: UsagePayload
    /// The active tab's client slice (all present clients on Overview).
    let clientIds: [String]
    let stats: UsageStats
    let modelReport: ModelReport?
    /// Forwarded to ModelBreakdownCard; see its `loading` doc.
    var modelLoading = false
    let colors: ModelColorMap
    let trace: [TraceBucket]
    /// Set when this view shows a single client's slice.
    var singleClient: String?
    /// Dashboard year filter (nil = all time), forwarded to the chart card.
    var year: String?
    /// The user's tab-hidden set, passed in from the observing parent
    /// (PopoverView) so the dependency is explicit rather than an imperative
    /// `ClientRegistry.hiddenClients()` read in this body.
    var hidden: Set<String> = []
    /// Cross-subscription quota position, folded by the model. Nil means no
    /// subscription reported a usable window.
    var quotaSummary: QuotaSummary?
    /// Whether the first quota fetch has settled, so a nil summary can read as
    /// "nothing to report" rather than "still asking".
    var usageAttempted = true

    var body: some View {
        VStack(spacing: 12) {
            // Quota cards moved to the Quota lens (2026-08-17): the window card
            // and the Agent-limits card answer the same question at two scales,
            // and having them here while the window history lived elsewhere
            // split one subject across two lenses. Overview keeps usage.
            if let singleClient {
                let name = ClientRegistry.style(singleClient).displayName
                chart
                ModelBreakdownCard(
                    report: modelReport, clientIds: clientIds, colors: colors,
                    title: "%@ models".localized(name), loading: modelLoading)
            } else {
                // Leads the all-agent tab: the cross-subscription question the
                // per-client cards structurally cannot answer, stated once.
                QuotaSummaryLine(
                    summary: quotaSummary, attempted: usageAttempted,
                    today: stats.perDayMap[Format.todayKey()].map {
                        (tokens: $0.tokens, cost: $0.cost)
                    })
                chart
                UsageTraceCard(buckets: trace, windowSecs: 600, hidden: hidden)
                ModelBreakdownCard(
                    report: modelReport, clientIds: clientIds, colors: colors,
                    loading: modelLoading)
            }
            StreaksCard(streaks: stats.streaks)
        }
    }

    private var chart: some View {
        UsageChartCard(
            payload: payload, clientIds: clientIds, stats: stats, colors: colors,
            year: year)
    }
}
