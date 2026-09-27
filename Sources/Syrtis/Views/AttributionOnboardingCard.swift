import SwiftUI
import TokenBarCore

/// The card that makes usage attribution findable without opening Settings.
///
/// Unlike `DiscordIntro` (whose flag is written the moment the card is
/// PRESENTED, so a feature the user already turned off is never explained
/// again), this follows `GrokBotKeychainConsent`'s rule instead: the flag
/// records an ANSWER — "not now" — never the fact of having been shown. A
/// user who has not yet decided keeps seeing the card every time Overview
/// opens, because nothing here is a one-time interruption; it is a standing
/// invitation until either it is declined or the thing it is inviting the
/// user to do (attribute something) has happened.
enum AttributionOnboardingCard {
    static let dismissedKey = "tokenbar.usage.attribution.onboardingDismissed"

    /// Suggestion lines beyond this fold into "and N more" rather than
    /// growing the card without bound.
    static let maxVisibleLines = 4

    /// The card has to stand out from the dashboard cards around it: in its
    /// first round it was a plain DashCard and the maintainer did not notice
    /// it. An accent wash and an accent border, both kept low enough that the
    /// card still reads as part of the panel.
    static let accentFill = 0.10
    static let accentStroke = 0.55

    enum Copy {
        static let title = "Attribute usage to subscriptions"
        static let subtitle = "Quota history shows no tokens or API-equivalent value until usage is attributed."
        /// source client · provider → target
        static let suggestionLine = "%@ · %@ → %@"
        static let moreCount = "and %lld more"
        static let unsuggestedHint = "%lld sources have no suggestion — set them in Settings."
        static let notNow = "Not now"
        static let setUpManually = "Set up manually…"
        static let applySuggestions = "Apply suggestions"
        /// Under the window history, where every row reads 0 / $0.00 until
        /// something is attributed: the zeros are the missing attribution,
        /// not a quiet window.
        static let historyZeroNote = "The tokens and amounts below stay at 0 until usage is attributed to this subscription."
        static let setUpLink = "Set up usage attribution…"

        static var all: [String] {
            [
                title, subtitle, suggestionLine, moreCount, unsuggestedHint,
                notNow, setUpManually, applySuggestions, historyZeroNote, setUpLink,
            ]
        }
    }

    /// All five gates the card must clear before it draws anything. Split out
    /// so the rule is assertable on its own — a SwiftUI `body` cannot be
    /// evaluated from a UI-free test, but this can.
    static func isVisible(
        confirmedIsEmpty: Bool,
        dismissed: Bool,
        hasReport: Bool,
        hasAgentUsage: Bool,
        attributableRowCount: Int,
        isNonUserRuntime: Bool
    ) -> Bool {
        confirmedIsEmpty && !dismissed && hasReport && hasAgentUsage
            && attributableRowCount > 0 && !isNonUserRuntime
    }

    /// Deliberately NOT `DiscordIntro`'s "write the flag when PRESENTED" rule
    /// — see `GrokBotKeychainConsent`'s note on the same contrast. This flag
    /// records an ANSWER ("not now"), so a user who has not yet decided keeps
    /// seeing the card on every open; only tapping "Not now" suppresses it.
    /// The gates that do not need the dashboard's data: whether the card could
    /// still appear once the report arrives. Decides whether a lens that does
    /// not otherwise need the model report fetches it for the card.
    static func mayShow(
        defaults: UserDefaults = .standard, arguments: [String] = CommandLine.arguments
    ) -> Bool {
        UsageAttribution.confirmed(defaults: defaults).records.isEmpty
            && defaults.object(forKey: dismissedKey) as? Bool != true
            && !BuildIdentity.isNonUserRuntime(arguments)
    }

    static func markDismissed(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: dismissedKey)
    }

    /// One proposal line. The record's own `state` IS the proposed target —
    /// `acceptanceRecords` already resolved it — so this only has to render
    /// it, never re-derive it.
    static func suggestionLine(_ record: UsageAttribution.Record) -> String {
        let providerLabel = (record.provider.isEmpty
            ? UsageAttributionSettings.Copy.unspecifiedProvider : record.provider
        ).localized
        let targetLabel: String
        switch record.state {
        case let .assigned(target):
            targetLabel = ClientRegistry.style(target).displayName
        case .excluded:
            targetLabel = UsageAttributionSettings.Copy.excluded.localized
        case .unassigned:
            targetLabel = UsageAttributionSettings.Copy.unassigned.localized
        }
        return Copy.suggestionLine.localized(
            ClientRegistry.style(record.client).displayName, providerLabel, targetLabel)
    }
}

