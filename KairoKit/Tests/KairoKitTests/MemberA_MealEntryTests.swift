import Testing
import Foundation
@testable import KairoKit

/// Member A - CF1 / OF1. The behaviour that distinguishes Kairo from every
/// photo calorie counter on the market is the path it takes when it does *not* know.
@Suite("Member A - meal logging")
struct MealEntryTests {
    let t = DateHelp.at(2026, 8, 25, 12, 30)

    @Test("a confident recognition goes straight to an estimate")
    func confidentPath() throws {
        var m = MealEntry(id: "meal-1", capturedAt: t)
        try m.lifecycle.transition(on: "beginRecognition", to: .classifying, at: t)
        try m.lifecycle.transition(on: "confidenceAccepted", to: .estimated, at: t)
        try m.lifecycle.transition(on: "userConfirmed", to: .confirmed, at: t)
        try m.lifecycle.transition(on: "written", to: .logged, at: t)
        #expect(m.state == .logged)
    }

    @Test("an ungrounded dish is never estimated without being taught first")
    func ungroundedDishCannotShortcutToEstimate() throws {
        var m = MealEntry(id: "meal-2", capturedAt: t)
        try m.lifecycle.transition(on: "beginRecognition", to: .classifying, at: t)
        try m.lifecycle.transition(on: "noGroundingFound", to: .ungrounded, at: t)
        // This is the guess the whole feature exists to forbid.
        #expect(throws: LifecycleError<MealEntryState>.self) {
            try m.lifecycle.transition(on: "confidenceAccepted", to: .estimated, at: t)
        }
        try m.lifecycle.transition(on: "teachRequested", to: .awaitingTeaching, at: t)
        try m.lifecycle.transition(on: "dishTaught", to: .estimated, at: t)
        m.taughtByUser = true
        #expect(m.state == .estimated)
        #expect(m.taughtByUser)
    }

    @Test("the estimate is only as confident as its weakest item")
    func confidenceIsTheMinimum() {
        let m = MealEntry(id: "meal-3", capturedAt: t, items: [
            FoodItem(name: "rice", grams: 180, facts: NutritionFacts(kilojoules: 1000), confidence: 0.91),
            FoodItem(name: "unidentified braise", grams: 200, facts: NutritionFacts(kilojoules: 1400), confidence: 0.38),
        ])
        #expect(m.confidence == 0.38)
        #expect(m.totalKilojoules == 2400)
    }

    @Test("kilojoules are stored, calories are derived (NFR14)")
    func kilojoulesAreCanonical() {
        let f = NutritionFacts(kilojoules: 8700)
        #expect(abs(f.calories - 2079.35) < 0.5)
    }
}

/// Member A - CF3. Roles disagree on purpose; the ruling is written policy, not a vibe.
@Suite("Member A - structured dissent")
struct DissentTests {
    @Test("safety outranks accuracy which outranks adherence")
    func precedenceRules() {
        let accuracy = Position(agent: .nutrition, objective: .accuracy,
                                claim: "you are 1,700 kJ over today",
                                evidence: ["meal-1", "meal-2"], confidence: 0.82, costIfWrong: 0.3)
        let adherence = Position(agent: .coach, objective: .adherence,
                                 claim: "do not raise restriction during recovery",
                                 evidence: ["contract-9"], confidence: 0.75, costIfWrong: 0.6)
        var c = DisagreementCase(id: "d-1", topic: "daily energy message", positions: [accuracy, adherence])
        guard case let .ruled(winner, policy) = c.resolve() else {
            Issue.record("expected a ruling"); return
        }
        #expect(winner.objective == .accuracy)
        #expect(policy.contains("safety"))
    }

    @Test("the Steward may not rule on a clinical disagreement")
    func clinicalGoesToFounder() {
        let a = Position(agent: .lifestyle, objective: .safety, claim: "resting HR is abnormal",
                         evidence: ["hr-week"], confidence: 0.7, costIfWrong: 0.9)
        let b = Position(agent: .coach, objective: .adherence, claim: "keep the plan",
                         evidence: [], confidence: 0.5, costIfWrong: 0.4)
        var c = DisagreementCase(id: "d-2", topic: "possible clinical deterioration", positions: [a, b])
        guard case let .referredToFounder(reason) = c.resolve() else {
            Issue.record("clinical topics must not be ruled by the Steward"); return
        }
        #expect(reason.contains("clinical"))
    }

    @Test("rebuttals are bounded at two rounds")
    func roundsAreBounded() {
        let p = Position(agent: .nutrition, objective: .accuracy, claim: "x",
                         evidence: [], confidence: 0.5, costIfWrong: 0.1)
        var c = DisagreementCase(id: "d-3", topic: "portion", positions: [p])
        let first = c.addRebuttal(p)
        let second = c.addRebuttal(p)
        let third = c.addRebuttal(p)
        #expect(first)
        #expect(second)
        #expect(!third, "a third rebuttal must be refused")
    }
}
