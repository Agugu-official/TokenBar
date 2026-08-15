import AppKit
import SwiftUI
import TokenBarCore

/// Card density: 'full' (with pace line) or 'classic' (compact), mirroring
/// LimitsLayout in settings.ts.
enum LimitsLayout: String, CaseIterable {
    case full, classic
}

/// OAuth quota cards per agent: usage-window bars with gauge colors, reset
/// text and a pace marker. Port of AgentLimitsCard.tsx. The pace mode, fill
/// direction and layout density read the same defaults the settings panel
/// (later phase) will edit.
struct AgentLimitsCard: View {
    /// Clients requested by the active tab.
    let clients: [String]
    let trace: [TraceBucket]
    let agentUsage: AgentUsagePayload?
    /// Whether the first quota fetch has finished, successfully or not.
    ///
    /// `agentUsage == nil` cannot tell "the first attempt is still in flight"
    /// from "the attempt finished and produced nothing", and the empty copy
    /// below asserts the second. Restoring a dashboard from disk makes that
    /// distinction visible: quota is deliberately never persisted (it carries
    /// account identity), so the graph renders instantly while these cards wait
    /// on their own poller. Defaults to true so call sites that always have a
    /// settled answer stay unchanged.
    var usageAttempted = true
    var title = "Agent limits"
    var note = "OAuth quota"
    /// When true, show only the passed `clients` (single-client view) instead
    /// of unioning in every agent that has a quota snapshot.
    var restrict = false
    /// When true, cards can be reordered by dragging their grip handle; the
    /// order persists to UserDefaults. Only the multi-agent overview opts in.
    var reorderable = false
    /// Quota readings per `"<clientId>|<cardId>"`. Present only on the
    /// multi-agent overview; a single-client tab passes nothing, because the
    /// full window card sits directly above this one there and a second, smaller
    /// drawing of the same series reads as a thumbnail of the card above it.
    var curves: [String: [QuotaSample]] = [:]

    /// Bar fills by used (true) or remaining (false).
    @AppStorage("tokenbar.limits.asUsed") private var asUsed = false
    @AppStorage("tokenbar.limits.paceMode") private var paceModeRaw = PaceMode.historical.rawValue
    @AppStorage("tokenbar.limits.layout") private var layoutRaw = LimitsLayout.full.rawValue
    /// Saved drag order (shared with the "Client tabs (top bar)" order in Settings).
    /// Reordering providers in Settings → Client tabs now also reorders the
    /// quota cards shown in Overview → Agent limits (and vice-versa via drag).
    @AppStorage(ClientRegistry.tabOrderKey) private var orderRaw = ""
    /// Per-client Agent-limits visibility, independent of tab visibility.
    @AppStorage(ClientRegistry.limitsHiddenKey) private var limitsHiddenRaw = ""

    @State private var dragId: String?
    @State private var overId: String?
    @State private var cardFrames: [String: CGRect] = [:]

    private var paceMode: PaceMode { PaceMode(rawValue: paceModeRaw) ?? .historical }
    private var classic: Bool { LimitsLayout(rawValue: layoutRaw) ?? .full == .classic }
    private var metric: QuotaMetric { asUsed ? .used : .remaining }

    /// Sparkline dimensions. Named because these are the numbers that get tuned
    /// against the running app, and a named constant makes the next adjustment
    /// one line instead of a hunt through a draw call.
    private enum Spark {
        /// Tall enough to read a slope; short enough that five agents with two
        /// windows each still fit the popover. The bar it replaces was 6.
        static let height: CGFloat = 26
        /// Keeps a line pinned at 0% or 100% from being clipped by the frame.
        static let inset: CGFloat = 2
        /// Thinner than the detail card's 1.8: this one is a glance, not a
        /// reading surface.
        static let lineWidth: CGFloat = 1.4
        /// Dashed so the expected line reads as a prediction rather than a
        /// second measurement.
        static let paceWidth: CGFloat = 1
        static let paceDash: [CGFloat] = [3, 2]
        /// Tint under the curve.
        ///
        /// Load-bearing, not decoration. Measured 2026-08-16 on live data: over
        /// a fixed 0...100 axis 26px tall, two of four eligible windows moved
        /// 2.6px and 2.9px — flat lines, indistinguishable from each other and
        /// from an untouched window. Height alone cannot carry the reading at
        /// this size, and rescaling the axis to fit would make 7% used and 63%
        /// used look identical, which is the thing the fixed axis exists to
        /// prevent. Area carries it instead: the axis stays honest and the fill
        /// reads at a glance. Raise the alpha before raising `height` — rows
        /// multiply, and ten of them do not fit the popover.
        static let fillOpacity: Double = 0.22
    }

