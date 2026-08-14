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
    /// Below the per-message scale bound: the line still draws (quota samples
    /// are cheap regardless of window length) but the bars do not, because a
    /// 31-day window is ~88k messages against a session window's ~1k.
    let barsSuppressed: Bool
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

    /// Per-message scanning is for session-class windows only. Measured: a
    /// 5-hour window is ~1k messages, the 31-day `chat.v1` is ~88k. The test is
    /// a dot-component match rather than a substring so `weekly_scoped.fable.v1`
    /// cannot slip through, and an unrecognised key fails closed — no scan, no
    /// curve — which is the safe direction for a key we have not seen.
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

    /// `nil` when nothing can be shown: no selection, or a window whose class
    /// bars the per-message path.
    /// Scoped to one agent: the card lives in that agent's tab, so only that
    /// agent's windows are offered. The top-level overview gets a text summary
    /// across subscriptions instead — a different question, not this card.
    static func load(
        source: UsageDataSource,
        payload: AgentUsagePayload?,
        clientId: String,
        nowMs: Int64
    ) async -> WindowCardData? {
        guard let payload else { return nil }
        guard let selected = select(
            payload: payload, clientId: clientId,
            chosen: UserDefaults.standard.string(forKey: selectionKey))
        else {
            // No session window right now. Say why when a provider is failing;
            // stay hidden when the user simply has no session-class plan.
            guard let failing = payload.agents.first(where: {
                $0.clientId == clientId && $0.error != nil
            }) else { return nil }
            return WindowCardData(
                clientId: failing.clientId, windowLabel: "session",
                resolution: .unavailable, samples: [],
                mine: [], bars: [], hits: [], candidates: [], cardId: "",
                barsSuppressed: false, nowMs: nowMs, blockedBy: failing.error)
        }

        let window = selected.window
        let sessionClass = isSessionClass(windowKey: window.paceStatus.windowKey)
        // First pass without usage. Only ACTIVE and UNAVAILABLE are decidable
        // here, which is the point: the usage probe is bounded by R1 and must
        // not run against a stale reset.
        var resolved = resolution(window: window, nowMs: nowMs, firstUsageAfterReset: nil)

        if case .idle = resolved, let resetMs = window.resetsAt.flatMap(parseISO8601Ms) {
            // `.idle` means R is past but within one window length, so `[R, now]`
            // is bounded by D — the only state in which this probe is legal.
            if let probe = try? await source.windowUsage(from: resetMs, until: nowMs) {
                resolved = resolution(
                    window: window, nowMs: nowMs,
                    firstUsageAfterReset: WindowResolver.firstUsageAfterReset(
                        messages: probe.messages, resetMs: resetMs))
            }
        }

        // The scan is the expensive half and it is what the class rule bounds:
        // a session window is ~1k messages, a 31-day one ~88k. Skip it entirely
        // rather than fetch and then decline to draw.
        var messages: [WindowMessage] = []
        if sessionClass {
            switch resolved {
            case let .active(start, end), let .inferred(start, end):
                messages = (try? await source.windowUsage(
                    from: start, until: min(end, nowMs)))?.messages ?? []
            case .idle, .unavailable:
                break
            }
        }

        let samples = await quotaSamples(
            source: source, payload: payload, clientId: selected.clientId,
            window: window, resolution: resolved, nowMs: nowMs)

        let confirmed = UsageAttribution.confirmed().records
        let mine = messages.filter {
            UsageAttribution.resolve(
                client: $0.client, provider: $0.providerId, model: nil,
                records: confirmed) == .assigned(selected.clientId)
        }
        var bars: [BarRect] = [], hits: [HitZone] = []
        if case let .active(start, end) = resolved {
            (bars, hits) = WindowCardGeometry.usageGeometry(
                windowStartMs: start, windowEndMs: end, nowMs: min(nowMs, end),
                samples: samples, messages: mine)
        } else if case let .inferred(start, end) = resolved {
            (bars, hits) = WindowCardGeometry.usageGeometry(
                windowStartMs: start, windowEndMs: end, nowMs: min(nowMs, end),
                samples: samples, messages: mine)
        }

        let candidates = payload.agents
            .first { $0.clientId == selected.clientId }?
            .uniqueCardWindows
            .map { (cardId: "\(selected.clientId)|\($0.cardId)", label: $0.label) } ?? []
        return WindowCardData(
            clientId: selected.clientId, windowLabel: window.label,
            resolution: resolved, samples: samples,
            mine: mine, bars: sessionClass ? bars : [], hits: hits,
            candidates: candidates, cardId: "\(selected.clientId)|\(window.cardId)",
            barsSuppressed: !sessionClass, nowMs: nowMs)
    }

    /// Quota readings inside the resolved interval. `sampledAt` is in SECONDS —
    /// the decoder subtracts `durationSeconds` from `resetAt` directly — while
    /// every window bound here is milliseconds. Comparing the two units gives
    /// an empty series that looks exactly like a missing data path.
    private static func quotaSamples(
        source: UsageDataSource, payload: AgentUsagePayload, clientId: String,
        window: UsageWindow, resolution: WindowResolution, nowMs: Int64
    ) async -> [QuotaSample] {
        guard let key = window.paceStatus.windowKey,
              let generation = payload.publicationGeneration,
              // `try?` on an optional-returning throwing call double-wraps;
              // flatten so a thrown error and a null series both mean "none".
              let curve = (try? await source.quotaCurve(
                  clientId: clientId, windowKey: key, generation: generation)) ?? nil
        else { return [] }

        let bounds: (Int64, Int64)
        switch resolution {
        case let .active(start, _): bounds = (start, nowMs)
        case let .inferred(start, _): bounds = (start, nowMs)
        case .idle, .unavailable: return []
        }
        let lo = bounds.0 / 1000, hi = bounds.1 / 1000
        return curve.points
            .filter { $0.sampledAt >= lo && $0.sampledAt <= hi }
            .sorted { $0.sampledAt < $1.sampledAt }
            .map { QuotaSample(atMs: $0.sampledAt * 1000, usedPercent: $0.usedPercent) }
    }
}
