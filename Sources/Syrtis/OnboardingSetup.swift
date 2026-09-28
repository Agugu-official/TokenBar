import Foundation

/// First-run setup as a set of cards on the global Overview, all shown at
/// once. Each card records its own answer; the header counts what is left and
/// can skip the rest. Existing users go through it once as well: the keys are
/// versioned (`v1`) and nothing here reads whether a setting was changed
/// before, so a user who already set things up sees their current choices
/// selected and confirms them with one click.
///
/// The pace and attribution cards keep their own answers (a chosen pace, a
/// confirmed or dismissed attribution) and are counted alongside these.
enum OnboardingSetup {
    enum Step: String, CaseIterable {
        case agents, icon, title, login, discord
    }

    static let keyPrefix = "tokenbar.onboarding.v1."
    static let completedKey = keyPrefix + "completed"

    static func answeredKey(_ step: Step) -> String { keyPrefix + step.rawValue }

    static func isAnswered(_ step: Step, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: answeredKey(step)) || isCompleted(defaults: defaults)
    }

    static func isCompleted(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: completedKey)
    }

    static func answer(_ step: Step, defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: answeredKey(step))
        if Step.allCases.allSatisfy({ defaults.bool(forKey: answeredKey($0)) }) {
            defaults.set(true, forKey: completedKey)
        }
    }

    /// "Skip setup": every step counts as answered. The pace falls back to its
    /// default and the attribution card is dismissed, so neither card stays
    /// behind asking on its own.
    static func skipAll(defaults: UserDefaults = .standard) {
        for step in Step.allCases { defaults.set(true, forKey: answeredKey(step)) }
        defaults.set(true, forKey: completedKey)
        if AnimationPace(rawValue: defaults.string(forKey: AnimationPace.storageKey) ?? "") == nil {
            defaults.set(AnimationPace.default.rawValue, forKey: AnimationPace.storageKey)
        }
        defaults.set(true, forKey: AnimationPaceOnboarding.answeredKey)
        AttributionOnboardingCard.markDismissed(defaults: defaults)
    }

    /// Cards still waiting for an answer, counting the pace and attribution
    /// cards only when they would show.
    static func remaining(
        defaults: UserDefaults = .standard, paceCardShows: Bool, attributionCardShows: Bool
    ) -> Int {
        Step.allCases.filter { !isAnswered($0, defaults: defaults) }.count
            + (paceCardShows ? 1 : 0) + (attributionCardShows ? 1 : 0)
    }
}
