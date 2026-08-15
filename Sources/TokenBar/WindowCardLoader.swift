import Foundation
import TokenBarCore

/// Everything `WindowUsageCard` needs, resolved once per load.
struct WindowCardData: Sendable {
    let clientId: String
    let windowLabel: String
    let resolution: WindowResolution
    let samples: [QuotaSample]
    /// Already filtered to this subscription's attributed usage, and already
    /// turned into bars and hit zones. Both are metric-free and O(messages),
    /// so they are computed once here rather than on every hover event — the
    /// per-body version pegged a CPU on a window holding a few thousand rows.
    let mine: [WindowMessage]
    let bars: [BarRect]
    let hits: [HitZone]
    /// Every window this client offers, so the card can switch between them.
    /// `cardId` is the stable identity; `label` is what the provider calls it.
    let candidates: [(cardId: String, label: String)]
    let cardId: String
    let nowMs: Int64
    /// Set when no session window could be found but one is expected to come
    /// back — a provider whose fetch failed. Vanishing silently in that case is
    /// indistinguishable from "you have no such subscription", which is the one
    /// reading the user cannot correct.
    var blockedBy: String?
}

/// Turns the selected quota window into card data: resolve the window, then —
/// and only then — ask the engine for the messages inside it.
enum WindowCardLoader {
    /// "<clientId>|<cardId>" — the same shape QuotaResolver uses for its own
    /// canonical selection, so the two cannot drift into different vocabularies.
    static let selectionKey = "tokenbar.window.card.selection"

    /// Only decides which window to show first when the user has not picked
    /// one: a session window is the question the card was built to answer.
    /// It no longer gates the scan — see the note in `load`.
    ///
    /// A dot-component match rather than a substring, so `weekly_scoped.fable.v1`
    /// cannot pass for a session window.
    ///
    /// Observed keys (2026-08-14, live payload): `session.v1`, `main.session.v1`,
    /// `weekly.v1`, `main.weekly.v1`, `weekly_scoped.fable.v1`, `chat.v1`,
    /// `billing.weekly.v1`, `additional.<hash>.primary.v1`.
    static func isSessionClass(windowKey: String?) -> Bool {
        guard let windowKey else { return false }
        return windowKey.split(separator: ".").contains("session")
    }

    /// Within one agent. An explicit pick from the card's own buttons wins;
    /// otherwise prefer a session-class window — that is the question the card
    /// was built to answer — and fall back to the most depleted window there is.
    static func select(
        payload: AgentUsagePayload, clientId: String, chosen explicit: String? = nil
    ) -> (clientId: String, window: UsageWindow)? {
        guard let agent = payload.agents.first(where: { $0.clientId == clientId }),
              agent.error == nil
        else { return nil }
        let windows = agent.uniqueCardWindows
        // A selection stored for a different agent is not stale state to clear,
        // it just does not apply here — each tab answers for its own client.
        if let explicit, let sep = explicit.firstIndex(of: "|"),
           String(explicit[explicit.startIndex..<sep]) == clientId,
           let window = windows.first(where: {
               $0.cardId == String(explicit[explicit.index(after: sep)...])
           }) {
            return (clientId, window)
        }
        if let session = windows.first(where: {
            isSessionClass(windowKey: $0.paceStatus.windowKey)
        }) {
            return (clientId, session)
        }
        let best = windows.filter { $0.remainingPercent.isFinite }
            .min { $0.remainingPercent < $1.remainingPercent }
        return best.map { (clientId, $0) }
    }

    static func resolution(
        window: UsageWindow, nowMs: Int64, firstUsageAfterReset: Int64?
    ) -> WindowResolution {
        let resetMs = window.resetsAt.flatMap(parseISO8601Ms)
        return WindowResolver.resolve(
            resetsAtMs: resetMs, durationMs: window.durationSeconds.map { $0 * 1000 },
            now: nowMs, firstUsageAfterReset: firstUsageAfterReset)
    }

    static func parseISO8601Ms(_ text: String) -> Int64? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard let date = withFraction.date(from: text) ?? plain.date(from: text)
        else { return nil }
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    // MARK: - Stage 1: quota half, no scan

    /// Derives everything a scan is not needed for. Takes the payload as a
    /// value that is already in memory — it never fetches one, which is the
    /// whole reason this half is instant.
    static func quotaHalf(
        payload: AgentUsagePayload?, clientId: String, attempted: Bool,
        curve: (String, String, UInt64) -> QuotaCurve?, nowMs: Int64
    ) -> WindowCardState {
        guard let payload else { return attempted ? .loading : .loading }
        guard let agent = payload.agents.first(where: { $0.clientId == clientId })
        else { return .loading }
        if let error = agent.error {
            return .blocked(clientId: clientId, reason: error)
        }
        guard let selected = select(
            payload: payload, clientId: clientId,
            chosen: UserDefaults.standard.string(forKey: selectionKey))
        else { return .loading }

        let window = selected.window
        let candidates = agent.uniqueCardWindows.map {
            (cardId: "\(clientId)|\($0.cardId)", label: $0.label)
        }
        let cardId = "\(clientId)|\(window.cardId)"

        let samples = curveSamples(
            payload: payload, clientId: clientId, window: window, curve: curve, nowMs: nowMs)
        guard !samples.isEmpty else {
            return .noQuotaHistory(
                clientId: clientId, windowLabel: window.label,
                candidates: candidates, cardId: cardId)
        }

        // No usage yet, so `.idle` here means "R is past and within one D" —
        // the scan may still turn it into `.inferred`.
        let resolved = resolution(window: window, nowMs: nowMs, firstUsageAfterReset: nil)
        var pending = false
        if case .idle = resolved { pending = true }

        return .quotaOnly(WindowQuotaHalf(
            clientId: clientId, cardId: cardId, windowLabel: window.label,
            candidates: candidates, resolution: resolved, samples: samples,
            resetMs: window.resetsAt.flatMap(parseISO8601Ms),
            durationMs: window.durationSeconds.map { $0 * 1000 },
            placementPending: pending, nowMs: nowMs))
    }

