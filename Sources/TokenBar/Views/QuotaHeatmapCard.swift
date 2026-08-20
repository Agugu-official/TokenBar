import SwiftUI
import TokenBarCore

/// When the allowance actually gets spent, as a weekday-by-hour grid.
///
/// One window at a time, chosen from the picker. Summing windows was considered
/// and rejected: a client's session window and its weekly window are consumed
/// by the same messages, so adding them counts the same work twice, and
/// percentage points of two different subscriptions are not the same quantity
/// to begin with.
struct QuotaHeatmapCard: View {
    /// Same list the strip card draws, heaviest peak first, so the picker's
    /// order matches the card above it.
    let summaries: [QuotaWindowSummary]
    /// Keyed as `QuotaWindowSummary.id`.
    let heatmaps: [String: QuotaHeatmap]
    /// The per-window equivalence, keyed the same way. What turns a percentage
    /// into money — and the only reason this card can show money at all
    /// without a scan.
    var equivalences: [String: WindowEquivalence.Row] = [:]
    var attempted = true

    @AppStorage("tokenbar.heatmap.window") private var selectedRaw = ""
    @State private var cardFrame: CGRect = .zero
    @State private var hover: (weekday: Int, hour: Int)?
    @State private var hoverAnchorInCard: CGPoint = .zero
    @State private var tooltipSize: CGSize = .zero
    @Environment(\.popoverScrollViewport) private var viewport

    private static let rowHeight: CGFloat = 13
    private static let cellGap: CGFloat = 1
    private static let labelWidth: CGFloat = 18
    private static let tooltipWidth: CGFloat = 186
    /// Faintest and strongest fill for a slot that carries anything. An
    /// occupied slot never drops to invisible: "a little" and "nothing" are
    /// different answers and the grid has to keep them apart.
    private static let floorOpacity: Double = 0.14
    private static let peakOpacity: Double = 0.92
    /// Below this share of the peak a slot is drawn at the floor rather than
    /// proportionally, so a grid with one dominant hour still shows its quiet
    /// activity instead of 167 blank cells.
    private static let floorShare: Double = 0.06

    private var selected: QuotaWindowSummary? {
        summaries.first { $0.id == selectedRaw }
            // Not merely the first summary: one with no placed consumption
            // draws an empty grid on open, which reads as a broken card rather
            // than as a window nobody has used this week.
            ?? summaries.first { !(heatmaps[$0.id]?.isEmpty ?? true) }
            ?? summaries.first
    }

    private var grid: QuotaHeatmap? { selected.flatMap { heatmaps[$0.id] } }

    var body: some View {
        DashCard("When the allowance goes", subtitle: subtitle) {
            if summaries.count > 1 { picker }
        } content: {
            if let grid, !grid.isEmpty {
                heatmap(grid)
                hourAxis
                footnote(grid)
            } else if attempted {
                Text("No allowance movement recorded yet. It accumulates as TokenBar runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LoadingLine(title: "Reading quota history…")
            }
        }
        .overlay(alignment: .topLeading) { tooltipLayer }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { cardFrame = $0 }
        .zIndex(hover == nil ? 0 : 1)
    }

    private var subtitle: String? {
        guard let grid, !grid.isEmpty else { return nil }
        return "%@ days observed".localized(String(grid.observedDays))
    }

    /// A menu rather than a segmented control: window names are long enough
    /// that four of them do not fit across the popover, and this card is not
    /// the place to abbreviate a subscription's own label.
    private var picker: some View {
        Menu {
            ForEach(summaries) { summary in
                Button {
                    selectedRaw = summary.id
                } label: {
                    Text(verbatim: label(summary))
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(verbatim: selected.map(label) ?? "")
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 6))
            }
            // Below the subtitle's `.caption` and well below the 13pt title:
            // this is a control label, not content. Weight matters as much as
            // size here — dropping it to secondary is what stops it reading as
            // a second heading beside the real one.
            .font(.system(size: 8))
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.mini)
        .fixedSize()
    }

    private func label(_ summary: QuotaWindowSummary) -> String {
        "\(ClientRegistry.style(summary.clientId).displayName) · "
            + summary.windowLabel.localized
    }