    /// Whether a row can draw a line instead of a bar, and over what interval.
    ///
    /// Pure and static so the rule is assertable: this is the single place that
    /// decides which of the two drawings the user sees. Two readings must fall
    /// INSIDE the drawn interval, not merely exist on file — a series whose
    /// points all predate this window would otherwise draw a flat line at
    /// whatever the last one said, which is a confident lie about a window
    /// nobody has sampled yet.
    static func sparklineInterval(
        window: UsageWindow, samples: [QuotaSample], nowMs: Int64
    ) -> (start: Int64, end: Int64)? {
        guard let interval = WindowCardLoader.interval(
            WindowCardLoader.resolution(
                window: window, nowMs: nowMs, firstUsageAfterReset: nil))
        else { return nil }
        let inside = samples.filter { $0.atMs >= interval.start && $0.atMs <= nowMs }
        return inside.count >= 2 ? interval : nil
    }

    /// Pure state presentation shared by every AgentLimitsCard consumer.
    enum PacePresentation {
        static var learningHistoryText: String { "Learning history · Linear estimate".localized }
        static var learningDurationText: String { "Learning reset duration".localized }
        static var linearText: String { "Linear".localized }
        static var legacyText: String { "Pace unavailable · legacy data".localized }

        static func statusText(
            state: UsagePaceState,
            reason: UsagePaceUnavailableReason?,
            mode: PaceMode
        ) -> String? {
            guard mode != .off else { return nil }
            switch state {
            case .learningHistory:
                return mode == .historical ? learningHistoryText : linearText
            case .learningDuration:
                return learningDurationText
            case .available:
                return mode == .linear ? linearText : nil
            case .unavailable:
                return unavailableText(reason)
            case .legacyMissing:
                return legacyText
            }
        }

        static func unavailableText(_ reason: UsagePaceUnavailableReason?) -> String {
            guard let reason else { return "Pace unavailable · unavailable reason".localized }
            switch reason {
            case .windowIdentity:
                return "Pace unavailable · unknown quota window".localized
            case .missingReset:
                return "Pace unavailable · missing reset".localized
            case .invalidEvidence:
                return "Pace unavailable · invalid quota data".localized
            case .accountScope:
                return "Pace unavailable · account identity unavailable".localized
            case .storeCapacity:
                return "Pace unavailable · history storage full".localized
            case .history:
                return "Pace unavailable · history unavailable".localized
            case .nonRecurring:
                return "Pace unavailable · non-recurring quota".localized
            }
        }

        /// Warning color follows codexbar: the marker is tinted when actual
        /// usage has passed the expected line, whichever estimator drew that
        /// line. Keying it to the basis instead made the warning blink out
        /// whenever the Historical fit failed to re-qualify — `available` is
        /// re-decided on every refresh by an out-of-sample fit gate, so a card
        /// oscillates between Historical and `learningHistory` while the deficit
        /// underneath never moves. The status text still names the basis, so a
        /// Linear estimate stays identifiable without the color flickering.
        static func isDeficit(_ pace: UsagePace?) -> Bool {
            pace?.stage.isDeficit == true
        }
    }

    /// Placeholder window labels for agents we know carry quotas but have no
    /// snapshot yet (LIMIT_ROWS in the web card).
    private static let placeholderRows: [String: [String]] = [
        "codex": ["Session", "Weekly"],
        "claude": ["Session", "Weekly"],
        "gemini": ["Pro", "Flash"],
        "grok": ["Weekly"],
    ]

