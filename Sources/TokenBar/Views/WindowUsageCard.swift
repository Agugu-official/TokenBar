import SwiftUI
import TokenBarCore

/// One quota window: the line is the subscription's quota, the bars underneath
/// are the local usage that moved it. All geometry comes from
/// `WindowCardGeometry`, so this file only strokes and fills.
///
/// Why the bars sit behind the line: in "used" mode early in a window the line
/// runs low, straight through the bar band. Rather than move either series, the
/// bars recede and light one at a time under the cursor while the line stays in
/// front (`V-5`).
struct WindowUsageCard: View {
    let clientId: String
    let windowLabel: String
    let resolution: WindowResolution
    /// Quota readings inside the window, in time order.
    let samples: [QuotaSample]
    /// Already attributed to this subscription, and already turned into bars
    /// and hit zones by the loader. Doing either here would redo O(messages)
    /// work on every hover event.
    let mine: [WindowMessage]
    let bars: [BarRect]
    let hits: [HitZone]
    /// "<clientId>|<cardId>" for every window that can be shown, and which one
    /// is showing. Buttons rather than a menu: there are a handful of windows
    /// and the point is to compare them, which a menu hides behind a click.
    let candidates: [(cardId: String, label: String)]
    let cardId: String
    /// The window is longer than the per-message path covers, so the bars are
    /// deliberately absent. Said out loud rather than drawn as an empty chart.
    let barsSuppressed: Bool
    let nowMs: Int64
    /// Why no window could be resolved, when the reason is a failing provider
    /// rather than an absent subscription.
    var blockedBy: String?

    @AppStorage("tokenbar.limits.asUsed") private var asUsed = false
    @AppStorage(WindowCardLoader.selectionKey) private var selection = ""
    @State private var hover: Int?
    @State private var hoverPoint: CGPoint = .zero
    @State private var tooltipSize: CGSize = .zero
    @Environment(\.popoverScrollViewport) private var viewport

    private static let chartHeight: CGFloat = 96
    /// The bar band is a third of the height. The line uses the whole box, so
    /// the two overlap by design — see the type comment.
    private static let barBand: CGFloat = 32
    private static let tooltipWidth: CGFloat = 190

    private var metric: QuotaMetric { asUsed ? .used : .remaining }

    private var interval: (start: Int64, end: Int64)? {
        switch resolution {
        case let .active(start, end), let .inferred(start, end): return (start, end)
        case .idle, .unavailable: return nil
        }
    }

