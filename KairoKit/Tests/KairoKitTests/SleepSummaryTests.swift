import Testing
import Foundation
@testable import KairoKit

// Every figure in this file is synthetic and round on purpose: an 8 h need
// against nights of 6, 7 and 10 hours, so a shortfall is 2, 1 or 0 and a week's
// debt can be checked by eye. None of it is anybody's sleep. This project treats
// an unverified real-looking number as a defect — the whole reason this suite
// exists is that the screen used to print "2.4 hours" as a string literal — so
// the fixtures here are obviously fake and stay that way.
private enum Nights {
    /// Seven consecutive nights, oldest first, ending on the 25th.
    static let week: [Date] = (0..<7).map { DateHelp.at(2026, 8, 19 + $0) }

    /// A window built from `hours` positionally against `week`, where `nil` is a
    /// night the watch was off the wrist. Going through `SleepSummary.slots` on
    /// purpose: that is the call site an adapter is meant to use, so the tests
    /// exercise the same path.
    static func window(_ hours: [Double?]) -> [NightReading] {
        var observed: [Date: Double] = [:]
        var worn: [Date: Double] = [:]
        for (i, h) in hours.enumerated() where h != nil {
            observed[week[i]] = h!
            worn[week[i]] = 9   // flat, so the wear figure is never load-bearing here
        }
        return SleepSummary.slots(for: Array(week.prefix(hours.count)),
                                  observedHours: observed, wornHours: worn)
    }
}

/// Member B — CF4 / CF6. The debt, and how much of one may be said out loud.
///
/// The behaviour that distinguishes this from every other sleep tracker is the
/// gap: what the number does when a night is missing, and what the app is then
/// allowed to say.
@Suite("Member B — sleep debt")
struct SleepSummaryTests {

    // MARK: - The sum

    @Test("a fully observed week sums every night's shortfall")
    func fullWeek() {
        // Seven nights of 6 h against an 8 h need: 2 h short each, 14 h total.
        let d = Nights.window(Array(repeating: 6, count: 7)).sleepDebt()
        #expect(d.hours == 14)
        #expect(d.observedNights == 7)
        #expect(d.expectedNights == 7)
        #expect(!d.isLowerBound, "nothing was missing, so the total is a total")
        #expect(d.hoursPerObservedNight == 2)
    }

    @Test("the nightly need is a parameter, not a constant baked into the sum")
    func needIsAParameter() {
        let week = Nights.window(Array(repeating: 6, count: 7))
        #expect(week.sleepDebt(nightlyNeed: 7).hours == 7)   // 1 h short × 7
        #expect(week.sleepDebt(nightlyNeed: 6).hours == 0)   // met exactly
        #expect(SleepSummary.defaultNightlyNeedHours == 8)
    }

    @Test("a gap contributes nothing at all — not a zero, not an interpolation")
    func gapsAreExcludedFromTheSum() {
        // Five nights of 6 h and two nights the watch was off. The debt is 10 h,
        // over five nights.
        let d = Nights.window([6, 6, nil, 6, 6, nil, 6]).sleepDebt()
        #expect(d.hours == 10, "zero-filling the two gaps would have read 16 h")
        #expect(d.observedNights == 5)
        #expect(d.expectedNights == 7)
        #expect(d.unobservedNights == 2)
        #expect(d.isLowerBound, "two nights missing makes the figure a floor")
        // And the per-night figure is over the nights that were seen, which is
        // the only figure comparable with the fully observed week above.
        #expect(d.hoursPerObservedNight == 2)
    }

    @Test("a week nobody saw yields no debt at all rather than a debt of zero")
    func emptyWindowHasNoDebt() {
        let d = Nights.window(Array(repeating: nil, count: 7)).sleepDebt()
        #expect(d.hours == nil, "\"no sleep debt\" is a claim about the user's week")
        #expect(d.observedNights == 0)
        #expect(d.expectedNights == 7)
        #expect(d.hoursPerObservedNight == nil)
        // A window with no slots in it at all is the same situation.
        #expect([NightReading]().sleepDebt().hours == nil)
    }

