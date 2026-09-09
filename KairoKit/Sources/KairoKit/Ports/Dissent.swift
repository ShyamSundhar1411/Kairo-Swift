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
    /// The bound that stops the demo running forever and the bill running away.
    public static let maxRounds = 2

    public init(id: String, topic: String, positions: [Position]) {
        self.id = id
        self.topic = topic
        self.positions = positions
    }

    public var isClinical: Bool {
        topic.lowercased().contains("clinical") || topic.lowercased().contains("diagnos")
    }

    public mutating func addRebuttal(_ p: Position) -> Bool {
        guard rounds < Self.maxRounds else { return false }
        positions.append(p)
        rounds += 1
        return true
    }

    public mutating func resolve() -> DisagreementOutcome {
        if let o = outcome { return o }
        let result: DisagreementOutcome
        if isClinical {
            // The Steward is not permitted to rule on anything clinical.
            result = .referredToFounder(reason: "clinical topic — outside the Steward's authority")
        } else if positions.count == 1, let only = positions.first {
            result = .converged(winner: only)
        } else {
            // Rule by precedence, then by confidence, then by lower cost-if-wrong.
            let winner = positions.min { a, b in
                if a.objective.precedence != b.objective.precedence {
                    return a.objective.precedence < b.objective.precedence
                }
                if a.confidence != b.confidence { return a.confidence > b.confidence }
                return a.costIfWrong < b.costIfWrong
            }!
            result = .ruled(winner: winner, policy: "safety > accuracy > adherence")
        }
        outcome = result
        return result
    }
}
