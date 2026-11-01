import Foundation

/// Member B - CF4 / CF6. The sleep debt, computed instead of asserted.
///
/// The screen used to print "Your sleep debt is 2.4 hours." as a string literal
/// and hand it to the evidence gate, which dutifully screened it as though it
/// were a reading. That is the exact failure this project exists to argue
/// against: a number nobody measured, wearing the badge of one that was.
///
/// So the debt lives here, as arithmetic over readings somebody else was handed.
/// Every function in this file is pure over its arguments - no clock, no port,
/// no `Date()` - for the same reason `EnergySummary` is: a week's debt is a
/// property of the nights that were observed, and asking the wall clock about it
/// would only make it untestable.
///
/// The rule that shapes the whole file is the promise in `SleepView`'s trust
/// note: *Kairo will not draw a trend line through days it could not see.* A
/// night the watch was off the wrist is not zero hours slept, it is not the
/// average of its neighbours, and it is not a data point. It is a hole, and the
/// only honest thing to do with a hole is to leave it and say how many there
/// were.

/// One night, as the wrist saw it or failed to.
///
/// `hoursAsleep` is optional and that optionality is the point: `nil` means the
/// watch was off the wrist, which is emphatically not `0`. Somebody who slept
/// badly and somebody who charged their watch produce very different nights, and
/// a `Double` cannot tell them apart.
public struct NightReading: Sendable, Equatable, Identifiable {
    /// The day the sleep is attributed to - by convention the morning the user
    /// woke up, which is how Health itself buckets a night that crosses midnight.
    /// Callers should pass a start-of-day date; nothing here depends on that, but
    /// two readings for the same night must compare equal to be de-duplicated.
    public let night: Date
    /// Hours genuinely asleep. `nil` = never observed. Not `0`.
    public let hoursAsleep: Double?
    /// Hours the device was actually recording across that night. The honest
    /// denominator behind the hours slept: five hours of sleep out of five hours
    /// worn is a different fact from five out of nine.
    public let hoursWorn: Double

    public var id: Date { night }

    public init(night: Date, hoursAsleep: Double?, hoursWorn: Double = 0) {
        self.night = night
        // A negative duration is not a reading. Clamping rather than trapping
        // because this type is fed by an adapter over a framework whose sample
        // dates are, in principle, whatever the source device wrote.
        self.hoursAsleep = hoursAsleep.map { max(0, $0) }
        self.hoursWorn = max(0, hoursWorn)
    }

    /// Whether this night is evidence at all.
    public var isObserved: Bool { hoursAsleep != nil }

    /// How far short of `need` this night fell, or `nil` if it was never seen.
    ///
    /// Never negative: a night above need cancels nothing. Sleep is not a bank
    /// account, and letting Saturday's ten hours erase Tuesday's four would be a
    /// claim about recovery physiology that this app has no business making.
    public func shortfall(need: Double) -> Double? {
        hoursAsleep.map { max(0, need - $0) }
    }
}

/// A window of nights, added up, with the evidence question already answered.
public struct SleepDebt: Sendable, Equatable {
    /// The debt in hours, or `nil` when not a single night in the window was
    /// observed. Note that this is *not* the same as a confidently asserted
    /// zero: "you have no sleep debt" is a claim about the user's week, and an
    /// empty window is the absence of evidence for any claim at all.
    public let hours: Double?
    /// Nights that actually carried a reading.
    public let observedNights: Int
    /// Nights the window asked about. `observedNights` over this is the coverage
    /// fraction, and the gap between them is what the user is owed an
    /// explanation for.
    public let expectedNights: Int
    /// The nightly need the sum was taken against, carried along so the surface
    /// drawing the number can say what it was measured against rather than
    /// implying Kairo invented a goal for this user.
    public let nightlyNeedHours: Double
    /// What a claim about this debt may sound like. See
    /// `SleepSummary.permittedForm(observedNights:expectedNights:)`.
    public let permittedForm: AssertionForm

