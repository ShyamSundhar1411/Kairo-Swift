import Foundation

/// Member B — CF6 Evidence-sufficiency gate.
///
/// Coverage is not a quality score shown to the user. It decides what any agent is
/// *permitted to assert*, which is why it is a first-class object with a lifecycle.
public enum DayCoverageState: String, LifecycleState {
    case open, partial, sufficient, sealed, reopened, contested

    public static let machineName = "DayCoverage"
    public static let initial: DayCoverageState = .open
    public var isTerminal: Bool { false }   // a sealed day reopens when late data arrives

    public static let transitions: [Transition<DayCoverageState>] = [
        .init(.open, "firstSampleArrived", .partial),
        .init(.partial, "coverageReachedFloor", .sufficient, guardText: "all domains >= floor"),
        .init(.partial, "dayEnded", .sealed, guardText: "sealed below floor: assertions stay downgraded"),
        .init(.sufficient, "dayEnded", .sealed),
        .init(.sealed, "lateDataArrived", .reopened),
        .init(.reopened, "recomputed", .sealed),
        .init(.sealed, "userDisputedBackfill", .contested),
        .init(.contested, "userAdjudicated", .reopened),
    ]
}

public enum CoverageDomain: String, CaseIterable, Sendable {
    case meals, sleep, movement, hydration
}

/// What a claim is allowed to sound like, given the evidence behind it.
///
/// The Steward enforces this by rejecting the Coach's own outbound message and
/// returning a downgraded form — the sequence diagram in Member B's chain.
public enum AssertionForm: Int, Comparable, Sendable {
    case forbidden = 0      // may not be said at all
    case question = 1       // "did you eat lunch?"
    case range = 2          // "somewhere between X and Y"
    case qualified = 3      // "on the four days I could see"
    case assertion = 4      // a bare number

    public static func < (l: AssertionForm, r: AssertionForm) -> Bool { l.rawValue < r.rawValue }
}

public struct CoverageMetric: Sendable, Equatable {
    public let domain: CoverageDomain
    /// 0...1 — observed over expected, where "expected" comes from this user's learned pattern.
    public let observedFraction: Double
    public let expectedCount: Int
    public let observedCount: Int

    public init(domain: CoverageDomain, observedCount: Int, expectedCount: Int) {
        self.domain = domain
        self.observedCount = observedCount
        self.expectedCount = expectedCount
        self.observedFraction = expectedCount == 0 ? 1 : min(1, Double(observedCount) / Double(expectedCount))
    }
}

public struct DayCoverage: Sendable {
    public let dayStart: Date
    public var lifecycle: Lifecycle<DayCoverageState>
    public private(set) var metrics: [CoverageDomain: CoverageMetric] = [:]
    /// Below this, a domain may not carry a bare number.
    /// Default 0.6: two of three expected meals is enough for a qualified claim,
    /// one of three is not.
    public let floor: Double

    public init(dayStart: Date, floor: Double = 0.6) {
        self.dayStart = dayStart
        self.floor = floor
        self.lifecycle = Lifecycle()
    }

    public var state: DayCoverageState { lifecycle.state }

    public mutating func record(_ m: CoverageMetric) { metrics[m.domain] = m }

    public func fraction(_ d: CoverageDomain) -> Double { metrics[d]?.observedFraction ?? 0 }

    public var allDomainsAboveFloor: Bool {
        CoverageDomain.allCases.allSatisfy { fraction($0) >= floor }
    }

    /// The gate itself. A claim about `domain` may take at most this form.
    public func permittedForm(for domain: CoverageDomain) -> AssertionForm {
        let f = fraction(domain)
        let rangeFloor = floor / 2
        if f >= 1.0        { return .assertion }
        if f >= floor      { return .qualified }
        if f >= rangeFloor { return .range }
        if f > 0           { return .question }
        return .forbidden
    }
}