    /// Every client id that can show a row in the multi-agent Agent-limits
    /// card. Thin wrapper over `ClientRegistry.knownLimitsClients` (the one
    /// implementation) that supplies this card's placeholder-row keys, so the
    /// registry-level lists and the card agree on the universe.
    static func knownClientIds(agentUsage: AgentUsagePayload?, present: [String]) -> [String] {
        ClientRegistry.knownLimitsClients(
            present: present,
            quotaIds: (agentUsage?.agents ?? []).map(\.clientId),
            placeholders: Set(placeholderRows.keys))
    }

    private var snapshots: [String: AgentUsageSnapshot] {
        var dict = Dictionary(
            (agentUsage?.agents ?? []).map { ($0.clientId, $0) },
            uniquingKeysWith: { first, _ in first })
        // Antigravity CLI shares the Antigravity IDE's account and quota, so it
        // gets no snapshot of its own. In its single-client view, surface the
        // Antigravity snapshot under its id so the card still shows the quota.
        // Only in `restrict` mode — the overview already renders Antigravity's
        // own card, so aliasing there would duplicate it.
        if restrict, dict["antigravity-cli"] == nil, let shared = dict["antigravity"] {
            dict["antigravity-cli"] = shared
        }
        return dict
    }

    /// Clients whose live tail shows activity right now.
    private var liveClients: Set<String> {
        Set(
            trace.filter { $0.tokensPerMin > 0 }
                .map { Self.normalizeTraceClient($0.client) })
    }

    private var opencodeSubs: [String] { agentUsage?.opencodeSubscriptions ?? [] }

    /// opencode is a router with no quota of its own; its client view instead
    /// shows the cards of the subscriptions it's authed against.
    private var opencodeView: Bool { restrict && clients.contains("opencode") }

    private var baseClients: [String] {
        let snapshots = self.snapshots
        if opencodeView {
            return opencodeSubs
                // The subscription-owner resolution, not the raw label mapper:
                // `Xai` maps to `xai` there, while the quota snapshot is keyed
                // `grok`, so the filter below would drop the very card opencode
                // is authed against.
                .compactMap(UsageAttributionSettings.subscriptionClient(forLabel:))
                .filter { snapshots[$0] != nil }
        }
        func known(_ id: String) -> Bool {
            Self.placeholderRows[id] != nil || snapshots[id] != nil
        }
        if restrict { return clients.filter(known) }
        var seen = Set<String>()
        var base = (clients.filter(known) + (agentUsage?.agents.map(\.clientId) ?? []))
            .filter { seen.insert($0).inserted }

        // Apply the same hide logic as Client tabs, plus the independent
        // per-client Agent-limits toggle: either one keeps a client out of
        // the multi-agent limits card.
        if reorderable {
            let limitsHidden = ClientRegistry.parseIdSet(limitsHiddenRaw)
            let hidden = ClientRegistry.hiddenClients().union(limitsHidden)
            base = base.filter { !hidden.contains($0) }
        }
        return base
    }

    /// Saved drag order applied; ids without a saved position keep their
    /// natural order at the end. Disabled in non-reorderable views. Reads the
    /// observed `orderRaw` so a drag re-sorts the cards reactively.
    private var visibleClients: [String] {
        reorderable ? ClientRegistry.orderedClients(baseClients, orderRaw: orderRaw) : baseClients
    }

    // The master `tokenbar.limits.enabled` gate lives at every call site
    // (OverviewView, SettingsWindowView) rather than inside `body`, so an
    // "off" card leaves no structural gap in its parent VStack.
    var body: some View {
        DashCard(title, trailing: { noteLabel }) {
            if opencodeView {
                integrationLine("↔ Routes through opencode")
            } else if !restrict && !opencodeSubs.isEmpty {
                integrationLine(
                    "opencode also taps: %@".localized(
                        opencodeSubs.joined(separator: " · ")))
            }
            let visible = visibleClients
            if visible.isEmpty, !usageAttempted {
                // Say "still asking" rather than "none": claiming no supported
                // agents while the first request is outstanding is a false
                // answer, not an empty one.
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking agent limits…".localized)
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
            } else if visible.isEmpty {
                Text(
                    opencodeView && !opencodeSubs.isEmpty
                        ? "Subscriptions: %@".localized(
                            opencodeSubs.joined(separator: " · "))
                        : "No supported agents yet".localized
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 12) {
                    ForEach(visible, id: \.self) { id in
                        agentSection(id, visible: visible)
                    }
                }
                .coordinateSpace(name: Self.dragSpace)
                .onPreferenceChange(CardFramesKey.self) { cardFrames = $0 }
            }
        }
    }

