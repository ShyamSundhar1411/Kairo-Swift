import Testing
import Foundation
@testable import KairoKit

/// The Tuesday 15:40 scenario, reproduced exactly as it is drawn in the object
/// diagram of the original design document. If the report and the code ever disagree,
/// this test fails.
@Suite("Arbitration - the object diagram, executed")
struct ArbitrationScenarioTests {

    static let now = DateHelp.at(2026, 8, 25, 15, 40)   // Tuesday 15:40

    static func memories() -> [MemoryItem] {
        var m17 = MemoryItem(id: "m17", text: "ignores nudges before 9am",
                             confidence: 0.81, sourceRef: "nudge-outcomes")
        _ = try? m17.lifecycle.transition(on: "corroboratedByBehaviour", to: .verified, at: now)
        _ = try? m17.lifecycle.transition(on: "promoted", to: .active, at: now)

        var m23 = MemoryItem(id: "m23", text: "lactose intolerant", confidence: 0.97,
                             sensitivity: .health, sourceRef: "user", decayExempt: true)
        _ = try? m23.lifecycle.transition(on: "userConfirmed", to: .verified, at: now)
        _ = try? m23.lifecycle.transition(on: "promoted", to: .active, at: now)
        return [m17, m23]
    }

    static func bids() -> [NudgeBid] {
        [
            NudgeBid(id: "b1", nudgeClass: "hydration", originAgent: AgentID.coach.rawValue,
                     expectedBenefit: 0.60, urgency: 0.3,
                     windowOpens: now.addingTimeInterval(-3600),
                     windowCloses: now.addingTimeInterval(3600),
                     text: "340 ml behind target"),
            NudgeBid(id: "b2", nudgeClass: "sedentary", originAgent: AgentID.lifestyle.rawValue,
                     expectedBenefit: 0.79, urgency: 0.7,
                     windowOpens: now.addingTimeInterval(-600),
                     windowCloses: now.addingTimeInterval(1800),
                     requiredCapabilities: [.standing, .walking],
                     text: "82 minutes unbroken - 90 second walk"),
            NudgeBid(id: "b3", nudgeClass: "bedtimePrep", originAgent: AgentID.lifestyle.rawValue,
                     expectedBenefit: 0.55, urgency: 0.2,
                     windowOpens: DateHelp.at(2026, 8, 25, 21, 30),
                     windowCloses: DateHelp.at(2026, 8, 25, 23, 0),
                     text: "start winding down"),
        ]
    }

    static let model = TableReceptivityModel([
        "hydration": 0.70, "sedentary": 0.90, "bedtimePrep": 0.60,
    ])

    func input(budget: Int = 6, spent: Int = 4,
               quiet: Bool = false,
               profile: CapabilityProfile = .unrestricted,
               contract: PlanContract? = nil,
               cost: Money = Money(cents: 10_000)) -> ArbitrationInput {
        ArbitrationInput(
            now: Self.now,
            schedule: NudgeSchedule(dayStart: DateHelp.at(2026, 8, 25), dailyBudget: budget, spent: spent),
            bids: Self.bids(), memories: Self.memories(),
            profile: profile, activeContract: contract, quietHours: quiet, costRemaining: cost)
    }

    func rounded(_ d: Double) -> Double { (d * 100).rounded() / 100 }

    @Test("scores match the figures printed in the report")
    func scoresMatchTheDiagram() throws {
        let r = try NudgeArbiter(receptivity: Self.model).arbitrate(input(), recordID: "dr-41")
        #expect(rounded(r.nudge(forClass: "hydration")!.score)   == 0.42)
        #expect(rounded(r.nudge(forClass: "sedentary")!.score)   == 0.71)
        #expect(rounded(r.nudge(forClass: "bedtimePrep")!.score) == 0.33)
    }

    @Test("the sedentary bid wins and is delivered to the watch")
    func sedentaryWins() throws {
        let r = try NudgeArbiter(receptivity: Self.model).arbitrate(input(), recordID: "dr-41")
        #expect(r.delivered.count == 1)
        #expect(r.delivered.first?.bid.nudgeClass == "sedentary")
        #expect(r.delivered.first?.channel == .watchHaptic)
        #expect(r.delivered.first?.state == .scheduled)
        #expect(r.schedule.spent == 5)
    }

