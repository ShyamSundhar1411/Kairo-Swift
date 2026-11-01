import Foundation

/// Member B - CF5 / CF6. Sedentary detection, computed instead of asserted.
///
/// CF5 is "detect a sedentary bout and deliver an actionable movement nudge",
/// and until this file existed the detection half did not. `Observations`
/// has carried `sedentaryMinutes` since day one; `AppModel` filled it from
/// `HealthDataSource.sedentaryMinutes(at:)`, which the live adapter answered by
/// refusing the question and the fake answered with a constant 82. The watch's
/// sitting page therefore showed either "not measured" or a fixture, and the
/// Lifestyle Signal Analyst bid on a number nobody had measured.
///
/// So the detection lives here, as arithmetic over readings somebody else was
/// handed. Every function in this file is pure over its arguments - no clock, no
/// port, no `Date()`, no HealthKit - for the same reason `SleepSummary` and
/// `EnergySummary` are: an unbroken sitting run is a property of the step
/// buckets that were observed, and reaching for the wall clock would only make
/// it untestable. The instant the run is measured *to* is an argument.
///
/// The rule that shapes the file is the same promise `SleepSummary` keeps: Kairo
/// will not draw a line through time it could not see. An interval with no step
/// data is not an interval with no steps. A watch on the charger is not a person
/// sitting still. So:
///
/// * every reading here is optional, and `nil` means *not observed* rather than
///   zero - the distinction `Observations.lines` exists to preserve;
/// * a gap in the step buckets **ends** the run rather than being sat through,
///   because a run that spans unobserved time is a claim about that time;
/// * zero observed intervals is `.forbidden`, not a confident zero.

// MARK: - Inputs

/// Steps counted in one fixed-width interval of the day.
///
/// This is deliberately the shape `HKStatisticsCollectionQuery` hands back - one
/// bucket per interval across a day, zeros included - so the adapter translates
/// rather than interprets. `steps` of 0 is a real measurement of no steps; an
/// interval HealthKit had nothing for should be **absent** from the array, not
/// present with 0, or the gap rule below cannot fire.
public struct StepBucket: Sendable, Equatable {
    /// Start of the interval. Buckets are assumed to be `minutes` wide and are
    /// sorted here rather than trusted to arrive in order.
    public let start: Date
    /// Steps counted in the interval. Clamped at zero; a negative step count is
    /// not a reading.
    public let steps: Int

    public init(start: Date, steps: Int) {
        self.start = start
        self.steps = max(0, steps)
    }
}

/// A day's movement, as the wrist saw it or failed to.
///
/// Every field is optional and each `nil` carries the same meaning: this was not
/// observed. That is not tidiness - it is the whole point. A day where the watch
/// sat on the charger must not read downstream as a day of stillness, no active
/// energy and no exercise.
public struct MovementDay: Sendable, Equatable {
    /// Start of the day these readings belong to.
    public let day: Date
    /// Distinct hours of the day that contained at least one sample, or `nil` if
    /// nobody has looked. See `MovementSummary.wearHours(hoursWithSamples:)`.
    public let hoursWorn: Double?
    /// The current unbroken run of not-moving, in minutes, or `nil` if there were
    /// no step buckets to derive one from.
    public let unbrokenSedentaryMinutes: Int?
    /// Active energy burned, in kilojoules (NFR14: kJ is the stored unit).
    public let activeKilojoules: Double?
    /// Apple exercise minutes for the day.
    public let exerciseMinutes: Int?

    public init(day: Date, hoursWorn: Double? = nil,
                unbrokenSedentaryMinutes: Int? = nil,
                activeKilojoules: Double? = nil,
                exerciseMinutes: Int? = nil) {
        self.day = day
        self.hoursWorn = hoursWorn.map { max(0, min(24, $0)) }
        // Negative or absurd durations are not readings. Clamped rather than
        // trapped because this type is fed by an adapter over a framework whose
        // sample dates are, in principle, whatever the source device wrote.
        self.unbrokenSedentaryMinutes = unbrokenSedentaryMinutes.map { max(0, min(24 * 60, $0)) }
        self.activeKilojoules = activeKilojoules.map { max(0, $0) }
        self.exerciseMinutes = exerciseMinutes.map { max(0, min(24 * 60, $0)) }
    }

