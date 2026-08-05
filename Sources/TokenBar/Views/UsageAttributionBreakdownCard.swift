import SwiftUI
import TokenBarCore

/// API-list-price equivalent split by the user's confirmed subscription
/// declarations. The report carries the year it was loaded for; the subtitle
/// keeps that actual range visible without inventing a new window.
struct UsageAttributionBreakdownCard: View {
    let loadedModelReport: LoadedModelReport?
    let clientIds: [String]
    /// The client tab this card is scoped to, or nil on Overview.
    var singleClient: String?
    /// Whether the report request has finished, however it finished. `load()`
    /// fetches the report with `try?` and still reaches `.ready` on the graph
    /// alone, so a nil report is not by itself an in-flight request — without
    /// this the card spins forever whenever the report keeps failing.
    var reportAttempted = false

    /// Bound rather than read, because a computed read of `UserDefaults` is not
    /// a view dependency: saving a classification in Settings left an already
    /// open Stats card showing the previous split until some unrelated state
    /// happened to rebuild it. `@AppStorage` on the raw value is what makes the
    /// write invalidate this view.
    @AppStorage(UsageAttribution.confirmedKey) private var confirmedRaw = ""

    var confirmed: [UsageAttribution.Record] {
        UsageAttribution.parseRaw(confirmedRaw).records
    }

    /// What the card body shows. Extracted so the choice is assertable: a nil
    /// report is two different states and the branch that separates them is not
    /// reachable from a UI-free test through `body`.
    enum ContentState: Equatable {
        case loading
        case unavailable
        case empty
        case rows
    }

    static func contentState(rowCount: Int?, reportAttempted: Bool) -> ContentState {
        guard let rowCount else { return reportAttempted ? .unavailable : .loading }
        return rowCount == 0 ? .empty : .rows
    }

    static func rangeLabel(for loadedModelReport: LoadedModelReport?) -> String {
        loadedModelReport?.year ?? "All years"
    }

    /// The card states both scopes that change its figures. Naming only the
    /// year made a client tab's subtotal read as an account-wide breakdown,
    /// which is exactly the misreading the whole feature exists to prevent.
    /// Parts are localized before composing because `DashCard` looks the
    /// finished subtitle up once, and a composed string is never a key.
    static func subtitle(
        for loadedModelReport: LoadedModelReport?, singleClient: String?
    ) -> String {
        let range = rangeLabel(for: loadedModelReport).localized
        guard let singleClient else { return range }
        return UsageAttributionSettings.Copy.source.localized(
            range, ClientRegistry.shortName(singleClient))
    }

    var body: some View {
        let rows = loadedModelReport.map {
            // Use raw entries: modelLevelEntries folds providers and erases the
            // dimension the attribution declarations resolve against.
            UsageAttributionBreakdown.rows(
                entries: $0.report.entries, clientIds: clientIds, confirmed: confirmed)
        }

        DashCard(
            UsageAttributionBreakdown.Copy.title,
            subtitle: Self.subtitle(
                for: loadedModelReport, singleClient: singleClient)
        ) {
            switch Self.contentState(
                rowCount: rows?.count, reportAttempted: reportAttempted)
            {
            case .loading:
                LoadingLine(title: "Loading…")
            case .unavailable:
                Text(UsageAttributionBreakdown.Copy.unavailable.localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .empty:
                Text(UsageAttributionBreakdown.Copy.noUsage.localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .rows:
                if confirmed.isEmpty {
                    Text(UsageAttributionBreakdown.Copy.hint.localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 6) {
                    ForEach(rows ?? []) { row in
                        breakdownRow(row)
                    }
                }
            }
        }
    }

    /// The two non-subscription buckets each get their own tint because they
    /// mean opposite things: `excluded` is money actually charged, `unassigned`
    /// is work left for the user. Sharing one colour, or leaving `unassigned`
    /// bare, would read as "nothing to do here".
    private enum RowTint {
        case assigned
        case excluded
        case unassigned

        var fill: Color {
            switch self {
            case .assigned: return .clear
            case .excluded: return Color.orange.opacity(0.12)
            case .unassigned: return Color(hex: "#3b82f6").opacity(0.12)
            }
        }

        var amount: Color {
            switch self {
            case .assigned, .unassigned: return Color(hex: "#22c55e")
            case .excluded: return .orange
            }
        }

        var label: AnyShapeStyle {
            self == .assigned ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.primary)
        }
    }

    private func breakdownRow(_ row: UsageAttributionBreakdown.Row) -> some View {
        let tint: RowTint
        let label: String
        switch row.state {
        case let .assigned(target):
            tint = .assigned
            label = UsageAttributionSettings.Copy.assigned.localized(
                ClientRegistry.shortName(target))
        case .excluded:
            tint = .excluded
            label = UsageAttributionSettings.Copy.excluded.localized
        case .unassigned:
            tint = .unassigned
            label = UsageAttributionSettings.Copy.unassigned.localized
        }

        return HStack(spacing: 8) {
            Text(label)
                .font(.caption.weight(tint == .assigned ? .regular : .semibold))
                .foregroundStyle(tint.label)
                .lineLimit(1)
            Spacer(minLength: 8)
            // Both figure columns reserve a minimum width and align trailing,
            // so short values pad with blank space instead of sliding their
            // column's left edge per row. minWidth rather than a fixed width:
            // an unusually long total still grows instead of clipping.
            Text(Format.compactTokens(row.tokens))
                .font(.caption.monospacedDigit())
                .frame(minWidth: 52, alignment: .trailing)
            Text(Format.usd(row.cost))
                .font(.caption.monospacedDigit())
                .foregroundStyle(tint.amount)
                .frame(minWidth: 76, alignment: .trailing)
        }
        // Every row carries the same inset so a tinted row's text and figures
        // stay on the same left and right edges as the untinted ones; padding
        // only the tinted rows visibly shortened them at both ends.
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(tint.fill, in: RoundedRectangle(cornerRadius: 6))
    }
}
