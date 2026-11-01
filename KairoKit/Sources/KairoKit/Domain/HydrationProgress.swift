import Foundation

/// FR8.5 - a non-visual equivalent for hydration progress.
///
/// The phone drew a ring: an arc, a tint, and a percentage in the middle. All
/// three are the same channel. A user who cannot see it had the totals read out
/// - "660 of 2000 millilitres" - which is the *number*, not the progress, and
/// NFR11's rule against colour-only encoding is pointing at exactly this gap:
/// the ring's green-at-target was the only thing that said "you are done".
///
/// Two non-visual channels, built from one source so they cannot disagree:
///
/// 1. **Spoken** - a sentence VoiceOver reads that states position, not just
///    quantity, and says when the target is met in words rather than in hue.
/// 2. **Haptic** - a distinct tap when a quarter boundary is crossed, played on
///    the wrist where the water was logged. This is the only one of the two that
///    works with the screen off and the phone in another room, which is the
///    situation one-tap logging exists for.
///
/// The milestones are quarters because they are the coarsest division that still
/// says something useful. A tap per sip tells the user only that the tap
/// registered - which `.click` already does - and a tap per percent is noise.
public enum HydrationProgress {

    /// Quarter boundaries. `target` is separate from "100%" on purpose: it is
    /// the one the user is waiting for and the one that gets its own haptic.
    public enum Milestone: Int, CaseIterable, Sendable, Comparable {
        case quarter = 25
        case half = 50
        case threeQuarters = 75
        case target = 100

        public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }

        /// Said aloud, never shown. "Halfway" is what somebody wants to hear;
        /// "50 percent" is what a progress bar wants to say.
        public var spoken: String {
            switch self {
            case .quarter:       "a quarter of the way"
            case .half:          "halfway"
            case .threeQuarters: "three quarters of the way"
            case .target:        "target reached"
            }
        }
    }

    /// Which boundary this change crossed, if any.
    ///
    /// Compares the two totals rather than testing the new one, so a sip that
    /// jumps two boundaries at once reports the higher - one glass that takes
    /// somebody from 20% to 60% has passed halfway, and reporting the quarter
    /// would be telling them about the boundary they left behind.
    ///
    /// Returns `nil` for an unchanged or decreasing total, so a re-delivered
    /// WatchConnectivity message cannot buzz the wrist twice for one glass.
    public static func crossed(from before: Int, to after: Int,
                               target: Int) -> Milestone? {
        guard target > 0, after > before else { return nil }
        let was = percent(before, of: target)
        let now = percent(after, of: target)
        return Milestone.allCases.last { $0.rawValue > was && $0.rawValue <= now }
    }

    /// FR8.5's spoken equivalent. Position first, because position is the thing
    /// the ring was encoding and the totals were not.
    ///
    /// `sipCount` of zero is "nothing logged", never "0 of 2000" - an absence of
    /// data presented as a measurement of zero is the claim the coverage gate
    /// refuses in a sentence, so the accessible text does not make it either.
    public static func spoken(totalMillilitres total: Int,
                              targetMillilitres target: Int,
                              sipCount: Int) -> String {
        guard sipCount > 0 else { return "No water logged yet today." }
        let pct = percent(total, of: target)
        let remaining = max(0, target - total)
        let position: String
        if remaining == 0 {
            position = "Target reached."
        } else if let reached = Milestone.allCases.last(where: { $0.rawValue <= pct }) {
            position = "\(reached.spoken.prefix(1).uppercased())\(reached.spoken.dropFirst())."
        } else {
            position = "Just started."
        }
        let detail = remaining == 0
            ? "\(total) of \(target) millilitres, logged \(sipCount) times."
            : "\(total) of \(target) millilitres, \(remaining) to go, "
              + "logged \(sipCount) times."
        return "\(position) \(detail)"
    }

    /// The `accessibilityValue` for the ring: percentage only, because the label
    /// already carries the words. VoiceOver reads label then value, and
    /// repeating the sentence in both is how a control becomes tiring to use.
    public static func accessibilityValue(totalMillilitres total: Int,
                                          targetMillilitres target: Int,
                                          sipCount: Int) -> String {
        sipCount > 0 ? "\(percent(total, of: target)) percent of today's target"
                     : "not measured"
    }

    static func percent(_ value: Int, of target: Int) -> Int {
        guard target > 0 else { return 0 }
        return min(100, Int((Double(value) / Double(target) * 100).rounded(.down)))
    }
}
