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

    @State private var expanded: Int64?

    /// Below this the cycle was barely witnessed and its consumption figure is
    /// not evidence about the window — the app simply was not running for most
    /// of it. Shown, but marked.
    private static let thinObservation = 0.5
    private static let barWidth: CGFloat = 54
    private static let barHeight: CGFloat = 5
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
                quotaBar(cycle)
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

    /// Fixed 0...100, matching the window card: the whole point of a history is
    /// comparing cycles to each other and to the ceiling, and a bar rescaled to
    /// the largest row would make a 3% window and a 58% one look alike.
    private func quotaBar(_ cycle: QuotaCycle) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary.opacity(0.6))
            Capsule()
                .fill(Color.accentColor.opacity(
                    cycle.observedFraction < Self.thinObservation ? 0.35 : 0.85))
                .frame(width: Self.barWidth * min(1, cycle.usedPercent / 100))
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
