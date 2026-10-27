import Testing
import Foundation
@testable import KairoKit

// MARK: - FR6.4

@Suite("CF6 — low coverage competes for attention rather than interrupting")
struct CoverageBidTests {
    private func coverage(meals: (Int, Int) = (3, 3), sleep: (Int, Int) = (1, 1),
                          movement: (Int, Int) = (24, 24),
                          hydration: (Int, Int) = (5, 5)) -> DayCoverage {
        var c = DayCoverage(dayStart: DateHelp.at(2026, 8, 25))
        c.record(CoverageMetric(domain: .meals, observedCount: meals.0, expectedCount: meals.1))
        c.record(CoverageMetric(domain: .sleep, observedCount: sleep.0, expectedCount: sleep.1))
        c.record(CoverageMetric(domain: .movement, observedCount: movement.0, expectedCount: movement.1))
        c.record(CoverageMetric(domain: .hydration, observedCount: hydration.0, expectedCount: hydration.1))
        return c
    }

    @Test("a fully covered day raises nothing, and costs nothing")
    func quietWhenCovered() {
        #expect(CoverageBid.bid(for: coverage(), dayStart: DateHelp.at(2026, 8, 25),
                                calendar: DateHelp.calendar) == nil)
        #expect(CoverageBid.text(for: coverage()).isEmpty)
    }

    @Test("a domain under the floor is named, worst first")
    func namesTheWorst() {
        let c = coverage(meals: (1, 3), sleep: (0, 1))
        #expect(CoverageBid.shortfalls(in: c).map(\.rawValue) == ["sleep", "meals"])
    }

    @Test("the user is told what cannot be said, not a coverage percentage")
    func noPercentages() {
        let text = CoverageBid.text(for: coverage(sleep: (0, 1)))
        #expect(text.contains("sleep"))
        #expect(!text.contains("%"))
    }

    @Test("it is low priority by construction, so a real finding outranks it")
    func lowPriority() {
        let bid = CoverageBid.bid(for: coverage(meals: (0, 3)),
                                  dayStart: DateHelp.at(2026, 8, 25),
                                  calendar: DateHelp.calendar)
        #expect(bid?.expectedBenefit == 0.25)
        #expect((bid?.urgency ?? 1) < (bid?.expectedBenefit ?? 0))
    }

    @Test("the window is the whole day, because a shortfall is not a moment")
    func wholeDay() {
        let day = DateHelp.at(2026, 8, 25)
        let bid = CoverageBid.bid(for: coverage(meals: (0, 3)), dayStart: day,
                                  calendar: DateHelp.calendar)
        #expect(bid?.windowOpens == day)
        #expect(bid?.isOpen(at: DateHelp.at(2026, 8, 25, 23, 0)) == true)
    }

    @Test("one bid per day, not one per round")
    func oneBidPerDay() {
        let day = DateHelp.at(2026, 8, 25)
        let a = CoverageBid.bid(for: coverage(meals: (0, 3)), dayStart: day,
                                calendar: DateHelp.calendar)
        let b = CoverageBid.bid(for: coverage(meals: (0, 3)), dayStart: day,
                                calendar: DateHelp.calendar)
        #expect(a?.id == b?.id)
        #expect(a?.id == "coverage:2026-08-25")
    }

    @Test("the id is built from components, so no locale can rewrite it")
    func localeProofID() {
        var hindi = DateHelp.calendar
        hindi.locale = Locale(identifier: "hi_IN")
        let bid = CoverageBid.bid(for: coverage(meals: (0, 3)),
                                  dayStart: DateHelp.at(2026, 8, 25), calendar: hindi)
        #expect(bid?.id == "coverage:2026-08-25")
    }
}

@Suite("FR6.4 — the phone raises it too, which is the point of it being model-free")
struct LocalCoverageBidTests {
    private var blind: DayCoverage {
        var c = DayCoverage(dayStart: DateHelp.at(2026, 8, 25))
        for d in CoverageDomain.allCases {
            c.record(CoverageMetric(domain: d, observedCount: 0, expectedCount: 3))
        }
        return c
    }

    @Test("a phone with no readings at all is no longer silent about that")
    func offlineAndBlind() {
        let bids = LocalBidSource.bids(at: DateHelp.at(2026, 8, 25, 15, 40),
                                       observations: Observations(),
                                       calendar: DateHelp.calendar,
                                       coverage: blind)
        #expect(bids.map(\.nudgeClass) == ["coverage"])
    }

    @Test("no coverage passed means no coverage bid, not a confident one")
    func noCoverageNoBid() {
        let bids = LocalBidSource.bids(at: DateHelp.at(2026, 8, 25, 15, 40),
                                       observations: Observations(),
                                       calendar: DateHelp.calendar)
        #expect(bids.isEmpty)
    }

    @Test("a real reading outranks it")
    func realReadingWins() {
        var obs = Observations()
        obs.sedentaryMinutes = 82
        let bids = LocalBidSource.bids(at: DateHelp.at(2026, 8, 25, 15, 40),
                                       observations: obs,
                                       calendar: DateHelp.calendar,
                                       coverage: blind)
        let sedentary = bids.first { $0.nudgeClass == "sedentary" }!
        let coverage = bids.first { $0.nudgeClass == "coverage" }!
        #expect(sedentary.expectedBenefit > coverage.expectedBenefit)
    }
}
