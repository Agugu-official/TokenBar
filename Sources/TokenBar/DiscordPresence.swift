import Foundation
import TokenBarCore

/// Pure payload construction for the (opt-in, default-off) Discord Rich
/// Presence feature. Deliberately UI-free and lifecycle-free: `SelfTest.run()`
/// returns `Never` before `NSApplication.shared` exists, so anything the
/// privacy assertions must cover has to be reachable without an `AppDelegate`.
///
/// Nothing here opens a socket, touches the network, reads `UserDefaults`, or
/// performs file I/O — the transport and the opt-in switch land separately.
/// `hidden` is a parameter, not a lookup, for the same reason.
enum DiscordPresence {
    /// Everything, and only what, would be published to a third party and shown
    /// on a public profile.
    struct Payload: Equatable {
        let details: String
        let state: String
        let largeImageKey: String

        /// **The published surface.** The transport must serialize this
        /// dictionary and nothing else — no field assembled at the transport
        /// layer, no property of this struct that is not in here.
        ///
        /// It is a dictionary rather than a list of values so that one
        /// assertion can pin the key set, and the same assertion is what the
        /// privacy value-scans read. An earlier revision kept a separate
        /// `allFields: [String]` for the scans and reflected over the stored
        /// properties for the key check; that made the published surface and
        /// the asserted surface two different things, and regressions escaped
        /// through the gap in both directions (a computed property is invisible
        /// to `Mirror`; a shrunk list silently narrows every scan). Keep them
        /// one thing.
        var fields: [String: String] {
            ["details": details, "state": state, "largeImageKey": largeImageKey]
        }
    }

    /// Shown instead of an unregistered client id.
    static let neutralClientLabel = "an AI tool"
    static let largeImageKey = "tokenbar"

    /// Fixed allowlist: a registered id gets its registry display name, anything
    /// else gets the neutral constant.
    ///
    /// The gate is the point. A graph client id can be `cc-mirror/<name>` where
    /// `<name>` comes straight out of a user's local config file and is only
    /// character-filtered, never semantically constrained
    /// (vendor/tokscale-core/src/sessions/claudecode.rs:60-62). Falling through
    /// to `ClientRegistry.style(id)` would title-case that string and publish an
    /// employer or internal-tool name on a public Discord profile. Gating first
    /// means `style()`'s title-case fallback branch is unreachable from here.
    static func safeClientLabel(_ id: String?) -> String {
        guard let id, ClientRegistry.allIds.contains(id) else { return neutralClientLabel }
        return ClientRegistry.style(id).displayName
    }

    /// Coarse cost band rather than `$%.2f`: the cost ÷ tokens ratio leaks the
    /// model tier and cache structure in use, and accumulated daily costs leak a
    /// monthly spend bracket.
    ///
    /// Finite input only. A NaN matches no range and falls through to `$100+`,
    /// which is why `payload(...)` rejects a non-finite cost before it ever gets
    /// here — keep that guard if you add a second call site.
    static func costBucket(_ cost: Double) -> String {
        switch cost {
        case ..<1: return "<$1"
        case ..<5: return "$1-5"
        case ..<10: return "$5-10"
        case ..<25: return "$10-25"
        case ..<50: return "$25-50"
        case ..<100: return "$50-100"
        default: return "$100+"
        }
    }

    /// Coarse token band. `Format.compactTokens` is the shared tray-title
    /// formatter and returns the exact `Int64` below 1000 (`Format.swift:19`),
    /// which is correct in the menu bar and wrong here: the published figure
    /// must never be an exact count. A negative total lands here too — the
    /// aggregator's per-lane clamping admits pathological negative deltas
    /// (see `trayTotals`' doc comment), and `String(count)` would publish the
    /// full signed digits.
    ///
    /// Do not "fix" this by changing `Format.compactTokens`; the tray title
    /// wants the exact small number.
    static func tokenBand(_ tokens: Int64) -> String {
        tokens < 1_000 ? "<1K" : Format.compactTokens(tokens)
    }

    /// The publishable payload for `today`, or nil when nothing may be
    /// published. `hidden` must be the tab-hidden set (`ClientRegistry
    /// .hiddenClients()` at the call site) — `trayTotals` applies it to the same
    /// stripes the top client is folded from.
    static func payload(graph: UsagePayload, hidden: Set<String>, today: String) -> Payload? {
        let totals = graph.trayTotals(hidden: hidden, today: today)
        // Non-finite numbers must never be published — garbage on a public
        // profile is worse than no presence at all.
        guard totals.todayCost.isFinite else { return nil }
        // Zero usage would otherwise publish a "this machine is switched on"
        // beacon. Nothing is published, and no startTimestamp is ever emitted.
        // `||`, not `&&`: UsageStats allows a day with cost > 0 and tokens == 0.
        guard totals.todayTokens > 0 || totals.todayCost > 0 else { return nil }
        return Payload(
            details: "\(tokenBand(totals.todayTokens)) tokens today",
            state: "\(safeClientLabel(totals.todayTopClient)) · \(costBucket(totals.todayCost))",
            largeImageKey: largeImageKey)
    }
}
