import SwiftUI
import TokenBarCore

/// Daily spend stacked by the subscription the user declared it against.
///
/// The existing usage chart buckets by CLIENT — which tool ran the work. On
/// this user's data the two answers invert: by client, `claude` carried $4,583
/// over a week and `codex` $510; by declaration it is `codex` $4,411 and
/// `claude` $682. So this is not a restyled copy of that chart, it answers a
/// question no existing view answers.
struct SubscriptionTrendCard: View {
    let trend: SubscriptionTrend?
    var attempted = true

    /// Cost or tokens. Cost leads because the API-equivalent figure is what the
    /// rest of this lens is denominated in; tokens are one tap away because a
    /// subscription question is really a token question with a price attached.
    @AppStorage("tokenbar.trend.metric") private var metricRaw = Metric.cost.rawValue

    enum Metric: String, CaseIterable {
        case cost, tokens

        var label: String { self == .cost ? "Cost" : "Tokens" }
    }

    private var metric: Metric { Metric(rawValue: metricRaw) ?? .cost }

    private static let chartHeight: CGFloat = 78
    private static let columnGap: CGFloat = 1.5
    /// A day with usage always draws at least this, so a quiet-but-worked day
    /// stays distinguishable from an idle one. Below it the column vanishes and
    /// the chart claims nothing happened.
    private static let minimumInk: CGFloat = 1.5

    var body: some View {
        DashCard("Daily by subscription", subtitle: subtitle) {
            SegmentedPicker(
                selection: Binding(get: { metric }, set: { metricRaw = $0.rawValue }),
                options: Metric.allCases.map { (value: $0, label: $0.label) })
        } content: {
            if let trend, !trend.days.isEmpty, peak > 0 {
                chart(trend)
                axis(trend)
                legend(trend)
            } else if attempted {
                placeholder(Text("No usage recorded in this range.".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary))
            } else {
                placeholder(LoadingLine(title: "Reading daily usage…"))
            }
        }
    }

    private var peak: Double {
        guard let trend else { return 0 }
        return metric == .cost ? trend.peakCost : Double(trend.peakTokens)
    }

    private func placeholder(_ content: some View) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Self.chartHeight + 22, alignment: .topLeading)
    }

    private var subtitle: String? {
        guard let trend, let first = trend.days.first?.date else { return nil }
        return "since %@".localized(Format.monthDay(first))
    }

    private func value(_ bucket: SubscriptionTrend.Bucket) -> Double {
        metric == .cost ? bucket.cost : Double(bucket.tokens)
    }

    private func total(_ day: SubscriptionTrend.Day) -> Double {
        metric == .cost ? day.totalCost : Double(day.totalTokens)
    }

    /// One column per calendar day, stacked bottom-up in the fold's order so
    /// the largest payer is always the base and the bands do not reshuffle
    /// between refreshes.
    private func chart(_ trend: SubscriptionTrend) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let columnWidth = max(
                1, (width - CGFloat(trend.days.count - 1) * Self.columnGap)
                    / CGFloat(max(trend.days.count, 1)))
            Canvas { context, size in
                for (index, day) in trend.days.enumerated() {
                    let dayTotal = total(day)
                    guard dayTotal > 0 else { continue }
                    let x = CGFloat(index) * (columnWidth + Self.columnGap)
                    let fullHeight = max(
                        Self.minimumInk, size.height * CGFloat(dayTotal / peak))
                    var cursor = size.height
                    for target in trend.targets {
                        guard let bucket = day.byTarget[target] else { continue }
                        let share = value(bucket) / dayTotal
                        let segment = fullHeight * CGFloat(share)
                        guard segment > 0 else { continue }
                        cursor -= segment
                        context.fill(
                            Path(CGRect(x: x, y: cursor, width: columnWidth, height: segment)),
                            with: .color(color(target)))
                    }
                }
            }
        }
        .frame(height: Self.chartHeight)
    }

    /// Ends only. At this width a label per column is unreadable, and the shape
    /// is what the card is for.
    private func axis(_ trend: SubscriptionTrend) -> some View {
        HStack {
            Text(verbatim: trend.days.first.map { Format.monthDay($0.date) } ?? "")
            Spacer()
            Text(verbatim: trend.days.last.map { Format.monthDay($0.date) } ?? "")
        }
        .font(.system(size: 9))
        .foregroundStyle(.tertiary)
    }

    private func legend(_ trend: SubscriptionTrend) -> some View {
        HStack(spacing: 10) {
            ForEach(trend.targets.prefix(4), id: \.self) { target in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(color(target))
                        .frame(width: 6, height: 6)
                    Text(name(target))
                }
            }
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    /// Subscription brand colours, so a band here matches that subscription
    /// everywhere else. Unclassified usage is deliberately grey rather than
    /// given a brand: it does not belong to anyone yet, and colouring it like a
    /// subscription would assert what the user has not declared.
    private func color(_ target: String) -> Color {
        target == SubscriptionTrendFold.unassignedTarget
            ? Color.secondary.opacity(0.45)
            : Color(hex: ClientRegistry.style(target).color)
    }

    private func name(_ target: String) -> String {
        target == SubscriptionTrendFold.unassignedTarget
            ? "Unclassified".localized
            : ClientRegistry.style(target).displayName
    }
}
