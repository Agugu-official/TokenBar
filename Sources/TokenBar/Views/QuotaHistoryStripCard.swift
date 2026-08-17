import SwiftUI
import TokenBarCore

/// Every window's recorded cycles as a strip, so the current one can be read
/// against the ones before it.
///
/// The bars are on a fixed 0...100 with the ceiling drawn, which is what makes
/// the honest headline possible: on this data the tallest bar in eighteen
/// recorded sessions is 58%, and the ceiling has never been reached. A gauge
/// showing "79% left" says the same thing far less usefully, because it cannot
/// say whether 79% is normal.
struct QuotaHistoryStripCard: View {
    let summaries: [QuotaWindowSummary]
    /// Per-window equivalence, keyed as the summary's `id`. Absent means either
    /// the window cannot support an estimate or the scan has not landed — the
    /// strip above never waits on it either way.
    var equivalences: [String: WindowEquivalence.Row] = [:]
    var attempted = true

    private static let stripHeight: CGFloat = 26
    private static let barGap: CGFloat = 1.5
    /// A recorded cycle always draws something. A cycle that consumed 1% is not
    /// the same as one that was never recorded, and a bar rounding to zero
    /// height would make them identical.
    private static let minimumInk: CGFloat = 1

    var body: some View {
        DashCard("Past windows", subtitle: subtitle) {
            if !summaries.isEmpty {
                VStack(spacing: 10) {
                    ForEach(summaries) { summary in
                        row(summary)
                    }
                }
            } else if attempted {
                Text("No completed windows recorded yet. They accumulate as TokenBar runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LoadingLine(title: "Reading quota history…")
            }
        }
    }

    private var subtitle: String? {
        guard !summaries.isEmpty else { return nil }
        return summaries.allSatisfy(\.neverExhausted) ? "never exhausted".localized : nil
    }

    @ViewBuilder
    private func row(_ summary: QuotaWindowSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                AgentIconView(clientId: summary.clientId, size: 11)
                Text(verbatim: "\(ClientRegistry.style(summary.clientId).displayName) · "
                     + summary.windowLabel.localized)
                    .font(.caption2)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("%@ windows".localized(String(summary.cycleCount)))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            strip(summary)
            Text(headline(summary))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            if let row = equivalences[summary.id] {
                Text(WindowEquivalence.text(
                    row, tokens: Format.compactTokens, money: Format.usd))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Fixed 0...100 with the ceiling drawn as a dotted rule. Rescaling to the
    /// tallest bar would make a run of 2% cycles look like a run of 60% ones,
    /// which is the one comparison this strip exists to support.
    private func strip(_ summary: QuotaWindowSummary) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let count = max(summary.recent.count, 1)
            let barWidth = max(
                1, (width - CGFloat(count - 1) * Self.barGap) / CGFloat(count))
            Canvas { context, size in
                var ceiling = Path()
                ceiling.move(to: CGPoint(x: 0, y: 0.5))
                ceiling.addLine(to: CGPoint(x: size.width, y: 0.5))
                context.stroke(
                    ceiling, with: .color(.secondary.opacity(0.35)),
                    style: StrokeStyle(lineWidth: 1, dash: [2, 3]))

                for (index, value) in summary.recent.enumerated() {
                    let height = max(
                        Self.minimumInk, size.height * CGFloat(min(1, value / 100)))
                    let isLatest = index == summary.recent.count - 1
                    context.fill(
                        Path(CGRect(
                            x: CGFloat(index) * (barWidth + Self.barGap),
                            y: size.height - height,
                            width: barWidth, height: height)),
                        // The newest cycle is the one being asked about; the
                        // rest are context, so they recede.
                        with: .color(.accentColor.opacity(isLatest ? 0.9 : 0.35)))
                }
            }
        }
        .frame(height: Self.stripHeight)
    }

    private func headline(_ summary: QuotaWindowSummary) -> String {
        let peak = String(Int(summary.peakPercent.rounded()))
        return summary.neverExhausted
            ? "Heaviest %@%% · never ran out".localized(peak)
            : "Heaviest %@%% · ran out at least once".localized(peak)
    }
}
