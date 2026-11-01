import Testing
import Foundation
@testable import KairoKit

/// Member B - CF6. The contribution is not a better sleep number; it is
/// governing when a number may be spoken at all.
@Suite("Member B - evidence sufficiency")
struct CoverageTests {
    let day = DateHelp.at(2026, 8, 25)

    func coverage(meals: Int, expectedMeals: Int = 3, wear: Int = 22) -> DayCoverage {
        var c = DayCoverage(dayStart: day)
        c.record(CoverageMetric(domain: .meals, observedCount: meals, expectedCount: expectedMeals))
        c.record(CoverageMetric(domain: .sleep, observedCount: 1, expectedCount: 1))
        c.record(CoverageMetric(domain: .movement, observedCount: wear, expectedCount: 24))
        c.record(CoverageMetric(domain: .hydration, observedCount: 5, expectedCount: 5))
        return c
    }

    @Test("full coverage permits a bare assertion")
    func fullCoverage() {
        #expect(coverage(meals: 3).permittedForm(for: .meals) == .assertion)
    }

    @Test("two of three meals downgrades a total to a qualified claim")
    func partialCoverage() {
        #expect(coverage(meals: 2).permittedForm(for: .meals) == .qualified)
    }

    @Test("one of three meals may only produce a range")
    func thinCoverage() {
        #expect(coverage(meals: 1).permittedForm(for: .meals) == .range)
    }

    @Test("no data at all forbids the claim entirely")
    func noCoverage() {
        #expect(coverage(meals: 0).permittedForm(for: .meals) == .forbidden)
    }

    @Test("a sealed day reopens when late data arrives")
    func lateDataReopens() throws {
        var c = coverage(meals: 3)
        let t = day
        try c.lifecycle.transition(on: "firstSampleArrived", to: .partial, at: t)
        try c.lifecycle.transition(on: "coverageReachedFloor", to: .sufficient, at: t)
        try c.lifecycle.transition(on: "dayEnded", to: .sealed, at: t)
        try c.lifecycle.transition(on: "lateDataArrived", to: .reopened, at: t)
        try c.lifecycle.transition(on: "recomputed", to: .sealed, at: t)
        #expect(c.state == .sealed)
        #expect(c.lifecycle.visited(.reopened))
    }

    /// The sequence diagram in Member B's chain: the Steward rejects the Coach's
    /// own outbound message and hands back a weaker form of it.
    @Test("the Steward downgrades the Coach's own message when evidence is thin")
    func stewardDowngradesTheCoach() {
        let gate = SafetyGate()
        let thin = coverage(meals: 1)
        let verdict = gate.screen("You are 1700 kJ over your target today.",
                                  locale: "en-AU", claimDomain: .meals, coverage: thin)
        guard case let .downgraded(text, form) = verdict else {
            Issue.record("expected a downgrade, got \(verdict)"); return
        }
        #expect(form == .range)
        #expect(!text.contains("1700"))
    }

    @Test("full coverage lets the same sentence through untouched")
    func fullCoveragePasses() {
        let gate = SafetyGate()
        let verdict = gate.screen("You are 1700 kJ over your target today.",
                                  locale: "en-AU", claimDomain: .meals, coverage: coverage(meals: 3))
        guard case let .pass(text) = verdict else {
            Issue.record("expected a pass, got \(verdict)"); return
        }
        #expect(text.contains("1700"))
    }
}

/// NFR7 - the hole the multi-lens sweep found in the first draft of the report.
@Suite("Safety gate honesty")
struct SafetyGateTests {
    @Test("a red-flag pattern is blocked")
    func redFlagBlocked() {
        guard case .blocked = SafetyGate().screen("Try to skip meals tomorrow.", locale: "en-AU") else {
            Issue.record("red flag must be blocked"); return
        }
    }

    @Test("input outside declared language competence is held, never silently passed")
    func outsideCompetenceIsHeld() {
        // The classifier was validated in English only. Passing this would be a
        // silent safety failure, which is the worst kind.
        guard case let .heldForHuman(why) = SafetyGate().screen("我最近都不太想吃东西", locale: "zh-Hans") else {
            Issue.record("must not silently pass untested locales"); return
        }
        #expect(why.contains("competence"))
    }

    @Test("an unavailable classifier fails closed")
    func failsClosed() {
        guard case .heldForHuman = SafetyGate().screen("anything", locale: "en-AU", classifierAvailable: false) else {
            Issue.record("must fail closed"); return
        }
    }
}
