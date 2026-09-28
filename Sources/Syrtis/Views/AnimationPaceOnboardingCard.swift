import SwiftUI
import TokenBarCore

/// Asks, once, how much token traffic the animated menu-bar icon should be
/// scaled for (`AnimationPace`). Picking a pace applies it at once so it can be
/// tried on the live icon; "Done" answers the card. Until a pace is picked the
/// icon runs at `.moderate`.
enum AnimationPaceOnboarding {
    enum Copy {
        static let title = "How busy are your agents?"
        static let body = "The menu-bar animation follows your live token rate. Pick the range that fits how you work; you can change it later in Settings."
        static let recommended = "Most people: Moderate"
    }

    /// A tint per pace: one family deepening from slate blue through indigo
    /// to amethyst. Not red, amber and green: a pace is a preference, not a
    /// limit, and traffic-light colours would read as a warning.
    static func tint(_ pace: AnimationPace) -> (top: Color, bottom: Color) {
        switch pace {
        case .light: (Color(red: 0.56, green: 0.66, blue: 0.80), Color(red: 0.42, green: 0.53, blue: 0.68))
        case .moderate: (Color(red: 0.45, green: 0.46, blue: 0.88), Color(red: 0.32, green: 0.36, blue: 0.80))
        case .heavy: (Color(red: 0.66, green: 0.40, blue: 0.86), Color(red: 0.48, green: 0.25, blue: 0.74))
        }
    }
    /// Option wash and border strength over the card's own accent wash; the
    /// picked option is drawn stronger so the current choice is obvious.
    static let optionFill = 0.16
    static let optionStroke = 0.45
    static let selectedFill = 0.34
    static let selectedStroke = 0.95

    /// Set by "Done" (or "Skip setup"). Choosing a pace alone does not answer
    /// the card: the maintainer wanted to try several before confirming.
    static let answeredKey = OnboardingSetup.keyPrefix + "pace"

    /// Shown for an animated icon that is animating, before any pace was
    /// picked, in a user runtime. Independent of the other onboarding cards:
    /// the maintainer asked for every card to show at once rather than one
    /// appearing only after another is answered.
    static func isVisible(
        style: String, animate: Bool, answered: Bool, isNonUserRuntime: Bool
    ) -> Bool {
        TrayAnimator.animatedStyles.contains(style) && animate && !answered && !isNonUserRuntime
    }
}

struct AnimationPaceOnboardingCardView: View {
    @AppStorage(TrayAnimator.styleKey) private var style = "cat"
    @AppStorage(TrayAnimator.animateKey) private var animate = true
    @AppStorage(AnimationPace.storageKey) private var paceRaw = ""
    @AppStorage(AnimationPaceOnboarding.answeredKey) private var answered = false

    private var visible: Bool {
        AnimationPaceOnboarding.isVisible(
            style: style, animate: animate, answered: answered,
            isNonUserRuntime: BuildIdentity.isNonUserRuntime(CommandLine.arguments))
    }

    private var current: AnimationPace { AnimationPace(rawValue: paceRaw) ?? .default }

    var body: some View {
        OnboardingCardContainer(visible: visible) {
            DashCard(AnimationPaceOnboarding.Copy.title) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(AnimationPaceOnboarding.Copy.body.localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(AnimationPace.allCases, id: \.self) { pace in
                        Button {
                            paceRaw = pace.rawValue
                        } label: {
                            option(pace)
                        }
                        .buttonStyle(.plain)
                    }
                    HStack {
                        Text(AnimationPaceOnboarding.Copy.recommended.localized)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button(OnboardingSetupCopy.done.localized) {
                            if AnimationPace(rawValue: paceRaw) == nil {
                                paceRaw = AnimationPace.default.rawValue
                            }
                            answered = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
            .onboardingCardStyle()
        }
    }

    private func option(_ pace: AnimationPace) -> some View {
        let tint = AnimationPaceOnboarding.tint(pace)
        let picked = pace == current
        let gradient = LinearGradient(
            colors: [tint.top, tint.bottom], startPoint: .top, endPoint: .bottom)
        return HStack(spacing: 8) {
            Capsule()
                .fill(gradient)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(pace.label.localized).font(.caption.weight(.semibold))
                Text(pace.detail.localized)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            gradient.opacity(
                picked ? AnimationPaceOnboarding.selectedFill : AnimationPaceOnboarding.optionFill),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    tint.top.opacity(
                        picked ? AnimationPaceOnboarding.selectedStroke : AnimationPaceOnboarding.optionStroke),
                    lineWidth: picked ? 1.5 : 1))
    }
}
