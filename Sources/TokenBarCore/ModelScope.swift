import Foundation

/// Whether a locally recorded model belongs to a window's declared model scope.
///
/// This is a JOIN BETWEEN TWO NAMING SYSTEMS, and saying so is the point. The
/// scope arrives as the provider's display-name slug — `fable`, from a limit
/// entry whose `scope.model.display_name` is "Fable" — while the model on a
/// message is the canonical id the local transcript carried, `claude-fable-5`.
/// Nothing guarantees the two agree, and the engine cannot close the gap for
/// us: the live `oauth/usage` payload reports `scope.model.id: null`, so the
/// display name is the only identity the provider actually sends.
///
/// A join like this fails silently by default — the bars simply stop matching
/// the curve, which is the one thing the card exists to explain. So the rule is
/// deliberately narrow, stated once, and its failure is made visible by
/// `WindowUsageHalf.scopeMatchedNothing` rather than left to look like an idle
/// week.
public enum ModelScope {
    /// Lowercase alphanumeric runs. The same shape `claude_slug` produces on
    /// the Rust side, so `Fable` and `claude-fable-5` decompose comparably.
    static func tokens(_ value: String) -> [String] {
        value.lowercased().split(whereSeparator: { !$0.isNumber && !$0.isLetter }).map(String.init)
    }

    /// True when every token of the scope appears in the model id.
    ///
    /// Subset rather than equality, because the two systems name at different
    /// granularities: the provider says "Fable" where the transcript says
    /// `claude-fable-5`. Subset rather than substring, because a substring test
    /// is not a rule anyone can state — it matches on accidents of spelling and
    /// cannot be reasoned about when a new model appears.
    ///
    /// Over-matching is bounded by the engine, not by this function: a scope
    /// naming every model (`all-models`, or a name ending in it) never reaches
    /// the wire, so there is no scope here broad enough to select a whole
    /// subscription.
    ///
    /// Under-matching — a display name carrying a word the id does not, so
    /// nothing matches — is the failure this cannot rule out, and is exactly
    /// why the caller reports an empty scoped result instead of drawing it as
    /// zero usage.
    public static func covers(_ scope: String, modelId: String) -> Bool {
        let wanted = tokens(scope)
        guard !wanted.isEmpty else { return false }
        let present = Set(tokens(modelId))
        return wanted.allSatisfy(present.contains)
    }
}