    public init(hours: Double?, observedNights: Int, expectedNights: Int,
                nightlyNeedHours: Double, permittedForm: AssertionForm) {
        self.hours = hours
        self.observedNights = observedNights
        self.expectedNights = expectedNights
        self.nightlyNeedHours = nightlyNeedHours
        self.permittedForm = permittedForm
    }

    /// Nights in the window that were never seen.
    public var unobservedNights: Int { max(0, expectedNights - observedNights) }

    /// True when nights are missing, which makes the figure a floor rather than a
    /// total.
    ///
    /// This follows from excluding unobserved nights instead of zero-filling
    /// them: every missing night could only have added shortfall, never removed
    /// any, so the sum can only be too small. Any sentence built from `hours`
    /// while this is true should say "at least", and the assertion ladder below
    /// is what stops it saying anything stronger.
    public var isLowerBound: Bool { unobservedNights > 0 }

    /// The coverage ring's input, so the ring stops being a constant.
    ///
    /// `observedCount` is nights with a reading, not nights that went well -
    /// coverage is about how much of the week Kairo could see.
    public var coverageMetric: CoverageMetric {
        CoverageMetric(domain: .sleep,
                       observedCount: observedNights,
                       expectedCount: max(1, expectedNights))
    }

    /// Average shortfall across the nights that were actually observed.
    ///
    /// The per-night figure is the only one that is comparable between a fully
    /// observed week and a half observed one, which is why it exists alongside
    /// the total. `nil` when nothing was observed.
    public var hoursPerObservedNight: Double? {
        guard let hours, observedNights > 0 else { return nil }
        return hours / Double(observedNights)
    }
}

public enum SleepSummary {

    /// The flat reference night. Eight hours is a population figure, not a
    /// personalised prescription, and every surface that draws it is required to
    /// say so - `SleepView` calls it "a flat 8 h reference" for that reason.
    /// A caller who knows this user's actual need should pass it.
    public static let defaultNightlyNeedHours: Double = 8

    /// The window a "sleep debt" claim is about. Seven nights because the claim
    /// the user reads is a weekly one; a fortnight would bury a bad week and a
    /// weekend would over-read one.
    public static let defaultWindowNights = 7

    // MARK: - The debt

    /// Debt over a window: the sum of each observed night's shortfall.
    ///
    /// `sum of max(0, need - slept)` across the nights that were **actually
    /// observed**. Unobserved nights are excluded from the sum - not zero-filled,
    /// not interpolated, not carried forward from the night before. The exclusion
    /// is structural rather than a comment: `NightReading.shortfall(need:)`
    /// returns `nil` for an unobserved night and `compactMap` drops it, so there
    /// is no code path in which a hole contributes a number.
    ///
    /// - Parameters:
    ///   - readings: one entry per night the window asks about. An adapter is
    ///     expected to emit a blank entry (`hoursAsleep: nil`) for a night it
    ///     found nothing for, which is what makes the hole visible; see
    ///     `slots(for:observedHours:wornHours:)`.
    ///   - nightlyNeed: hours needed per night. Clamped at zero, since a
    ///     non-positive need makes every night a surplus and the debt trivially 0.
    ///   - expectedNights: the denominator for coverage. Defaults to the number
    ///     of readings supplied, which is right when the adapter emits a slot per
    ///     night. Pass it explicitly when the caller knows the window was longer
    ///     than the readings it managed to build - `DayCoverage` describes
    ///     `expectedCount` as coming from this user's learned pattern, and this is
    ///     where that would enter.
    public static func debt(over readings: [NightReading],
                            nightlyNeed: Double = defaultNightlyNeedHours,
                            expectedNights: Int? = nil) -> SleepDebt {
        let need = max(0, nightlyNeed)
        // De-duplicated by night, because two adapters (or one adapter run
        // twice) offering the same night must not double the debt. The later
        // entry wins: a re-read of a night is a correction, not a second night.
        let nights = deduplicated(readings)
        let shortfalls = nights.compactMap { $0.shortfall(need: need) }
        let observed = shortfalls.count
        // The window is at least as long as the readings we have; a caller who
        // claims to have asked about fewer nights than it handed us is wrong
        // rather than authoritative.
        let expected = max(nights.count, expectedNights ?? nights.count)
        let form = permittedForm(observedNights: observed, expectedNights: expected)

        return SleepDebt(
            // Nothing observed means no number, not a zero. `.forbidden` and a
            // nil debt travel together, and the test suite pins that.
            hours: observed == 0 ? nil : shortfalls.reduce(0, +),
            observedNights: observed,
            expectedNights: expected,
            nightlyNeedHours: need,
            permittedForm: form)
    }