    /// Whether the day is evidence of anything at all.
    ///
    /// Wear is the load-bearing field: it is the denominator every other figure
    /// here is measured against, and a day with no wear reading has no honest
    /// denominator. The old adapter's `samples.isEmpty ? 0 : 24` was exactly that
    /// missing denominator, invented.
    public var isObserved: Bool { (hoursWorn ?? 0) > 0 }
}

// MARK: - The domain

public enum MovementSummary {

    /// Width of a step bucket, in minutes.
    ///
    /// Five minutes, not one. A one-minute bucket sounds more precise and is
    /// worse: wrist step counts are noisy at that resolution, so a single
    /// stray minute would break a genuine two-hour sitting bout, and the run
    /// would flap between 4 and 120 while the user sat perfectly still. Five
    /// minutes is also the finest resolution at which the *nudge* is meaningful
    /// - nobody needs telling they have been sitting for 43 minutes rather than
    /// 45 - so the extra precision would buy nothing and cost stability.
    public static let defaultBucketMinutes = 5

    /// Steps in one bucket at or above which the user counts as having moved.
    ///
    /// 25 steps in 5 minutes, i.e. an average of 5 steps a minute. The reasoning,
    /// which is a judgement call and should be argued with:
    ///
    /// * **Above the noise floor.** A wrist-worn accelerometer credits a few
    ///   steps to typing, gesturing and shifting in a chair. Published
    ///   false-positive rates for seated activity sit in the low tens of steps
    ///   per hour, so a handful per five minutes must not clear the bar or the
    ///   run would never survive a phone call.
    /// * **Far below real walking.** Walking is roughly 100 steps a minute, so
    ///   anything that is actually a movement break - standing up, walking to the
    ///   kitchen, even crossing the room - clears 25 in the first fifteen
    ///   seconds. The threshold does not need to be near walking pace to detect
    ///   walking; it needs to be above fidgeting.
    /// * **Erring towards silence.** The two ways to be wrong are not
    ///   symmetrical. Too high a threshold swallows real breaks, lengthens the
    ///   run, and nags somebody who *did* get up - the failure that makes people
    ///   delete the app. Too low a threshold breaks the run early and Kairo says
    ///   nothing. This project would rather stay quiet, so the threshold sits at
    ///   the low end of the defensible band.
    ///
    /// A caller with per-user calibration should pass its own figure; nothing
    /// here assumes the default.
    public static let defaultMovedStepsPerBucket = 25

    /// Hours a day is expected to have the watch on the wrist, for coverage
    /// purposes.
    ///
    /// Sixteen: a waking day, leaving eight for sleeping and charging. Note that
    /// this is *not* a claim that wearing it overnight is wrong - a day worn 24
    /// hours simply clamps to full coverage, because `CoverageMetric` caps the
    /// fraction at 1.
    ///
    /// This is the population default. `DayCoverage` describes `expectedCount` as
    /// coming from "this user's learned pattern", so a caller that knows this
    /// user takes it off at their desk should pass their own figure.
    public static let expectedWornHoursPerDay = 16

    // MARK: - Unbroken sitting