    @Test("a night above need contributes nothing rather than negative debt")
    func surplusDoesNotCancel() {
        // One night of 10 h (2 h above need) and one of 6 h (2 h short). The debt
        // is 2 h, not 0: Saturday does not repay Tuesday.
        let d = Nights.window([10, 6]).sleepDebt()
        #expect(d.hours == 2)
        // And a week entirely above need is a debt of zero, which is a real
        // measured zero — every night was seen.
        let rested = Nights.window(Array(repeating: 10, count: 7)).sleepDebt()
        #expect(rested.hours == 0)
        #expect(rested.observedNights == 7)
    }

    @Test("a single night's shortfall is clamped at the reading, not the need")
    func shortfallPerNight() {
        let need = 8.0
        #expect(NightReading(night: Nights.week[0], hoursAsleep: 6).shortfall(need: need) == 2)
        #expect(NightReading(night: Nights.week[0], hoursAsleep: 10).shortfall(need: need) == 0)
        #expect(NightReading(night: Nights.week[0], hoursAsleep: nil).shortfall(need: need) == nil,
                "an unobserved night has no shortfall, which is what keeps it out of the sum")
    }

    @Test("a nonsense reading is clamped rather than trapped")
    func defensiveAgainstBadReadings() {
        // Fed by an adapter over HealthKit, whose sample dates come from whatever
        // device wrote them; a negative duration must not become negative debt.
        let n = NightReading(night: Nights.week[0], hoursAsleep: -3, hoursWorn: -1)
        #expect(n.hoursAsleep == 0)
        #expect(n.hoursWorn == 0)
        #expect(n.isObserved, "clamped to zero is still a reading, unlike nil")
        // A non-positive need makes every night a surplus rather than an error.
        #expect(Nights.window([6, 6]).sleepDebt(nightlyNeed: -1).hours == 0)
    }

    @Test("the same night offered twice is one night, and the later read wins")
    func duplicateNightsDoNotDoubleTheDebt() {
        let n = Nights.week[0]
        let d = SleepSummary.debt(over: [
            NightReading(night: n, hoursAsleep: 6),
            NightReading(night: n, hoursAsleep: 7),
        ])
        #expect(d.observedNights == 1, "a re-read is a correction, not a second night")
        #expect(d.hours == 1, "the corrected 7 h reading, not the stale 6 h one")
    }

    // MARK: - Coverage

    @Test("the coverage metric comes from observed-versus-expected nights")
    func coverageMetricIsDerived() {
        let m = Nights.window([6, 6, nil, 6, 6, nil, 6]).sleepDebt().coverageMetric
        #expect(m.domain == .sleep)
        #expect(m.observedCount == 5)
        #expect(m.expectedCount == 7)
        #expect(abs(m.observedFraction - 5.0 / 7.0) < 0.000_1)
        // The point of the exercise: this is no longer the hardcoded 1-of-1 the
        // model used to record.
        #expect(m != CoverageMetric(domain: .sleep, observedCount: 1, expectedCount: 1))
    }

    @Test("a caller who knows the window was longer than its readings may say so")
    func expectedNightsIsPerCaller() {
        // Three nights handed over, but the claim is a weekly one: coverage is
        // 3-of-7, not 3-of-3.
        let three = Nights.window([6, 6, 6])
        #expect(three.sleepDebt().expectedNights == 3)
        #expect(three.sleepDebt(expectedNights: 7).expectedNights == 7)
        #expect(three.sleepDebt(expectedNights: 7).hours == 6, "the sum is unaffected")
        // And a caller claiming a shorter window than the readings it supplied
        // does not get to shrink the denominator below what it handed over.
        #expect(three.sleepDebt(expectedNights: 1).expectedNights == 3)
    }

    @Test("zero expected nights cannot divide by zero")
    func zeroExpectedIsSafe() {
        let m = SleepSummary.debt(over: [], expectedNights: 0).coverageMetric
        #expect(m.expectedCount == 1)
        #expect(m.observedFraction == 0)
    }

    // MARK: - The assertion-form ladder

    @Test("a week nobody saw forbids any claim about a debt")
    func nothingObservedIsForbidden() {
        let d = Nights.window(Array(repeating: nil, count: 7)).sleepDebt()
        #expect(d.permittedForm == .forbidden)
        #expect(d.hours == nil, "forbidden and a nil debt travel together")
        #expect([NightReading]().sleepDebt().permittedForm == .forbidden)
    }

    @Test("one night is not a debt, so it may only be asked about")
    func oneNightIsAQuestion() {
        // The case the screen has to handle honestly: a first launch with last
        // night's sleep and nothing behind it.
        #expect(Nights.window([6]).sleepDebt(expectedNights: 7).permittedForm == .question)
        #expect(Nights.window([6]).sleepDebt().permittedForm == .question,
                "a one-night window is fully covered and still not a week")
    }

    @Test("two of seven nights may not carry a bare number")
    func twoOfSevenIsScreened() {
        let d = Nights.window([6, 6, nil, nil, nil, nil, nil]).sleepDebt()
        #expect(d.hours == 4)
        #expect(d.permittedForm < .assertion)
        // 2/7 = 0.286, below half the 0.6 floor, which DayCoverage calls a
        // question — weaker than the two-night window limit of a range.
        #expect(d.permittedForm == .question)
    }

    @Test("the full ladder over a seven-night window")
    func theLadder() {
        func form(observed n: Int) -> AssertionForm {
            let hours: [Double?] = (0..<7).map { $0 < n ? 6 : nil }
            return Nights.window(hours).sleepDebt().permittedForm
        }
        #expect(form(observed: 0) == .forbidden)
        #expect(form(observed: 1) == .question)
        #expect(form(observed: 2) == .question)   // coverage 0.286 caps it below the range floor
        #expect(form(observed: 3) == .range)      // coverage 0.429
        #expect(form(observed: 4) == .range)      // coverage 0.571, still under the 0.6 floor
        #expect(form(observed: 5) == .qualified)  // coverage 0.714
        #expect(form(observed: 6) == .qualified)  // the window limit yields; coverage does not
        #expect(form(observed: 7) == .assertion)
    }

    @Test("the ladder never lets more evidence say less")
    func ladderIsMonotonic() {
        let forms = (0...7).map {
            SleepSummary.permittedForm(observedNights: $0, expectedNights: 7)
        }
        #expect(zip(forms, forms.dropFirst()).allSatisfy { $0 <= $1 })
        // Same for the absolute-nights limit on its own, well past a week.
        let window = (0...20).map { SleepSummary.windowForm(observedNights: $0) }
        #expect(zip(window, window.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test("a short window cannot flatter itself into a bare number")
    func shortWindowIsCappedByAbsoluteNights() {
        // Two of two nights is a coverage fraction of 1.0, which the coverage
        // ladder alone would call an assertion. It is still a long weekend of
        // ignorance, and the absolute-nights limit is what says so.
        let two = Nights.window([6, 6]).sleepDebt()
        #expect(two.expectedNights == 2)
        #expect(two.coverageMetric.observedFraction == 1)
        #expect(two.permittedForm == .range)
        // Three of three, likewise.
        #expect(Nights.window([6, 6, 6]).sleepDebt().permittedForm == .range)
        // Six of six is where the two limits finally agree on a bare number.
        #expect(Nights.window(Array(repeating: 6, count: 6)).sleepDebt().permittedForm == .assertion)
    }

    @Test("the form is about evidence, not about whether the news is good")
    func formIgnoresTheSizeOfTheDebt() {
        // A well-slept fully observed week and a badly-slept one earn the same
        // right to a number. Nothing here rewards a flattering figure.
        #expect(Nights.window(Array(repeating: 10, count: 7)).sleepDebt().permittedForm == .assertion)
        #expect(Nights.window(Array(repeating: 6, count: 7)).sleepDebt().permittedForm == .assertion)
    }

    // MARK: - Observations

    @Test("an observed window fills in the two sleep observations")
    func observationsAreFilled() {
        // Six nights of 6 h then a last night of 7 h: 13 h of debt, and last
        // night reported as 7 h.
        let obs = Nights.window([6, 6, 6, 6, 6, 6, 7]).sleepObservations()
        #expect(obs.sleepHoursLastNight == 7)
        #expect(obs.sleepDebtHours == 13)
        #expect(obs.lines.contains { $0.contains("sleep last night: 7.0 hours") })
        #expect(obs.lines.contains { $0.contains("sleep debt: 13.0 hours") })
    }

    @Test("an unmeasured last night is nil even when earlier nights were seen")
    func lastNightNilWhenUnmeasured() {
        // Six nights seen and last night missed. Reporting the most recent night
        // Kairo happened to see as "last night" is the interpolation the trust
        // note promises not to do.
        let obs = Nights.window([6, 6, 6, 6, 6, 6, nil]).sleepObservations()
        #expect(obs.sleepHoursLastNight == nil)
        #expect(obs.sleepDebtHours == 12, "the debt still stands on the six nights that were seen")
        #expect(obs.lines.contains { $0.contains("sleep last night: not recorded") })
    }

    @Test("an unmeasured week reports both fields as absent, not as zero")
    func observationsAreNilWhenUnmeasured() {
        let obs = Nights.window(Array(repeating: nil, count: 7)).sleepObservations()
        #expect(obs.sleepHoursLastNight == nil)
        #expect(obs.sleepDebtHours == nil,
                "0.0 hours of debt would read to an agent as a well-slept week")
        #expect(obs.lines.contains { $0.contains("sleep last night: not recorded") })
        #expect(!obs.lines.contains { $0.contains("sleep debt") })
        // And an empty window, likewise.
        #expect([NightReading]().sleepObservations().sleepDebtHours == nil)
    }

    @Test("a zero-hour reading is reported as zero, because it was measured")
    func measuredZeroIsNotAbsence() {
        // The distinction the whole app rests on, in one assertion: a watch that
        // recorded no sleep at all is a reading of 0, and it is not nil.
        let obs = Nights.window([6, 6, 6, 6, 6, 6, 0]).sleepObservations()
        #expect(obs.sleepHoursLastNight == 0)
        #expect(obs.sleepDebtHours == 20, "12 h from six nights plus a full 8 h night missed")
    }

    // MARK: - Building the window

    @Test("slots are emitted for every night, blanks included")
    func slotsMakeTheHolesVisible() {
        // An adapter returning only what it found would hand back two readings
        // and every coverage figure downstream would read 2-of-2.
        let slots = SleepSummary.slots(for: Nights.week,
                                       observedHours: [Nights.week[0]: 6, Nights.week[3]: 7])
        #expect(slots.count == 7)
        #expect(slots.filter(\.isObserved).count == 2)
        #expect(slots.map(\.night) == Nights.week, "order is preserved, oldest first")
        #expect(slots[1].hoursAsleep == nil)
        #expect(slots[1].hoursWorn == 0, "nothing recorded genuinely is zero hours worn")
    }

    @Test("readings arriving out of order still resolve the most recent night")
    func orderIndependence() {
        let shuffled = Nights.window([6, 6, 6, 6, 6, 6, 7]).reversed().map { $0 }
        #expect(shuffled.sleepObservations().sleepHoursLastNight == 7)
        #expect(shuffled.sleepDebt().hours == 13)
    }

    @Test("the window default says what a debt claim is about")
    func windowDefault() {
        #expect(SleepSummary.defaultWindowNights == 7)
    }
}
