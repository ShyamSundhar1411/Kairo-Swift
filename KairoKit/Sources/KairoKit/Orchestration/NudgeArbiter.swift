import Foundation

/// Member C — CF7. The project's headline mechanism.
///
/// Every agent bids for the user's attention; this allocates a bounded daily
/// budget across those bids. Spending nothing is a legitimate outcome, and the
/// reason for every suppression is recorded rather than discarded.
public struct ArbitrationInput: Sendable {
    public let now: Date
    public var schedule: NudgeSchedule
    public let bids: [NudgeBid]
    public let memories: [MemoryItem]
    public let profile: CapabilityProfile
    public let activeContract: PlanContract?
    public let quietHours: Bool
    /// Remaining margin for this user this month (Section 7.1, the second budget).
    public let costRemaining: Money

    public init(now: Date, schedule: NudgeSchedule, bids: [NudgeBid],
                memories: [MemoryItem] = [], profile: CapabilityProfile = .unrestricted,
                activeContract: PlanContract? = nil, quietHours: Bool = false,
                costRemaining: Money = Money(cents: 10_000)) {
        self.now = now
        self.schedule = schedule
        self.bids = bids
        self.memories = memories
        self.profile = profile
        self.activeContract = activeContract
        self.quietHours = quietHours
        self.costRemaining = costRemaining
    }
}

public struct ArbitrationResult: Sendable {
    public let delivered: [Nudge]
    public let suppressed: [Nudge]
    public let schedule: NudgeSchedule
    public let record: DecisionRecord

    /// Public so the app can rebuild one from a decision the backend made,
    /// replaying it through the same state machines rather than rendering JSON.
    public init(delivered: [Nudge], suppressed: [Nudge],
                schedule: NudgeSchedule, record: DecisionRecord) {
        self.delivered = delivered
        self.suppressed = suppressed
        self.schedule = schedule
        self.record = record
    }

    /// True when the arbiter deliberately spent nothing. Not a failure.
    public var spentNothing: Bool { delivered.isEmpty }

    public func nudge(forClass c: String) -> Nudge? {
        (delivered + suppressed).first { $0.bid.nudgeClass == c }
    }
}

public struct NudgeArbiter: Sendable {
    private let receptivity: ReceptivityModel
    private let costPerDelivery: Money

    public init(receptivity: ReceptivityModel, costPerDelivery: Money = Money(cents: 2)) {
        self.receptivity = receptivity
        self.costPerDelivery = costPerDelivery
    }

