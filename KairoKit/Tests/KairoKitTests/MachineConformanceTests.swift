import Testing
import Foundation
@testable import KairoKit

/// The two halves' lifecycle tables, pinned to one file.
///
/// `docs/DEVELOPMENT.md` has carried this for months:
///
///   The cost is real: `kairo-uml audit` checks only the Swift tables,
///   `scripts/export-state-machines.sh` renders only the Python ones, and
///   **no test compares the two**. If they drift again, nothing will say so.
///
/// Something says so now. The backend's `test_machine_conformance.py` reads
/// the same `docs/state-machines.json`; this asserts the device's tables match
/// it, minus the edges `deviceOmits` says the phone cannot make.
@Suite("Both halves - lifecycle tables")
struct MachineConformanceTests {

    /// One row of a table, flattened the way the shared file stores it.
    private struct Edge: Hashable, CustomStringConvertible {
        let from: String, event: String, to: String
        var description: String { "\(from) --\(event)--> \(to)" }
        init(_ row: [String]) { from = row[0]; event = row[1]; to = row[2] }
        init(from: String, event: String, to: String) {
            self.from = from; self.event = event; self.to = to
        }
    }

    private struct Shared {
        let machines: [String: [String: Any]]
        let omits: [String: Set<Edge>]
    }

    private func shared() throws -> Shared {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // KairoKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // KairoKit
            .deletingLastPathComponent()   // <repo root>
        let data = try Data(contentsOf: root.appending(path: "docs/state-machines.json"))
        let doc = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let omitsRaw = doc["deviceOmits"] as? [String: [[String]]] ?? [:]
        return Shared(machines: doc["machines"] as! [String: [String: Any]],
                      omits: omitsRaw.mapValues { Set($0.map(Edge.init)) })
    }

    /// Compare one machine against the file, allowing its declared omissions.
    private func check<S: LifecycleState>(_ type: S.Type) throws {
        let doc = try shared()
        let name = S.machineName
        let expectedRows = try #require(doc.machines[name]?["transitions"] as? [[String]],
                                        "\(name) is not in docs/state-machines.json")
        let omitted = doc.omits[name] ?? []
        let expected = Set(expectedRows.map(Edge.init)).subtracting(omitted)
        // `name`, not `rawValue`: LifecycleState does not require
        // RawRepresentable, and `name` is the identifier the diagrams and the
        // shared file both use.
        let actual = Set(S.transitions.map {
            Edge(from: $0.from.name, event: $0.event, to: $0.to.name)
        })

        // Reported as two sets rather than one equality, because "these three
        // edges are missing" is a fix and "the tables differ" is a bisect.
        let missing = expected.subtracting(actual)
        let extra = actual.subtracting(expected).subtracting(omitted)
        #expect(missing.isEmpty, "\(name) is missing: \(missing.map(\.description).sorted())")
        #expect(extra.isEmpty, "\(name) has undeclared edges: \(extra.map(\.description).sorted())")

        #expect(S.initial.name == doc.machines[name]?["initial"] as? String)
        let expectedTerminal = (doc.machines[name]?["terminal"] as? [String] ?? []).sorted()
        let actualTerminal = S.allCases.filter(\.isTerminal).map(\.name).sorted()
        #expect(actualTerminal == expectedTerminal, "\(name) terminal states differ")
    }

    @Test func dayCoverage()      throws { try check(DayCoverageState.self) }
    @Test func planContract()     throws { try check(PlanContractState.self) }
    @Test func nudge()            throws { try check(NudgeState.self) }
    @Test func decisionRecord()   throws { try check(DecisionRecordState.self) }
    @Test func memoryItem()       throws { try check(MemoryItemState.self) }
    @Test func disagreementCase() throws { try check(DisagreementCaseState.self) }
    @Test func adviceScreening()  throws { try check(AdviceScreeningState.self) }

    @Test("the device's one declared omission is still the only one")
    func omissionsAreNarrow() throws {
        // `MealEntry` is device-only and has no backend table, so it is
        // deliberately absent from the shared file rather than omitted from it.
        let doc = try shared()
        #expect(doc.omits.keys.sorted() == ["Nudge"])
        #expect(doc.machines["MealEntry"] == nil)
    }
}
