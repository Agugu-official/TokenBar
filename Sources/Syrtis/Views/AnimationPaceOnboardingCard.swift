import SwiftUI
import TokenBarCore

/// Asks, once, how much token traffic the animated menu-bar icon should be
/// scaled for (`AnimationPace`). The flag is the answer itself: picking a pace
/// here or in Settings ends the card, and until then the icon runs at
/// `.moderate`.
enum AnimationPaceOnboarding {
    enum Copy {
        static let title = "How busy are your agents?"
        static let body = "The menu-bar animation follows your live token rate. Pick the range that fits how you work; you can change it later in Settings."
        static let recommended = "Most people: Moderate"
    }

    /// Shown for an animated icon that is animating, before any pace was
    /// picked, in a user runtime, and not while the attribution card is still
    /// on screen, so two onboarding cards never stack.
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
    /// Option wash and border strength over the card's own accent wash.
    static let optionFill = 0.16
    static let optionStroke = 0.45

    static func isVisible(
        style: String, animate: Bool, hasChosen: Bool, attributionCardMayShow: Bool,
        isNonUserRuntime: Bool
    ) -> Bool {
        ["cat", "parrot", TrayAnimator.sandStyle].contains(style) && animate && !hasChosen
            && !attributionCardMayShow && !isNonUserRuntime
    }
}

struct AnimationPaceOnboardingCardView: View {
    @AppStorage(TrayAnimator.styleKey) private var style = "cat"
    @AppStorage(TrayAnimator.animateKey) private var animate = true
    @AppStorage(AnimationPace.storageKey) private var paceRaw = ""
    @AppStorage(UsageAttribution.confirmedKey) private var attributionRaw = ""
    @AppStorage(AttributionOnboardingCard.dismissedKey) private var attributionDismissed = false

    var body: some View {
        let _ = (attributionRaw, attributionDismissed)
        if AnimationPaceOnboarding.isVisible(
            style: style, animate: animate,
            hasChosen: AnimationPace(rawValue: paceRaw) != nil,
            attributionCardMayShow: AttributionOnboardingCard.mayShow(),
            isNonUserRuntime: BuildIdentity.isNonUserRuntime(CommandLine.arguments))
        {
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
                            let tint = AnimationPaceOnboarding.tint(pace)
                            let gradient = LinearGradient(
                                colors: [tint.top, tint.bottom], startPoint: .top, endPoint: .bottom)
                            HStack(spacing: 8) {
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
                                gradient.opacity(AnimationPaceOnboarding.optionFill),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(
                                        tint.top.opacity(AnimationPaceOnboarding.optionStroke),
                                        lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    Text(AnimationPaceOnboarding.Copy.recommended.localized)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .onboardingCardStyle()
        }
    }
}
