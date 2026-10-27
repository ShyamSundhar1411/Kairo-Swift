import Foundation
import Testing
@testable import KairoKit

/// The fixture these replace raised three bids unconditionally — including a
/// sitting run of 82 minutes on a phone that had measured nothing. The property
/// worth pinning is the opposite one: no reading, no bid.
@Suite("LocalBidSource — bids follow readings")
struct LocalBidSourceTests {
    private let now = DateHelp.at(2026, 9, 10, 15, 40)

    /// Every call passes `DateHelp.calendar` because every fixture date is built
    /// in it. The production default is `.current` and should stay that way —
    /// the evening window belongs to the user's own day. But a Sydney fixture
    /// read in UTC puts 23:30 at 13:30, which is *before* a 21:30 window rather
    /// than past it, so `tooLateToWindDown` passed in Sydney and failed on the
    /// first CI run in a way that looked like a logic bug and was not.

    @Test("a phone that has measured nothing says nothing")
    func silentWithoutReadings() {
        #expect(LocalBidSource.bids(at: now, observations: .none, calendar: DateHelp.calendar).isEmpty)
    }

    @Test("a sitting run under the floor is not worth an interruption")
    func shortRunIsIgnored() {
        let obs = Observations(sedentaryMinutes: LocalBidSource.sedentaryFloorMinutes - 1)
        #expect(LocalBidSource.bids(at: now, observations: obs, calendar: DateHelp.calendar).isEmpty)
    }

    @Test("a real sitting run bids, and quotes the reading it came from")
    func sittingBid() throws {
        let obs = Observations(sedentaryMinutes: 82)
        let bid = try #require(LocalBidSource.bids(at: now, observations: obs, calendar: DateHelp.calendar).first)
        #expect(bid.nudgeClass == "sedentary")
        #expect(bid.text.contains("82"))
        #expect(bid.requiredCapabilities == [.standing, .walking])
        #expect(bid.isOpen(at: now))
    }

    @Test("urgency rises with the run and then saturates")
    func urgencyClimbs() throws {
        func urgency(_ minutes: Int) throws -> Double {
            try #require(LocalBidSource.bids(
                at: now, observations: Observations(sedentaryMinutes: minutes)).first).urgency
        }
        #expect(try urgency(60) < urgency(90))
        #expect(try urgency(300) <= 0.9)
    }

    @Test("millilitres with no target cannot be judged, so nothing is claimed")
    func hydrationNeedsBothHalves() {
        let obs = Observations(hydrationML: 400)
        #expect(LocalBidSource.bids(at: now, observations: obs, calendar: DateHelp.calendar).isEmpty)
    }

    @Test("someone near their target is left alone")
    func hydrationCloseEnough() {
        let obs = Observations(hydrationML: 1_900, hydrationTargetML: 2_000)
        #expect(LocalBidSource.bids(at: now, observations: obs, calendar: DateHelp.calendar).isEmpty)
    }

    @Test("a real shortfall bids the real figure")
    func hydrationBid() throws {
        let obs = Observations(hydrationML: 400, hydrationTargetML: 2_000)
        let bid = try #require(LocalBidSource.bids(at: now, observations: obs, calendar: DateHelp.calendar).first)
        #expect(bid.nudgeClass == "hydration")
        #expect(bid.text.contains("1600"))
        #expect(bid.text.contains("2000"))
    }

    @Test("the wind-down window is this evening, not a date in the fixture")
    func bedtimeWindowFollowsTheDay() throws {
        // The bid this replaces had windowOpens pinned to 25 August 2026, so on
        // every other day it was raised and immediately suppressed as
        // windowNotOpen — restraint the arbiter never actually exercised.
        let obs = Observations(sleepHoursLastNight: 6.2)
        let bid = try #require(LocalBidSource.bids(at: now, observations: obs, calendar: DateHelp.calendar)
            .first { $0.nudgeClass == "bedtimePrep" })
        // Read back in the calendar the window was computed in. Reading a
        // Sydney 21:30 with `Calendar.current` gives hour 10 in UTC, which is
        // the assertion failing rather than the window being wrong.
        let cal = DateHelp.calendar
        #expect(cal.isDate(bid.windowOpens, inSameDayAs: now))
        #expect(cal.component(.hour, from: bid.windowOpens) == 21)
        #expect(bid.text.contains("6.2"))
    }

    @Test("a full night raises no wind-down bid")
    func sleptEnough() {
        let obs = Observations(sleepHoursLastNight: 8.1)
        #expect(LocalBidSource.bids(at: now, observations: obs, calendar: DateHelp.calendar).isEmpty)
    }

    @Test("past the window, the evening bid is not raised at all")
    func tooLateToWindDown() {
        let lateNight = DateHelp.at(2026, 9, 10, 23, 30)
        let obs = Observations(sleepHoursLastNight: 6.2)
        #expect(LocalBidSource.bids(at: lateNight, observations: obs, calendar: DateHelp.calendar).isEmpty)
    }

    @Test("three readings raise three bids")
    func allThree() {
        let obs = Observations(sedentaryMinutes: 82, hydrationML: 400,
                               hydrationTargetML: 2_000, sleepHoursLastNight: 6.2)
        let classes = Set(LocalBidSource.bids(at: now, observations: obs, calendar: DateHelp.calendar).map(\.nudgeClass))
        #expect(classes == ["sedentary", "hydration", "bedtimePrep"])
    }
}
