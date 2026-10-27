import Foundation

/// Member A — CF3. Roles carry conflicting objectives on purpose; this is the
/// bounded procedure that resolves a contradiction on the record.

public enum Objective: String, Sendable, CaseIterable {
    case safety, accuracy, adherence
    /// The written, versioned precedence policy: safety > accuracy > adherence.
    public var precedence: Int {
        switch self { case .safety: 0; case .accuracy: 1; case .adherence: 2 }
    }
}

public struct Position: Sendable, Equatable {
    public let agent: AgentID
    public let objective: Objective
    public let claim: String
    public let evidence: [String]
    public let confidence: Double
    /// How bad it is to act on this position when it is wrong.
    public let costIfWrong: Double

    public init(agent: AgentID, objective: Objective, claim: String,
                evidence: [String], confidence: Double, costIfWrong: Double) {
        self.agent = agent
        self.objective = objective
        self.claim = claim
        self.evidence = evidence
        self.confidence = confidence
        self.costIfWrong = costIfWrong
    }
}

public enum DisagreementOutcome: Sendable, Equatable {
    case converged(winner: Position)
    case ruled(winner: Position, policy: String)
    case referredToFounder(reason: String)
}

public struct DisagreementCase: Sendable {
    public let id: String
    public let topic: String
    public private(set) var positions: [Position]
    public private(set) var rounds: Int = 0
    public private(set) var outcome: DisagreementOutcome?
    /// Figure 34, driven rather than declared beside the case. A machine
    /// nothing fires is the `stewardVetoed` mistake, and this is where the
    /// evidence trail for a contested recommendation comes from.
    public private(set) var lifecycle = Lifecycle<DisagreementCaseState>()
    /// The bound that stops the demo running forever and the bill running away.
    public static let maxRounds = 2

    public init(id: String, topic: String, positions: [Position]) {
        self.id = id
        self.topic = topic
        self.positions = positions
    }

    public var state: DisagreementCaseState { lifecycle.state }

    public var isClinical: Bool {
        topic.lowercased().contains("clinical") || topic.lowercased().contains("diagnos")
    }

    /// Fewer than two positions is nothing to adjudicate.
    ///
    /// A case is opened *because* roles disagree, so two standing positions
    /// are a disagreement by construction. Consensus is what rebuttals are
    /// for: a role withdrawing leaves one position, which is the diagram's
    /// `consensus reached`.
    public var hasConsensus: Bool { positions.count < 2 }

    /// One rebuttal, if the round budget allows it.
    ///
    /// The counter and the `nextRound` self-transition move together. The
    /// counter alone was skippable by anything that forgot to check it.
    public mutating func addRebuttal(_ p: Position, at: Date = .distantPast) -> Bool {
        guard rounds < Self.maxRounds else { return false }
        if state == .open {
            _ = try? lifecycle.transition(on: "positionsComplete", to: .underRebuttal, at: at)
        }
        _ = try? lifecycle.transition(on: "nextRound", to: .underRebuttal, at: at)
        positions.append(p)
        rounds += 1
        return true
    }

    /// Walk Figure 34 and return what the walk decided.
    ///
    /// The order is the diagram's, not the old short-circuit's. Clinical is
    /// checked at the choice node *under* DEADLOCKED, which is the only place
    /// it appears: escalation is about who may rule when roles disagree, not
    /// about the subject being medical. A clinical topic with nothing to
    /// adjudicate converges like any other. Mirrors `dissent.py`.
    @discardableResult
    public mutating func resolve(at: Date = .distantPast) -> DisagreementOutcome {
        if let o = outcome { return o }
        if state == .open {
            _ = try? lifecycle.transition(on: "positionsComplete", to: .underRebuttal, at: at)
        }

        if hasConsensus, let only = positions.first {
            _ = try? lifecycle.transition(on: "consensusReached", to: .resolved, at: at)
            outcome = .converged(winner: only)
            return outcome!
        }

        // No consensus, and the rebuttal budget is spent. The diagram only
        // deadlocks at round = 2; a caller that supplied no rebuttals has
        // exhausted it at zero, which is the same standing disagreement.
        _ = try? lifecycle.transition(on: "declareDeadlock", to: .deadlocked, at: at)

        let result: DisagreementOutcome
        if isClinical {
            // The Steward is not permitted to rule on anything clinical.
            _ = try? lifecycle.transition(on: "notifyHumanOperator", to: .escalated, at: at)
            result = .referredToFounder(reason: "clinical topic — outside the Steward's authority")
        } else {
            // Rule by precedence, then by confidence, then by lower cost-if-wrong.
            let winner = positions.min { a, b in
                if a.objective.precedence != b.objective.precedence {
                    return a.objective.precedence < b.objective.precedence
                }
                if a.confidence != b.confidence { return a.confidence > b.confidence }
                return a.costIfWrong < b.costIfWrong
            }!
            _ = try? lifecycle.transition(on: "stewardRuled", to: .resolved, at: at)
            result = .ruled(winner: winner, policy: "safety > accuracy > adherence")
        }
        outcome = result
        return result
    }

    /// The human operator's answer, which outranks every AI position (AG-5).
    ///
    /// Only reachable from `escalated`, which is the point: nothing can record
    /// an operator ruling on a case no operator was ever shown.
    @discardableResult
    public mutating func ruleOn(_ winner: Position, at: Date = .distantPast) throws -> DisagreementOutcome {
        _ = try lifecycle.transition(on: "operatorRuled", to: .resolved, at: at)
        outcome = .ruled(winner: winner, policy: "ruled by the on-call human operator")
        return outcome!
    }

    /// Both branches of the screen under RESOLVED end sealed. An empty case and
    /// a case deliberately not shown are otherwise indistinguishable.
    public mutating func seal(releasable: Bool, at: Date = .distantPast) throws {
        _ = try lifecycle.transition(on: releasable ? "presented" : "withheld",
                                     to: .sealed, at: at)
    }
}