    // MARK: - The evidence question

    /// What a claim about a sleep debt may take the form of.
    ///
    /// This is the weaker of two independent limits, in the same shape as
    /// `EnergySummary.permittedForm(for:expectedMeals:)`:
    ///
    /// 1. **Coverage** - what fraction of the window was visible. That ladder is
    ///    already written, in `DayCoverage.permittedForm(for:)`, and is not
    ///    restated here: at the default 0.6 floor, five of seven nights is a
    ///    qualified claim and four of seven is only a range. Duplicating the
    ///    ladder would give the project two floors to retune.
    /// 2. **Absolute nights observed** - how many nights there are, regardless of
    ///    the fraction. See `windowForm(observedNights:)`.
    ///
    /// The second limit exists because coverage alone can be fooled by a short
    /// window. Two nights out of two is a coverage fraction of 1.0, which the
    /// ladder would happily call a bare assertion - but two nights is not a week,
    /// and "your sleep debt is 3 hours" said of a Monday and a Tuesday is a
    /// weekly claim built from a long weekend of ignorance.
    ///
    /// Worked through, the brief's own example: **two of seven nights** gives a
    /// coverage fraction of 0.286, below half the 0.6 floor, which the ladder
    /// calls `.question`; the window limit calls it `.range`. The weaker wins, so
    /// the answer is `.question` and the number is never spoken. That is the
    /// intended behaviour.
    public static func permittedForm(observedNights: Int, expectedNights: Int) -> AssertionForm {
        guard observedNights > 0 else { return .forbidden }
        var coverage = DayCoverage(dayStart: Date(timeIntervalSince1970: 0))
        coverage.record(CoverageMetric(domain: .sleep,
                                       observedCount: observedNights,
                                       expectedCount: max(1, expectedNights)))
        return min(coverage.permittedForm(for: .sleep), windowForm(observedNights: observedNights))
    }

    /// The absolute-nights half of the gate.
    ///
    /// These thresholds are a judgement call, so here is the reasoning to argue
    /// with. A debt is an *accumulation*: unlike a day's kilojoule total, a
    /// single reading is not a small version of it, it is a different quantity.
    /// And because unobserved nights are excluded rather than zero-filled, the
    /// sum is a lower bound whose looseness grows with every missing night - so
    /// the ladder is really asking "how badly could this understate the week?"
    ///
    /// * `>= 6` → `.assertion`. Six or seven nights is enough of a week that this
    ///   limit stops objecting: the figure understates the week by at most one
    ///   night's shortfall. Note that six of seven still comes out `.qualified`
    ///   overall, because the coverage ladder reserves a bare number for a
    ///   complete window - this limit yielding does not mean the gate opened.
    /// * `4...5` → `.qualified`. A majority of the week, but enough missing that
    ///   the number has to carry the caveat naming how many nights it is built
    ///   from - "on the nights I could see". Four is the floor here because it is
    ///   the first count that is more than half of a seven-night week.
    /// * `2...3` → `.range`. Two or three nights can establish that *some* debt
    ///   exists and roughly how large a typical night's shortfall is, but the
    ///   weekly total they imply is mostly extrapolation. A band, never a point.
    /// * `1` → `.question`. One night is not a debt at all. There is nothing to
    ///   accumulate and no way to tell an unusual night from a habit, so the only
    ///   honest output is to ask about the rest of the week.
    /// * `0` → `.forbidden`. No evidence, no claim.
    ///
    /// The counts are absolute rather than fractional on purpose: the failure
    /// this guards against is a short window flattering itself, and a fraction
    /// cannot see the length of its own denominator.
    public static func windowForm(observedNights n: Int) -> AssertionForm {
        if n >= 6 { return .assertion }
        if n >= 4 { return .qualified }
        if n >= 2 { return .range }
        if n >= 1 { return .question }
        return .forbidden
    }

