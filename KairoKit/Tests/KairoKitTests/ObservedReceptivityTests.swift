import Foundation
import Testing
@testable import KairoKit

private final class ArrayOutcomeLog: NudgeOutcomeLog, @unchecked Sendable {
    private var stored: [NudgeOutcome]
    init(_ stored: [NudgeOutcome] = []) { self.stored = stored }
    func outcomes() -> [NudgeOutcome] { stored }
    func append(_ outcome: NudgeOutcome) { stored.append(outcome) }
}

@Suite("ObservedReceptivityModel — learned, not tabled")
struct ObservedReceptivityTests {
    private let noon = DateHelp.at(2026, 9, 10, 12, 0)
    /// The fixtures are built in Australia/Sydney by `DateHelp`, so the model
    /// has to read them in the same calendar. `.current` agreed with that on a
    /// laptop in Sydney and disagreed on the first CI run, in UTC — the hour
    /// bucket a 7am fixture lands in is not 7 anywhere else.
    private var calendar: Calendar { DateHelp.calendar }

    private func log(_ entries: [(String, NudgeOutcome.Response, Int)]) -> ArrayOutcomeLog {
        ArrayOutcomeLog(entries.map {
            NudgeOutcome(nudgeClass: $0.0, response: $0.1,
                         at: DateHelp.at(2026, 9, 9, $0.2, 0))
        })
    }

    @Test("with no history the prior is returned, and the evidence count says so")
    func noHistory() {
        let model = ObservedReceptivityModel(log: ArrayOutcomeLog(), calendar: calendar)
        #expect(model.receptivity(nudgeClass: "hydration", at: noon, memories: []) == 0.5)
        #expect(model.evidence(for: "hydration") == 0)
    }

    @Test("acceptances raise the estimate, dismissals lower it")
    func historyMoves() {
        let accepted = ObservedReceptivityModel(
            log: log(Array(repeating: ("hydration", .accepted, 12), count: 10)), calendar: calendar)
        let dismissed = ObservedReceptivityModel(
            log: log(Array(repeating: ("hydration", .dismissed, 12), count: 10)), calendar: calendar)

        let up = accepted.receptivity(nudgeClass: "hydration", at: noon, memories: [])
        let down = dismissed.receptivity(nudgeClass: "hydration", at: noon, memories: [])
        #expect(up > 0.5)
        #expect(down < 0.5)
        #expect(up > down)
    }

    @Test("one dismissal does not silence a class")
    func shrinkageResistsOneBadMorning() {
        let model = ObservedReceptivityModel(log: log([("sedentary", .dismissed, 12)]),
                                             calendar: calendar)
        let value = model.receptivity(nudgeClass: "sedentary", at: noon, memories: [])
        // Pulled down, but nowhere near off: one outcome against a strength of 6.
        #expect(value > 0.4)
        #expect(value < 0.5)
    }

    @Test("snoozing is not a refusal")
    func snoozeCountsPositive() {
        let snoozed = ObservedReceptivityModel(
            log: log(Array(repeating: ("sedentary", .snoozed, 12), count: 8)), calendar: calendar)
        let dismissed = ObservedReceptivityModel(
            log: log(Array(repeating: ("sedentary", .dismissed, 12), count: 8)), calendar: calendar)
        #expect(snoozed.receptivity(nudgeClass: "sedentary", at: noon, memories: [])
                > dismissed.receptivity(nudgeClass: "sedentary", at: noon, memories: []))
    }

    @Test("classes are learned separately")
    func perClass() {
        let model = ObservedReceptivityModel(log: log(
            Array(repeating: ("hydration", .accepted, 12), count: 8)
            + Array(repeating: ("sedentary", .dismissed, 12), count: 8)), calendar: calendar)
        #expect(model.receptivity(nudgeClass: "hydration", at: noon, memories: [])
                > model.receptivity(nudgeClass: "sedentary", at: noon, memories: []))
        #expect(model.evidence(for: "hydration") == 8)
    }

    @Test("an hour the user never accepts in is discounted, but not erased")
    func hourOfDayIsLearned() {
        var entries = Array(repeating: ("hydration", NudgeOutcome.Response.accepted, 12), count: 12)
        entries += Array(repeating: ("hydration", NudgeOutcome.Response.dismissed, 7), count: 6)
        let model = ObservedReceptivityModel(log: log(entries), calendar: calendar)

        let sevenAM = DateHelp.at(2026, 9, 10, 7, 0)
        let bad = model.receptivity(nudgeClass: "hydration", at: sevenAM, memories: [])
        let good = model.receptivity(nudgeClass: "hydration", at: noon, memories: [])
        #expect(bad < good)
        #expect(bad > 0)   // bounded at half, never zeroed by one bucket
    }

    @Test("a stated quiet window outranks the history")
    func statedConstraintWins() throws {
        let model = ObservedReceptivityModel(
            log: log(Array(repeating: ("hydration", .accepted, 7), count: 20)), calendar: calendar)
        var memory = MemoryItem(id: "m17", text: "ignores nudges before 9am",
                                confidence: 0.81, sourceRef: "nudge-outcomes")
        _ = try memory.lifecycle.transition(on: "userConfirmed", to: .verified, at: noon)
        _ = try memory.lifecycle.transition(on: "promoted", to: .active, at: noon)

        let sevenAM = DateHelp.at(2026, 9, 10, 7, 0)
        let quiet = model.receptivity(nudgeClass: "hydration", at: sevenAM, memories: [memory])
        let loud = model.receptivity(nudgeClass: "hydration", at: sevenAM, memories: [])
        #expect(quiet < loud * 0.2)
    }

    @Test("the quiet hour is read from the memory, not fixed at nine")
    func quietHourIsParsed() {
        #expect(ObservedReceptivityModel.quietBefore("ignores nudges before 9am") == 9)
        #expect(ObservedReceptivityModel.quietBefore("no nudges before 11am") == 11)
        #expect(ObservedReceptivityModel.quietBefore("ignores anything before 1pm") == 13)
        #expect(ObservedReceptivityModel.quietBefore("lactose intolerant") == nil)
        #expect(ObservedReceptivityModel.quietBefore("walks the dog at 7pm") == nil)
    }
}
