import Testing
import Foundation
@testable import KairoKit

// Every number in this file is synthetic and round on purpose, so the arithmetic
// can be checked by eye rather than trusted. Buckets are the default five
// minutes wide and anchored on the hour, sitting buckets carry 0 steps, and a
// movement bucket carries 400 — an obviously-walking figure well clear of the
// 25-step threshold rather than a plausible-looking one. None of it is a real
// day. This project treats an unverified real-looking number as a defect.
private enum Fixture {
    /// A Tuesday, so the fixture cannot be mistaken for a live reading.
    static let dayStart = DateHelp.at(2026, 8, 25)
    static let nineAM = DateHelp.at(2026, 8, 25, 9, 0)

    /// `count` contiguous five-minute buckets from `start`, all sitting still
    /// except the ones named in `movedAt` (indices), which carry 400 steps.
    static func buckets(from start: Date, count: Int, movedAt: Set<Int> = []) -> [StepBucket] {
        (0..<count).map { i in
            StepBucket(start: start.addingTimeInterval(Double(i) * 300),
                       steps: movedAt.contains(i) ? 400 : 0)
        }
    }

    /// `minutes` past nine.
    static func past9(_ minutes: Int) -> Date {
        nineAM.addingTimeInterval(Double(minutes) * 60)
    }
}

/// Member B — CF5 / CF6. The unbroken sitting run, which used to be a constant
/// 82 in the fake and a refusal in the live adapter.
@Suite("Member B — sedentary run")
struct SedentaryRunTests {

    @Test("an hour of stillness plus three minutes of the open bucket is 63 minutes")
    func unbrokenRun() {
        // Buckets 09:00 … 10:00 inclusive (13 of them), measured at 10:03.
        let b = Fixture.buckets(from: Fixture.nineAM, count: 13)
        let run = MovementSummary.unbrokenSedentaryMinutes(buckets: b, at: Fixture.past9(63))
        // 12 whole buckets = 60 min, plus 3 minutes elapsed of the 13th.
        #expect(run == 63)
    }

    @Test("the open bucket only contributes the part of it that has elapsed")
    func openBucketIsProRated() {
        // One bucket at 09:00, measured at 09:02. Reporting the whole five
        // minutes would be reporting sitting that has not happened yet.
        let b = Fixture.buckets(from: Fixture.nineAM, count: 1)
        let run = MovementSummary.unbrokenSedentaryMinutes(buckets: b, at: Fixture.past9(2))
        #expect(run == 2)
    }

    @Test("movement in the middle of the day ends the run there")
    func runBrokenInTheMiddle() {
        // 13 buckets from 09:00; the one at 09:30 (index 6) is a walk. Measured
        // at 10:03, the run is 09:35 → 10:03.
        let b = Fixture.buckets(from: Fixture.nineAM, count: 13, movedAt: [6])
        let run = MovementSummary.unbrokenSedentaryMinutes(buckets: b, at: Fixture.past9(63))
        #expect(run == 28, "the run starts at the end of the moving bucket, not the start of the day")
    }

    @Test("movement in the open bucket means the run has only just started")
    func movementInTheCurrentBucket() {
        let b = Fixture.buckets(from: Fixture.nineAM, count: 13, movedAt: [12])
        let run = MovementSummary.unbrokenSedentaryMinutes(buckets: b, at: Fixture.past9(63))
        #expect(run == 0, "zero here is measured: the user moved inside the bucket we are in")
    }

    @Test("no step data at all is nil, not zero")
    func noDataIsNotZero() {
        // The distinction the whole layer exists for. Zero would render as
        // "0 min sitting unbroken", i.e. a reassurance nobody measured.
        #expect(MovementSummary.unbrokenSedentaryMinutes(buckets: [], at: Fixture.past9(63)) == nil)
    }

    @Test("a gap in the buckets ends the run rather than being sat through")
    func gapEndsTheRun() {
        // 09:00–09:25 observed (6 buckets), then nothing until 09:45, then
        // 09:45–10:00 observed (4 buckets). Measured at 10:03 the run may only
        // claim 09:45 → 10:03; the missing twenty minutes might have been a walk.
        let early = Fixture.buckets(from: Fixture.nineAM, count: 6)
        let late = Fixture.buckets(from: Fixture.past9(45), count: 4)
        let run = MovementSummary.unbrokenSedentaryMinutes(buckets: early + late, at: Fixture.past9(63))
        #expect(run == 18)
    }

    @Test("stale buckets give nil rather than a run that looks current")
    func staleDataIsNotACurrentRun() {
        // Last observation 09:00–09:05, asked about 12:00. Three hours are
        // unobserved, so there is no current run to report — reporting five
        // minutes would read as "you have just sat down".
        let b = Fixture.buckets(from: Fixture.nineAM, count: 1)
        #expect(MovementSummary.unbrokenSedentaryMinutes(buckets: b, at: Fixture.past9(180)) == nil)
    }