    // MARK: - Filling in the observations

    /// The two `Observations` fields this domain owns.
    ///
    /// `Observations.lines` is explicit that its job is to let the model tell
    /// "zero" from "not measured", and this is the domain where that distinction
    /// does the most work. Both fields stay `nil` where there is no reading:
    ///
    /// * `sleepHoursLastNight` is the *most recent night in the window*, and it
    ///   is `nil` when that night is a hole - even if earlier nights were seen.
    ///   Reporting the last night Kairo happened to observe as "last night" is
    ///   exactly the interpolation the trust note promises not to do.
    /// * `sleepDebtHours` is `nil` when no night was observed, so a week Kairo
    ///   could not see never reads to an agent as a week with no debt.
    ///
    /// Deliberately *not* filtered by `permittedForm`: the agents receive the
    /// figure and the Steward governs the sentence. Screening the input as well
    /// as the output would hide the evidence from the very component whose job is
    /// to weigh it.
    public static func observations(for readings: [NightReading],
                                    nightlyNeed: Double = defaultNightlyNeedHours,
                                    expectedNights: Int? = nil) -> Observations {
        let nights = deduplicated(readings)
        let computed = debt(over: nights, nightlyNeed: nightlyNeed, expectedNights: expectedNights)
        return Observations(
            sleepHoursLastNight: nights.last?.hoursAsleep,
            sleepDebtHours: computed.hours)
    }

    // MARK: - Building a window

    /// One slot per night, so a night nobody saw is present as a blank rather
    /// than absent from the array.
    ///
    /// This is the helper that makes the promise structural. An adapter that
    /// simply returns what it found would hand back three readings for a week and
    /// every downstream coverage figure would read 3-of-3; going through here it
    /// hands back seven, four of them blank, and the coverage ring tells the
    /// truth without anybody remembering to.
    ///
    /// - Parameters:
    ///   - nights: every night the window covers, blanks included.
    ///   - observedHours: hours asleep, keyed by the same night dates. A missing
    ///     key is an unobserved night.
    ///   - wornHours: hours recording, keyed likewise. Missing means zero worn,
    ///     which for a wear duration genuinely is zero.
    public static func slots(for nights: [Date],
                             observedHours: [Date: Double],
                             wornHours: [Date: Double] = [:]) -> [NightReading] {
        nights.map { night in
            NightReading(night: night,
                         hoursAsleep: observedHours[night],
                         hoursWorn: wornHours[night] ?? 0)
        }
    }

    /// Sorted oldest-first and one entry per night, so "the most recent night" is
    /// well defined and a repeated night cannot be counted twice.
    private static func deduplicated(_ readings: [NightReading]) -> [NightReading] {
        var byNight: [Date: NightReading] = [:]
        for r in readings { byNight[r.night] = r }
        return byNight.values.sorted { $0.night < $1.night }
    }
}

public extension Array where Element == NightReading {
    /// Convenience for the surfaces that only want the debt.
    func sleepDebt(nightlyNeed: Double = SleepSummary.defaultNightlyNeedHours,
                   expectedNights: Int? = nil) -> SleepDebt {
        SleepSummary.debt(over: self, nightlyNeed: nightlyNeed, expectedNights: expectedNights)
    }

    /// Convenience for `AppModel`, which merges this with the other domains'
    /// observations.
    func sleepObservations(nightlyNeed: Double = SleepSummary.defaultNightlyNeedHours,
                           expectedNights: Int? = nil) -> Observations {
        SleepSummary.observations(for: self, nightlyNeed: nightlyNeed,
                                 expectedNights: expectedNights)
    }
}
