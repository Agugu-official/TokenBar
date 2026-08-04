import SwiftUI
import TokenBarCore

// Flat, Sunday-first contribution heatmap. Reads the exact same
// `GridLayout` UsageChartCard builds for ContributionGraph3D (same
// `buildGrid(year:perDayMap:)` call over `stats.perDayMap`) — this is only a
// different renderer over identical data (FLAT-HEATMAP invariant 2), not a
// second aggregation path.

/// Visual parameters as named constants so a design-review pass only touches
/// one line (FLAT-HEATMAP invariant 9).
enum HeatmapLayout {
    static let cell: CGFloat = 11
    static let gap: CGFloat = 3
    static let cornerRadius: CGFloat = 2
    static let monthLabelHeight: CGFloat = 14
    static let step: CGFloat = cell + gap

    /// Five-level intensity ramp. Thresholds ported from token-monitor's
    /// `heatmapIntensity()` (usageCharts.js:60-65: `>=0.75→4`, `>=0.5→3`,
    /// `>=0.25→2`, `>0→1`, else `0`); colors ported from its `.heat.lvl-*`
    /// rules (dashboard.css:98-102), a blue ramp climbing opacity 0→1.
    private static let levelFills: [Color] = [
        Color.primary.opacity(0.05),
        Color(red: 90 / 255, green: 170 / 255, blue: 255 / 255).opacity(0.22),
        Color(red: 120 / 255, green: 190 / 255, blue: 255 / 255).opacity(0.5),
        Color(red: 150 / 255, green: 210 / 255, blue: 255 / 255).opacity(0.82),
        Color(red: 180 / 255, green: 230 / 255, blue: 255 / 255),
    ]

    static func level(value: Double, max: Double) -> Int {
        guard max > 0, value > 0 else { return 0 }
        let ratio = value / max
        if ratio >= 0.75 { return 4 }
        if ratio >= 0.5 { return 3 }
        if ratio >= 0.25 { return 2 }
        return 1
    }

    static func fill(level: Int) -> Color {
        levelFills[max(0, min(level, levelFills.count - 1))]
    }
}

/// Month abbreviations for the header row above the grid. Reuses the same
/// "Jan"…"Dec" localization keys as `Format.monthDay` (see zh-Hant.lproj)
/// rather than reaching into Format's private array.
private let monthAbbrev = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
]

/// The full-year flat heatmap. Tokens/Price only — no Model/Agent stacking
/// (a single color-ramped cell has nowhere to stack).
struct ContributionHeatmap: View {
    let grid: TokenBarCore.GridLayout
    let metric: ChartMetric
    /// The year `grid` was built for — needed only to decide the future-day
    /// cutoff (round 2, item 3); `buildGrid` itself is untouched.
    let year: String

    @State private var hoverCell: GridCell?
    @State private var tooltipSize: CGSize = .zero
    /// The scrolling content's on-screen origin, tracked so the tooltip
    /// (rendered in an overlay *outside* the horizontal ScrollView, see
    /// `body`) can find a hovered cell's true screen position instead of one
    /// pinned to the clipped, scrolled-past content frame.
    @State private var contentOrigin: CGPoint = .zero
    @Environment(\.popoverScrollViewport) private var popoverScrollViewport

    private static let tooltipWidth: CGFloat = 170
    private static let contentID = "heatmap-content"

    // MARK: - Pure per-metric data (no Calendar/TimeZone/Date — ISODay only)

    /// Raw metric value for a cell. Internal (not `private`) so SelfTest can
    /// exercise it directly.
    static func value(_ cell: GridCell, metric: ChartMetric) -> Double {
        metric == .cost ? cell.cost : Double(cell.tokens)
    }

    /// "This day has data" per metric — FLAT-HEATMAP invariant 3: never
    /// `cell.active` (that's tokens-only; Grid.swift:49), because a day can
    /// carry `cost > 0` with `tokens == 0` (UsageStats.swift:105-110).
    static func hasData(_ cell: GridCell, metric: ChartMetric) -> Bool {
        cell.inYear && value(cell, metric: metric) > 0
    }

    /// Per-metric intensity denominator, computed here rather than reusing
    /// `GridLayout.maxTokens` (invariant 4) — `maxTokens` only ever tracks
    /// tokens, so Price needs its own max over the in-year cells.
    static func maxValue(_ grid: TokenBarCore.GridLayout, metric: ChartMetric) -> Double {
        switch metric {
        case .tokens:
            return Double(grid.maxTokens)
        case .cost:
            return grid.cells.reduce(0.0) { $1.inYear ? max($0, $1.cost) : $0 }
        }
    }

