import Foundation

/// Member C - CF7 attention budget.
public enum NudgeState: String, LifecycleState {
    case bid, queued, scored, suppressed, scheduled, delivered
    case accepted, snoozed, dismissed, expired, recorded

    public static let machineName = "Nudge"
    public static let initial: NudgeState = .bid
    public var isTerminal: Bool { self == .recorded }

    public static let transitions: [Transition<NudgeState>] = [
        .init(.bid, "admitted", .queued),
        .init(.queued, "scoredByReceptivity", .scored),
        .init(.scored, "budgetExhausted", .suppressed, guardText: "spent >= dailyBudget"),
        .init(.scored, "quietHours", .suppressed, guardText: "inside quiet hours or Focus"),
        .init(.scored, "outrankedByAnotherBid", .suppressed),
        .init(.scored, "costCeilingReached", .suppressed,
              guardText: "recorded as a COST suppression, never presented as restraint"),
        .init(.scored, "classSuspendedByContract", .suppressed),
        .init(.scored, "windowNotOpen", .suppressed, guardText: "the useful moment has not arrived yet"),
        .init(.scored, "evidenceInsufficient", .suppressed,
              guardText: "coverage permits no claim about this domain (CF6)"),
        .init(.scored, "duplicateInClass", .suppressed,
              guardText: "another bid in the same class scored higher"),
        .init(.scored, "allocated", .scheduled),
        .init(.scheduled, "windowClosed", .expired),
        .init(.scheduled, "sent", .delivered),
        .init(.delivered, "userAccepted", .accepted),
        .init(.delivered, "userSnoozed", .snoozed),
        .init(.delivered, "userDismissed", .dismissed),
        .init(.delivered, "noResponseInWindow", .expired),
        .init(.snoozed, "requeued", .queued),
        // Figure 37's `Snoozed → Expired [expiry passes]`, drawn and never
        // implemented. Without it the only way out of a snooze was `requeued`,
        // so a nudge nobody requeued never reached `recorded` and never
        // reached the outcome log receptivity learns from. Mirrors nudge.py.
        .init(.snoozed, "snoozeWindowClosed", .expired,
              guardText: "the window passed before anything requeued it"),
        .init(.accepted, "outcomeLogged", .recorded),
        .init(.dismissed, "outcomeLogged", .recorded),
        .init(.expired, "outcomeLogged", .recorded),
        .init(.suppressed, "outcomeLogged", .recorded),
    ]
}

/// The classes an agent may bid in. A model asked to name a class without being
/// shown the vocabulary invents one, and a contract then suspends a class that
/// does not exist - silently doing nothing.
public enum NudgeClassVocabulary {
    public static let known = ["hydration", "sedentary", "bedtimePrep", "mealLog", "movement"]
    public static func isKnown(_ c: String) -> Bool { known.contains(c) }
    /// Nearest known class, or nil. Models reach for plausible synonyms.
    public static func normalise(_ c: String) -> String? {
        let lower = c.lowercased()
        if let exact = known.first(where: { $0.lowercased() == lower }) { return exact }
        switch lower {
        case "water", "drink", "fluid":                    return "hydration"
        case "sitting", "sedentarybreak", "standup":       return "sedentary"
        case "sleep", "bedtime", "winddown", "wind_down":  return "bedtimePrep"
        case "meal", "food", "logging", "meallogging":     return "mealLog"
        case "exercise", "activity", "walk":               return "movement"
        default:                                           return nil
        }
    }
}

public enum NudgeChannelKind: String, Sendable, CaseIterable {
    case watchHaptic, push, inApp, silentHold
}

/// Why an intervention could not be delivered as written (NFR11).
public enum Capability: String, Sendable, CaseIterable, Hashable {
    case standing, walking, hearing, vision, fineMotor
}

public struct NudgeBid: Sendable, Equatable {
    public let id: String
    public let nudgeClass: String          // "hydration", "sedentary", "bedtimePrep"
    public let originAgent: String
    public let expectedBenefit: Double     // 0...1
    public let urgency: Double             // 0...1
    public let windowOpens: Date
    public let windowCloses: Date
    public let requiredCapabilities: Set<Capability>
    public let text: String

    public init(id: String, nudgeClass: String, originAgent: String,
                expectedBenefit: Double, urgency: Double,
                windowOpens: Date, windowCloses: Date,
                requiredCapabilities: Set<Capability> = [],
                text: String) {
        self.id = id
        self.nudgeClass = nudgeClass
        self.originAgent = originAgent
        self.expectedBenefit = expectedBenefit
        self.urgency = urgency
        self.windowOpens = windowOpens
        self.windowCloses = windowCloses
        self.requiredCapabilities = requiredCapabilities
        self.text = text
    }

    public func isOpen(at t: Date) -> Bool { t >= windowOpens && t <= windowCloses }
}

public enum SuppressionReason: String, Sendable, CaseIterable {
    case budgetExhausted, quietHours, outranked, costCeiling, classSuspended
    case windowNotOpen, windowClosed, inaccessible, duplicateClass
    /// CF6 - nothing measured in this domain, so nothing may be claimed about it.
    case ungrounded
    /// The Steward refused the wording, so nothing was sent and the attention
    /// budget was not spent on it. Distinct from `ungrounded`: there *was*
    /// evidence, and the sentence built on it did not clear the safety gate.
    /// The backend emits this on `/v1/arbitrate`; a client that folded it into
    /// `outranked` would tell the user a contest happened that never did.
    case safetyRefused
    /// The policy from Section 7.1: a cost suppression is never dressed up as restraint.
    public var isPresentableAsRestraint: Bool { self != .costCeiling }
}

public struct Nudge: Sendable {
    public let bid: NudgeBid
    public var lifecycle: Lifecycle<NudgeState>
    public var score: Double = 0
    public var receptivity: Double = 0
    public var channel: NudgeChannelKind?
    public var suppressionReason: SuppressionReason?

    public init(bid: NudgeBid) {
        self.bid = bid
        self.lifecycle = Lifecycle()
    }
    public var state: NudgeState { lifecycle.state }
}

public struct NudgeSchedule: Sendable {
    public let dayStart: Date
    public let dailyBudget: Int
    public private(set) var spent: Int
    public init(dayStart: Date, dailyBudget: Int = 6, spent: Int = 0) {
        self.dayStart = dayStart
        self.dailyBudget = dailyBudget
        self.spent = spent
    }
    public var remaining: Int { max(0, dailyBudget - spent) }
    public mutating func spendOne() { spent += 1 }
}
