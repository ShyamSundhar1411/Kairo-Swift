import SwiftUI
import KairoKit

/// Why a bid lost, in one vocabulary.
///
/// There were two. `TodayView.swift` and `WhyView.swift` each carried their own
/// `explanation` / `reasonIcon` / `reasonTint` triple over the same enum, and
/// they had already drifted: the live screen said one thing about a cost
/// suppression and the record said another about the same decision. A user who
/// taps through from the ledger to the receipt is looking at one event, so it
/// gets one sentence.
///
/// `costing` is a parameter rather than a lookup because the honest sentence for
/// a cost ceiling depends on whether there is a bill behind it. Under
/// `costing: "shadow"` there is no month's service cost to stay inside — the
/// ladder still moves, on shadow rates, and saying otherwise invents an invoice.
enum SuppressionCopy {

    /// Whether the deployment's cost ceiling stands for money that will be
    /// charged. Carried from `/v1/arbitrate`'s `budget` object, which arrives on
    /// every pass, so reading it costs no extra request.
    enum Costing: Equatable {
        case metered
        case notional

        init(backendValue: String?) {
            self = backendValue == "shadow" ? .notional : .metered
        }
    }

    struct Copy {
        let sentence: String
        let icon: String
        let tint: Color
        /// Set only where the reason itself needs a badge beside the sentence.
        let badge: (text: String, icon: String)?
    }

    static func copy(for reason: SuppressionReason?, costing: Costing) -> Copy {
        switch reason {
        case .budgetExhausted:
            Copy(sentence: "today's interruption budget was already spent",
                 icon: "gauge.with.dots.needle.0percent", tint: Kairo.amber, badge: nil)
        case .quietHours:
            Copy(sentence: "quiet hours", icon: "moon.fill", tint: Kairo.violet, badge: nil)
        case .outranked:
            Copy(sentence: "a more useful interruption won this slot",
                 icon: "arrow.up.arrow.down", tint: Kairo.inkFaint, badge: nil)
        case .costCeiling:
            // Section 7.1 — never dressed up as restraint, which is why it is
            // the only reason that keeps the warning colour in both branches.
            costing == .notional
                ? Copy(sentence: "held back by the cost ladder — this deployment runs a "
                       + "free local model, so the ceiling is a stand-in, not a bill.",
                       icon: "dollarsign.circle", tint: Kairo.coral,
                       badge: ("cost · notional", "dollarsign.circle.fill"))
                : Copy(sentence: "held back to stay inside this month's service cost",
                       icon: "dollarsign.circle", tint: Kairo.coral,
                       badge: ("cost", "dollarsign.circle.fill"))
        case .classSuspended:
            Copy(sentence: "suspended by your current plan contract",
                 icon: "pause.circle", tint: Kairo.teal, badge: nil)
        case .windowNotOpen:
            Copy(sentence: "not due yet", icon: "clock.badge.questionmark",
                 tint: Kairo.inkFaint, badge: nil)
        case .windowClosed:
            Copy(sentence: "the useful moment passed", icon: "clock.badge.xmark",
                 tint: Kairo.inkFaint, badge: nil)
        case .inaccessible:
            Copy(sentence: "could not be delivered in a form you can act on",
                 icon: "figure.roll", tint: Kairo.coral, badge: nil)
        case .duplicateClass:
            Copy(sentence: "a similar interruption was already delivered",
                 icon: "square.on.square", tint: Kairo.inkFaint, badge: nil)
        case .ungrounded:
            Copy(sentence: "nothing was measured here today, so nothing was claimed",
                 icon: "eye.slash", tint: Kairo.inkFaint, badge: nil)
        case .safetyRefused:
            // Not a contest it lost. The Steward refused the wording, and the
            // attention budget was not charged for it — so it must not read as
            // though a better bid beat it.
            Copy(sentence: "the Steward would not let this be said the way it was written",
                 icon: "shield.lefthalf.filled", tint: Kairo.coral,
                 badge: ("safety", "shield.fill"))
        case .none:
            Copy(sentence: "no reason recorded", icon: "questionmark.circle",
                 tint: Kairo.inkFaint, badge: nil)
        }
    }
}