    @Test("buckets starting after the instant asked about are ignored")
    func futureBucketsIgnored() {
        // HealthKit will happily return the whole day's buckets. Measured at
        // 09:02, only the 09:00 bucket is evidence.
        let b = Fixture.buckets(from: Fixture.nineAM, count: 13, movedAt: [5])
        let run = MovementSummary.unbrokenSedentaryMinutes(buckets: b, at: Fixture.past9(2))
        #expect(run == 2)
    }

    @Test("fidgeting does not clear the threshold but walking does")
    func thresholdBoundary() {
        // 24 steps in five minutes is a person shifting in a chair; 25 is the
        // documented bar. The boundary is inclusive.
        let fidget = [StepBucket(start: Fixture.nineAM, steps: 0),
                      StepBucket(start: Fixture.past9(5), steps: 24)]
        let stepped = [StepBucket(start: Fixture.nineAM, steps: 0),
                       StepBucket(start: Fixture.past9(5), steps: 25)]
        #expect(MovementSummary.unbrokenSedentaryMinutes(buckets: fidget, at: Fixture.past9(8)) == 8)
        #expect(MovementSummary.unbrokenSedentaryMinutes(buckets: stepped, at: Fixture.past9(8)) == 0)
    }

    @Test("a caller may set its own threshold and bucket width")
    func callerSuppliedCalibration() {
        // Six one-minute buckets of 30 steps each. At the default 25-step bar
        // every one of them is movement; at a 60-step bar none of them is.
        let b = (0..<6).map { StepBucket(start: Fixture.past9($0), steps: 30) }
        let loose = MovementSummary.unbrokenSedentaryMinutes(
            buckets: b, at: Fixture.past9(6), bucketMinutes: 1, movedThreshold: 60)
        let strict = MovementSummary.unbrokenSedentaryMinutes(
            buckets: b, at: Fixture.past9(6), bucketMinutes: 1, movedThreshold: 25)
        #expect(loose == 6)
        #expect(strict == 0)
    }

    @Test("a negative step count is clamped rather than trusted")
    func negativeStepsClamped() {
        #expect(StepBucket(start: Fixture.nineAM, steps: -400).steps == 0)
    }
}

/// Member B — the wear proxy, whose only job is to be an honest denominator.
@Suite("Member B — wear hours from sample density")
struct WearHoursTests {

    @Test("nobody has looked is nil, and looking and finding nothing is zero")
    func nilIsNotEmpty() {
        // The original defect in the health adapter, in one assertion: these two
        // are different facts and a plain Set<Int> could not tell them apart.
        #expect(MovementSummary.wearHours(hoursWithSamples: nil) == nil)
        #expect(MovementSummary.wearHours(hoursWithSamples: []) == 0)
    }

    @Test("the count is distinct hours containing at least one sample")
    func countsDistinctHours() {
        // 09:00 through 22:00 inclusive: fourteen hours worn.
        let hours = Set(9...22)
        #expect(MovementSummary.wearHours(hoursWithSamples: hours) == 14)
    }

    @Test("hour indices outside the day are dropped rather than inflating wear")
    func rejectsImpossibleHours() {
        // 25 and -1 can only be an adapter bug, and a bug underneath a hero
        // number is worse than a smaller number.
        let hours: Set<Int> = [0, 12, 23, 25, -1]
        #expect(MovementSummary.wearHours(hoursWithSamples: hours) == 3)
    }

    @Test("a full day of samples is 24, not 25")
    func fullDay() {
        #expect(MovementSummary.wearHours(hoursWithSamples: Set(0..<24)) == 24)
    }
}

/// Member B — CF6. The movement coverage metric and the assertion ladder over it.
@Suite("Member B — movement coverage")
struct MovementCoverageTests {

    @Test("the metric is hours recorded over hours expected, in the movement domain")
    func metricShape() {
        // Eight of an expected sixteen: half a day.
        let m = MovementSummary.coverageMetric(observedHours: 8)
        #expect(m.domain == .movement)
        #expect(m.observedCount == 8)
        #expect(m.expectedCount == 16)
        #expect(m.observedFraction == 0.5)
    }

    @Test("unobserved wear gives a zero fraction rather than a full ring")
    func nilObservedIsZero() {
        let m = MovementSummary.coverageMetric(observedHours: nil)
        #expect(m.observedCount == 0)
        #expect(m.observedFraction == 0)
    }

    @Test("a day worn round the clock clamps at full coverage")
    func overExpectationClamps() {
        // 24 hours against a 16-hour expectation is 1.0, not 1.5 — a ring cannot
        // overflow and a fraction above one is not a thing.
        #expect(MovementSummary.coverageMetric(observedHours: 24).observedFraction == 1)
    }

    @Test("fractional hours floor to the resolution the proxy actually has")
    func flooredToWholeHours() {
        #expect(MovementSummary.coverageMetric(observedHours: 8.9).observedCount == 8)
    }

    // MARK: - The ladder

    @Test("nothing observed may not be spoken about at all")
    func nothingObservedIsForbidden() {
        // Not a confident zero. "You have not moved today" is a claim about the
        // user's day, and an unworn watch is the absence of evidence for it.
        #expect(MovementSummary.permittedForm(hoursWorn: nil) == .forbidden)
        #expect(MovementSummary.permittedForm(hoursWorn: 0) == .forbidden)
    }