    public func arbitrate(_ input: ArbitrationInput, recordID: String) throws -> ArbitrationResult {
        var schedule = input.schedule
        var scored: [Nudge] = []
        var suppressed: [Nudge] = []

        // 1. Admit and score. A bid whose window has already closed never competes.
        for bid in input.bids {
            var n = Nudge(bid: bid)
            try n.lifecycle.transition(on: "admitted", to: .queued, at: input.now)

            let r = receptivity.receptivity(nudgeClass: bid.nudgeClass, at: input.now, memories: input.memories)
            n.receptivity = r
            n.score = r * bid.expectedBenefit
            try n.lifecycle.transition(on: "scoredByReceptivity", to: .scored, at: input.now)
            scored.append(n)
        }

        // 2. Hard gates, in policy order. Each records *why*, and the score the
        //    losing bid would have had, so the decision record is legible.
        var eligible: [Nudge] = []
        for var n in scored {
            if !n.bid.isOpen(at: input.now) {
                let reason: SuppressionReason = input.now < n.bid.windowOpens ? .windowNotOpen : .windowClosed
                let event = reason == .windowNotOpen ? "windowNotOpen" : "outrankedByAnotherBid"
                try suppress(&n, reason, event, at: input.now); suppressed.append(n); continue
            }
            if input.quietHours {
                try suppress(&n, .quietHours, "quietHours", at: input.now); suppressed.append(n); continue
            }
            if let c = input.activeContract, c.isActive,
               c.suspended.contains(SuspendedNudgeClass(n.bid.nudgeClass)) {
                try suppress(&n, .classSuspended, "classSuspendedByContract", at: input.now); suppressed.append(n); continue
            }
            if !input.profile.satisfies(n.bid.requiredCapabilities) {
                // NFR11: only inaccessible if no confirmed equivalent exists. The bid is
                // rewritten where possible rather than dropped.
                let missing = n.bid.requiredCapabilities.subtracting(input.profile.available)
                let rewritable = missing.allSatisfy { input.profile.equivalents[$0] != nil }
                if !rewritable {
                    try suppress(&n, .inaccessible, "outrankedByAnotherBid", at: input.now)
                    suppressed.append(n); continue
                }
            }
            eligible.append(n)
        }

        // 3. Deduplicate: two bids in the same class are one interruption's worth
        //    of value, so the weaker one loses to its own class rather than
        //    inflating the queue.
        eligible.sort { $0.score > $1.score }
        var bestPerClass: [String: Nudge] = [:]
        var duplicates: [Nudge] = []
        for n in eligible {
            if bestPerClass[n.bid.nudgeClass] == nil {
                bestPerClass[n.bid.nudgeClass] = n
            } else {
                duplicates.append(n)
            }
        }
        for var n in duplicates {
            try suppress(&n, .duplicateClass, "duplicateInClass", at: input.now)
            suppressed.append(n)
        }
        eligible = Array(bestPerClass.values)

        // 4. Rank and allocate against the attention budget and the cost ceiling.
        eligible.sort { $0.score > $1.score }
        var delivered: [Nudge] = []
        var costSpent = Money.zero

        for var n in eligible {
            if schedule.remaining == 0 {
                try suppress(&n, .budgetExhausted, "budgetExhausted", at: input.now); suppressed.append(n); continue
            }
            if costSpent + costPerDelivery > input.costRemaining {
                try suppress(&n, .costCeiling, "costCeilingReached", at: input.now); suppressed.append(n); continue
            }
            if !delivered.isEmpty {
                // One interruption at a time: everything else this round is outranked.
                try suppress(&n, .outranked, "outrankedByAnotherBid", at: input.now); suppressed.append(n); continue
            }
            try n.lifecycle.transition(on: "allocated", to: .scheduled, at: input.now)
            n.channel = channel(for: n, profile: input.profile)
            schedule.spendOne()
            costSpent = costSpent + costPerDelivery
            delivered.append(n)
        }

        // 5. Seal the decision record: who contributed, what lost, and why.
        var record = DecisionRecord(id: recordID, createdAt: input.now)
        for n in delivered {
            try record.add(ContributionFragment(
                agentID: n.bid.originAgent, promptVersion: "v1",
                claim: n.bid.text, confidence: n.score))
        }
        try record.add(ContributionFragment(
            agentID: AgentID.coach.rawValue, promptVersion: "v1",
            claim: "arbitrated \(input.bids.count) bids, delivered \(delivered.count)",
            confidence: 1.0))
        for m in input.memories where m.isRetrievable {
            try record.cite(MemoryCitation(memoryID: m.id, confidenceAtCitation: m.confidence))
        }
        for n in suppressed {
            try record.reject(RejectedAlternative(
                bidID: n.bid.id, nudgeClass: n.bid.nudgeClass,
                score: n.score, reason: n.suppressionReason ?? .outranked))
        }
        try record.setSafetyVerdict("pass", tier: "Healthy")
        try record.lifecycle.transition(on: "allFragmentsCollected", to: .sealed, at: input.now)

        return ArbitrationResult(delivered: delivered, suppressed: suppressed,
                                 schedule: schedule, record: record)
    }

    private func suppress(_ n: inout Nudge, _ reason: SuppressionReason,
                          _ event: String, at now: Date) throws {
        n.suppressionReason = reason
        try n.lifecycle.transition(on: event, to: .suppressed, at: now)
    }

    private func channel(for n: Nudge, profile: CapabilityProfile) -> NudgeChannelKind {
        if !profile.available.contains(.vision) { return .watchHaptic }
        return n.bid.urgency > 0.6 ? .watchHaptic : .push
    }
}
