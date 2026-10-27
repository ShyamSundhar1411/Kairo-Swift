import Testing
import Foundation
@testable import KairoKit

@Suite("NFR10 — the companion's activity budget, which is not a battery reading")
struct WatchEnergyBudgetTests {

    @Test("a fresh day starts at nothing and is within budget")
    func freshDay() {
        let ledger = WatchEnergyBudget(dayStart: DateHelp.at(2026, 8, 25))
        #expect(ledger.wakes == 0)
        #expect(ledger.withinBudget)
        #expect(ledger.exceeded.isEmpty)
    }

    @Test("each event lands on its own counter")
    func countsSeparately() {
        var ledger = WatchEnergyBudget(dayStart: DateHelp.at(2026, 8, 25))
        let noon = DateHelp.at(2026, 8, 25, 12)
        ledger.record(.wake, at: noon, calendar: DateHelp.calendar)
        ledger.record(.transmission, at: noon, calendar: DateHelp.calendar)
        ledger.record(.transmission, at: noon, calendar: DateHelp.calendar)
        ledger.record(.haptic, at: noon, calendar: DateHelp.calendar)
        #expect(ledger.wakes == 1)
        #expect(ledger.transmissions == 2)
        #expect(ledger.haptics == 1)
    }

    @Test("crossing a budget names which one")
    func namesTheBreach() {
        var ledger = WatchEnergyBudget(dayStart: DateHelp.at(2026, 8, 25))
        let noon = DateHelp.at(2026, 8, 25, 12)
        for _ in 0...WatchEnergyBudget.Budget.transmissions {
            ledger.record(.transmission, at: noon, calendar: DateHelp.calendar)
        }
        #expect(!ledger.withinBudget)
        #expect(ledger.exceeded == [.transmission])
    }

    @Test("the day rolls over on the first event of the new day")
    func rollsOver() {
        // A watch app is not running at midnight. The first event of a new day
        // is the only reliable moment to notice the day changed — a ledger that
        // rolled only while the app happened to be open would attribute a
        // morning's events to yesterday.
        var ledger = WatchEnergyBudget(dayStart: DateHelp.at(2026, 8, 25))
        ledger.record(.wake, at: DateHelp.at(2026, 8, 25, 23), calendar: DateHelp.calendar)
        #expect(ledger.wakes == 1)

        ledger.record(.wake, at: DateHelp.at(2026, 8, 26, 7), calendar: DateHelp.calendar)
        #expect(ledger.wakes == 1, "yesterday's count must not carry over")
        #expect(ledger.dayStart == DateHelp.at(2026, 8, 26))
    }

    @Test("the summary refuses to be read as a battery percentage")
    func honestSummary() {
        // A line of counters on a screen headed "battery" gets read as one.
        let ledger = WatchEnergyBudget(dayStart: DateHelp.at(2026, 8, 25))
        #expect(ledger.summary.contains("not a battery measurement"))
        #expect(!ledger.summary.contains("%"))
    }

    @Test("it round-trips, because a ledger lost on relaunch counts nothing")
    func codable() throws {
        var ledger = WatchEnergyBudget(dayStart: DateHelp.at(2026, 8, 25))
        ledger.record(.wake, at: DateHelp.at(2026, 8, 25, 9), calendar: DateHelp.calendar)
        let back = try JSONDecoder().decode(
            WatchEnergyBudget.self, from: JSONEncoder().encode(ledger))
        #expect(back == ledger)
    }
}