    @Test("the losers are suppressed for the reasons the report gives")
    func losersHaveReasons() throws {
        let r = try NudgeArbiter(receptivity: Self.model).arbitrate(input(), recordID: "dr-41")
        #expect(r.nudge(forClass: "hydration")?.suppressionReason == .outranked)
        #expect(r.nudge(forClass: "bedtimePrep")?.suppressionReason == .windowNotOpen)
    }

    @Test("the sealed record carries the bids that lost")
    func recordCarriesRejectedAlternatives() throws {
        let r = try NudgeArbiter(receptivity: Self.model).arbitrate(input(), recordID: "dr-41")
        #expect(r.record.isSealed)
        #expect(Set(r.record.rejectedAlternatives.map(\.bidID)) == ["b1", "b3"])
        #expect(r.record.contributingAgents.contains(AgentID.lifestyle.rawValue))
        #expect(r.record.citations.contains { $0.memoryID == "m17" && $0.confidenceAtCitation == 0.81 })
    }

    // MARK: - Spending nothing is a legitimate outcome

    @Test("an exhausted budget delivers nothing at all")
    func exhaustedBudgetSpendsNothing() throws {
        let r = try NudgeArbiter(receptivity: Self.model).arbitrate(input(spent: 6), recordID: "dr-42")
        #expect(r.spentNothing)
        #expect(r.nudge(forClass: "sedentary")?.suppressionReason == .budgetExhausted)
    }

    @Test("quiet hours suppress everything, including the winner")
    func quietHoursSuppressAll() throws {
        let r = try NudgeArbiter(receptivity: Self.model).arbitrate(input(quiet: true), recordID: "dr-43")
        #expect(r.spentNothing)
        // A bid whose window has not opened never competed, so it is not a
        // quiet-hours suppression - it simply was not due.
        let competed = r.suppressed.filter { $0.suppressionReason != .windowNotOpen }
        #expect(competed.count == 2)
        #expect(competed.allSatisfy { $0.suppressionReason == .quietHours })
    }

    /// Section 7.1: a suppression bought by the cost ceiling must be recorded as
    /// a cost suppression, never dressed up to the user as restraint.
    @Test("a cost suppression is never presentable as restraint")
    func costSuppressionIsLabelledHonestly() throws {
        let r = try NudgeArbiter(receptivity: Self.model)
            .arbitrate(input(cost: Money(cents: 0)), recordID: "dr-44")
        #expect(r.spentNothing)
        let winner = r.nudge(forClass: "sedentary")!
        #expect(winner.suppressionReason == .costCeiling)
        #expect(winner.suppressionReason?.isPresentableAsRestraint == false)
    }

    // MARK: - NFR11

    /// CF5's premise is undeliverable to a wheelchair user. The bid must not be
    /// silently dropped, and must not be delivered as written either.
    @Test("a nudge the user cannot act on is refused when no equivalent exists")
    func inaccessibleWithoutEquivalent() throws {
        let profile = CapabilityProfile(available: [.hearing, .vision, .fineMotor])
        let r = try NudgeArbiter(receptivity: Self.model).arbitrate(input(profile: profile), recordID: "dr-45")
        #expect(r.nudge(forClass: "sedentary")?.suppressionReason == .inaccessible)
        #expect(r.delivered.first?.bid.nudgeClass == "hydration",
                "the next-best actionable bid should win instead")
    }

    @Test("a confirmed equivalent lets the same bid through, rewritten")
    func inaccessibleWithEquivalent() throws {
        let profile = CapabilityProfile(
            available: [.hearing, .vision, .fineMotor],
            equivalents: [.standing: "roll break", .walking: "push count"])
        let r = try NudgeArbiter(receptivity: Self.model).arbitrate(input(profile: profile), recordID: "dr-46")
        #expect(r.delivered.first?.bid.nudgeClass == "sedentary")
    }

    // MARK: - CF9 interaction

    @Test("an active contract suspends the nudge classes it named")
    func contractSuspendsClasses() throws {
        var c = PlanContract(id: "pc-live")
        try c.lifecycle.transition(on: "signalDetected", to: .disruptionSuspected, at: Self.now)
        try c.lifecycle.transition(on: "corroborated", to: .proposed, at: Self.now)
        try c.lifecycle.transition(on: "userAccepted", to: .active, at: Self.now)
        c.suspended = [SuspendedNudgeClass("sedentary")]

        let r = try NudgeArbiter(receptivity: Self.model).arbitrate(input(contract: c), recordID: "dr-47")
        #expect(r.nudge(forClass: "sedentary")?.suppressionReason == .classSuspended)
        #expect(r.delivered.first?.bid.nudgeClass == "hydration")
    }
}