    @Test("the full ladder, at the default sixteen-hour expectation")
    func fullLadder() {
        // Both limits are in play at every rung; see permittedForm's doc comment
        // for which one is binding where.
        #expect(MovementSummary.permittedForm(hoursWorn: 16) == .assertion)
        #expect(MovementSummary.permittedForm(hoursWorn: 12) == .qualified,
                "coverage reserves a bare number for a complete day even once the absolute limit yields")
        #expect(MovementSummary.permittedForm(hoursWorn: 10) == .qualified)
        #expect(MovementSummary.permittedForm(hoursWorn: 8) == .range)
        #expect(MovementSummary.permittedForm(hoursWorn: 4) == .question)
        #expect(MovementSummary.permittedForm(hoursWorn: 1) == .question)
        #expect(MovementSummary.permittedForm(hoursWorn: 0.5) == .forbidden,
                "under an hour of recording is a watch being picked up, not a day")
    }

    @Test("a short expectation cannot flatter itself into a bare assertion")
    func shortWindowTrap() {
        // The reason the absolute limit exists. Four hours of an expected four is
        // a coverage fraction of 1.0, which the coverage ladder alone would call
        // an assertion — about a day it saw four hours of.
        #expect(MovementSummary.permittedForm(hoursWorn: 4, expectedHours: 4) == .range)
    }

    @Test("a zero or negative expectation does not divide by zero")
    func degenerateExpectation() {
        // CoverageMetric treats expectedCount 0 as full coverage, so the
        // expectation is clamped to at least one hour before it gets there; the
        // absolute limit then does the work.
        #expect(MovementSummary.permittedForm(hoursWorn: 2, expectedHours: 0) == .question)
    }

    @Test("the absolute-hours ladder in isolation")
    func wornFormBands() {
        #expect(MovementSummary.wornForm(hoursWorn: 24) == .assertion)
        #expect(MovementSummary.wornForm(hoursWorn: 12) == .assertion)
        #expect(MovementSummary.wornForm(hoursWorn: 11.9) == .qualified)
        #expect(MovementSummary.wornForm(hoursWorn: 8) == .qualified)
        #expect(MovementSummary.wornForm(hoursWorn: 7.9) == .range)
        #expect(MovementSummary.wornForm(hoursWorn: 4) == .range)
        #expect(MovementSummary.wornForm(hoursWorn: 3.9) == .question)
        #expect(MovementSummary.wornForm(hoursWorn: 1) == .question)
        #expect(MovementSummary.wornForm(hoursWorn: 0.9) == .forbidden)
        #expect(MovementSummary.wornForm(hoursWorn: 0) == .forbidden)
    }
}

/// Member B — what the day hands to the agents.
@Suite("Member B — movement day")
struct MovementDayTests {

    @Test("an unmeasured sitting run stays nil in the observations")
    func observationsPreserveAbsence() {
        let day = MovementDay(day: Fixture.dayStart, hoursWorn: 14)
        let obs = MovementSummary.observations(for: day)
        #expect(obs.sedentaryMinutes == nil)
        #expect(obs.lines.contains("sitting: not measured"))
    }

    @Test("a measured sitting run is rendered as minutes unbroken")
    func observationsCarryTheRun() {
        let day = MovementDay(day: Fixture.dayStart, hoursWorn: 14,
                              unbrokenSedentaryMinutes: 63)
        #expect(day.observations.sedentaryMinutes == 63)
        #expect(day.observations.lines.contains("sitting: 63 minutes unbroken"))
    }

    @Test("energy burned is not poured into the food ledger's field")
    func burnIsNotIntake() {
        // Adding a burn figure to kilojoulesLogged would silently turn Member A's
        // meal total into a net figure nobody asked for.
        let day = MovementDay(day: Fixture.dayStart, hoursWorn: 14,
                              activeKilojoules: 2000, exerciseMinutes: 30)
        #expect(day.observations.kilojoulesLogged == nil)
    }

    @Test("implausible readings are clamped rather than trapped")
    func clamping() {
        let day = MovementDay(day: Fixture.dayStart, hoursWorn: 40,
                              unbrokenSedentaryMinutes: -5,
                              activeKilojoules: -100,
                              exerciseMinutes: 100_000)
        #expect(day.hoursWorn == 24)
        #expect(day.unbrokenSedentaryMinutes == 0)
        #expect(day.activeKilojoules == 0)
        #expect(day.exerciseMinutes == 1440)
    }

    @Test("a day nobody looked at is not observed, and a worn day is")
    func isObserved() {
        #expect(MovementDay(day: Fixture.dayStart).isObserved == false)
        #expect(MovementDay(day: Fixture.dayStart, hoursWorn: 0).isObserved == false)
        #expect(MovementDay(day: Fixture.dayStart, hoursWorn: 14).isObserved)
    }

    @Test("the convenience accessors agree with the free functions")
    func conveniencesMatch() {
        let day = MovementDay(day: Fixture.dayStart, hoursWorn: 8)
        #expect(day.coverageMetric.observedFraction == 0.5)
        #expect(day.permittedForm() == .range)
    }
}