    var body: some View {
        DashCard("%@ window".localized(windowLabel), subtitle: stateLine) {
            SegmentedPicker(
                selection: Binding(get: { asUsed }, set: { asUsed = $0 }),
                options: [(value: false, label: "Remaining"), (value: true, label: "Used")])
        } content: {
            if candidates.count > 1 {
                // The selection is written straight to the same key the loader
                // reads, so the next poll rebuilds against it — no second copy
                // of "which window" to keep in step.
                SegmentedPicker(
                    selection: Binding(get: { selection.isEmpty ? cardId : selection },
                                       set: { selection = $0 }),
                    options: candidates.map { (value: $0.cardId, label: $0.label) })
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let interval {
                // Only the quota half is recomputed per body: it is O(samples)
                // — a few dozen points — while bars and hit zones arrived
                // precomputed and cannot change with the metric anyway.
                let quota = WindowCardGeometry.quotaGeometry(
                    windowStartMs: interval.start, windowEndMs: interval.end,
                    nowMs: min(nowMs, interval.end), samples: samples, metric: metric)
                let geo = ChartGeometry(
                    nowX: quota.nowX, firstSampleX: quota.firstSampleX,
                    bars: bars, hits: hits,
                    samplePoints: quota.samplePoints, curve: quota.curve)
                headline(geo)
                // Above the legend and the equivalence row, which are later
                // siblings in this VStack and would otherwise paint straight
                // through the tooltip. The card-level zIndex handles the
                // neighbouring cards; this one handles its own rows.
                chart(geo).zIndex(1)
                legend(geo)
                if barsSuppressed {
                    Text("Usage bars need a per-message scan, which is bounded to session windows — this one covers far more history.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    equivalenceRow
                }
            } else {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Without this the sibling cards below paint over the tooltip; the
        // usage chart lifts its whole card the same way.
        .zIndex(hover == nil ? 0 : 1)
    }

    // MARK: - Header

    private var stateLine: String {
        if blockedBy != nil { return "Waiting for quota" }
        switch resolution {
        case let .active(_, end):
            return "Resets in %@".localized(Format.duration(ms: end - nowMs))
        case let .inferred(_, end):
            return "Inferred window · resets in %@".localized(Format.duration(ms: end - nowMs))
        case .idle: return "No window running"
        case .unavailable: return "Window unavailable"
        }
    }

    private var emptyText: String {
        if let blockedBy { return blockedBy }
        switch resolution {
        case .idle:
            return "The last window ended and nothing has been used since — no window is running."
        case .unavailable:
            return "This subscription did not report a usable reset time, so the window cannot be placed."
        default: return ""
        }
    }

    @ViewBuilder
    private func headline(_ geo: ChartGeometry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let latest = geo.samplePoints.last {
                Text(verbatim: "\(Int(latest.y.rounded()))%")
                    .font(.system(size: 22, weight: .semibold))
                Text(asUsed ? "used" : "remaining")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No quota reading in this window")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Chart

    private func chart(_ geo: ChartGeometry) -> some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = Self.chartHeight
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in draw(ctx, geo: geo, w: w, h: h) }
                    .frame(width: w, height: h)
                if let hover, geo.hits.indices.contains(hover) {
                    overlay(geo, index: hover, w: w, h: h,
                            container: proxy.frame(in: .global))
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(p):
                    hoverPoint = p
                    // Zones tile [0, nowX] exactly, so this both finds the zone
                    // and rejects the future in one step: past nowX nothing
                    // contains the point.
                    let x = p.x / max(w, 1)
                    hover = geo.hits.firstIndex { x >= $0.x && x < $0.x + $0.width }
                case .ended:
                    hover = nil
                }
            }
        }
        .frame(height: Self.chartHeight)
    }

    private func draw(_ ctx: GraphicsContext, geo: ChartGeometry, w: CGFloat, h: CGFloat) {
        // Hatch means one thing: no quota sample here, so no line. Both the
        // pre-sampling stretch and the future qualify, so both get one weight;
        // whether usage data exists is answered by the bars drawn over it.
        for (from, to) in [(0.0, geo.firstSampleX), (geo.nowX, 1.0)] where to > from {
            let rect = CGRect(x: from * w, y: 0, width: (to - from) * w, height: h)
            ctx.fill(Path(rect), with: .color(.secondary.opacity(0.06)))
            var stripes = Path()
            var x = rect.minX - h
            while x < rect.maxX {
                stripes.move(to: CGPoint(x: x, y: h))
                stripes.addLine(to: CGPoint(x: x + h, y: 0))
                x += 5
            }
            // Scoped so the clip cannot leak onto the bars and line below.
            ctx.drawLayer { layer in
                layer.clip(to: Path(rect))
                layer.stroke(stripes, with: .color(.secondary.opacity(0.18)), lineWidth: 0.6)
            }
        }

        for (i, bar) in geo.bars.enumerated() {
            let x = bar.x * w
            let bw = max(bar.width * w - 1, 0.5)
            if bar.isEmpty {
                ctx.fill(Path(CGRect(x: x, y: h - 1, width: bw, height: 1)),
                         with: .color(.primary.opacity(0.28)))
                continue
            }
            let bh = max(bar.height * Self.barBand, 1)
            ctx.fill(Path(CGRect(x: x, y: h - bh, width: bw, height: bh)),
                     with: .color(.accentColor.opacity(hover == i ? 0.62 : 0.17)))
        }

        guard geo.curve.count > 1 else { return }
        var path = Path()
        for (i, p) in geo.curve.enumerated() {
            let pt = CGPoint(x: p.x * w, y: y(p.y, h: h))
            i == 0 ? path.move(to: pt) : path.addLine(to: pt)
        }
        // A ground-coloured underlay keeps the line legible where it crosses a
        // lit bar, so "the line is always in front" holds by construction.
        ctx.stroke(path, with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.85)),
                   style: StrokeStyle(lineWidth: 3.4, lineCap: .round, lineJoin: .round))
        ctx.stroke(path, with: .color(.accentColor),
                   style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))

