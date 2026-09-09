import Foundation

/// Member D — CF10 habit memory.
public enum MemoryItemState: String, LifecycleState {
    case candidate, verified, active, contradicted, superseded
    case unconfirmed, decaying, expired, deleted

    public static let machineName = "MemoryItem"
    public static let initial: MemoryItemState = .candidate
    public var isTerminal: Bool { self == .superseded || self == .expired || self == .deleted }

    public static let transitions: [Transition<MemoryItemState>] = [
        .init(.candidate, "userConfirmed", .verified),
        .init(.candidate, "corroboratedByBehaviour", .verified, guardText: "observed >= 3 times"),
        .init(.candidate, "rejected", .deleted),
        .init(.verified, "promoted", .active),
        .init(.active, "contradictionDetected", .contradicted),
        .init(.contradicted, "userAdjudicatedAgainst", .superseded),
        .init(.contradicted, "userAdjudicatedFor", .active),
        .init(.active, "noLongerObserved", .unconfirmed),
        .init(.unconfirmed, "reobserved", .active),
        .init(.unconfirmed, "decayWindowPassed", .decaying),
        .init(.decaying, "reobserved", .active),
        .init(.decaying, "confidenceFloorReached", .expired),
        .init(.active, "userDeleted", .deleted),
        .init(.decaying, "userDeleted", .deleted),
    ]
}

public enum MemorySensitivity: String, Sendable, Comparable, CaseIterable {
    case ordinary, personal, health
    private var rank: Int { switch self { case .ordinary: 0; case .personal: 1; case .health: 2 } }
    public static func < (l: Self, r: Self) -> Bool { l.rank < r.rank }
    /// NFR5: health-sensitive memories are pinned on-device and never reach the cloud.
    public var mustStayOnDevice: Bool { self == .health }
}

public struct MemoryItem: Sendable {
    public let id: String
    public var text: String
    public var lifecycle: Lifecycle<MemoryItemState>
    public var confidence: Double
    public let sensitivity: MemorySensitivity
    public let sourceRef: String
    public var decayAt: Date?
    /// Decision-record ids that cited this memory. A pinned memory keeps the
    /// version that was cited, so sealed history cannot be rewritten by decay.
    public private(set) var pinnedBy: Set<String> = []
    /// CF2/reserve: a hard dietary constraint is a MemoryItem that is exempt from decay.
    public let decayExempt: Bool

    public init(id: String, text: String, confidence: Double,
                sensitivity: MemorySensitivity = .ordinary,
                sourceRef: String, decayExempt: Bool = false) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.sensitivity = sensitivity
        self.sourceRef = sourceRef
        self.decayExempt = decayExempt
        self.lifecycle = Lifecycle()
    }

    public var state: MemoryItemState { lifecycle.state }
    public var isRetrievable: Bool { state == .active || state == .unconfirmed || !pinnedBy.isEmpty }

    public mutating func pin(by recordID: String) { pinnedBy.insert(recordID) }
}