struct AttributionOnboardingCardView: View {
    var modelReport: ModelReport?
    var agentUsage: AgentUsagePayload?

    @AppStorage(UsageAttribution.confirmedKey) private var confirmedRaw = ""
    @AppStorage(AttributionOnboardingCard.dismissedKey) private var dismissed = false
    @State private var applyFailure: String?

    private var confirmed: [UsageAttribution.Record] {
        UsageAttribution.parseRaw(confirmedRaw).records
    }

    /// Computed from THIS surface's own inputs — the model report and the
    /// agent-usage payload the popover already polls — never from the stored
    /// suggestions table, which Settings alone fills. Reading that table here
    /// would show suggestions that only exist because Settings happened to be
    /// opened once, rather than what this data actually supports right now.
    private var summary: UsageAttributionSettings.OnboardingSummary? {
        guard let modelReport, let agentUsage else { return nil }
        return UsageAttributionSettings.onboardingSummary(
            entries: modelReport.entries,
            confirmed: confirmed,
            subscriptionClients: UsageAttributionSettings.subscriptionClients(from: agentUsage),
            routedSubscriptions: UsageAttributionSettings.routedSubscriptions(from: agentUsage))
    }

    private var attributableRowCount: Int {
        UsageAttributionSettings.rows(
            entries: modelReport?.entries ?? [], confirmed: confirmed, suggestions: []
        ).count
    }

    var isVisible: Bool {
        AttributionOnboardingCard.isVisible(
            confirmedIsEmpty: confirmed.isEmpty,
            dismissed: dismissed,
            hasReport: modelReport != nil,
            hasAgentUsage: agentUsage != nil,
            attributableRowCount: attributableRowCount,
            isNonUserRuntime: BuildIdentity.isNonUserRuntime(CommandLine.arguments))
    }

    var body: some View {
        if isVisible, let summary {
            DashCard(AttributionOnboardingCard.Copy.title) {
                content(summary)
            }
            .background(
                Color.accentColor.opacity(AttributionOnboardingCard.accentFill),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        Color.accentColor.opacity(AttributionOnboardingCard.accentStroke),
                        lineWidth: 1))
        }
    }

    @ViewBuilder
    private func content(_ summary: UsageAttributionSettings.OnboardingSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AttributionOnboardingCard.Copy.subtitle.localized)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let applyFailure {
                Text(applyFailure.localized)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 3) {
                ForEach(
                    Array(summary.records.prefix(AttributionOnboardingCard.maxVisibleLines).enumerated()),
                    id: \.offset
                ) { _, record in
                    Text(AttributionOnboardingCard.suggestionLine(record))
                        .font(.caption)
                        .lineLimit(1)
                }
                if summary.records.count > AttributionOnboardingCard.maxVisibleLines {
                    Text(AttributionOnboardingCard.Copy.moreCount.localized(
                        Int64(summary.records.count - AttributionOnboardingCard.maxVisibleLines)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if summary.unsuggestedCount > 0 {
                    Text(AttributionOnboardingCard.Copy.unsuggestedHint.localized(
                        Int64(summary.unsuggestedCount)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Button(AttributionOnboardingCard.Copy.notNow.localized) {
                    AttributionOnboardingCard.markDismissed()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)

                Button(AttributionOnboardingCard.Copy.setUpManually.localized) {
                    SettingsWindowController.shared.show(scrollingTo: .usageAttribution)
                }
                .buttonStyle(.plain)
                .font(.caption)

                Spacer()

                if !summary.records.isEmpty {
                    Button(AttributionOnboardingCard.Copy.applySuggestions.localized) {
                        applyFailure = UsageAttributionSettings.accept(
                            summary.records, defaults: .standard)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
    }
}

/// The link every "nothing attributed yet" surface uses to reach the page.
struct AttributionSetupLink: View {
    var body: some View {
        Button(AttributionOnboardingCard.Copy.setUpLink.localized) {
            SettingsWindowController.shared.show(scrollingTo: .usageAttribution)
        }
        .buttonStyle(.link)
        .font(.caption)
    }
}