    /// The length of the run of not-moving that is still open at `instant`.
    ///
    /// Walks backwards from `instant` through the buckets and stops at the first
    /// reason to stop. There are three, and the last two are the honest ones:
    ///
    /// 1. **A bucket that cleared the threshold.** The user moved; the run ended
    ///    there and its length is the time since.
    /// 2. **A gap in the buckets.** Buckets are `bucketMinutes` wide and
    ///    contiguous; if the previous bucket does not abut this one, there is
    ///    time in between that was never observed. The run stops at the edge of
    ///    what was seen rather than being extended across the hole - an unobserved
    ///    twenty minutes might have been a walk, and claiming otherwise would be
    ///    the interpolation this whole layer refuses to do.
    /// 3. **Running out of buckets.** The earliest bucket is the earliest
    ///    evidence; the run is at least that long and is reported as that long.
    ///    Like `SleepDebt.hours` this is a lower bound, and for the same reason:
    ///    every direction the missing data could go can only make it longer.
    ///
    /// The bucket containing `instant` counts only the part of it that has
    /// elapsed, so a run measured two minutes into a five-minute bucket reports
    /// two minutes rather than five. Counting the whole bucket would report
    /// sitting that has not happened yet.
    ///
    /// - Parameters:
    ///   - buckets: step counts per interval. Order is not trusted. Buckets
    ///     starting after `instant` are ignored - they are the future as far as
    ///     this call is concerned, whatever HealthKit happened to return.
    ///   - instant: the moment the run is measured to. An argument, not a clock.
    ///   - bucketMinutes: bucket width. Clamped to at least 1.
    ///   - movedThreshold: steps at or above which the bucket counts as movement.
    ///     See `defaultMovedStepsPerBucket`.
    /// - Returns: minutes sat unbroken, or `nil` when the recent past was not
    ///   observed at all - which is "we have not looked", not "you have been
    ///   moving". See the staleness guard below for what counts as recent.
    public static func unbrokenSedentaryMinutes(
        buckets: [StepBucket],
        at instant: Date,
        bucketMinutes: Int = defaultBucketMinutes,
        movedThreshold: Int = defaultMovedStepsPerBucket
    ) -> Int? {
        let width = max(1, bucketMinutes)
        let seconds = Double(width) * 60

        // Only buckets that have started. A bucket beginning after `instant`
        // describes time that has not happened, and one HealthKit padded onto the
        // end of the day would otherwise be read as evidence about the future.
        let past = buckets.filter { $0.start <= instant }.sorted { $0.start < $1.start }
        guard let newest = past.last else { return nil }

        // Staleness. `instant` has to fall inside the newest bucket for the run
        // to be *current*. If the last thing we observed ended three hours ago,
        // those three hours are unobserved and the honest answer about a run
        // reaching `instant` is that we do not have one - the same rule as the
        // gap check below, applied to the leading edge. Without this the run
        // would be reported as one bucket wide, which reads as "you just sat
        // down" for a watch that has been off since lunchtime.
        let sinceNewest = instant.timeIntervalSince(newest.start)
        guard sinceNewest >= 0, sinceNewest <= seconds + 1 else { return nil }

        // The open bucket contributes only the part of it that has elapsed.
        let elapsedInNewest = min(seconds, max(0, sinceNewest))
        guard newest.steps < movedThreshold else {
            // Movement inside the current bucket. The run is however long it has
            // been since that movement, which we cannot resolve more finely than
            // the bucket - so zero, honestly coarse, rather than a guess.
            return 0
        }

        var runSeconds = elapsedInNewest
        var previousStart = newest.start

        for bucket in past.dropLast().reversed() {
            // Rule 2: contiguity. Allow a second of slack for the floating-point
            // and rounding noise an adapter's interval anchor can introduce; any
            // real gap is a whole bucket wide.
            let expectedStart = previousStart.addingTimeInterval(-seconds)
            guard abs(bucket.start.timeIntervalSince(expectedStart)) <= 1 else { break }
            // Rule 1: the run ends at the last movement.
            guard bucket.steps < movedThreshold else { break }
            runSeconds += seconds
            previousStart = bucket.start
        }

        // Rounded down: reporting 44 minutes of a 45-minute bout understates the
        // sitting, which is the direction this file errs in throughout.
        return Int(runSeconds / 60)
    }

    // MARK: - Wear, from sample density

