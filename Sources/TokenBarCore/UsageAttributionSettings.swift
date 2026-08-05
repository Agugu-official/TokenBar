import Foundation

/// Pure derivation for the provider-level Usage Attribution settings page.
public enum UsageAttributionSettings {
    public enum Copy {
        public static let section = "Usage attribution"
        public static let classifyHint = "Classify each observed client/provider source against the subscription it should count toward. Nothing here is inferred as a billing event."
        public static let canonicalizationHint = "Provider IDs are canonicalized before they reach TokenBar: openai_codex becomes openai, and vertex / vertex_ai become anthropic. Routes that canonicalize to the same provider cannot be separated here."
        public static let declarationHint = "A declaration is your classification, not a billing fact."
        public static let noRows = "No provider-split usage in this range."
        /// The report request finished without one. Distinct from `noRows`,
        /// which is an answer about a report that did arrive.
        public static let unavailable = "Usage could not be loaded, so there is nothing to classify yet."
        public static let acceptSuggestions = "Accept all suggestions (%lld)"
        public static let suggestionsHint = "Suggestions are proposals; they do not change your classification until accepted."
        public static let source = "%@ · %@"
        public static let observed = "Observed %@ tokens · %@"
        public static let classification = "Classification"
        public static let unassigned = "Unassigned"
        public static let excluded = "Not a subscription"
        public static let assigned = "Counts toward %@"
        public static let suggested = "Suggested: counts toward %@"
        public static let suggestedExcluded = "Suggested: not a subscription"
        public static let unspecifiedProvider = "Unspecified provider"
        public static let classificationFor = "Classification for %@"

        public static var all: [String] {
            [
                section, classifyHint, canonicalizationHint, declarationHint, noRows, unavailable,
                acceptSuggestions, suggestionsHint, source, observed, classification,
                unassigned, excluded, assigned, suggested, suggestedExcluded, unspecifiedProvider,
                classificationFor,
                WriteFailure.invalidExistingValue.message,
                WriteFailure.entryLimit.message,
                WriteFailure.sizeOrInvalidRecord.message,
            ]
        }
    }

    public struct Row: Identifiable, Equatable, Sendable {
        public let client: String
        public let provider: String
        public let tokens: Int64
        public let cost: Double
        public let state: UsageAttribution.State
        public let suggestedState: UsageAttribution.State?

        public var id: String { "\(client)\u{0}\(provider)" }

        /// Empty provider is valid wire data. Keep it as its own source key and
        /// give it a readable label instead of hiding or merging the row.
        public var providerLabel: String {
            provider.isEmpty ? Copy.unspecifiedProvider : provider
        }
    }

    public enum WriteFailure: Equatable, Sendable {
        case invalidExistingValue
        case entryLimit
        case sizeOrInvalidRecord

        public var message: String {
            switch self {
            case .invalidExistingValue:
                return "Could not save this classification: existing attribution data is invalid or foreign."
            case .entryLimit:
                return "Could not save this classification: the attribution entry limit was reached."
            case .sizeOrInvalidRecord:
                return "Could not save this classification: the new value is too large or unsupported."
            }
        }
    }

    /// This is auditable product knowledge, not an inference from local usage
    /// or quota payloads. Cross-client suggestions remain proposals and are only
    /// offered where the provider's subscription terms permit that route.
    /// Providers whose subscription terms allow it to be reached through some
    /// other agent. Only these can carry a cross-client assignment suggestion.
    ///
    /// An allowlist rather than a denylist, because being wrong in the
    /// permissive direction proposes that the user did something their provider
    /// forbids. Extend it per provider, with the terms checked.
    ///
    /// xAI ships OAuth sign-in for SuperGrok / X Premium+ into third-party
    /// agents (Pi, OpenCode) and its own ACP protocol for them, and that usage
    /// draws on the same shared weekly pool as grok.com — so a row of theirs
    /// logged elsewhere really did consume the subscription.
    public static let crossAgentSubscriptionProviders: Set<String> = ["openai", "xai"]

    /// Providers whose subscription may only be used by its own client. A row
    /// of theirs logged by a different client is API spend under any compliant
    /// reading, so that is what gets suggested — never their subscription.
    public static let subscriptionBoundProviders: Set<String> = ["anthropic", "google"]

    /// The client whose *own* subscription a provider is. This is what
    /// `subscriptionBoundProviders` actually restricts: driving Anthropic's or
    /// Google's own subscription from a third-party agent is what their terms
    /// forbid. A different subscription that resells the same models — Copilot
    /// serving Anthropic — is that subscription's own matter and is not covered
    /// by the restriction, so it stays assignable.
    public static let providerOwnClient: [String: String] = [
        "anthropic": "claude",
        "openai": "codex",
        "google": "antigravity",
        "xai": "grok",
    ]

    public static let subscriptionProviderMap: [String: Set<String>] = [
        "claude": ["anthropic"],
        "codex": ["openai"],
        "copilot": ["openai", "anthropic"],
        "grok": ["xai"],
        "antigravity": ["google"],
    ]

