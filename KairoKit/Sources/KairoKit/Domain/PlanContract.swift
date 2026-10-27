import Foundation

/// Member C — CF9 Disruption contract.
///
/// The point of the machine is what it refuses to do: it will not extend forever.
/// A third extension escalates, because a fortnight of "still unwell" is a signal,
/// not a setting.
public enum PlanContractState: String, LifecycleState {
    case standard, disruptionSuspected, proposed, declined, active
    case extending, recovering, restored, abandoned, escalated

    public static let machineName = "PlanContract"
    public static let initial: PlanContractState = .standard
    public var isTerminal: Bool { self == .restored || self == .abandoned || self == .escalated }

    public static let transitions: [Transition<PlanContractState>] = [
        .init(.standard, "signalDetected", .disruptionSuspected),
        .init(.disruptionSuspected, "insufficientEvidence", .standard,
              guardText: "fewer than 2 corroborating signals and no user confirmation"),
        .init(.disruptionSuspected, "corroborated", .proposed,
              guardText: ">= 2 signals || user confirmed"),
        // Figure 38: the veto edge leaves *Drafted* and lands on *Escalated*.
        // The Steward vetoes when it thinks the contract would hide someone
        // getting worse, and returning quietly to standard targets is the one
        // response that guarantees that goes unseen. Mirrors contract.py.
        .init(.disruptionSuspected, "stewardVetoed", .escalated,
              guardText: "contract would mask genuine deterioration"),
        .init(.proposed, "userDeclined", .declined),
        .init(.declined, "returnToStandard", .standard),
        .init(.proposed, "userAccepted", .active),
        .init(.active, "expiryReached", .extending, guardText: "extensionCount < 1 (auto-extend once)"),
        .init(.extending, "extensionGranted", .active),
        .init(.active, "expiryReachedAgain", .recovering, guardText: "extensionCount >= 1"),
        .init(.active, "thirdExtensionRequested", .escalated,
              guardText: "extensionCount >= 2 — escalate instead of extending"),
        .init(.active, "userEndedEarly", .recovering),
        .init(.recovering, "rampCompleted", .restored),
        .init(.recovering, "userDisengaged", .abandoned),
        .init(.recovering, "relapseDetected", .escalated),
    ]
}

public enum DisruptionKind: String, CaseIterable, Sendable {
    case illness, travel, deadline, injury
}

/// Abstract `DisruptionSignal` in the class diagram; the kind discriminates the subclasses.
public struct DisruptionSignal: Sendable, Equatable {
    public let kind: DisruptionKind
    public let source: String        // e.g. "wristTemperature", "timeZoneShift"
    public let observedAt: Date
    public let strength: Double      // 0...1
    public init(kind: DisruptionKind, source: String, observedAt: Date, strength: Double) {
        self.kind = kind
        self.source = source
        self.observedAt = observedAt
        self.strength = strength
    }
}

public struct SuspendedNudgeClass: Sendable, Equatable, Hashable {
    public let name: String
    public init(_ name: String) { self.name = name }
}

public struct PlanContract: Sendable {
    public let id: String
    public var lifecycle: Lifecycle<PlanContractState>
    public private(set) var signals: [DisruptionSignal] = []
    public var kind: DisruptionKind?
    /// Fraction the day's targets are reduced by while the contract is active.
    public var targetReduction: Double = 0
    public var suspended: Set<SuspendedNudgeClass> = []
    public var expiresAt: Date?
    public private(set) var extensionCount: Int = 0
    /// FR9.5. Why the Steward refused this contract, in its own sentence. Set
    /// only on the vetoed path, and kept after the state returns to `.standard`:
    /// the contract is gone, and the reason it never happened is the part worth
    /// showing. Mirrors `PlanContract.steward_veto_reason` in the backend.
    public var stewardVetoReason: String?

    public init(id: String) {
        self.id = id
        self.lifecycle = Lifecycle()
    }

    public var state: PlanContractState { lifecycle.state }
    public var isActive: Bool { state == .active }

    public mutating func observe(_ s: DisruptionSignal) { signals.append(s) }

    /// CF9's hard rule, written once and enforced here rather than in a prompt:
    /// two independent corroborating signals, or the user saying so out loud.
    public func isCorroborated(userConfirmed: Bool) -> Bool {
        if userConfirmed { return true }
        let distinctSources = Set(signals.map(\.source))
        return distinctSources.count >= 2
    }

    public mutating func noteExtension() { extensionCount += 1 }

    /// Whether the *next* expiry may auto-extend, must ask, or must escalate.
    public enum ExpiryDisposition: String, Sendable { case autoExtend, askUser, escalate }
    public var expiryDisposition: ExpiryDisposition {
        switch extensionCount {
        case 0: return .autoExtend
        case 1: return .askUser
        default: return .escalate
        }
    }
}
