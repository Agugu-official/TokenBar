import SwiftUI
import TokenBarCore

/// The windows before this one: how much allowance each consumed, and what was
/// spent inside it.
///
/// Both halves are required. Measured on live data, a `claude/session.v1`
/// window moved 1% while 308M tokens and $535 of API-equivalent value were
/// recorded in the same five hours, almost all of it charged to a different
/// subscription. The quota column alone would say "a quiet window"; the spend
/// column alone would say "an expensive one". Neither is the answer.
struct QuotaHistoryCard: View {
    let clientId: String
    /// Newest first. Present as soon as the persisted curve is read, which is
    /// milliseconds — the rows render with their quota bars immediately.
    let cycles: [QuotaCycle]
    /// The join to local usage. Empty while the scan is out; a row then shows
    /// its quota and a placeholder where the numbers will land, rather than the
    /// whole card waiting.
    let rows: [QuotaHistoryRow]
    /// The app-wide model palette. Shared so a model is the same colour here as
    /// in the model breakdown and the usage chart.
    var colors: ModelColorMap = ModelColorMap(entries: [])

    @State private var expanded: Int64?

    /// Below this the cycle was barely witnessed and its consumption figure is
    /// not evidence about the window — the app simply was not running for most
    /// of it. Shown, but marked.
    private static let thinObservation = 0.5
    private static let barWidth: CGFloat = 62
    private static let barHeight: CGFloat = 4
    private static let barGap: CGFloat = 2
    /// Enough to read a trend without turning the lens into a scroll marathon.
    /// The engine retains 128 cycles, so this is a display choice, not a
    /// storage one — and one worth revisiting if anyone asks for more.
    private static let visibleRows = 12