    /// `agentUsage` is the capability source for assignment targets. A transient
    /// last-good snapshot keeps its display-ready identity, windows, or credits,
    /// while the Rust producer's required placeholder for an absent provider has
    /// none of them. Exclude only that terminal empty shape so it cannot invent a
    /// subscription the user never configured.
    ///
    /// `opencodeSubscriptions` is a second, independent statement of ownership:
    /// opencode reports the providers its `auth.json` holds an oauth entry for,
    /// and a user who reaches a subscription only that way has no snapshot of
    /// their own — just the empty placeholder the filter above removes. Dropping
    /// them would leave exactly those rows unable to name the subscription they
    /// are known to consume, so the labels are folded back in as targets.
    public static func subscriptionClients(from payload: AgentUsagePayload?) -> [String] {
        var seen = Set<String>()
        let configured = (payload?.agents ?? []).compactMap { snapshot -> String? in
            guard snapshot.identity != nil || !snapshot.windows.isEmpty || snapshot.credits != nil
            else { return nil }
            return snapshot.clientId
        }
        let viaOpencode = (payload?.opencodeSubscriptions ?? [])
            .compactMap(subscriptionClient(forLabel:))
        return (configured + viaOpencode).filter {
            ClientRegistry.allIds.contains($0) && seen.insert($0).inserted
        }
    }

    /// The subscription client an opencode label names, or nil when none is.
    ///
    /// Two rules, because the producer's labels are not uniformly invertible.
    /// `subscription_label` renames four providers outright (`openai` to `Codex`
    /// and so on) and otherwise just capitalizes the provider key, so the renames
    /// need an explicit inverse while everything else *is* a provider and can be
    /// resolved through the map that already says which client serves it. Writing
    /// the second rule as a lookup rather than a second hand-kept table is what
    /// stops a provider added to `subscriptionProviderMap` from being invisible
    /// here — `xai` was, which is how a Grok subscription reached only through
    /// opencode could not be named as a target.
    public static func subscriptionClient(forLabel label: String) -> String? {
        if let alias = ClientRegistry.subscriptionLabelAliases[label] { return alias }
        let provider = label.lowercased()
        let owners = subscriptionProviderMap
            .filter { $0.value.contains(provider) }
            .keys
            .sorted()
        // A label with no owner names no subscription, whatever else it may
        // name. `Kiro` lowercases to a registered client, so returning it would
        // put "Counts toward Kiro" in the picker for a client that owns no
        // subscription provider and that the policy below can never resolve.
        // Ambiguity yields nothing for the same reason: a guess is not an answer.
        guard owners.count == 1 else { return nil }
        return owners[0]
    }

    /// What the attribution page shows. A nil report is two states: the request
    /// is still running, or it finished without one — `DashboardModel.load()`
    /// takes the report with `try?` and reaches `.ready` on the graph alone.
    /// Collapsing the second into "no provider-split usage" tells the user there
    /// is nothing to classify at exactly the moment the data needed to classify
    /// could not be loaded.
    public enum PageState: Equatable {
        case loading
        case unavailable
        case empty
        case rows
    }

    public static func pageState(
        hasReport: Bool, rowCount: Int, isLoading: Bool
    ) -> PageState {
        guard hasReport else { return isLoading ? .loading : .unavailable }
        return rowCount == 0 ? .empty : .rows
    }

    /// Consume raw provider-split rows. `modelLevelEntries` folds providers
    /// back together, which would erase the exact dimension this page classifies.
    public static func rows(
        entries: [ModelReportEntry],
        confirmed: [UsageAttribution.Record],
        suggestions: [UsageAttribution.Record]
    ) -> [Row] {
        var aggregate: [String: (client: String, provider: String, tokens: Int64, cost: Double)] = [:]
        var order: [String] = []
        for entry in entries {
            let key = sourceKey(client: entry.client, provider: entry.provider)
            if let current = aggregate[key] {
                aggregate[key] = (
                    current.client,
                    current.provider,
                    current.tokens.saturatingAdding(entry.total),
                    current.cost + entry.cost)
            } else {
                aggregate[key] = (entry.client, entry.provider, entry.total, entry.cost)
                order.append(key)
            }
        }

        return order.compactMap { key in
            guard let value = aggregate[key] else { return nil }
            let state = UsageAttribution.resolve(
                client: value.client, provider: value.provider, model: nil, records: confirmed)
            // A stored suggestion carries its own state now: `excluded` is a
            // proposal in its own right, not the absence of one.
            let suggestion: UsageAttribution.State?
            if case .unassigned = state {
                suggestion = suggestions.first {
                    $0.client == value.client && $0.provider == value.provider && $0.model == nil
                }?.state
            } else {
                suggestion = nil
            }
            return Row(
                client: value.client,
                provider: value.provider,
                tokens: value.tokens,
                cost: value.cost,
                state: state,
                suggestedState: suggestion)
        }
    }

