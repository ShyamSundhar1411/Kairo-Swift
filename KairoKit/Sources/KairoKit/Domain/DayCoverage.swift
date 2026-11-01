import Foundation

/// Member B - CF6 Evidence-sufficiency gate.
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
/// returning a downgraded form - the sequence diagram in Member B's chain.
public extension CoverageDomain {
    /// The domain a nudge of this class makes claims about, or nil when it claims
    /// nothing measurable - a bid that only asks a question is not making one.
    ///
    /// This mapping is what lets CF6 apply to the nudges the user actually sees.
    /// Until it existed the evidence gate was reachable from exactly one badge on
    /// one screen, and every interruption the arbiter delivered went out unscreened.
    static func claimed(byNudgeClass nudgeClass: String) -> CoverageDomain? {
        switch nudgeClass {
        case "hydration":                 return .hydration
        case "sedentary", "movement":     return .movement
        case "bedtimePrep", "sleep":      return .sleep
        case "mealLog", "meal", "meals":  return .meals
        default:                          return nil
        }
    }
}

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
    /// 0...1 - observed over expected, where "expected" comes from this user's learned pattern.
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

// MARK: - FR6.4

/// Low coverage, raised as its own low-priority bid.
///
/// Mirrors `kairo/domain/nudge.py: coverage_bid`. Deterministic and model-free,
/// which is the point of having it here at all: it is the one bid the phone can
/// raise while completely offline, and NFR9's fallback arbiter is only worth
/// having if the day with no connectivity is also the day the user can be told
/// Kairo is not seeing anything.
public enum CoverageBid {
    /// Fixed and low. FR6.4 says low coverage *competes*, so this has to be
    /// beatable by anything with a real finding behind it - and still win on a
    /// day where nothing else bids, which is the day it matters most.
    public static let expectedBenefit = 0.25
    public static let urgency = 0.15
    public static let nudgeClass = "coverage"

    /// The domains under the floor, worst first.
    public static func shortfalls(in coverage: DayCoverage) -> [CoverageDomain] {
        CoverageDomain.allCases
            .filter { coverage.fraction($0) < coverage.floor }
            .sorted { coverage.fraction($0) < coverage.fraction($1) }
    }

    /// What the user is told. Named domains, never a percentage: "coverage is
    /// 41%" is a number about the system, "I have not seen your sleep today" is
    /// a sentence about the user, and FR6.1 asks for the second.
    public static func text(for coverage: DayCoverage) -> String {
        let named = shortfalls(in: coverage).map(\.rawValue)
        guard !named.isEmpty else { return "" }
        let what: String
        switch named.count {
        case 1: what = named[0]
        case 2: what = "\(named[0]) or \(named[1])"
        default:
            what = named.dropLast().joined(separator: ", ") + " or " + named[named.count - 1]
        }
        return "I have not seen enough \(what) today to say much about it. "
             + "Logging any of it would help."
    }

    /// `YYYY-MM-DD` in the given calendar. Built from components rather than a
    /// `DateFormatter` so no locale can turn it into something else.
    static func isoDay(_ date: Date, in calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `nil` when every domain is above the floor - the common case, and it
    /// must cost nothing.
    /// `calendar` defaults to `.current` deliberately: the user's day is theirs,
    /// not ours. Tests pass `DateHelp.calendar` so they say which day they mean
    /// - the distinction that broke three KairoKit tests on the first CI run.
    public static func bid(for coverage: DayCoverage, dayStart: Date,
                           calendar: Calendar = .current) -> NudgeBid? {
        let message = text(for: coverage)
        guard !message.isEmpty else { return nil }
        let day = calendar.startOfDay(for: dayStart)
        return NudgeBid(
            // The id is the day, so a round that runs six times does not produce
            // six identical complaints about the same missing data.
            id: "coverage:" + Self.isoDay(day, in: calendar),
            nudgeClass: nudgeClass, originAgent: "Orchestrator",
            expectedBenefit: expectedBenefit, urgency: urgency,
            // The whole day. A coverage shortfall is not a moment - it does not
            // become more or less true at 3pm - so a short window would let the
            // one bid about *not having data* expire before anything saw it.
            windowOpens: day,
            windowCloses: calendar.date(byAdding: .day, value: 1, to: day) ?? day,
            text: message)
    }
}