    /// The earliest interval start across every candidate window of every
    /// displayed agent. See `UnionScan` for why this one bound covers all
    /// three window states.
    static func unionStart(
        payload: AgentUsagePayload?, clients: [String], nowMs: Int64
    ) -> Int64? {
        guard let payload else { return nil }
        var earliest: Int64?
        for agent in payload.agents where agent.error == nil && clients.contains(agent.clientId) {
            for window in agent.uniqueCardWindows {
                guard let reset = window.resetsAt.flatMap(parseISO8601Ms),
                      let duration = window.durationSeconds.map({ $0 * 1000 })
                else { continue }
                let start = reset - duration
                if earliest == nil || start < earliest! { earliest = start }
            }
        }
        return earliest
    }

    /// Stage 2, per client, from the one scan.
    static func usageHalf(
        quota: WindowQuotaHalf, scan: UnionScan, confirmed: [UsageAttribution.Record]
    ) -> (WindowQuotaHalf, WindowUsageHalf)? {
        // Refine `.idle` now that usage is known: the same resolver, this time
        // with the first usage after the reset.
        var resolved = quota.resolution
        if quota.placementPending, let reset = quota.resetMs {
            resolved = WindowResolver.resolve(
                resetsAtMs: reset, durationMs: quota.durationMs, now: quota.nowMs,
                firstUsageAfterReset: WindowResolver.firstUsageAfterReset(
                    messages: scan.slice(from: reset, to: quota.nowMs), resetMs: reset))
        }
        let settled = WindowQuotaHalf(
            clientId: quota.clientId, cardId: quota.cardId,
            windowLabel: quota.windowLabel, candidates: quota.candidates,
            resolution: resolved, samples: quota.samples,
            resetMs: quota.resetMs, durationMs: quota.durationMs,
            placementPending: false, nowMs: quota.nowMs)

        guard let (start, end) = interval(resolved) else {
            return (settled, WindowUsageHalf(mine: [], bars: [], hits: []))
        }
        // A scan that starts after this window did cannot answer for it.
        guard scan.covers(start: start) else { return nil }

        let mine = scan.slice(from: start, to: min(end, quota.nowMs)).filter {
            UsageAttribution.resolve(
                client: $0.client, provider: $0.providerId, model: nil,
                records: confirmed) == .assigned(quota.clientId)
        }
        let geo = WindowCardGeometry.usageGeometry(
            windowStartMs: start, windowEndMs: end, nowMs: min(quota.nowMs, end),
            samples: quota.samples, messages: mine)
        return (settled, WindowUsageHalf(mine: mine, bars: geo.bars, hits: geo.hits))
    }

    static func interval(_ s: WindowResolution) -> (start: Int64, end: Int64)? {
        switch s {
        case let .active(start, end), let .inferred(start, end): return (start, end)
        case .idle, .unavailable: return nil
        }
    }

    /// Quota readings inside the resolved interval. `sampledAt` is in SECONDS —
    /// the decoder subtracts `durationSeconds` from `resetAt` directly — while
    /// every window bound here is milliseconds. Comparing the two units gives
    /// an empty series that looks exactly like a missing data path.
    private static func curveSamples(
        payload: AgentUsagePayload, clientId: String, window: UsageWindow,
        curve read: (String, String, UInt64) -> QuotaCurve?, nowMs: Int64
    ) -> [QuotaSample] {
        guard let key = window.paceStatus.windowKey,
              let generation = payload.publicationGeneration,
              let curve = read(clientId, key, generation)
        else { return [] }

        // Bounded by the window the provider anchors, not by a resolution that
        // does not exist yet at stage 1.
        guard let reset = window.resetsAt.flatMap(parseISO8601Ms),
              let duration = window.durationSeconds.map({ $0 * 1000 })
        else { return [] }
        let lo = (reset - duration) / 1000, hi = nowMs / 1000
        // NOT filtered by reset cycle, deliberately.
        //
        // A foreign-cycle sample would let the interpolation draw a fall to
        // zero and back — a refill that never happened — so a guard looks
        // obviously right. Measured 2026-08-16, it is not:
        //
        //   * No window admits two cycles. Under usage-triggered windows
        //     `R - D = t0` and the previous cycle ends at or before `t0`, so
        //     the time range already separates them. All four live series
        //     returned exactly one cycle.
        //   * Both attempts at a guard broke working cards. Comparing against
        //     the parsed `resetsAt` fails because the engine quantises
        //     `resetAt` to the minute (codex differed by 62s, grok by 19s);
        //     comparing against `activeResetAt` fails too — it does not mean
        //     the cycle these points belong to. Each version silently filtered
        //     every sample and the card fell to "no quota history".
        //
        // No guard for an unobserved case, twice implemented wrongly, each
        // time causing the failure that IS observed. If a mixed-cycle window
        // ever appears, the fix belongs where the cycle is known: the engine.
        return curve.points
            .filter { $0.sampledAt >= lo && $0.sampledAt <= hi }
            .sorted { $0.sampledAt < $1.sampledAt }
            .map { QuotaSample(atMs: $0.sampledAt * 1000, usedPercent: $0.usedPercent) }
    }
}