/// CF6 applied where it matters: to the interruptions the user actually receives.
///
/// The gate existed and was reachable from one badge on one screen, so every
/// nudge the arbiter delivered went out unscreened. These pin it to the path.
@Suite("CF6 - a bid the readings cannot support is not delivered")
struct EvidenceGateTests {
    private let now = DateHelp.at(2026, 9, 10, 15, 40)

    private func bid(_ cls: String, benefit: Double = 0.8) -> NudgeBid {
        NudgeBid(id: "b-\(cls)", nudgeClass: cls, originAgent: "role",
                 expectedBenefit: benefit, urgency: 0.5,
                 windowOpens: now.addingTimeInterval(-600),
                 windowCloses: now.addingTimeInterval(1800),
                 text: "something about \(cls)")
    }

    private func arbiter() -> NudgeArbiter {
        NudgeArbiter(receptivity: TableReceptivityModel(["mealLog": 0.9, "hydration": 0.9]))
    }

    private func coverage(_ metrics: [CoverageMetric]) -> DayCoverage {
        var c = DayCoverage(dayStart: Calendar.current.startOfDay(for: now))
        metrics.forEach { c.record($0) }
        return c
    }

    @Test("a claim about a domain nothing measured is suppressed as ungrounded")
    func unmeasuredDomainIsSuppressed() throws {
        let result = try arbiter().arbitrate(ArbitrationInput(
            now: now, schedule: NudgeSchedule(dayStart: now, dailyBudget: 6, spent: 0),
            bids: [bid("mealLog")], coverage: coverage([])), recordID: "dr-1")

        #expect(result.delivered.isEmpty)
        #expect(result.suppressed.first?.suppressionReason == .ungrounded)
        #expect(result.suppressed.first?.state == .suppressed)
    }

    @Test("the suppression is restraint, and is shown as such")
    func ungroundedIsPresentableAsRestraint() {
        // Unlike a cost suppression: declining to speak without evidence is a
        // decision the user is entitled to see credited.
        #expect(SuppressionReason.ungrounded.isPresentableAsRestraint)
    }

    @Test("a measured domain is unaffected")
    func measuredDomainCompetesNormally() throws {
        let result = try arbiter().arbitrate(ArbitrationInput(
            now: now, schedule: NudgeSchedule(dayStart: now, dailyBudget: 6, spent: 0),
            bids: [bid("hydration")],
            coverage: coverage([CoverageMetric(domain: .hydration,
                                               observedCount: 5, expectedCount: 5)])),
            recordID: "dr-2")
        #expect(result.delivered.count == 1)
    }

    @Test("without coverage the arbiter does not check, and says so by doing nothing")
    func noCoverageMeansNoCheck() throws {
        // The old behaviour, kept reachable on purpose: an arbiter with no
        // coverage has not been told what was measured, which is different from
        // being told nothing was.
        let result = try arbiter().arbitrate(ArbitrationInput(
            now: now, schedule: NudgeSchedule(dayStart: now, dailyBudget: 6, spent: 0),
            bids: [bid("mealLog")]), recordID: "dr-3")
        #expect(result.delivered.count == 1)
    }

    @Test("a class that claims nothing measurable is not gated")
    func unmappedClassPasses() throws {
        let result = try arbiter().arbitrate(ArbitrationInput(
            now: now, schedule: NudgeSchedule(dayStart: now, dailyBudget: 6, spent: 0),
            bids: [bid("checkIn")], coverage: coverage([])), recordID: "dr-4")
        #expect(result.delivered.count == 1)
    }
}