    private var byCycle: [Int64: QuotaHistoryRow] {
        Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        DashCard("Window history", subtitle: subtitle) {
            if cycles.isEmpty {
                Text("No earlier windows recorded yet. They accumulate as TokenBar runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let joined = byCycle
                equivalence
                VStack(spacing: 0) {
                    ForEach(cycles.prefix(Self.visibleRows), id: \.resetAtMs) { cycle in
                        row(cycle, row: joined[cycle.resetAtMs])
                        if cycle.resetAtMs != cycles.prefix(Self.visibleRows).last?.resetAtMs {
                            Divider().opacity(0.4)
                        }
                    }
                }
                footnote
            }
        }
    }

    private var subtitle: String? {
        guard !cycles.isEmpty else { return nil }
        return "%@ windows".localized(String(min(cycles.count, Self.visibleRows)))
    }

    @ViewBuilder
    private func row(_ cycle: QuotaCycle, row: QuotaHistoryRow?) -> some View {
        let isOpen = expanded == cycle.resetAtMs
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 8)
                Text(Format.windowStamp(ms: cycle.startMs))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                bars(cycle, row: row)
                Text(verbatim: "\(Int(cycle.usedPercent.rounded()))%")
                    .font(.caption2.monospacedDigit())
                    .frame(width: 30, alignment: .trailing)
                Spacer(minLength: 4)
                if let row {
                    Text(Format.compactTokens(row.mineTokens))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(Format.usd(row.mineCost))
                        .font(.caption2.monospacedDigit())
                        .frame(width: 54, alignment: .trailing)
                } else {
                    Text(verbatim: "·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(width: 54, alignment: .trailing)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { expanded = isOpen ? nil : cycle.resetAtMs }
            if isOpen { detail(cycle, row: row) }
        }
        .padding(.vertical, 5)
    }

    /// Two bars, stacked and deliberately NOT sharing a scale.
    ///
    /// Quota and tokens are not proportional. Measured on live data, one window
    /// moved 1% of the allowance while carrying 18.0M attributed tokens and
    /// another moved 9% carrying 22.8M — a 5x difference in tokens per point.
    /// Putting them on one bar, or on one axis, would draw a relationship that
    /// is not there. Adjacent and separately scaled, the mismatch between the
    /// two lengths is legible instead of hidden, and that mismatch is the thing
    /// this card exists to expose.
    private func bars(_ cycle: QuotaCycle, row: QuotaHistoryRow?) -> some View {
        VStack(alignment: .leading, spacing: Self.barGap) {
            // Fixed 0...100, matching the window card: the point of a history is
            // comparing cycles to each other and to the ceiling, and rescaling
            // to the largest row would make a 3% window and a 58% one look
            // alike.
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary.opacity(0.6))
                Capsule()
                    .fill(Color.accentColor.opacity(
                        cycle.observedFraction < Self.thinObservation ? 0.35 : 0.85))
                    .frame(width: Self.barWidth * min(1, cycle.usedPercent / 100))
            }
            .frame(width: Self.barWidth, height: Self.barHeight)

            // Relative to the heaviest window on screen, segmented by model in
            // the app's shared palette. An empty strip is a real answer: this
            // window consumed allowance but nothing was declared as this
            // subscription's.
            usageBar(row)
        }
    }

    /// The largest attributed token count among the visible rows, and therefore
    /// the usage bar's full width. Nil when nothing has been scanned yet.
    private var usageScale: Int64? {
        let peak = rows.map(\.mineTokens).max() ?? 0
        return peak > 0 ? peak : nil
    }

    @ViewBuilder
    private func usageBar(_ row: QuotaHistoryRow?) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary.opacity(0.35))
            if let row, let scale = usageScale, row.mineTokens > 0 {
                let full = Self.barWidth * min(1, Double(row.mineTokens) / Double(scale))
                HStack(spacing: 0) {
                    ForEach(row.models) { model in
                        Rectangle()
                            .fill(Color(hex: colors.color(model.providerId, model.modelId)))
                            .frame(width: full * Double(model.tokens) / Double(row.mineTokens))
                    }
                }
                .frame(width: full, alignment: .leading)
                .clipShape(Capsule())
            }
        }
        .frame(width: Self.barWidth, height: Self.barHeight)
    }

    @ViewBuilder
    private func detail(_ cycle: QuotaCycle, row: QuotaHistoryRow?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // The full interval lives here rather than in the row: it is the
            // one place with room for it, and it is what a reader opens a row
            // to confirm.
            Text(Format.clockRange(fromMs: cycle.startMs, toMs: cycle.resetAtMs))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.tertiary)
            if cycle.observedFraction < Self.thinObservation {
                Text("TokenBar observed %@%% of this window, so its usage figure is a floor."
                    .localized(String(Int((cycle.observedFraction * 100).rounded()))))
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let row {
                ForEach(row.models.prefix(4)) { model in
                    HStack(spacing: 6) {
                        Text(model.modelId)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(Format.compactTokens(model.tokens))
                            .foregroundStyle(.secondary)
                        Text(Format.usd(model.cost))
                            .frame(width: 54, alignment: .trailing)
                    }
                    .font(.system(size: 10).monospacedDigit())
                }
                if row.models.isEmpty {
                    Text("Nothing in this window was charged to this subscription.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                // The line that explains a flat bar. Without it a 1% window
                // holding $535 of work looks like a quiet afternoon.
                if row.otherTokens > 0 {
                    Text("Other subscriptions in the same hours: %@ · %@".localized(
                        Format.compactTokens(row.otherTokens), Format.usd(row.otherCost)))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 1)
                }
            } else {
                LoadingLine(title: "Reading local usage…")
                    .scaleEffect(0.85, anchor: .leading)
            }
        }
        .padding(.leading, 16)
        .padding(.top, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What a tenth of this window's allowance has been worth, taken across
    /// every cycle on screen rather than one.
    ///
    /// Placed above the rows because it is the summary of them: a single row's
    /// ratio is dominated by the 1-point reading quantisation, and the whole
    /// reason to accumulate is that the individual figures cannot be trusted.
    @ViewBuilder
    private var equivalence: some View {
        let shown = Set(cycles.prefix(Self.visibleRows).map(\.resetAtMs))
        let counted = rows.filter { shown.contains($0.id) }
        if !counted.isEmpty {
            Text(WindowEquivalence.text(
                WindowEquivalence.aggregate(
                    sumDeltaPercent: counted.reduce(0) { $0 + $1.cycle.usedPercent },
                    cycleCount: counted.count,
                    tokens: counted.reduce(0) { $0 + $1.mineTokensExCacheRead },
                    cost: counted.reduce(0) { $0 + $1.mineCost }),
                tokens: Format.compactTokens, money: Format.usd))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 2)
        }
    }

    private var footnote: some View {
        Text("Amounts are API list-price equivalents for usage you declared as %@ — not what the subscription charged."
            .localized(ClientRegistry.style(clientId).displayName))
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }
}