        for p in geo.samplePoints {
            let r = CGRect(x: p.x * w - 2, y: y(p.y, h: h) - 2, width: 4, height: 4)
            ctx.fill(Path(ellipseIn: r), with: .color(Color(nsColor: .windowBackgroundColor)))
            ctx.stroke(Path(ellipseIn: r), with: .color(.accentColor), lineWidth: 1.1)
        }
    }

    /// Fixed 0...100: rescaling would make 7% used and 63% used look the same,
    /// which is the one thing this card exists to tell apart.
    private func y(_ value: Double, h: CGFloat) -> CGFloat {
        10 + (1 - value / 100) * (h - 16)
    }

    // MARK: - Hover

    @ViewBuilder
    private func overlay(
        _ geo: ChartGeometry, index: Int, w: CGFloat, h: CGFloat, container: CGRect
    ) -> some View {
        let zone = geo.hits[index]
        let anchorX = (zone.x + zone.width) * w
        Path { p in
            p.move(to: CGPoint(x: anchorX, y: 0))
            p.addLine(to: CGPoint(x: anchorX, y: h))
        }
        .stroke(Color.primary.opacity(0.3), lineWidth: 1)
        .allowsHitTesting(false)
        if let sample = zone.closingSample {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)
                .position(x: anchorX,
                          y: y(metric.value(fromUsedPercent: sample.usedPercent), h: h))
                .allowsHitTesting(false)
        }
        WindowHoverTooltip(
            zone: zone, metric: metric,
            messages: mine.filter { $0.timestamp > zone.loMs && $0.timestamp <= zone.hiMs },
            subtitle: "\(ClientRegistry.style(clientId).displayName) · \(windowLabel)",
            measuredSize: $tooltipSize)
        // X pins to the zone edge, Y follows the cursor so the helper can flip
        // the tooltip above or below and keep it off the pointer.
        .offset(placement(anchor: CGPoint(x: anchorX, y: hoverPoint.y),
                          container: container))
        .allowsHitTesting(false)
    }

    private func placement(anchor: CGPoint, container: CGRect) -> CGSize {
        let measured = tooltipSize == .zero
            ? CGSize(width: Self.tooltipWidth, height: 120) : tooltipSize
        return PopoverTooltipPlacement.offset(
            anchor: anchor, tooltipSize: measured, containerFrame: container,
            viewport: viewport) ?? .zero
    }

    // MARK: - Footer

    private func legend(_ geo: ChartGeometry) -> some View {
        HStack(spacing: 10) {
            key(Color.accentColor, "Quota", line: true)
            key(Color.accentColor.opacity(0.5), "Usage")
            key(.secondary.opacity(0.3), "No sample")
            Spacer()
            Text("%@ readings".localized(String(geo.samplePoints.count)))
                .foregroundStyle(.tertiary)
        }
        .font(.caption2)
    }

    private func key(_ color: Color, _ label: String, line: Bool = false) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: line ? 1 : 2)
                .fill(color)
                .frame(width: line ? 12 : 8, height: line ? 2 : 8)
            Text(label.localized)
        }
        .foregroundStyle(.secondary)
    }

    private var equivalenceRow: some View {
        let row = WindowEquivalence.row(samples: samples, messages: mine)
        let plain: Bool = { if case .ratio = row { return false }; return true }()
        return Text(WindowEquivalence.text(
            row, tokens: Format.compactTokens, money: Format.usd))
            .font(.caption2)
            .foregroundStyle(plain ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Same shape as the Models card's tooltip, down to the palette and the
/// zero-value filter, so one interval reads the same wherever it appears.
private struct WindowHoverTooltip: View {
    let zone: HitZone
    let metric: QuotaMetric
    let messages: [WindowMessage]
    let subtitle: String
    @Binding var measuredSize: CGSize

    private var total: Int64 { messages.reduce(0) { $0 + $1.tokens } }

    private var kinds: [(label: String, color: String, value: Int64)] {
        let sums: [Int64] = [
            messages.reduce(0) { $0 + $1.input },
            messages.reduce(0) { $0 + $1.output },
            messages.reduce(0) { $0 + $1.cacheRead },
            messages.reduce(0) { $0 + $1.cacheWrite },
            messages.reduce(0) { $0 + $1.reasoning },
        ]
        return zip(TokenKindPalette.all, sums)
            .map { (label: $0.label, color: $0.color, value: $1) }
            .filter { $0.value > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Format.clockRange(fromMs: zone.loMs, toMs: zone.hiMs))
                .font(.caption.weight(.semibold))
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            // The quota row keeps the spike's three states; a zone with no
            // closing sample is the hatched stretch, and must say so rather
            // than show nothing.
            Text(zone.closingSample.map {
                "Quota %@%% %@".localized(
                    String(Int(metric.value(fromUsedPercent: $0.usedPercent).rounded())),
                    metric == .used ? "used" : "remaining")
            } ?? "No quota reading in this interval".localized)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Text("%@ tokens".localized(Format.compactTokens(total)))
                Spacer()
                Text(Format.usd(messages.reduce(0) { $0 + $1.cost }))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            ForEach(kinds, id: \.label) { kind in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color(hex: kind.color))
                        .frame(width: 6, height: 6)
                    Text(kind.label.localized)
                    Spacer()
                    Text("\(Format.compactTokens(kind.value)) · "
                         + "\(Int((Double(kind.value) / Double(max(1, total)) * 100).rounded()))%")
                        .foregroundStyle(.secondary)
                }
                .font(.caption2)
            }
            if kinds.isEmpty {
                Text("No usage in this interval")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        // Same chrome as the usage chart's tooltip, down to the radius and the
        // border style — two tooltips in one popover that differ by two points
        // of padding read as two different kinds of thing.
        .padding(8)
        .frame(width: 190, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        // Same measurement path as the usage chart's tooltip: a background
        // GeometryReader reports one frame late, which is exactly the frame
        // the placement is computed in.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { measuredSize = $0 }
    }
}
