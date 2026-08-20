import Foundation
import TokenBarCore

/// The card loads in two halves because they cost four orders of magnitude
/// apart: reading the persisted quota samples is ~2ms, scanning local usage is
/// 6-12s. Loading them together made the whole card wait for the slow one --
/// and worse, both waited on a network fetch neither of them needs.

/// Stage 1. Everything derivable without a scan: the window, the line, the
/// headline. Needs an `AgentUsagePayload` that is already in memory; it never
/// waits on one being fetched.
struct WindowQuotaHalf: Sendable {
    let clientId: String
    let cardId: String
    let windowLabel: String
    let candidates: [(cardId: String, label: String)]
    let resolution: WindowResolution
    let samples: [QuotaSample]
    /// The provider anchor this half was resolved against. Carried so stage 2
    /// can re-resolve `.idle` with usage in hand without re-reading the payload.
    let resetMs: Int64?
    let durationMs: Int64?
    /// True when stage 1 resolved `.idle` — which the scan may still refine to
    /// `.inferred`. Shown as pending rather than as "no window running", so the
    /// card cannot state one answer and then replace it with another.
    let placementPending: Bool
    let nowMs: Int64
}

/// Stage 2. The product of the union scan, already attributed and already
/// turned into geometry.
struct WindowUsageHalf: Sendable {
    let mine: [WindowMessage]
    let bars: [BarRect]
    let hits: [HitZone]
}

/// What the card is, at any moment. Five cases, exhaustive by construction:
/// there is no "absent", because absence is what this slice exists to remove.
enum WindowCardState: Sendable {
    /// No quota payload has arrived yet, not even a failed one.
    case loading
    /// A provider reported an error instead of windows.
    case blocked(clientId: String, reason: String)
    /// The payload arrived but this window has no recorded quota history — a
    /// terminal answer, not a slow one. `copilot/chat.v1` is this case, and
    /// mapping it to `loading` would spin forever.
    case noQuotaHistory(clientId: String, windowLabel: String,
                        candidates: [(cardId: String, label: String)], cardId: String)
    /// Window placed; usage still scanning.
    case quotaOnly(WindowQuotaHalf)
    /// Both halves in.
    case ready(WindowQuotaHalf, WindowUsageHalf)
}

extension WindowCardState {
    var quotaHalf: WindowQuotaHalf? {
        switch self {
        case let .quotaOnly(q), let .ready(q, _): return q
        case .loading, .blocked, .noQuotaHistory: return nil
        }
    }

    var usageHalf: WindowUsageHalf? {
        if case let .ready(_, u) = self { return u }
        return nil
    }
}

/// The single scan that serves every card.
///
/// `from` is the earliest interval start across all candidate windows, so one
/// pass covers all three window states: an ACTIVE window starts at `R - D`;
/// the `.idle` probe needs `[R, now]` and `R >= R - D`; an INFERRED window
/// starts at `t0`, and `t0 >= R >= R - D` by the filter in
/// `firstUsageAfterReset`. `t0` being a product of the scan is therefore not a
/// problem: the range covers it without knowing it.
struct UnionScan: Sendable {
    let fromMs: Int64
    let untilMs: Int64
    let capturedAt: Date
    let messages: [WindowMessage]

    /// Whether this scan can answer for a window starting at `start`. A scan
    /// that begins after the window did would silently under-count, which is
    /// worse than not answering.
    func covers(start: Int64) -> Bool { start >= fromMs }

    /// Half-open `[from, to)`, matching the FFI's own interval and
    /// `QuotaHistoryFold.rows`.
    ///
    /// It used to be `(from, to]`, which is wrong at both ends for what it is
    /// asked. An inferred window's `start` IS the timestamp of the first usage
    /// after the reset, so an exclusive start dropped the very message that
    /// established the window; and an inclusive end claimed a message landing
    /// exactly on a reset for the cycle it ends rather than the one it opens.
    func slice(from: Int64, to: Int64) -> [WindowMessage] {
        messages.filter { $0.timestamp >= from && $0.timestamp < to }
    }
}
