import Foundation

/// Member A - CF1 / CF2, meeting Member B's CF6 gate.
///
/// An `EnergyLedger` is a day's arithmetic. Two other parts of the system need
/// something from it and neither of them wants the arithmetic:
///
/// * the agents bid on `Observations`, which has carried `kilojoulesLogged` and
///   `kilojoulesTarget` since day one with nothing filling them in;
/// * the Steward will not let a sentence out of the building without knowing what
///   form the claim behind it is allowed to take.
///
/// This file is that bridge and nothing else. Every function here is pure over
/// the ledger it is handed: no clock, no port, no `Date()`. A day's energy total
/// is a property of what was logged, and asking the wall clock about it would
/// only make it untestable.
public enum EnergySummary {

    /// What a day is expected to contain, for coverage purposes: breakfast,
    /// lunch, dinner. Snacks are real but not expected, so a day with three
    /// meals and no snacks is fully covered rather than perpetually short.
    ///
    /// This is the population default. `DayCoverage`'s doc comment describes
    /// `expectedCount` as coming from "this user's learned pattern", so callers
    /// that know better - a two-meal-a-day user - should pass their own figure.
    public static let expectedMealsPerDay = 3

    // MARK: - Filling in the observations

    /// The ledger as the agents see it.
    ///
    /// Absent readings stay absent. `Observations.lines` is explicit that its job
    /// is to let the model tell "zero" from "not measured", so a day with nothing
    /// logged reports `nil` rather than 0 kJ - otherwise the Nutrition Analyst
    /// reads an untouched morning as a fast.
    public static func observations(for ledger: EnergyLedger) -> Observations {
        Observations(
            kilojoulesLogged: ledger.loggedMealCount == 0 ? nil : ledger.loggedKilojoules,
            // A non-positive target is not a target. Rendering "against a 0 kJ
            // target" would invite the agents to declare every day a blowout.
            kilojoulesTarget: ledger.targetKilojoules > 0 ? ledger.targetKilojoules : nil)
    }

    // MARK: - The evidence question

    /// What a claim about this day's energy may take the form of.
    ///
    /// A day's total is only as strong as the portions behind it, so this is the
    /// weaker of two independent limits:
    ///
    /// 1. **Coverage** - how much of the day is visible at all. That ladder is
    ///    already written, in `DayCoverage.permittedForm(for:)`, and is not
    ///    restated here: two of three meals is a qualified claim, one of three is
    ///    a range. Duplicating it would give the project two floors to retune.
    /// 2. **Portion precision** - how the visible portions were arrived at. See
    ///    `portionForm(weakestConfidence:)`.
    ///
    /// The weaker limit wins, because both failures are real: a fully weighed
    /// breakfast is still only breakfast, and three meals eyeballed from across
    /// the room are still three guesses.
    public static func permittedForm(for ledger: EnergyLedger,
                                     expectedMeals: Int = expectedMealsPerDay) -> AssertionForm {
        // Nothing logged means nothing may be said. Note that this is *not* the
        // same as a confidently asserted zero: an empty ledger is the absence of
        // evidence, and "you have eaten 0 kJ today" is a claim about the user's
        // eating that the app has no grounds for.
        guard let weakest = ledger.weakestPortionConfidence else { return .forbidden }

        var coverage = DayCoverage(dayStart: ledger.dayStart)
        coverage.record(CoverageMetric(domain: .meals,
                                       observedCount: ledger.loggedMealCount,
                                       expectedCount: expectedMeals))
        return min(coverage.permittedForm(for: .meals), portionForm(weakestConfidence: weakest))
    }

    /// The portion half of the gate, keyed to the confidences `PortionBasis`
    /// publishes so that the two stay in step.
    ///
    /// The thresholds sit *between* the four bases rather than on them, so
    /// retuning a basis by a few points moves nothing. They are a judgement call;
    /// the reasoning is:
    ///
    /// * `>= 0.90` → `.assertion`. The weakest portion was weighed (1.00) or read
    ///   off a declared serving (0.90). Both are measured, so the residual error
    ///   belongs to the composition table rather than to the user, and a bare
    ///   number is defensible.
    /// * `>= 0.65` → `.qualified`. The weakest portion was a household measure
    ///   (0.70) - a real measure with real variance. The number may be spoken but
    ///   must carry the caveat that it came from cups and slices.
    /// * `>= 0.30` → `.range`. The weakest portion was the user's estimate by eye
    ///   (0.45). This is the case the feature exists for: a day built from four
    ///   eyeballed portions gets a band, never a point.
    /// * `> 0` → `.question`. Below the eyeball floor the item was barely
    ///   identified at all; the only honest output is to ask.
    /// * `<= 0` → `.forbidden`. A zero-confidence item is not evidence.
    ///
    /// The input is the *weakest* portion, not the average, for the same reason
    /// `MealEntry.confidence` is a minimum: averaging lets three weighed portions
    /// launder one guess into a number that looks measured.
    public static func portionForm(weakestConfidence c: Double) -> AssertionForm {
        if c >= 0.90 { return .assertion }
        if c >= 0.65 { return .qualified }
        if c >= 0.30 { return .range }
        if c > 0     { return .question }
        return .forbidden
    }
}

public extension EnergyLedger {
    /// Entries that actually contribute energy.
    ///
    /// An entry sitting in `.ungrounded` or `.awaitingTeaching` has no items yet,
    /// so it adds no kilojoules and must not add coverage either - otherwise
    /// photographing a dish the analyst could not identify would make the day
    /// *look* better covered while telling us nothing about what was eaten.
    var loggedMealCount: Int {
        entries.filter { !$0.items.isEmpty }.count
    }

    /// Convenience for the surfaces that only want the two numbers.
    var observations: Observations { EnergySummary.observations(for: self) }

    /// Convenience for the Steward, which asks this per outbound sentence.
    func permittedForm(expectedMeals: Int = EnergySummary.expectedMealsPerDay) -> AssertionForm {
        EnergySummary.permittedForm(for: self, expectedMeals: expectedMeals)
    }
}
