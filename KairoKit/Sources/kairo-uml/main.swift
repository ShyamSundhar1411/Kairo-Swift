import Foundation
import KairoKit

// Regenerates every state machine diagram in the Stage 1 report from the code
// that enforces it.  Usage:
//   swift run kairo-uml            -> PlantUML for all machines
//   swift run kairo-uml mermaid    -> Mermaid instead
//   swift run kairo-uml audit      -> unreachable / dead-end report

let mode = CommandLine.arguments.dropFirst().first ?? "plantuml"

func emit<S: LifecycleState>(_ t: S.Type) {
    switch mode {
    case "mermaid":
        print("%% \(S.machineName)")
        print(UMLExport.mermaid(t))
    case "audit":
        let a = UMLExport.audit(t)
        let mark = a.isClean ? "OK  " : "FAIL"
        print("\(mark) \(a.machine.padding(toLength: 16, withPad: " ", startingAt: 0)) states=\(S.allCases.count) edges=\(S.transitions.count)")
        if !a.unreachable.isEmpty { print("       unreachable: \(a.unreachable.joined(separator: ", "))") }
        if !a.deadEnds.isEmpty    { print("       dead ends:   \(a.deadEnds.joined(separator: ", "))") }
    default:
        print(UMLExport.plantUML(t))
    }
    print("")
}

emit(MealEntryState.self)       // Member A
emit(DayCoverageState.self)     // Member B
emit(PlanContractState.self)    // Member C
emit(NudgeState.self)           // Member C (second machine, used in the group diagrams)
emit(DecisionRecordState.self)  // Member D
emit(MemoryItemState.self)      // Member D (alternative)
emit(DisagreementCaseState.self)   // Member A — Figure 34 (UC2)
emit(AdviceScreeningState.self)    // Member D — Figure 40 (UC8)