    private var noteLabel: some View {
        Text(note.localized)
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    private func integrationLine(_ text: String) -> some View {
        Text(text.localized)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    // MARK: - Drag reorder

    private static let dragSpace = "limits-cards"

    private struct CardFramesKey: PreferenceKey {
        static let defaultValue: [String: CGRect] = [:]
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { $1 })
        }
    }

    /// Move `from` to the `to` card's slot, direction-aware. Delegates to the
    /// single `ClientRegistry.reorder` implementation (SelfTest asserts against
    /// this symbol; keeping the wrapper keeps those checks addressing the card).
    static func reorder(_ list: [String], from: String, to: String) -> [String] {
        ClientRegistry.reorder(list, from: from, to: to)
    }

    /// Which edge of a card the drop line sits on, matching the
    /// direction-aware insert.
    private func dropEdge(_ id: String, in visible: [String]) -> VerticalEdge? {
        guard let dragId, overId == id, dragId != id,
              let fromI = visible.firstIndex(of: dragId), let toI = visible.firstIndex(of: id)
        else { return nil }
        return fromI < toI ? .bottom : .top
    }

    private func dragGesture(for id: String, visible: [String]) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.dragSpace))
            .onChanged { value in
                dragId = id
                let over = cardFrames.first { $0.value.contains(value.location) }?.key
                overId = (over != nil && over != id) ? over : nil
            }
            .onEnded { _ in
                if let over = overId, over != id {
                    // `visible` is a subset of the shared tab order (it excludes
                    // hidden and non-quota clients). Merge the reordered subset
                    // back into the full saved order so off-screen ids keep
                    // their slots instead of being dropped from the key.
                    let full = ClientRegistry.parseIdList(orderRaw)
                    let merged = ClientRegistry.mergeReorder(
                        full: full, visible: visible, from: id, to: over)
                    orderRaw = merged.joined(separator: ",")
                }
                dragId = nil
                overId = nil
            }
    }

    // MARK: - Per-agent section

    @ViewBuilder private func agentSection(_ id: String, visible: [String]) -> some View {
        let style = ClientRegistry.style(id)
        let snapshot = snapshots[id]
        let uniqueWindows = snapshot?.uniqueCardWindows ?? []
        let isLive = liveClients.contains(id)
        let edge = dropEdge(id, in: visible)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if reorderable {
                    Text("⠿")
                        .font(.caption)
                        .foregroundStyle(dragId == id ? .primary : .tertiary)
                        .help("Drag to reorder")
                        .gesture(dragGesture(for: id, visible: visible))
                }
                AgentIconView(clientId: id, size: 14)
                Text(style.displayName)
                    .font(.caption.weight(.semibold))
                Spacer()
                statusBadge(snapshot: snapshot, isLive: isLive)
            }
            if snapshot?.source == "unconfigured" {
                setupPrompt()
            } else {
                if let detail = detailText(snapshot) {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(snapshot?.error != nil ? .red : .secondary)
                        .lineLimit(2)
                        .help(snapshot?.error ?? detail)
                }
                VStack(spacing: 8) {
                    if !uniqueWindows.isEmpty {
                        ForEach(uniqueWindows, id: \.cardId) { window in
                            windowRow(window, clientId: id, brand: style.color)
                                .id("\(id):\(window.cardId)")
                        }
                    } else {
                        ForEach(Self.placeholderRows[id] ?? ["Limit"], id: \.self) { label in
                            placeholderRow(label, brand: style.color)
                        }
                    }
                }
            }
        }
        .opacity(dragId == id ? 0.5 : 1)
        .overlay(alignment: edge == .top ? .top : .bottom) {
            if edge != nil {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .offset(y: edge == .top ? -6 : 6)
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: CardFramesKey.self,
                    value: [id: geo.frame(in: .named(Self.dragSpace))])
            })
    }

    /// Keychain command that hands TokenBar a Claude setup-token when the
    /// automatic shell/env detection can't reach it (e.g. a plain `~/.zshrc`
    /// export a Finder-launched app never inherits).
    // `-U` updates the item if it already exists (so re-pasting after a wrong
    // token, or rotating the token, works instead of failing). `-w` is given last
    // with no value on purpose: `security(1)` then prompts for the token
    // interactively, so it never lands in shell history or process args.
    private static let claudeSetupCommand =
        #"security add-generic-password -U -a "$USER" -s tokenbar-claude-oauth-token -w"#

    /// Setup prompt shown for Claude when no credential is configured at all
    /// (source "unconfigured"), instead of a red "credentials not found" error.
    @ViewBuilder private func setupPrompt() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Using a Claude `setup-token`? TokenBar auto-detects `CLAUDE_CODE_OAUTH_TOKEN` from your login shell. If limits don't appear, store the token in Keychain — run this, then paste the token at the prompt:")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 6) {
                Text(Self.claudeSetupCommand)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.claudeSetupCommand, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("Copy command")
            }
        }
    }

    private func statusBadge(snapshot: AgentUsageSnapshot?, isLive: Bool) -> some View {
        let text: String
        var color: Color = .secondary
        if snapshot?.source == "unconfigured" {
            // Not set up yet -- neutral prompt, not an alarming red error.
            text = "Set up".localized
        } else if snapshot?.error != nil {
            text = "Error".localized
            color = .red
        } else if let snapshot, !snapshot.uniqueCardWindows.isEmpty {
            // Backend-reported source ("oauth", "api", …) — data, not copy.
            text = snapshot.source.uppercased()
        } else if isLive {
            text = "Live".localized
            color = .green
        } else {
            text = "No quota".localized
        }
        return Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
    }

    private func detailText(_ snapshot: AgentUsageSnapshot?) -> String? {
        guard let snapshot else { return nil }
        if let error = snapshot.error { return error }
        let parts = [snapshot.identity?.email, snapshot.identity?.plan].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Window rows

    /// A quota bar reads green when healthy, ambers under 25% left and reds
    /// under 10% (tokscale/codexbar Usage view). No quota signal → brand color.
    private func gaugeColor(remaining: Double?, brand: String) -> Color {
        guard let remaining else { return Color(hex: brand) }
        if remaining <= 10 { return Color(red: 0.937, green: 0.267, blue: 0.267) }
        if remaining <= 25 { return Color(red: 0.961, green: 0.620, blue: 0.043) }
        return Color(red: 0.133, green: 0.773, blue: 0.369)
    }

    @ViewBuilder private func windowRow(
        _ window: UsageWindow, clientId: String, brand: String
    ) -> some View {
        let remaining = min(100, max(0, window.remainingPercent))
        let used = min(100, max(0, window.usedPercent))
        // Pace is suppressed entirely in the classic layout and when the user
        // turns it off; otherwise it follows the chosen mode.
        let pace = classic ? nil : UsagePace.compute(window: window, mode: paceMode)
        // The bar fills by used (counting up) or remaining (counting down)
        // per the setting; the pace marker sits on the same axis so it lines
        // up with the fill either way.
        let fill = asUsed ? used : remaining
        let leftLabel = asUsed
            ? "%lld%% used".localized(Int(used.rounded()))
            : "%lld%% left".localized(Int(remaining.rounded()))
        // `resetText` is a compatibility field produced in English by Rust.
        // Derive the visible countdown from the structured timestamp so the
        // quota card follows the selected UI language; non-countdown metadata
        // (for example a monthly cap) keeps its provider text.
        let resetText = window.resetsAt.flatMap { UsagePace.resetText(for: $0) }
            ?? window.resetText
        let gauge = gaugeColor(remaining: remaining, brand: brand)

        if classic {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    // Display only — the payload's `label` stays untranslated
                    // so QuotaResolver's legacy-selection matching still works.
                    Text(window.label.localized)
                        .font(.caption2.weight(.medium))
                    Spacer()
                    Text(resetText ?? leftLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                bar(fillPercent: fill, color: gauge, paceLeft: nil, paceIsDeficit: false)
                if resetText != nil {
                    Text(leftLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    // Display only — the payload's `label` stays untranslated
                    // so QuotaResolver's legacy-selection matching still works.
                    Text(window.label.localized)
                        .font(.caption2.weight(.medium))
                    Spacer()
                    if let reset = resetText {
                        Text(reset)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                // The line replaces the bar only where it has something to draw
                // and somewhere to draw it. A single-client tab passes no
                // curves, so it keeps the bar and does not repeat the full card
                // sitting directly above it.
                let samples = curves["\(clientId)|\(window.cardId)"] ?? []
                if let interval = Self.sparklineInterval(
                    window: window, samples: samples,
                    nowMs: Int64(Date().timeIntervalSince1970 * 1000))
                {
                    sparkline(samples: samples, interval: interval, color: gauge, pace: pace)
                } else {
                    bar(
                        fillPercent: fill, color: gauge,
                        paceLeft: pace.map {
                            let left = asUsed ? $0.expectedUsedPercent : 100 - $0.expectedUsedPercent
                            return min(100, max(0, left))
                        },
                        paceIsDeficit: Self.PacePresentation.isDeficit(pace))
                }
                paceFooter(window: window, leftLabel: leftLabel, pace: pace)
            }
        }
    }

    @ViewBuilder private func paceFooter(
        window: UsageWindow, leftLabel: String, pace: UsagePace?
    ) -> some View {
        let status = Self.PacePresentation.statusText(
            state: window.paceStatus.state,
            reason: window.paceStatus.reason,
            mode: paceMode)
        // Historical ETA/lasts and risk are composed together so a visible
        // risk suppresses the generic "Lasts until reset" phrase when the
        // backend reports both.
        let projection = pace.map {
            UsagePace.presentation(window: window, mode: paceMode, pace: $0)
        }
        let projectionText = [projection?.etaText, projection?.riskText]
            .compactMap(\.self).joined(separator: " · ")
        let paceText = [status, pace?.label]
            .compactMap(\.self).joined(separator: " · ")

        if paceText.isEmpty {
            paceLeftLabel(leftLabel)
        } else if projectionText.isEmpty {
            HStack(spacing: 8) {
                paceLeftLabel(leftLabel)
                Spacer(minLength: 8)
                paceTextLabel(paceText, pace: pace)
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    paceLeftLabel(leftLabel)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 8)
                    paceTextLabel("\(paceText) · \(projectionText)", pace: pace)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                VStack(alignment: .trailing, spacing: 1) {
                    HStack(spacing: 8) {
                        paceLeftLabel(leftLabel)
                        Spacer(minLength: 8)
                        paceTextLabel(paceText, pace: pace)
                    }
                    paceTextLabel(projectionText, pace: pace)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func paceLeftLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private func paceTextLabel(_ text: String, pace: UsagePace?) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(
                Self.PacePresentation.isDeficit(pace)
                    ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
    }

    /// What a row with no quota value should say.
    ///
    /// "No data" asserts the provider was asked and had nothing. Before the
    /// first fetch settles that is a false answer: the client list comes from
    /// the graph payload, which a disk restore brings back instantly, so every
    /// row renders while quota is still outstanding. Quota is deliberately
    /// never persisted, so this window exists on every relaunch.
    private var placeholderValueLabel: String {
        usageAttempted ? "No data".localized : "Checking…".localized
    }

    private func placeholderRow(_ label: String, brand: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label.localized)
                    .font(.caption2.weight(.medium))
                Spacer()
                if classic {
                    Text(placeholderValueLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            bar(fillPercent: 0, color: Color(hex: brand), paceLeft: nil, paceIsDeficit: false)
            if !classic {
                Text(placeholderValueLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// The quota over the window's own time axis, with the pace estimate as a
    /// second line rather than a marker.
    ///
    /// Pace means "at this rate you should have used X% by now", which is a rate
    /// over time. On a bar there is no time axis, so it can only collapse to a
    /// point; here it is the straight line from the window's start to that
    /// value at `now`. Straight because a single expected percentage is all
    /// `UsagePace` exposes — this draws the number the bar's marker already
    /// carried, on an axis that can show it.
    ///
    /// y is fixed 0...100 and never rescaled to the data, for the same reason
    /// the detail card fixes it: autoscaling makes 7% used and 63% used look
    /// identical, which is the one comparison these rows exist to support.
    private func sparkline(
        samples: [QuotaSample], interval: (start: Int64, end: Int64),
        color: Color, pace: UsagePace?
    ) -> some View {
        let nowMs = min(Int64(Date().timeIntervalSince1970 * 1000), interval.end)
        let geo = WindowCardGeometry.quotaGeometry(
            windowStartMs: interval.start, windowEndMs: interval.end,
            nowMs: nowMs, samples: samples, metric: metric)
        let deficit = Self.PacePresentation.isDeficit(pace)
        return Canvas { ctx, size in
            func at(_ p: CurvePoint) -> CGPoint {
                CGPoint(
                    x: p.x * size.width,
                    y: Spark.inset + (1 - p.y / 100) * (size.height - Spark.inset * 2))
            }
            if let pace {
                var expected = Path()
                expected.move(to: at(CurvePoint(x: 0, y: metric.value(fromUsedPercent: 0))))
                expected.addLine(to: at(CurvePoint(
                    x: geo.nowX,
                    y: metric.value(fromUsedPercent: min(100, max(0, pace.expectedUsedPercent))))))
                ctx.stroke(
                    expected,
                    with: .color(deficit ? .orange : .secondary.opacity(0.55)),
                    style: StrokeStyle(lineWidth: Spark.paceWidth, dash: Spark.paceDash))
            }
            guard geo.curve.count > 1 else { return }
            var line = Path()
            for (i, p) in geo.curve.enumerated() {
                i == 0 ? line.move(to: at(p)) : line.addLine(to: at(p))
            }
            // Area first, line on top. The fill is what makes a 12-point move
            // legible at this height — see `Spark.fillOpacity`.
            var area = line
            let floorY = at(CurvePoint(x: 0, y: 0)).y
            if let last = geo.curve.last, let first = geo.curve.first {
                area.addLine(to: CGPoint(x: at(last).x, y: floorY))
                area.addLine(to: CGPoint(x: at(first).x, y: floorY))
                area.closeSubpath()
                ctx.fill(area, with: .color(color.opacity(Spark.fillOpacity)))
            }
            ctx.stroke(
                line, with: .color(color),
                style: StrokeStyle(
                    lineWidth: Spark.lineWidth, lineCap: .round, lineJoin: .round))
        }
        .frame(height: Spark.height)
    }

    private func bar(
        fillPercent: Double, color: Color, paceLeft: Double?, paceIsDeficit: Bool
    ) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary.opacity(0.6))
                    .frame(height: geo.size.height)
                Capsule()
                    .fill(color.opacity(0.85))
                    .frame(
                        width: geo.size.width * fillPercent / 100,
                        height: geo.size.height)
                if let paceLeft {
                    RoundedRectangle(cornerRadius: 0.75)
                        .fill(paceIsDeficit ? Color.orange : Color.secondary)
                        .frame(width: 1.5, height: geo.size.height + 4)
                        .offset(x: geo.size.width * paceLeft / 100 - 0.75)
                        .help("Expected \(Int((asUsed ? paceLeft : 100 - paceLeft).rounded()))% used by now")
                }
            }
        }
        .frame(height: 6)
    }

    /// The live tail reports raw client ids; quota snapshots use short ids.
    /// Layers this card's deliberate quota-attribution fold on top of the shared
    /// explicit aliases: after the registry's exact mappings, a generic `-cli`
    /// strip folds CLI variants onto their base client so e.g. `antigravity-cli`
    /// shares the `antigravity` quota snapshot. This generic fold is intentional
    /// HERE (quota grouping) and must NOT leak into the hidden-set deny-filters,
    /// which need `antigravity-cli` kept distinct — hence it lives in the card,
    /// not in `ClientRegistry.canonicalClient`.
    static func normalizeTraceClient(_ id: String) -> String {
        let canonical = ClientRegistry.canonicalClient(id)
        guard canonical == id else { return canonical } // an explicit alias applied
        return id.hasSuffix("-cli") ? String(id.dropLast(4)) : id
    }
}
