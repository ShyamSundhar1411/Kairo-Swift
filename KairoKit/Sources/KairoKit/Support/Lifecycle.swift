import Foundation

/// One declared edge of a state machine.
///
/// The transition table is data, not control flow, which is what lets
/// `kairo-uml` render the same machine the code enforces.
public struct Transition<S: Hashable & Sendable>: Sendable, Hashable {
    public let from: S
    public let to: S
    public let event: String
    /// Human-readable guard, rendered into the diagram as `[guard]`.
    public let guardText: String?

    public init(_ from: S, _ event: String, _ to: S, guardText: String? = nil) {
        self.from = from
        self.event = event
        self.to = to
        self.guardText = guardText
    }
}

/// A domain object with a declared, enforceable lifecycle.
public protocol LifecycleState: Hashable, Sendable, CaseIterable {
    static var machineName: String { get }
    static var initial: Self { get }
    static var transitions: [Transition<Self>] { get }
    var isTerminal: Bool { get }
    /// The name rendered into diagrams and errors.
    var name: String { get }
}

public extension LifecycleState {
    /// Every state reachable from `self` by one declared edge.
    var successors: [Self] { Self.transitions.filter { $0.from == self }.map(\.to) }
}

// Every machine in this project is a String-backed enum, so the state name comes
// for free.  Do NOT implement this as `String(describing: self)`: on a type that
// also conforms to CustomStringConvertible that recurses until the stack dies.
public extension LifecycleState where Self: RawRepresentable, Self.RawValue == String {
    var name: String { rawValue }
}

public struct TransitionRecord<S: LifecycleState>: Sendable, Equatable {
    public let from: S
    public let to: S
    public let event: String
    public let at: Date

    public init(from: S, to: S, event: String, at: Date) {
        self.from = from
        self.to = to
        self.event = event
        self.at = at
    }
}

public enum LifecycleError<S: LifecycleState>: Error, CustomStringConvertible {
    case illegalTransition(from: S, to: S, event: String)
    case alreadyTerminal(state: S)

    public var description: String {
        switch self {
        case let .illegalTransition(from, to, event):
            return "\(S.machineName): no declared transition \(from.name) --\(event)--> \(to.name)"
        case let .alreadyTerminal(state):
            return "\(S.machineName): \(state.name) is terminal and accepts no further transitions"
        }
    }
}

/// Holds the current state and the full transition history of one object.
///
/// The history is not a debugging convenience: it is the evidence a
/// `DecisionRecord` cites and the audit log the Steward reads.
public struct Lifecycle<S: LifecycleState>: Sendable {
    public private(set) var state: S
    public private(set) var history: [TransitionRecord<S>] = []

    public init(_ state: S = S.initial) { self.state = state }

    public var isTerminal: Bool { state.isTerminal }

    @discardableResult
    public mutating func transition(on event: String, to next: S, at now: Date) throws -> S {
        if state.isTerminal { throw LifecycleError<S>.alreadyTerminal(state: state) }
        let declared = S.transitions.contains { $0.from == state && $0.to == next && $0.event == event }
        guard declared else {
            throw LifecycleError<S>.illegalTransition(from: state, to: next, event: event)
        }
        history.append(TransitionRecord(from: state, to: next, event: event, at: now))
        state = next
        return next
    }

    /// True when the object ever passed through `state`.
    public func visited(_ s: S) -> Bool {
        s == S.initial || history.contains { $0.to == s }
    }
}
