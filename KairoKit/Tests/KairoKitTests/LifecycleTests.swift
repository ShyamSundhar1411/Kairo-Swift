import Testing
import Foundation
@testable import KairoKit

@Suite("Lifecycle enforcement")
struct LifecycleTests {
    let t = DateHelp.at(2026, 8, 25, 12, 0)

    @Test("a declared transition is accepted")
    func legalTransition() throws {
        var lc = Lifecycle<MealEntryState>()
        try lc.transition(on: "beginRecognition", to: .classifying, at: t)
        #expect(lc.state == .classifying)
        #expect(lc.history.count == 1)
    }

    @Test("an undeclared transition is refused")
    func illegalTransition() {
        var lc = Lifecycle<MealEntryState>()
        #expect(throws: LifecycleError<MealEntryState>.self) {
            try lc.transition(on: "written", to: .logged, at: t)
        }
        #expect(lc.state == .captured)
    }

    @Test("a terminal state accepts nothing further")
    func terminalIsFinal() throws {
        var lc = Lifecycle<MealEntryState>(.failed)
        #expect(throws: LifecycleError<MealEntryState>.self) {
            try lc.transition(on: "beginRecognition", to: .classifying, at: t)
        }
    }

    @Test("every machine in the report is reachable and has no dead ends",
          arguments: [
            UMLExport.audit(MealEntryState.self),
            UMLExport.audit(DayCoverageState.self),
            UMLExport.audit(PlanContractState.self),
            UMLExport.audit(NudgeState.self),
            UMLExport.audit(DecisionRecordState.self),
            UMLExport.audit(MemoryItemState.self),
          ])
    func machinesAreWellFormed(_ audit: UMLExport.Audit) {
        #expect(audit.unreachable.isEmpty, "\(audit.machine): unreachable \(audit.unreachable)")
        #expect(audit.deadEnds.isEmpty, "\(audit.machine): dead ends \(audit.deadEnds)")
    }
}