    /// Round 2, item 3(a): the last day this heatmap should draw. Only the
    /// selected year matching today's year clips to today — any other
    /// (necessarily past) year still draws through Dec 31. View-level only;
    /// `buildGrid` still produces the full padded year.
    static func cutoffDate(year: String, today: String) -> String {
        year == String(today.prefix(4)) ? today : "\(year)-12-31"
    }

    /// A cell is drawn/hoverable only if it's in-year and on or before the
    /// cutoff — i.e. never a future day in the current year.
    static func isRenderable(_ cell: GridCell, cutoff: String) -> Bool {
        cell.inYear && cell.date <= cutoff
    }

    /// Round 3: the last column that has any renderable cell. Layout width,
    /// month labels, and hit-testing all derive from this — never from
    /// `grid.cols` — so a future day (round 2's `isRenderable` correctly
    /// excludes it from drawing/hover, but round 2 left `grid.cols` driving
    /// the layout width, so cutoff-past columns still ate blank space and
    /// `scrollTo(.trailing)` landed past the actual last day) occupies no
    /// layout width at all. `isRenderable` stays the single judgment call;
    /// this only reduces it to a column number instead of inventing a
    /// separate "visible range" concept.
    static func lastRenderableCol(_ grid: TokenBarCore.GridLayout, cutoff: String) -> Int {
        grid.cells.filter { isRenderable($0, cutoff: cutoff) }.map(\.col).max() ?? -1
    }

    /// The columns that get a month-name header — the same `isRenderable`
    /// cutoff as the cell drawing loop, so a month past the cutoff gets no
    /// label any more than it gets cells. Static (not a private computed
    /// property) so SelfTest can exercise the exact production filter rather
    /// than a hand-rebuilt copy of it.
    static func monthLabelCols(grid: TokenBarCore.GridLayout, cutoff: String) -> [(col: Int, label: String)] {
        grid.cells
            .filter { isRenderable($0, cutoff: cutoff) && $0.date.hasSuffix("-01") }
            .compactMap { cell in
                let monthChars = cell.date.dropFirst(5).prefix(2)
                guard let month = Int(monthChars), (1...12).contains(month) else { return nil }
                return (cell.col, monthAbbrev[month - 1].localized)
            }
    }

    /// Round 2, item 1: the tooltip's anchor in the OUTER (non-scrolling)
    /// container's coordinate space, derived from the hovered cell's
    /// position in the scrolling content plus that content's current
    /// on-screen origin. This is what lets the tooltip escape the horizontal
    /// ScrollView's clip: an anchor pinned to the scrolled content's own
    /// local frame is exactly the bug being fixed.
    static func tooltipAnchor(cellCenter: CGPoint, contentOrigin: CGPoint, containerOrigin: CGPoint) -> CGPoint {
        CGPoint(
            x: cellCenter.x + contentOrigin.x - containerOrigin.x,
            y: cellCenter.y + contentOrigin.y - containerOrigin.y)
    }

    private var metricMax: Double { Self.maxValue(grid, metric: metric) }
    private var cutoff: String { Self.cutoffDate(year: year, today: Format.todayKey()) }

    private var monthLabelCols: [(col: Int, label: String)] {
        Self.monthLabelCols(grid: grid, cutoff: cutoff)
    }

