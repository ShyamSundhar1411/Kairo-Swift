import Foundation

/// Member D - CF12 "why did you say that?".
///
/// The modelling point worth making in the interview: no transition may mutate
/// sealed content. Corrections append an annotation; they never edit history.
public enum DecisionRecordState: String, LifecycleState {
    case assembling, sealed, published, queried, replayed
    /// `purged` is reachable only from `assembling`: a draft abandoned before
    /// it was ever sealed is not a record, and discarding it deletes no
    /// evidence. There is no path from `published`.
    case disputed, underReview, amendedByAnnotation, purged

    public static let machineName = "DecisionRecord"
    public static let initial: DecisionRecordState = .assembling
    public var isTerminal: Bool { self == .purged }

    public static let transitions: [Transition<DecisionRecordState>] = [
        .init(.assembling, "allFragmentsCollected", .sealed),
        .init(.assembling, "abandoned", .purged),
        .init(.sealed, "deliveredToUser", .published),
        .init(.published, "userAskedWhy", .queried),
        .init(.queried, "founderReplayed", .replayed),
        .init(.replayed, "closed", .published),
        .init(.queried, "closed", .published),
        .init(.published, "userDisputed", .disputed),
        .init(.disputed, "openedForReview", .underReview),
        .init(.underReview, "annotationAppended", .amendedByAnnotation,
              guardText: "append only - sealed content is never rewritten"),
        .init(.amendedByAnnotation, "closed", .published),
        // Figure 41 carries an annotation rather than an edge: "No final
        // state: sealed records are never deleted or rewritten; they are
        // retained for audit (FR12.3, NFR12)". The two edges that used to be
        // here - published → retentionExpired → purged - are not drift from
        // that, they are its opposite. Mirrors records.py.
    ]
}

/// What one agent contributed to one released recommendation.
public struct ContributionFragment: Sendable, Equatable {
    public let agentID: String
    public let promptVersion: String
    public let claim: String
    public let confidence: Double
    public init(agentID: String, promptVersion: String, claim: String, confidence: Double) {
        self.agentID = agentID
        self.promptVersion = promptVersion
        self.claim = claim
        self.confidence = confidence
    }
}

public struct MemoryCitation: Sendable, Equatable {
    public let memoryID: String
    /// The confidence the memory held *at the moment it was cited*, not now.
    public let confidenceAtCitation: Double
    public init(memoryID: String, confidenceAtCitation: Double) {
        self.memoryID = memoryID
        self.confidenceAtCitation = confidenceAtCitation
    }
}

/// A bid that lost. Recording these is what makes the arbitration inspectable.
public struct RejectedAlternative: Sendable, Equatable {
    public let bidID: String
    public let nudgeClass: String
    public let score: Double
    public let reason: SuppressionReason
    public init(bidID: String, nudgeClass: String, score: Double, reason: SuppressionReason) {
        self.bidID = bidID
        self.nudgeClass = nudgeClass
        self.score = score
        self.reason = reason
    }
}

public struct Annotation: Sendable, Equatable {
    public let at: Date
    public let author: String
    public let text: String
    public init(at: Date, author: String, text: String) {
        self.at = at; self.author = author; self.text = text
    }
}

public struct DecisionRecord: Sendable {
    public let id: String
    public var lifecycle: Lifecycle<DecisionRecordState>
    public let createdAt: Date

    private var _fragments: [ContributionFragment] = []
    private var _citations: [MemoryCitation] = []
    private var _rejected: [RejectedAlternative] = []
    public private(set) var safetyVerdict: String?
    public private(set) var serviceTier: String?
    /// Appended after sealing. The only thing that may grow on a sealed record.
    public private(set) var annotations: [Annotation] = []

    public init(id: String, createdAt: Date) {
        self.id = id
        self.createdAt = createdAt
        self.lifecycle = Lifecycle()
    }

    public var state: DecisionRecordState { lifecycle.state }
    public var isSealed: Bool { state != .assembling }
    public var fragments: [ContributionFragment] { _fragments }
    public var citations: [MemoryCitation] { _citations }
    public var rejectedAlternatives: [RejectedAlternative] { _rejected }
    /// Which roles contributed - the direct answer to "are these five relabelled prompts?".
    public var contributingAgents: [String] { _fragments.map(\.agentID) }

    public enum SealError: Error, CustomStringConvertible {
        case recordIsSealed(String)
        public var description: String {
            switch self { case let .recordIsSealed(what): return "DecisionRecord is sealed; cannot add \(what)" }
        }
    }

    public mutating func add(_ f: ContributionFragment) throws {
        guard !isSealed else { throw SealError.recordIsSealed("a contribution fragment") }
        _fragments.append(f)
    }
    public mutating func cite(_ c: MemoryCitation) throws {
        guard !isSealed else { throw SealError.recordIsSealed("a memory citation") }
        _citations.append(c)
    }
    public mutating func reject(_ r: RejectedAlternative) throws {
        guard !isSealed else { throw SealError.recordIsSealed("a rejected alternative") }
        _rejected.append(r)
    }
    public mutating func setSafetyVerdict(_ v: String, tier: String) throws {
        guard !isSealed else { throw SealError.recordIsSealed("a safety verdict") }
        safetyVerdict = v
        serviceTier = tier
    }
    /// Permitted on a sealed record - this is the whole point of "append only".
    public mutating func annotate(_ a: Annotation) { annotations.append(a) }
}