    private func heatmap(_ grid: QuotaHeatmap) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width - Self.labelWidth
            let cellWidth = max(1, (width - 23 * Self.cellGap) / 24)
            HStack(spacing: 0) {
                VStack(spacing: Self.cellGap) {
                    ForEach(0..<7, id: \.self) { weekday in
                        Text(Self.weekdayLabels[weekday].localized)
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                            .frame(width: Self.labelWidth,
                                   height: Self.rowHeight, alignment: .leading)
                    }
                }
                Canvas { context, size in
                    for weekday in 0..<7 {
                        for hour in 0..<24 {
                            let value = grid.cells[weekday][hour]
                            let rect = CGRect(
                                x: CGFloat(hour) * (cellWidth + Self.cellGap),
                                y: CGFloat(weekday) * (Self.rowHeight + Self.cellGap),
                                width: cellWidth, height: Self.rowHeight)
                            let isHovered = hover?.weekday == weekday && hover?.hour == hour
                            context.fill(
                                Path(roundedRect: rect, cornerRadius: 2),
                                with: .color(fill(value, peak: grid.peak,
                                                  hovered: isHovered)))
                        }
                    }
                    _ = size
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(point):
                        let hour = Int(point.x / (cellWidth + Self.cellGap))
                        let weekday = Int(point.y / (Self.rowHeight + Self.cellGap))
                        guard (0..<24).contains(hour), (0..<7).contains(weekday)
                        else { hover = nil; break }
                        hover = (weekday, hour)
                        let canvas = proxy.frame(in: .global)
                        hoverAnchorInCard = CGPoint(
                            x: CGFloat(hour) * (cellWidth + Self.cellGap) + cellWidth
                                + Self.labelWidth + canvas.minX - cardFrame.minX,
                            y: CGFloat(weekday) * (Self.rowHeight + Self.cellGap)
                                + Self.rowHeight / 2 + canvas.minY - cardFrame.minY)
                    case .ended:
                        hover = nil
                    }
                }
            }
        }
        .frame(height: 7 * Self.rowHeight + 6 * Self.cellGap)
    }

    /// Occupied slots ramp between a floor and the peak; an empty one gets a
    /// near-invisible plate so the grid reads as a grid rather than as floating
    /// squares.
    private func fill(_ value: Double, peak: Double, hovered: Bool) -> Color {
        guard value > 0, peak > 0 else {
            return .primary.opacity(hovered ? 0.16 : 0.05)
        }
        let share = value / peak
        let opacity = share <= Self.floorShare
            ? Self.floorOpacity
            : Self.floorOpacity
                + (Self.peakOpacity - Self.floorOpacity)
                * ((share - Self.floorShare) / (1 - Self.floorShare))
        return .accentColor.opacity(hovered ? min(1, opacity + 0.25) : opacity)
    }

    private static let weekdayLabels =
        ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    private var hourAxis: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: Self.labelWidth)
            ForEach([0, 6, 12, 18], id: \.self) { hour in
                Text(verbatim: "\(hour)")
                    .frame(maxWidth: .infinity, alignment: .leading)
                if hour == 18 { Spacer(minLength: 0) }
            }
        }
        .font(.system(size: 8))
        .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private func footnote(_ grid: QuotaHeatmap) -> some View {
        if grid.unplacedPercent >= 1 {
            // Stated, not swallowed: consumption we could not place in time is
            // consumption the grid is not showing, and a reader comparing the
            // grid's total against the strip card above would otherwise find a
            // gap with no explanation.
            Text("%@%% consumed between readings too far apart to place"
                .localized(String(Int(grid.unplacedPercent.rounded()))))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var tooltipLayer: some View {
        if let hover, let grid, let selected, cardFrame != .zero {
            let value = grid.cells[hover.weekday][hover.hour]
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: Self.weekdayLabels[hover.weekday].localized
                     + String(format: " %02d:00", hover.hour))
                    .font(.caption2.weight(.semibold))
                if value <= 0 {
                    Text("No allowance consumed in this slot")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("%@%% of the allowance".localized(Self.percent(value)))
                        .font(.caption2)
                    equivalent(value, row: equivalences[selected.id])
                }
            }
            .padding(8)
            .frame(width: Self.tooltipWidth, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { tooltipSize = $0 }
            .offset(
                PopoverTooltipPlacement.offset(
                    anchor: hoverAnchorInCard,
                    tooltipSize: tooltipSize == .zero
                        ? CGSize(width: Self.tooltipWidth, height: 84) : tooltipSize,
                    containerFrame: cardFrame, viewport: viewport) ?? .zero)
            .allowsHitTesting(false)
        }
    }

    /// Converted from the window's own equivalence rather than measured.
    ///
    /// The measured route would need a message scan over the whole recorded
    /// history, which this project has already paid 60 seconds for once. The
    /// equivalence is derived from attributed spend against quota movement, so
    /// the figures below are attributed too — they are an estimate, and they
    /// say so, carrying the same error the history card publishes.
    @ViewBuilder
    private func equivalent(_ percent: Double, row: WindowEquivalence.Row?) -> some View {
        if case let .ratio(tokensPerTenth, costPerTenth, errorPercent) = row {
            let share = percent / 10
            Text(verbatim: "≈ " + Format.compactTokens(
                Int64((Double(tokensPerTenth) * share).rounded())))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("~ %@ API-equivalent, ±%@%%".localized(
                Format.usd(costPerTenth * share), String(errorPercent)))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(row == .undeclared
                 ? "Classify your usage in Settings to see what this window is worth"
                 : "Not enough history to convert this window to a figure")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One decimal below 10, none above: a 0.4% slot and an idle one must not
    /// both render as "0%".
    static func percent(_ value: Double) -> String {
        value < 10
            ? String(format: "%.1f", value)
            : String(Int(value.rounded()))
    }
}