    /// Which subscription a source row could plausibly belong to, or nil when
    /// nothing can be said.
    ///
    /// The question is asked provider-first, not source-first: a row records
    /// which provider served the tokens, and the answer is which of the user's
    /// subscriptions covers that provider — usually *not* the client that
    /// happened to log it. Routing a Claude Code session through a gateway to
    /// an OpenAI model produces `("claude", "openai")`, and the subscription it
    /// consumed is Codex.
    ///
    /// Still only a suggestion. The same row on another machine is an OpenAI
    /// API key, whose right answer is `excluded`, and no field in the data tells
    /// the two apart. This turns N clicks into one confirmation; it never
    /// decides.
    public static func suggestionTarget(
        sourceClient: String, provider: String, subscriptionClients: [String]
    ) -> UsageAttribution.State? {
        let owners = subscriptionClients.filter {
            subscriptionProviderMap[$0]?.contains(provider) == true
        }
        // A client talking to its own provider is the plainest reading, and
        // stays unambiguous even when another subscription also accepts it.
        //
        // "Its own" is asked of the subscription the source draws on, not of its
        // process identity: `antigravity-cli` is a client in its own right but
        // spends the `antigravity` subscription, so comparing the raw id would
        // find no owner and fall through to the subscription-bound branch —
        // declaring the CLI's own subscription usage to be API spend.
        let sourceOwner = ClientRegistry.quotaOwner(sourceClient)
        if owners.contains(sourceOwner) { return .assigned(sourceOwner) }

        // Which of the covering subscriptions could legitimately have been
        // reached from somewhere else. For a bound provider that is every owner
        // except the provider's own client, whose terms forbid exactly that
        // route; a reseller like Copilot is unaffected. For a permitted
        // provider every owner qualifies.
        let bound = subscriptionBoundProviders.contains(provider)
        let eligible: [String]
        if bound {
            eligible = owners.filter { $0 != providerOwnClient[provider] }
        } else if crossAgentSubscriptionProviders.contains(provider) {
            eligible = owners
        } else {
            // Neither policy covers this provider. The self-test pins that this
            // cannot happen for a provider a subscription serves; it remains the
            // runtime backstop if that stops holding.
            eligible = []
        }

        // Nothing eligible and the provider is bound: assume the user is
        // complying, so the tokens were bought rather than drawn from the
        // subscription. Nothing eligible otherwise says nothing at all.
        guard let only = eligible.count == 1 ? eligible[0] : nil else {
            return eligible.isEmpty && bound ? .excluded : nil
        }
        return .assigned(only)
    }

    public static func suggestionRecords(
        entries: [ModelReportEntry],
        confirmed: [UsageAttribution.Record],
        subscriptionClients: [String]
    ) -> [UsageAttribution.Record] {
        rows(entries: entries, confirmed: confirmed, suggestions: []).compactMap { row in
            guard case .unassigned = row.state,
                  let proposed = suggestionTarget(
                    sourceClient: row.client,
                    provider: row.provider,
                    subscriptionClients: subscriptionClients)
            else { return nil }
            return UsageAttribution.Record(
                client: row.client, provider: row.provider, state: proposed)
        }
    }

    /// Returns only provider-level proposals that are still unassigned. The
    /// caller stores them with `suggestionsRaw`; only explicit acceptance may
    /// pass the same records to `confirmedRaw`.
    public static func acceptanceRecords(rows: [Row]) -> [UsageAttribution.Record] {
        rows.compactMap { row in
            guard case .unassigned = row.state,
                  let proposed = row.suggestedState
            else { return nil }
            return UsageAttribution.Record(
                client: row.client, provider: row.provider, state: proposed)
        }
    }

    public static func writeFailure(
        table: UsageAttribution.Table,
        record: UsageAttribution.Record,
        result: String?
    ) -> WriteFailure? {
        writeFailure(table: table, records: [record], result: result)
    }

    public static func writeFailure(
        table: UsageAttribution.Table,
        records updates: [UsageAttribution.Record],
        result: String?
    ) -> WriteFailure? {
        guard result == nil else { return nil }
        guard table.isWritable else { return .invalidExistingValue }
        var records = table.records
        for update in updates {
            records.removeAll {
                $0.client == update.client && $0.provider == update.provider
                    && $0.model == update.model
            }
            if case .unassigned = update.state { continue }
            records.append(update)
        }
        if records.count > UsageAttribution.maxEntries { return .entryLimit }
        return .sizeOrInvalidRecord
    }

    public static func signature(
        entries: [ModelReportEntry], subscriptionClients: [String]
    ) -> String {
        let entrySignature = entries.map {
            [
                $0.client, $0.provider, $0.model, String($0.total),
                String($0.cost.bitPattern),
            ].joined(separator: "\u{1f}")
        }.joined(separator: "\u{1e}")
        return entrySignature + "|" + subscriptionClients.joined(separator: ",")
    }

    private static func sourceKey(client: String, provider: String) -> String {
        "\(client)\u{0}\(provider)"
    }
}
