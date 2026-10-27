import Testing
import Foundation
@testable import KairoKit

/// Figure 34 (UC2) — the states that existed only as a diagram.
///
/// `resolve()` used to answer identically whether it was called on a case that
/// had been through the procedure or one created a line earlier, so the
/// rebuttal round the diagram counts was a number nobody could be stopped from
/// skipping. The backend's `test_the_case_walks_the_drawn_path_rather_than_short_circuiting`
/// pins the same walk.
@Suite("Member A — disagreement case lifecycle")
struct DisagreementCaseLifecycleTests {

    private func position(_ agent: AgentID, _ objective: Objective) -> Position {
        Position(agent: agent, objective: objective, claim: "claim",
                 evidence: ["evidence"], confidence: 0.7, costIfWrong: 0.5)
    }

    @Test("a ruling walks open → underRebuttal → deadlocked → resolved")
    func drawnPath() {
        var c = DisagreementCase(id: "d1", topic: "today energy message", positions: [
            position(.nutrition, .accuracy), position(.coach, .adherence)])
        #expect(c.state == .open)
        c.resolve()
        #expect(c.lifecycle.history.map(\.to) == [.underRebuttal, .deadlocked, .resolved])
    }

    @Test("a clinical deadlock passes through escalated")
    func clinicalEscalates() {
        // The clinical branch sits under DEADLOCKED, so the record shows a
        // human was notified rather than merely that the outcome was named
        // for one.
        var c = DisagreementCase(id: "d2", topic: "possible clinical deterioration",
                                 positions: [position(.steward, .safety),
                                             position(.coach, .adherence)])
        c.resolve()
        #expect(c.state == .escalated)
        #expect(c.lifecycle.history.contains { $0.to == .escalated })
    }

    @Test("an operator ruling is only reachable after escalation")
    func operatorRulingNeedsEscalation() throws {
        // AG-5 — the human's answer outranks every AI position. Nothing may
        // record one on a case no human was ever shown.
        let p = position(.coach, .adherence)
        var neverEscalated = DisagreementCase(id: "d3", topic: "portion size",
                                              positions: [position(.nutrition, .accuracy), p])
        neverEscalated.resolve()
        #expect(neverEscalated.state == .resolved)
        #expect(throws: (any Error).self) { try neverEscalated.ruleOn(p) }

        var escalated = DisagreementCase(id: "d4", topic: "possible clinical deterioration",
                                         positions: [position(.steward, .safety), p])
        escalated.resolve()
        try escalated.ruleOn(p)
        #expect(escalated.state == .resolved)
    }

    @Test("both branches of the screen end sealed")
    func sealedEitherWay() throws {
        for releasable in [true, false] {
            var c = DisagreementCase(id: "d5", topic: "today energy message", positions: [
                position(.nutrition, .accuracy), position(.coach, .adherence)])
            c.resolve()
            try c.seal(releasable: releasable)
            #expect(c.state == .sealed)
            #expect(c.lifecycle.isTerminal)
        }
    }

    @Test("a third rebuttal is refused by the budget and the machine")
    func rebuttalsBounded() {
        let p = position(.nutrition, .accuracy)
        var c = DisagreementCase(id: "d6", topic: "portion", positions: [p])
        // Hoisted: `#expect` evaluates its argument inside a closure that
        // captures `c` immutably, so a mutating call has to happen outside it.
        let first = c.addRebuttal(p)
        let second = c.addRebuttal(p)
        let third = c.addRebuttal(p)
        #expect(first && second)
        #expect(!third, "a third rebuttal must be refused")
        #expect(c.rounds == 2)
        #expect(c.lifecycle.history.map(\.event) == ["positionsComplete", "nextRound", "nextRound"])
    }
}
