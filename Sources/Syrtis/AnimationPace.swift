import Foundation

/// How much token traffic the animated menu-bar icons (cat, parrot, sand) are
/// scaled for. The live rate is divided by `multiplier` before it reaches the
/// speed curve and the sand levels, so one curve serves a light user and a
/// user running many agents at once.
///
/// Calibrated on one Claude Max 5x user's last 30 days (hourly averages,
/// cache reads included): median about 190k tok/min, p95 about 3M, which is
/// where `.moderate` reaches the top speed. The other two scale that by the
/// allowance ratio of the plans named in their descriptions: Pro is a fifth of
/// Max 5x, and Max 20x's weekly allowance is 16.67x Pro, 3.33x Max 5x. The
/// plans are examples only; the setting does not read any subscription.
enum AnimationPace: String, CaseIterable {
    case light
    case moderate
    case heavy

    static let storageKey = "tokenbar.tray.animationPace"
    static let `default`: AnimationPace = .moderate

    var multiplier: Double {
        switch self {
        case .light: 0.2
        case .moderate: 1
        case .heavy: 16.67 / 5
        }
    }

    var label: String {
        switch self {
        // Own keys: bare "Light" is the appearance setting ("淺色"), and a
        // shared key silently takes the other string's translation.
        case .light: "Light pace"
        case .moderate: "Moderate pace"
        case .heavy: "Heavy pace"
        }
    }

    /// One line for Settings and the onboarding card.
    var detail: String {
        switch self {
        case .light: "Occasional use, or a plan like Claude Pro"
        case .moderate: "A few agents at once, or a plan like Claude Max 5x"
        case .heavy: "Lots of agents at once, such as Claude Code's ultracode, or a plan like Claude Max 20x"
        }
    }

    /// The rate the curve and the sand levels see.
    func scaled(_ tokensPerMinute: Double) -> Double {
        tokensPerMinute / multiplier
    }

    static func current(defaults: UserDefaults = .standard) -> AnimationPace {
        defaults.string(forKey: storageKey).flatMap(AnimationPace.init(rawValue:)) ?? .default
    }

    /// Whether the user has picked a pace, which is what ends the onboarding
    /// card: the card records an answer, like the attribution card.
    static func hasChosen(defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: storageKey).flatMap(AnimationPace.init(rawValue:)) != nil
    }
}
