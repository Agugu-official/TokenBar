import Foundation
import TokenBarCore

/// Shared quota-selection policy for the tray and Settings preview. Both live
/// and demo callers use the same payload-aware canonical migration.
enum QuotaSelectionPolicy {
    static func effectiveSelection(
        payload: AgentUsagePayload?,
        persistedSelection: String,
        excluding: Set<String>
    ) -> String {
        QuotaResolver.canonicalSelection(payload: payload, selection: persistedSelection)
    }

    /// Returns a stable card-id selection only when the current payload proves
    /// that a persisted pre-v3 label has one unambiguous migration target.
    static func migrationToPersist(
        payload: AgentUsagePayload?,
        persistedSelection: String
    ) -> String? {
        let canonical = QuotaResolver.canonicalSelection(
            payload: payload, selection: persistedSelection)
        guard canonical != QuotaResolver.auto, canonical != persistedSelection else { return nil }
        return canonical
    }

    static func resolve(
        payload: AgentUsagePayload?,
        persistedSelection: String,
        excluding: Set<String>
    ) -> (clientId: String, accountKey: String?, window: UsageWindow)? {
        let selection = effectiveSelection(
            payload: payload,
            persistedSelection: persistedSelection,
            excluding: excluding)
        return QuotaResolver.resolve(
            payload: payload, selection: selection, excluding: excluding)
    }

    /// A missing outer payload may reuse the last-good scalar. Once a payload
    /// arrives, only a finite value resolved from that payload is valid.
    static func resolveRemainingPercent(
        payload: AgentUsagePayload?,
        persistedSelection: String,
        excluding: Set<String>,
        cachedRemaining: Double?
    ) -> Double? {
        guard payload != nil else { return cachedRemaining }
        guard let remaining = resolve(
            payload: payload,
            persistedSelection: persistedSelection,
            excluding: excluding)?.window.remainingPercent,
            remaining.isFinite
        else { return nil }
        return remaining
    }

    /// When the selected reading was fetched (#8): the `updatedAt` of the
    /// snapshot `resolve` picked. Rust's same-binding `last_good` fallback
    /// keeps the original fetch's `updated_at`, so an explicit selection served
    /// from it reports its real age. This is only as accurate as the
    /// snapshot's own `updatedAt`; a provider that serves cached data under a
    /// fresh stamp is reported younger than it is.
    static func resolvedAt(
        payload: AgentUsagePayload,
        persistedSelection: String,
        excluding: Set<String>
    ) -> Date? {
        guard let resolved = resolve(
            payload: payload, persistedSelection: persistedSelection, excluding: excluding),
            let agent = payload.agents.first(where: {
                $0.clientId == resolved.clientId && $0.accountKey == resolved.accountKey
            }),
            let ms = WindowCardLoader.parseISO8601Ms(agent.updatedAt)
        else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }
}
