import Foundation

/// Figure 34 - the disagreement case lifecycle (UC2).
///
/// The case already had `rounds`, `maxRounds` and `resolve()`, and no machine.
/// So the rebuttal round the diagram counts was a number nobody could be
/// stopped from skipping: `resolve()` answered the same way whether it was
/// called on a case that had been through the procedure or one created a line
/// earlier. The states are what make the procedure a procedure rather than a
/// convention. Mirrors `backend/kairo/domain/dissent.py`.
public enum DisagreementCaseState: String, LifecycleState {
    case open, underRebuttal, deadlocked, escalated, resolved, sealed

    public static let machineName = "DisagreementCase"
    public static let initial: DisagreementCaseState = .open
    public var isTerminal: Bool { self == .sealed }

    public static let transitions: [Transition<DisagreementCaseState>] = [
        .init(.open, "positionsComplete", .underRebuttal,
              guardText: "both roles have stated an admissible position; round = 1"),
        // The self-transition the diagram draws as `nextRound()`. An edge
        // rather than a counter alone, so a third round cannot be taken by
        // anything that forgot to check.
        .init(.underRebuttal, "nextRound", .underRebuttal,
              guardText: "no consensus and round < 2"),
        .init(.underRebuttal, "consensusReached", .resolved,
              guardText: "resolve(CONSENSUS)"),
        .init(.underRebuttal, "declareDeadlock", .deadlocked,
              guardText: "no consensus and round = 2"),
        // The choice node under DEADLOCKED. Clinical goes to a person: the
        // Steward may not rule on it, and the precedence policy is not a
        // clinical opinion.
        .init(.deadlocked, "notifyHumanOperator", .escalated, guardText: "clinical"),
        .init(.deadlocked, "stewardRuled", .resolved,
              guardText: "not clinical - rank(positions), resolve(STEWARD_RULING)"),
        .init(.escalated, "operatorRuled", .resolved,
              guardText: "ruleOn(case) - resolve(OPERATOR_RULING)"),
        // Both branches of the screen under RESOLVED end sealed. A withheld
        // recommendation is sealed with the reason it was withheld, which is
        // the branch that makes the record worth keeping.
        .init(.resolved, "presented", .sealed,
              guardText: "verdict.isReleasable() - present card, seal()"),
        .init(.resolved, "withheld", .sealed,
              guardText: "not releasable - withhold, record reason, seal()"),
    ]
}