    /// Hours of the day the device was recording, counted as distinct hours that
    /// contained at least one sample.
    ///
    /// A proxy, and a conservative one: an hour holding a single sample counts as
    /// a whole hour worn. It is not a wear *duration* and nothing should call it
    /// one. What recommends it is that it is derived entirely from something the
    /// device actually wrote, which the previous implementation
    /// (`samples.isEmpty ? 0 : 24`) was not.
    ///
    /// The input is optional because the three states have to survive the trip.
    /// `nil` in means *nobody has looked* and produces `nil` out. An **empty
    /// set** means we looked and the device wrote nothing all day, which is a
    /// measured zero and produces `0`. Collapsing those two was the original
    /// defect in the health adapter, and it would be reintroduced here by taking
    /// a plain `Set<Int>` and reading `isEmpty` as either answer.
    ///
    /// - Parameter hoursWithSamples: hour-of-day indices, `0..<24`. Indices
    ///   outside that range are dropped rather than trusted - a sample bucketed
    ///   into hour 25 is an adapter bug, and letting it inflate wear time would
    ///   put the bug underneath a hero number.
    public static func wearHours(hoursWithSamples: Set<Int>?) -> Double? {
        guard let hours = hoursWithSamples else { return nil }
        return Double(hours.filter { (0..<24).contains($0) }.count)
    }

    // MARK: - Coverage

    /// The movement ring's input, so the ring stops being a constant.
    ///
    /// Observed is *hours the device recorded*, not steps taken and not intervals
    /// HealthKit returned. Coverage asks how much of the day Kairo could see, and
    /// a `HKStatisticsCollectionQuery` obligingly returns all 288 buckets of a
    /// day whether the watch was worn or not - using that as the numerator would
    /// report perfect coverage for a day the watch spent in a drawer.
    ///
    /// - Parameter observedHours: hours the device recorded, or `nil`/`0` when
    ///   nothing was seen - both of which give a zero fraction, and therefore
    ///   `.forbidden`.
    public static func coverageMetric(observedHours: Double?,
                                      expectedHours: Int = expectedWornHoursPerDay) -> CoverageMetric {
        // Floored to whole hours because that is the resolution the wear proxy
        // has; `CoverageMetric` counts, and a fractional count would be a
        // precision this measurement does not possess.
        let observed = max(0, Int((observedHours ?? 0).rounded(.down)))
        return CoverageMetric(domain: .movement,
                              observedCount: observed,
                              expectedCount: max(1, expectedHours))
    }

    // MARK: - The evidence question

    /// What a claim about this day's movement may take the form of.
    ///
    /// The weaker of two independent limits, in the same shape as
    /// `SleepSummary.permittedForm(observedNights:expectedNights:)` and
    /// `EnergySummary.permittedForm(for:expectedMeals:)`:
    ///
    /// 1. **Coverage** - what fraction of the expected wear day was visible. That
    ///    ladder is already written, in `DayCoverage.permittedForm(for:)`, and is
    ///    deliberately *not* restated here: at the default 0.6 floor and a
    ///    16-hour expectation, ten hours worn is a qualified claim and four is
    ///    only a range. Duplicating the ladder would give the project two floors
    ///    to retune, which is how floors drift apart.
    /// 2. **Absolute hours worn** - how much of a day there is, regardless of the
    ///    fraction. See `wornForm(hoursWorn:)`.
    ///
    /// The second limit exists because a fraction cannot see the length of its
    /// own denominator. A caller that knows this user only ever wears the watch
    /// for a four-hour shift would pass `expectedHours: 4`, four hours worn would
    /// be a coverage fraction of 1.0, and the ladder would happily license a bare
    /// number about their day's movement - built from four hours of it.
    ///
    /// Worked through the default case: **four hours worn of an expected
    /// sixteen** is a fraction of 0.25, below the 0.3 half-floor, which the
    /// coverage ladder calls `.question`; the absolute limit calls it `.range`.
    /// The weaker wins, so the answer is `.question` and no number is spoken.
    ///
    /// - Parameter hoursWorn: `nil` means nobody has looked, which is not
    ///   evidence and is therefore `.forbidden` - the same treatment zero gets,
    ///   for the same reason.
    public static func permittedForm(hoursWorn: Double?,
                                     expectedHours: Int = expectedWornHoursPerDay) -> AssertionForm {
        guard let worn = hoursWorn, worn > 0 else { return .forbidden }
        var coverage = DayCoverage(dayStart: Date(timeIntervalSince1970: 0))
        coverage.record(coverageMetric(observedHours: worn, expectedHours: expectedHours))
        return min(coverage.permittedForm(for: .movement), wornForm(hoursWorn: worn))
    }

