import Foundation

/// Renders a state machine's declared transition table.
///
/// The report's state machine diagrams are generated from the same table the
/// `Lifecycle` enforces, so a diagram cannot drift from its implementation.
/// Run `swift run kairo-uml` to regenerate.
public enum UMLExport {
    public static func plantUML<S: LifecycleState>(_ type: S.Type) -> String {
        var out = ["@startuml \(S.machineName)", "hide empty description", "skinparam shadowing false"]
        out.append("[*] --> \(S.initial.name)")
        for t in S.transitions {
            let label = t.guardText.map { "\(t.event)\\n[\($0)]" } ?? t.event
            out.append("\(t.from.name) --> \(t.to.name) : \(label)")
        }
        for s in S.allCases where s.isTerminal {
            out.append("\(s.name) --> [*]")
        }
        out.append("@enduml")
        return out.joined(separator: "\n")
    }

    public static func mermaid<S: LifecycleState>(_ type: S.Type) -> String {
        var out = ["stateDiagram-v2", "    [*] --> \(S.initial.name)"]
        for t in S.transitions {
            let label = t.guardText.map { "\(t.event) [\($0)]" } ?? t.event
            out.append("    \(t.from.name) --> \(t.to.name): \(label)")
        }
        for s in S.allCases where s.isTerminal {
            out.append("    \(s.name) --> [*]")
        }
        return out.joined(separator: "\n")
    }

    /// Sanity checks the machine itself. These are the mistakes that survive a
    /// hand-drawn diagram and get caught in the interview.
    public struct Audit: Sendable {
        public let machine: String
        public let unreachable: [String]
        public let deadEnds: [String]
        public var isClean: Bool { unreachable.isEmpty && deadEnds.isEmpty }
    }

    public static func audit<S: LifecycleState>(_ type: S.Type) -> Audit {
        var reachable: Set<S> = [S.initial]
        var frontier = [S.initial]
        while let s = frontier.popLast() {
            for n in s.successors where !reachable.contains(n) {
                reachable.insert(n)
                frontier.append(n)
            }
        }
        let unreachable = S.allCases.filter { !reachable.contains($0) }.map(\.name)
        // A non-terminal state with no outgoing edge is a state the object can never leave.
        let deadEnds = S.allCases
            .filter { !$0.isTerminal && $0.successors.isEmpty }
            .map(\.name)
        return Audit(machine: S.machineName, unreachable: unreachable.sorted(), deadEnds: deadEnds.sorted())
    }
}
