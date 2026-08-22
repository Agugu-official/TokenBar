import Foundation

/// The pieces the Overview lens can show, and which of them the user may hide.
///
/// Declaration order is render order, exactly as `AppView`'s is tab order, so
/// "what appears where" has one source rather than two that can disagree.
public enum OverviewCard: String, CaseIterable, Sendable {
    /// Order restored 2026-08-17 after being got wrong once: the usage chart
    /// comes before the limits card, which is where it sat before this lens was
    /// reorganised. The commit that "restored" it had them the other way round
    /// and said so in its message; the pinned order below is what caught it.
    case quotaSummary, chart, limits, trace, models, streaks

    /// Title-cased id as the translation key, matching `AppView.label`.
    public var label: String {
        let spaced = rawValue.reduce(into: "") { out, character in
            if character.isUppercase, !out.isEmpty { out.append(" ") }
            out.append(character)
        }
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    /// `chart` is a fixed anchor, following `AppView`'s own rule that Overview
    /// and Models cannot be hidden.
    ///
    /// Overview is the fallback every hidden lens falls back TO
    /// (`AppView.effective`). A fallback that can be emptied leaves the user
    /// nowhere to land, and the usage chart is the reason the lens exists.
    public static let toggleable: [OverviewCard] = allCases.filter { $0 != .chart }

    /// Cards shown, given the persisted hidden-set raw string. Same
    /// comma-separated shape as `tokenbar.views.hidden`, parsed by the same
    /// function — a second parser for the same format is a second place for it
    /// to drift.
    ///
    /// Anchors survive a tampered raw string, for the same reason `AppView`'s
    /// do: a hand-edited preference must not be able to produce a surface with
    /// no way out.
    public static func visible(hiddenRaw: String) -> [OverviewCard] {
        let hidden = ClientRegistry.parseIdSet(hiddenRaw)
        return allCases.filter { !toggleable.contains($0) || !hidden.contains($0.rawValue) }
    }

    public static let hiddenKey = "tokenbar.overview.hidden"
}