    /// The absolute-hours half of the gate.
    ///
    /// These thresholds are a judgement call, so here is the reasoning to argue
    /// with. A day's movement is a *day's* quantity: unlike a single meal, a
    /// couple of hours of it is not a small version of the day, it is a different
    /// thing. And because unobserved hours are excluded rather than zero-filled,
    /// every figure derived from them is a lower bound whose looseness grows with
    /// each hour missing - so the ladder is asking "how badly could this
    /// understate the day?"
    ///
    /// * `>= 12` → `.assertion`. Twelve hours covers the active part of a waking
    ///   day. Note that at the default 16-hour expectation twelve hours still
    ///   comes out `.qualified` overall, because the coverage ladder reserves a
    ///   bare number for a complete day - this limit yielding does not mean the
    ///   gate opened.
    /// * `8...11` → `.qualified`. Most of a working day, but enough missing that
    ///   the number must carry the caveat naming what it is built from - "in the
    ///   nine hours I could see".
    /// * `4...7` → `.range`. Half a day establishes that movement happened and
    ///   roughly how much per hour, but the day's total it implies is mostly
    ///   extrapolation. A band, never a point.
    /// * `1...3` → `.question`. An hour or two says nothing about a day. There is
    ///   no way to tell a sedentary morning from a sedentary person, so the only
    ///   honest output is to ask.
    /// * `< 1` → `.forbidden`. Under an hour of recording is a watch being picked
    ///   up and put down, not a day, and there is nothing to ask about either.
    ///   The wear proxy counts whole hours, so in practice this band is only
    ///   reachable by a caller passing a figure from somewhere else.
    ///
    /// The bands are absolute rather than fractional on purpose: the failure this
    /// guards against is a short observation window flattering itself.
    public static func wornForm(hoursWorn h: Double) -> AssertionForm {
        if h >= 12 { return .assertion }
        if h >= 8  { return .qualified }
        if h >= 4  { return .range }
        if h >= 1  { return .question }
        return .forbidden
    }

    // MARK: - Filling in the observations

    /// The `Observations` field this domain owns.
    ///
    /// Exactly one: `sedentaryMinutes`. Active energy and exercise minutes are
    /// carried on `MovementDay` for the surfaces that show them, but they are
    /// deliberately *not* poured into `Observations.kilojoulesLogged` - that
    /// field is Member A's food ledger, and energy burned is not energy eaten.
    /// Adding a burn figure to it would silently turn every meal total into a
    /// net.
    ///
    /// `nil` stays `nil`. `Observations.lines` renders the absence as "sitting:
    /// not measured", which is the sentence this file exists to make possible;
    /// a zero here would read to the Lifestyle Signal Analyst as a user who has
    /// not sat down all day.
    ///
    /// Deliberately not filtered by `permittedForm`: the agents receive the
    /// figure and the Steward governs the sentence. Screening the input as well
    /// as the output would hide the evidence from the component whose job is to
    /// weigh it.
    public static func observations(for day: MovementDay) -> Observations {
        Observations(sedentaryMinutes: day.unbrokenSedentaryMinutes)
    }
}

public extension MovementDay {
    /// Convenience for the surfaces that only want the ring.
    var coverageMetric: CoverageMetric {
        MovementSummary.coverageMetric(observedHours: hoursWorn)
    }

    /// Convenience for the Steward, which asks this per outbound sentence.
    func permittedForm(expectedHours: Int = MovementSummary.expectedWornHoursPerDay) -> AssertionForm {
        MovementSummary.permittedForm(hoursWorn: hoursWorn, expectedHours: expectedHours)
    }

    /// Convenience for `AppModel`, which merges this with the other domains'
    /// observations.
    var observations: Observations { MovementSummary.observations(for: self) }
}
