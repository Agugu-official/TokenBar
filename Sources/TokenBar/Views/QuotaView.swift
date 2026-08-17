import SwiftUI
import TokenBarCore

/// The "Quota" lens: everything about a subscription's usage windows in one
/// place, rather than the current window on Overview and its history somewhere
/// else.
///
/// The two tabs answer different questions and so render different things.
/// Across all agents the question is comparative — which subscription is
/// tightest, which is burning fastest — and `AgentLimitsCard` already answers
/// it, one sparkline per window. On a single client the question is specific:
/// this window, then the windows before it.
struct QuotaView: View {
    /// The open client tab, or nil on the all-agent view.
    let singleClient: String?
    let clientIds: [String]
    let trace: [TraceBucket]
    let agentUsage: AgentUsagePayload?
    var usageAttempted = true
    /// Quota readings per `"<clientId>|<cardId>"`, for the sparklines.
    var windowCurves: [String: [QuotaSample]] = [:]
    /// The selected window's card state on a single-client tab.
    var windowCard: WindowCardState?
    /// Recorded reset cycles of that window, newest first.
    var quotaCycles: [QuotaCycle] = []
    /// Those cycles joined to local usage; empty while the scan is out.
    var quotaHistory: [QuotaHistoryRow] = []

    @AppStorage("tokenbar.limits.enabled") private var limitsEnabled = true

    var body: some View {
        VStack(spacing: 12) {
            if let singleClient {
                if let windowCard {
                    // Above its siblings: a `zIndex` set inside the card orders
                    // that card's children, not the card among these.
                    WindowUsageCard(state: windowCard).zIndex(1)
                }
                if limitsEnabled {
                    AgentLimitsCard(
                        clients: [singleClient], trace: trace, agentUsage: agentUsage,
                        usageAttempted: usageAttempted,
                        title: "%@ limits".localized(
                            ClientRegistry.style(singleClient).displayName),
                        note: "Session / weekly / model limits",
                        restrict: true)
                }
                QuotaHistoryCard(
                    clientId: singleClient, cycles: quotaCycles, rows: quotaHistory)
            } else if limitsEnabled {
                AgentLimitsCard(
                    clients: clientIds, trace: trace, agentUsage: agentUsage,
                    usageAttempted: usageAttempted,
                    reorderable: true, curves: windowCurves)
            } else {
                Text("The Agent limits card is turned off in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