    /// Columns after the last renderable one (round 3) carry no layout width
    /// at all — never derived from `grid.cols`.
    private var visibleCols: Int { max(0, Self.lastRenderableCol(grid, cutoff: cutoff) + 1) }
    private var contentWidth: CGFloat {
        visibleCols > 0 ? CGFloat(visibleCols) * HeatmapLayout.step - HeatmapLayout.gap : 0
    }
    private var gridHeight: CGFloat { 7 * HeatmapLayout.step - HeatmapLayout.gap }
    private var contentHeight: CGFloat { HeatmapLayout.monthLabelHeight + gridHeight }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if grid.cells.isEmpty {
                Color.clear
            } else {
                GeometryReader { outerGeo in
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            canvasBody
                                .id(Self.contentID)
                        }
                        // Round 2, item 3(b): land on the most recent columns
                        // on open, GitHub-style, instead of Jan 1.
                        .onAppear { proxy.scrollTo(Self.contentID, anchor: .trailing) }
                    }
                    // Tooltip lives in the ScrollView's overlay, not its
                    // content — an overlay isn't clipped by the view it
                    // decorates, so this is what stops the tooltip being cut
                    // off at the heatmap's edge (round 2, item 1).
                    .overlay(alignment: .topLeading) {
                        if let cell = hoverCell {
                            let anchor = Self.tooltipAnchor(
                                cellCenter: cellCenter(cell),
                                contentOrigin: contentOrigin,
                                containerOrigin: outerGeo.frame(in: .global).origin)
                            let measuredSize = tooltipSize == .zero
                                ? CGSize(width: Self.tooltipWidth, height: 60)
                                : tooltipSize
                            let offset = PopoverTooltipPlacement.offset(
                                anchor: anchor,
                                tooltipSize: measuredSize,
                                containerFrame: outerGeo.frame(in: .global),
                                viewport: popoverScrollViewport)
                            tooltip(cell)
                                .offset(offset ?? .zero)
                        }
                    }
                }
                .frame(height: contentHeight)
            }
            Spacer(minLength: 0)
        }
    }

    private var canvasBody: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for (col, label) in monthLabelCols {
                    context.draw(
                        Text(label).font(.caption2).foregroundStyle(.secondary),
                        at: CGPoint(x: CGFloat(col) * HeatmapLayout.step, y: HeatmapLayout.monthLabelHeight / 2),
                        anchor: .leading)
                }
                for cell in grid.cells where Self.isRenderable(cell, cutoff: cutoff) {
                    let level = HeatmapLayout.level(value: Self.value(cell, metric: metric), max: metricMax)
                    let rect = CGRect(
                        x: CGFloat(cell.col) * HeatmapLayout.step,
                        y: HeatmapLayout.monthLabelHeight + CGFloat(cell.row) * HeatmapLayout.step,
                        width: HeatmapLayout.cell, height: HeatmapLayout.cell)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: HeatmapLayout.cornerRadius),
                        with: .color(HeatmapLayout.fill(level: level)))
                }
            }
        }
        .frame(width: contentWidth, height: contentHeight)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case let .active(point):
                hoverCell = cellAt(point).flatMap { Self.hasData($0, metric: metric) ? $0 : nil }
            case .ended:
                hoverCell = nil
            }
        }
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { contentOrigin = $0 }
        // Round 2, item 2: let a plain vertical mouse wheel scroll this
        // horizontal grid (DashboardTabs.swift's pattern) — placed inside the
        // ScrollView's content, per HorizontalWheelScroll's own doc comment,
        // so `enclosingScrollView` resolves to this row's NSScrollView.
        .background(HorizontalWheelScroll())
    }

    // MARK: - Hit testing

    /// `grid.cells` is laid out `col * 7 + row` by `buildGrid` (Grid.swift's
    /// nested col/row loop), so direct indexing avoids a lookup dictionary;
    /// the col/row re-check guards against that ordering ever changing.
    private func cellAt(_ point: CGPoint) -> GridCell? {
        guard point.x >= 0, point.y >= HeatmapLayout.monthLabelHeight else { return nil }
        let row = Int((point.y - HeatmapLayout.monthLabelHeight) / HeatmapLayout.step)
        let col = Int(point.x / HeatmapLayout.step)
        guard (0..<7).contains(row), (0..<visibleCols).contains(col) else { return nil }
        let index = col * 7 + row
        guard grid.cells.indices.contains(index) else { return nil }
        let cell = grid.cells[index]
        guard cell.col == col, cell.row == row, Self.isRenderable(cell, cutoff: cutoff) else { return nil }
        return cell
    }

    private func cellCenter(_ cell: GridCell) -> CGPoint {
        CGPoint(
            x: CGFloat(cell.col) * HeatmapLayout.step + HeatmapLayout.cell / 2,
            y: HeatmapLayout.monthLabelHeight + CGFloat(cell.row) * HeatmapLayout.step + HeatmapLayout.cell / 2)
    }

    // MARK: - Tooltip

    private func tooltip(_ cell: GridCell) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Format.monthDay(cell.date)).font(.caption.weight(.semibold))
            Text("%@ tokens".localized(Format.exactTokens(cell.tokens)))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(Format.usd(cell.cost))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .frame(width: Self.tooltipWidth, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { tooltipSize = $0 }
        .allowsHitTesting(false)
    }
}
