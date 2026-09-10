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

// MARK: - Replaying a state that arrived from outside

@Suite("Lifecycle.replaying")
struct LifecycleReplayTests {
    private let now = Date(timeIntervalSince1970: 1_756_100_400)

    @Test("reaches a state the machine declares, through declared edges only")
    func replaysToActive() throws {
        let lifecycle = try #require(Lifecycle<MemoryItemState>.replaying(to: .active, at: now))
        #expect(lifecycle.state == .active)
        // candidate --userConfirmed--> verified --promoted--> active
        #expect(lifecycle.history.count == 2)
        #expect(lifecycle.history.map(\.event) == ["userConfirmed", "promoted"])
        #expect(lifecycle.visited(.verified))
    }

    @Test("the route is the shortest declared one")
    func shortestRoute() throws {
        let route = try #require(Lifecycle<MemoryItemState>.route(to: .decaying))
        // active --noLongerObserved--> unconfirmed --decayWindowPassed--> decaying
        #expect(route.map(\.to) == [.verified, .active, .unconfirmed, .decaying])
    }

    @Test("the initial state needs no events")
    func initialIsFree() throws {
        let lifecycle = try #require(Lifecycle<MemoryItemState>.replaying(to: .candidate, at: now))
        #expect(lifecycle.state == .candidate)
        #expect(lifecycle.history.isEmpty)
    }

    @Test("a state no declared edge reaches is refused, not fabricated")
    func unreachableIsNil() {
        // A machine whose only edge leaves the target orphaned. The point is that
        // an outside caller cannot hand us a state the diagram does not contain
        // and have it displayed as though the object had lived through it.
        #expect(Lifecycle<Orphaned>.replaying(to: .unreachable, at: now) == nil)
        #expect(Lifecycle<Orphaned>.route(to: .unreachable) == nil)
    }

    private enum Orphaned: String, LifecycleState {
        case start, middle, unreachable
        static let machineName = "Orphaned"
        static let initial: Orphaned = .start
        var isTerminal: Bool { false }
        static let transitions: [Transition<Orphaned>] = [.init(.start, "go", .middle)]
    }
}
