import Foundation

/// One delivered nudge and what the user did with it.
public struct NudgeOutcome: Sendable, Equatable, Codable {
    public enum Response: String, Sendable, Codable {
        case accepted, dismissed, snoozed, expired

        /// Snoozing is not a refusal - the user wanted this, later. Counting it as
        /// a rejection would teach the model to stop raising exactly the nudges
        /// somebody keeps deferring because they intend to act on them.
        var isPositive: Bool { self == .accepted || self == .snoozed }
    }

    public let nudgeClass: String
    public let response: Response
    public let at: Date

    public init(nudgeClass: String, response: Response, at: Date) {
        self.nudgeClass = nudgeClass
        self.response = response
        self.at = at
    }
}

/// Where outcomes are kept. A port, so the arbiter's model can be driven from a
/// file on the phone, from the backend, or from a fixture in a test.
public protocol NudgeOutcomeLog: Sendable {
    func outcomes() -> [NudgeOutcome]
    func append(_ outcome: NudgeOutcome)
}

/// CF7 receptivity, learned from what the user has actually done.
///
/// The app shipped with a fixed table - hydration 0.70, sedentary 0.90,
/// bedtimePrep 0.60 - which never moved no matter how many times a nudge was
/// dismissed. The port's own documentation says receptivity is "learned from the
/// outcome history of past nudges", and nothing was.
///
/// Two things are learned here, both shrunk toward a stated prior so that one
/// dismissal does not silence a class for good:
///
///   - a per-class acceptance rate, and
///   - an hour-of-day multiplier, because when somebody is interruptible is at
///     least as strong a signal as what about.
///
/// With no history at all this returns the prior unchanged, and says so through
/// `evidence(for:)` - a 0.5 backed by nothing and a 0.5 backed by forty
/// deliveries are different claims, and the receipt screen is entitled to know
/// which one it is showing.
public struct ObservedReceptivityModel: ReceptivityModel {
    /// What an unmeasured class is worth. Deliberately mid-scale: a new class is
    /// neither promoted nor suppressed until the user has had a say.
    public static let defaultPrior = 0.5

    /// Beta-style shrinkage. At `strength` observations the estimate sits halfway
    /// between the prior and the observed rate. Six is about a week of nudges in
    /// one class - enough to move, not enough to be moved by one bad morning.
    public static let strength = 6.0

    /// The hour multiplier is shrunk harder: there are twenty-four buckets, so any
    /// single one fills slowly and a lone dismissal at 3pm must not close the
    /// afternoon.
    public static let hourStrength = 4.0

    private let log: NudgeOutcomeLog
    private let prior: Double
    private let calendar: Calendar

    public init(log: NudgeOutcomeLog,
                prior: Double = ObservedReceptivityModel.defaultPrior,
                calendar: Calendar = .current) {
        self.log = log
        self.prior = min(1, max(0, prior))
        self.calendar = calendar
    }

    public func receptivity(nudgeClass: String, at t: Date, memories: [MemoryItem]) -> Double {
        let history = log.outcomes()
        let inClass = history.filter { $0.nudgeClass == nudgeClass }

        let base = shrunk(rate: inClass, toward: prior, strength: Self.strength)
        let value = base * hourFactor(at: t, history: history)
        return min(1, max(0, value * quietMultiplier(at: t, memories: memories)))
    }

    /// How much evidence stands behind the number, so a screen can say "based on
    /// 3 deliveries" rather than presenting a prior as a measurement.
    public func evidence(for nudgeClass: String) -> Int {
        log.outcomes().filter { $0.nudgeClass == nudgeClass }.count
    }

    // MARK: - Estimation

    private func shrunk(rate outcomes: [NudgeOutcome],
                        toward prior: Double,
                        strength: Double) -> Double {
        guard !outcomes.isEmpty else { return prior }
        let positive = Double(outcomes.filter { $0.response.isPositive }.count)
        let n = Double(outcomes.count)
        return (positive + prior * strength) / (n + strength)
    }

    /// This hour's acceptance rate relative to *the other* hours', shrunk toward 1.
    ///
    /// Relative rather than absolute: a user who accepts half of everything should
    /// not have every hour scaled to 0.5 twice.
    ///
    /// The baseline deliberately excludes this hour's own outcomes. Comparing a
    /// bucket against a total it is itself part of applies the same evidence
    /// twice - with a single dismissal in the whole history it dragged the
    /// estimate down through the class rate and then again through the hour
    /// factor, which is how one bad morning got to count as two.
    private func hourFactor(at t: Date, history: [NudgeOutcome]) -> Double {
        guard !history.isEmpty else { return 1 }
        let hour = calendar.component(.hour, from: t)
        var thisHour: [NudgeOutcome] = []
        var otherHours: [NudgeOutcome] = []
        for outcome in history {
            if calendar.component(.hour, from: outcome.at) == hour {
                thisHour.append(outcome)
            } else {
                otherHours.append(outcome)
            }
        }
        // Nothing to be relative to: either this hour is unmeasured, or it is the
        // only hour there is and carries no information about time of day.
        guard !thisHour.isEmpty, !otherHours.isEmpty else { return 1 }

        let baseline = shrunk(rate: otherHours, toward: prior, strength: Self.strength)
        guard baseline > 0 else { return 1 }
        let here = shrunk(rate: thisHour, toward: baseline, strength: Self.hourStrength)
        // Bounded: an hour may halve or double the estimate, not erase it. An
        // unbounded factor lets a handful of outcomes in one bucket decide the
        // whole day, which is the overfitting the shrinkage is there to prevent.
        return min(2, max(0.5, here / baseline))
    }

    /// A user who has said when not to interrupt them has stated a constraint, not
    /// produced an observation, and it outranks anything the history suggests.
    ///
    /// The hour is read out of the memory rather than fixed at 9, and the user's
    /// own calendar decides what hour it is - the model this replaces hard-coded
    /// `Australia/Sydney`, which is a fact about where the project was written.
    private func quietMultiplier(at t: Date, memories: [MemoryItem]) -> Double {
        let hour = calendar.component(.hour, from: t)
        for memory in memories where memory.isRetrievable {
            guard let before = Self.quietBefore(memory.text) else { continue }
            if hour < before { return 0.1 }
        }
        return 1
    }

    /// Reads "ignores nudges before 9am" and its neighbours. Returns the hour on a
    /// 24-hour clock, or nil when the memory is not about a quiet window.
    static func quietBefore(_ text: String) -> Int? {
        let lower = text.lowercased()
        guard lower.contains("before") else { return nil }
        guard let range = lower.range(of: #"before\s+(\d{1,2})\s*(am|pm)?"#,
                                      options: .regularExpression) else { return nil }
        let phrase = lower[range]
        guard let digits = phrase.range(of: #"\d{1,2}"#, options: .regularExpression),
              var hour = Int(phrase[digits]), (0...12).contains(hour) || hour < 24
        else { return nil }
        if phrase.contains("pm"), hour < 12 { hour += 12 }
        if phrase.contains("am"), hour == 12 { hour = 0 }
        return min(23, max(0, hour))
    }
}
