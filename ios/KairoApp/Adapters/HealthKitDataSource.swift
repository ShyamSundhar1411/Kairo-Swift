import Foundation
import KairoKit
#if canImport(HealthKit)
import HealthKit
#endif

/// Why a health reading is not available, which is a different question from what
/// the reading was.
///
/// `HealthDataSource` returns `Double?` for sleep, and the old adapter used that
/// one `nil` for three unrelated situations: HealthKit is not on this device,
/// nobody has fetched anything yet, and the watch was off the wrist. The whole
/// app rests on telling the last of those from the other two — the screen says
/// "the watch was off your wrist" — so the first two are errors and only the
/// third is a `nil` value.
enum HealthReadError: Error, LocalizedError {
    /// No HealthKit on this device at all.
    case notAvailable
    /// Never fetched for that day. A fetch has been started; ask again shortly.
    /// Seeing this is not a bug, but seeing it *forever* is, which is what the
    /// self-priming below exists to prevent.
    case notFetchedYet(Date)
    /// The last fetch for that day failed. Deliberately distinct from an empty
    /// result: a failed query must not be cached as "there was nothing there".
    case fetchFailed(String)
    /// This adapter cannot answer that question at all. Better than a plausible
    /// zero.
    case notSupported(String)
    /// The day *was* read and HealthKit had nothing of that kind in it.
    ///
    /// Needed because two of the port's signatures — `wearHours(on:)` and
    /// `sedentaryMinutes(at:)` — return non-optionals, so there is nowhere to put
    /// "measured, nothing there" except an error. Deliberately distinct from
    /// `.notFetchedYet`: this one will not change if you ask again, and a surface
    /// may honestly say "nothing recorded" about it, which it may not say about
    /// the other.
    case notRecorded(String)

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "HealthKit is not available on this device."
        case let .notFetchedYet(day):
            return "Health data for \(day) has not been read yet."
        case let .fetchFailed(why):
            return "The Health query failed: \(why)"
        case let .notSupported(what):
            return "This adapter does not measure \(what)."
        case let .notRecorded(what):
            return "Nothing was recorded for \(what)."
        }
    }
}

/// Adapters that can answer a question about more than one night.
///
/// Deliberately *not* folded into `HealthDataSource`. That port is implemented by
/// `StubHealthDataSource` in KairoKit's fakes, which is what keeps the domain and
/// the recorded demo free of HealthKit; widening the port would break it and drag
/// a multi-night concept into a protocol whose whole point is to be trivially
/// fakeable. So this lives in the app layer, alongside the only adapter that can
/// honour it, and a surface that wants a window asks for it with a conditional
/// cast. A source that cannot answer simply is not one, and the caller falls back
/// to what the single-day port can tell it — which is one night, honestly labelled.
protocol SleepWindowSource {
    /// One `NightReading` per night in the window, oldest first, **including a
    /// blank for every night nothing was found for**. Returning only the nights
    /// that had data would make a three-night week look fully covered.
    func nightReadings(endingOn day: Date, nights: Int) async -> [NightReading]
}

/// Adapters that can answer the movement questions CF5 needs.
///
/// Here for exactly the reason `SleepWindowSource` is: `HealthDataSource` is
/// implemented by `StubHealthDataSource` in KairoKit's fakes, and widening that
/// port would break the fake and drag active energy, exercise minutes and step
/// bucketing into a protocol whose whole point is to be trivially fakeable. So
/// this lives in the app layer next to the only adapter that can honour it, and
/// a surface that wants a `MovementDay` asks with a conditional cast; a source
/// that cannot answer simply is not one.
///
/// Note what is *not* here: nothing async. The read path is the same
/// three-state, self-priming cache the sleep reads use, so these are getters
/// that either answer, refuse, or start a fetch and refuse.
protocol MovementDaySource {
    /// Everything this adapter knows about one day's movement.
    ///
    /// Throws rather than returning a blank `MovementDay` when nothing has been
    /// read yet, because a blank one is indistinguishable from a day the watch
    /// spent on the charger — the conflation this whole adapter was rewritten to
    /// remove.
    func movementDay(on day: Date, at instant: Date) throws -> MovementDay
}

/// The only file in the app that knows HealthKit exists. Everything upstream
/// depends on `HealthDataSource`, which is why the domain builds and tests
/// without Xcode, a device, or a health permission dialog.
///
/// ## What has never run
///
/// Everything inside `#if canImport(HealthKit)` below is still unverified
/// against data, and this section is kept honest deliberately.
///
/// One earlier claim here was simply wrong and has been corrected: the simulator
/// *does* have a working Health database — `healthdb.sqlite` under the device's
/// data directory, with a live `HKHealthStore` in front of it. What it has is no
/// data in that database, and there is no `simctl` subcommand to import any, so
/// `HealthKitSeeder` exists to write a week of marked synthetic samples through
/// `HKHealthStore.save(_:)`. That is now the route to executing this file.
///
/// What has actually been executed so far is the authorisation call and the
/// seeder's guards; the queries below have been compiled and reasoned about but
/// have still never returned a sample. Seeding needs one manual tap on iOS's
/// Health Access sheet — see `KairoHealthSeeding` for why that step cannot be
/// automated and for the exact commands. Until somebody takes that tap, treat
/// every number this file can produce as unproven.
///
/// Consequences, and the choices made because of them:
///
/// * every query failure is caught and reported as `.fetchFailed`, and a failed
///   day is **not** cached — so a bug here degrades to "not measured" rather than
///   to a confident wrong number;
/// * durations are clamped and implausible samples dropped, so a malformed
///   sample cannot produce a 400-hour night;
/// * every judgement call — the sedentary threshold, the wear expectation, the
///   assertion ladders — lives in `MovementSummary` and `SleepSummary` in
///   KairoKit, where it is pure, tested and arguable without a device. This file
///   translates; it does not decide.
/// * nothing here traps. There is no `!` on a HealthKit result and no assumption
///   that a type identifier resolves.
///
/// The first two things to check against a seeded store are the night bucketing
/// — whether the nights this produces line up with what the Health app shows —
/// and whether a night seeded at 7.5 hours reads back as 7.5 and not as the
/// 7.9 hours it would be if `inBed` were being counted as sleep again.
public final class HealthKitDataSource: HealthDataSource, SleepWindowSource, MovementDaySource, @unchecked Sendable {
    public let name = "HealthKit"

    /// Guards every cache below. The sync getters are called from the main actor
    /// while the fetches complete on whatever queue HealthKit calls back on, so
    /// the dictionaries are genuinely shared. The old adapter mutated them
    /// unsynchronised behind `@unchecked Sendable`, which was a data race waiting
    /// for a slow query.
    private let lock = NSLock()

    /// Three states, not two, and the reason this type is a dictionary of
    /// optionals rather than a dictionary of doubles: a **missing key** means
    /// nobody has fetched that day, while a **present key holding nil** means the
    /// day was fetched and there was nothing there. Collapsing those two was the
    /// original bug.
    private var sleepHoursByDay: [Date: Double?] = [:]
    private var wearHoursByDay: [Date: Double?] = [:]
    /// The day's step buckets, not the day's sitting run.
    ///
    /// Caching the *answer* would be wrong: the unbroken run is a function of the
    /// instant you ask about, and `sedentaryMinutes(at:)` is asked once a frame
    /// with a moving `t`. The buckets are the reading; the run is arithmetic over
    /// them, and `MovementSummary` does it synchronously on every call.
    private var stepBucketsByDay: [Date: [StepBucket]?] = [:]
    private var activeKilojoulesByDay: [Date: Double?] = [:]
    private var exerciseMinutesByDay: [Date: Int?] = [:]
    /// Days a fetch is already in flight for, so a screen that reads the same day
    /// on every frame starts one query rather than sixty.
    private var priming: Set<Date> = []
    private var hasRequestedAuthorisation = false
    /// Set once a fetch discovers there is no Health database here at all.
    ///
    /// Without it, every read of an unfillable day would throw `.notFetchedYet`
    /// and start another pointless fetch, once per frame. The flag is not a
    /// cached *value* — caching "nothing there" for a device that cannot answer
    /// would be exactly the conflation this adapter was rewritten to remove.
    private var healthDataUnavailable = false

    public init() {}

    // MARK: - Day arithmetic

    /// The calendar is read once per call rather than held, because the user can
    /// change time zone between launches and a cached `Calendar` would keep
    /// bucketing nights into yesterday.
    private func startOfDay(_ d: Date) -> Date { Calendar.current.startOfDay(for: d) }

    /// The nights in a window, oldest first, keyed the way every cache here is.
    private func nightKeys(endingOn day: Date, nights: Int) -> [Date] {
        let last = startOfDay(day)
        let count = max(1, nights)
        return (0..<count).reversed().compactMap {
            Calendar.current.date(byAdding: .day, value: -$0, to: last)
        }
    }

    // MARK: - Reading the cache

    /// All cache access goes through here, and it is deliberately *not* async:
    /// `NSLock` may not be held across a suspension point, and a synchronous
    /// critical section called from an async context cannot accidentally do so.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// The cache read for one day. `Double??` because the outer optional is the
    /// three-state answer: `nil` = never fetched, `.some(nil)` = fetched and
    /// nothing recorded, `.some(.some(h))` = fetched, `h` hours.
    ///
    /// One method per table rather than one taking the table as an argument: an
    /// argument would be a copy taken *before* the lock, which is the race the
    /// lock exists to prevent.
    private func cachedSleep(_ key: Date) -> Double?? {
        withLock { sleepHoursByDay[key] }
    }

    private func cachedWear(_ key: Date) -> Double?? {
        withLock { wearHoursByDay[key] }
    }

    private func cachedSteps(_ key: Date) -> [StepBucket]?? {
        withLock { stepBucketsByDay[key] }
    }

    private func cachedActiveKilojoules(_ key: Date) -> Double?? {
        withLock { activeKilojoulesByDay[key] }
    }

    private func cachedExerciseMinutes(_ key: Date) -> Int?? {
        withLock { exerciseMinutesByDay[key] }
    }

    /// Starts a fetch for a day nobody has asked HealthKit about yet.
    ///
    /// This is the fix for the original defect. `sleepHours(on:)` was a
    /// synchronous getter over a cache that only `refresh(day:)` filled, and
    /// nothing in the app called `refresh(day:)` — so in live mode the adapter
    /// returned `nil` forever and looked exactly like a watch that had been off
    /// the wrist for the rest of time. A caller can now no longer forget to prime
    /// it: the first read primes it, and until the fetch lands the read *throws*
    /// rather than answering `nil`, so "not yet read" is impossible to mistake
    /// for "nothing recorded".
    private func primeIfNeeded(_ key: Date) {
        let alreadyRunning = withLock {
            let running = priming.contains(key)
            if !running { priming.insert(key) }
            return running
        }
        guard !alreadyRunning else { return }
        Task { [weak self] in
            await self?.refresh(day: key)
            // Released whatever happened, including on the platforms where
            // `refresh` is a no-op — a day stuck in `priming` would never be
            // retried, which is the original bug wearing a different hat.
            self?.finishedPriming([key])
        }
    }

    // MARK: - HealthDataSource

    public func sleepHours(on day: Date) throws -> Double? {
        let key = startOfDay(day)
        if withLock({ healthDataUnavailable }) { throw HealthReadError.notAvailable }
        guard let entry = cachedSleep(key) else {
            primeIfNeeded(key)
            throw HealthReadError.notFetchedYet(key)
        }
        // Fetched. `entry` is the honest answer, `nil` included: no asleep sample
        // for that night means the watch was off the wrist, which is not zero
        // hours slept.
        return entry
    }

    public func wearHours(on day: Date) throws -> Double {
        let key = startOfDay(day)
        if withLock({ healthDataUnavailable }) { throw HealthReadError.notAvailable }
        guard let entry = cachedWear(key) else {
            primeIfNeeded(key)
            throw HealthReadError.notFetchedYet(key)
        }
        // Zero here is measured: the day was looked at and the watch recorded
        // nothing. The port's signature cannot express the difference, which is
        // why the unfetched case throws above instead of returning 0.
        return entry ?? 0
    }

    /// CF5's missing half: the run of not-moving that is still open at `t`.
    ///
    /// This used to `throw .notSupported("unbroken sitting")`, and before that it
    /// returned a cached 0 that nothing ever filled — which the Today screen
    /// rendered as "0 min sitting unbroken", i.e. a reassurance nobody measured.
    /// It is now a real reading: `.stepCount` bucketed into five-minute intervals
    /// across the day (see `stepBuckets(forDay:)`) with the run computed by
    /// `MovementSummary.unbrokenSedentaryMinutes`, which is pure and tested.
    ///
    /// The detector lives in KairoKit rather than here on purpose. The threshold
    /// for "moved" is a judgement call the project has to be able to argue about
    /// and retune, and a judgement call buried in an adapter that cannot be run
    /// without a device is a judgement call nobody will ever revisit.
    public func sedentaryMinutes(at t: Date) throws -> Int {
        let key = startOfDay(t)
        if withLock({ healthDataUnavailable }) { throw HealthReadError.notAvailable }
        guard let entry = cachedSteps(key) else {
            primeIfNeeded(key)
            throw HealthReadError.notFetchedYet(key)
        }
        // Fetched. Two ways there is still no answer, and neither of them is 0:
        // the query came back with no step data for the day at all, or it came
        // back but nothing covers the recent past (see the staleness rule in
        // `MovementSummary`). The port returns a non-optional `Int`, so both have
        // to be errors — a 0 here is a claim that the user has not sat down.
        guard let buckets = entry,
              let run = MovementSummary.unbrokenSedentaryMinutes(buckets: buckets, at: t) else {
            throw HealthReadError.notRecorded("unbroken sitting")
        }
        return run
    }

    // MARK: - MovementDaySource

    /// Everything read for one day's movement, in one value.
    ///
    /// Unlike the port's getters this returns the absences rather than throwing
    /// them, because `MovementDay` has somewhere to put them: every field is
    /// optional and `nil` means not observed. The one thing it still throws for
    /// is *nothing read yet*, which is not an absence but an unanswered question.
    ///
    /// - Parameters:
    ///   - day: the day to report on.
    ///   - instant: the moment the sitting run is measured to. Passed in rather
    ///     than taken from `Date()` so a caller with a test clock gets the same
    ///     answer this adapter's domain tests do.
    func movementDay(on day: Date, at instant: Date) throws -> MovementDay {
        let key = startOfDay(day)
        if withLock({ healthDataUnavailable }) { throw HealthReadError.notAvailable }
        // Any one cache being unfilled means the day has not been read; they are
        // filled together in `refreshMovement(day:)`.
        guard let steps = cachedSteps(key),
              let energy = cachedActiveKilojoules(key),
              let exercise = cachedExerciseMinutes(key),
              let wear = cachedWear(key) else {
            primeIfNeeded(key)
            throw HealthReadError.notFetchedYet(key)
        }
        return MovementDay(
            day: key,
            hoursWorn: wear,
            unbrokenSedentaryMinutes: steps.flatMap {
                MovementSummary.unbrokenSedentaryMinutes(buckets: $0, at: instant)
            },
            activeKilojoules: energy,
            exerciseMinutes: exercise)
    }

    #if canImport(HealthKit)
    private let store = HKHealthStore()

    /// NFR5: read-only, and only the types the features actually use. Every extra
    /// scope is a promise to the user that has to be justified.
    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = []
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
        // `.activeEnergyBurned` was missing, which meant the energy read added
        // below would have come back empty on a real device however correct the
        // query was — the failure mode HealthKit is worst about, because a denied
        // read is indistinguishable from an empty day.
        for id: HKQuantityTypeIdentifier in [.stepCount, .heartRate, .heartRateVariabilitySDNN,
                                             .appleExerciseTime, .activeEnergyBurned,
                                             .dietaryWater] {
            if let t = HKObjectType.quantityType(forIdentifier: id) { types.insert(t) }
        }
        return types
    }

    public func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthReadError.notAvailable }
        try await store.requestAuthorization(toShare: [], read: readTypes)
        withLock { hasRequestedAuthorisation = true }
    }

    /// Requests authorisation once, before the first query of a session.
    ///
    /// Nothing in the app called `requestAuthorization()` either, so this is the
    /// same class of fix as the priming: the fetch path asks for what it needs
    /// rather than depending on somebody else having remembered. HealthKit shows
    /// its sheet at most once per install, and re-requesting is documented as a
    /// no-op, so the worst case here is a wasted call.
    ///
    /// Note that HealthKit deliberately will not tell an app whether *read*
    /// access was granted — a denied type reads as an empty result. That is the
    /// other reason "fetched and empty" has to stay distinguishable from "not
    /// fetched": empty is the only signal a refusal ever produces, and it must
    /// not be silently upgraded into a claim about the user's sleep.
    private func ensureAuthorised() async {
        guard !withLock({ hasRequestedAuthorisation }) else { return }
        try? await requestAuthorization()
        // Marked either way: a refused or failed request must not make every
        // subsequent read re-present the sheet.
        withLock { hasRequestedAuthorisation = true }
    }

    // MARK: - Fetching

    /// Fills the caches for one day: the night's sleep and the day's wear.
    ///
    /// Still public and still callable explicitly — a screen that knows it is
    /// about to need a day should say so — but no longer the only thing that can
    /// fill the cache.
    public func refresh(day: Date) async {
        _ = await nightReadings(endingOn: day, nights: 1)
        await refreshMovement(day: day)
    }

    /// A window of nights, one entry per night, blanks included.
    ///
    /// Unverified against real data. See the type's note.
    public func nightReadings(endingOn day: Date, nights: Int) async -> [NightReading] {
        let keys = nightKeys(endingOn: day, nights: nights)
        defer { finishedPriming(keys) }

        guard HKHealthStore.isHealthDataAvailable(),
              let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            // Nothing can be observed here, which is not the same as nothing
            // having happened: the caches stay unfilled so the sync getters keep
            // refusing rather than reporting a fabricated empty night.
            withLock { healthDataUnavailable = true }
            return SleepSummary.slots(for: keys, observedHours: [:])
        }
        await ensureAuthorised()

        guard let earliest = keys.first,
              let windowEnd = Calendar.current.date(byAdding: .day, value: 1, to: keys.last ?? startOfDay(day)) else {
            return SleepSummary.slots(for: keys, observedHours: [:])
        }
        // Non-strict start on purpose: a night that began at 23:10 the evening
        // before the window opened still ends inside it, and it is the end date
        // that decides which night a sample belongs to.
        let predicate = HKQuery.predicateForSamples(withStart: earliest, end: windowEnd)

        let samples: [HKCategorySample]
        do {
            samples = try await categorySamples(sleepType, predicate)
        } catch {
            // A failed query is not an empty night. Nothing is cached, so the
            // getters keep throwing `.notFetchedYet` and the screens keep saying
            // they do not know.
            return SleepSummary.slots(for: keys, observedHours: [:])
        }

        let (asleepHours, recordedHours) = bucketed(samples, into: keys)

        // Wear is a day-level question and comes from a different signal; see
        // `wearHours(forDay:)`. Only the window's final day is fetched, because
        // that is the day any screen showing "on your wrist" is asking about.
        let wornOnLastDay = await wearHours(forDay: keys.last ?? startOfDay(day))

        withLock {
            for key in keys {
                // Present-key-holding-nil: fetched, nothing there.
                sleepHoursByDay[key] = .some(asleepHours[key])
            }
            if let last = keys.last { wearHoursByDay[last] = .some(wornOnLastDay) }
        }

        return SleepSummary.slots(for: keys, observedHours: asleepHours, wornHours: recordedHours)
    }

    /// Sorts samples into nights and adds up the two figures each night needs.
    ///
    /// Two rules, both of which the previous version got wrong:
    ///
    /// 1. **Only genuine asleep stages count.** `inBed` is time in bed, not sleep;
    ///    summing it with the asleep stages inflates the number by however long
    ///    the user lay there reading, and would then be presented as a measured
    ///    figure.
    /// 2. **A sample belongs to the night it ends in.** The old code ran a
    ///    start-of-day-to-end-of-day predicate per day and summed whole
    ///    overlapping samples, so a 23:00–07:00 night was counted in full against
    ///    *both* days. Bucketing by end date is also how Health itself presents a
    ///    night — the morning you woke up.
    private func bucketed(_ samples: [HKCategorySample],
                          into keys: [Date]) -> (asleep: [Date: Double], recorded: [Date: Double]) {
        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
        ]
        let wanted = Set(keys)
        var asleepSeconds: [Date: Double] = [:]
        var recorded: [Date: [(start: Date, end: Date)]] = [:]

        for s in samples {
            let duration = s.endDate.timeIntervalSince(s.startDate)
            // Defensive: a zero-length or backwards sample is meaningless, and a
            // sample longer than a day is malformed however it got written.
            guard duration > 0, duration <= 24 * 3600 else { continue }
            let night = startOfDay(s.endDate)
            guard wanted.contains(night) else { continue }

            // Every sleepAnalysis sample — `inBed` included — is evidence the
            // device was on the wrist and recording, so it counts towards the
            // night's recorded time while only the asleep stages count towards
            // sleep.
            recorded[night, default: []].append((s.startDate, s.endDate))
            guard asleepValues.contains(s.value) else { continue }
            asleepSeconds[night, default: 0] += duration
        }

        var asleep: [Date: Double] = [:]
        for (night, seconds) in asleepSeconds {
            // Clamped at a day: overlapping samples from two sources — a watch and
            // a sleep-tracking app both writing the same night — could otherwise
            // sum past 24 hours. A cap is crude, but a 31-hour night on screen
            // would destroy the one thing this app is selling.
            asleep[night] = min(24, seconds / 3600)
        }
        var recordedHours: [Date: Double] = [:]
        for (night, intervals) in recorded {
            recordedHours[night] = min(24, unionSeconds(intervals) / 3600)
        }
        return (asleep, recordedHours)
    }

    /// Total time covered by a set of possibly overlapping intervals.
    ///
    /// Recorded time has to be a union rather than a sum: two sources writing the
    /// same night, or overlapping stage samples, would otherwise report more
    /// hours on the wrist than the night contains.
    private func unionSeconds(_ intervals: [(start: Date, end: Date)]) -> Double {
        let sorted = intervals.sorted { $0.start < $1.start }
        var total: Double = 0
        var openStart: Date?
        var openEnd: Date?
        for i in sorted {
            guard let s = openStart, let e = openEnd else {
                openStart = i.start; openEnd = i.end; continue
            }
            if i.start > e {
                total += e.timeIntervalSince(s)
                openStart = i.start; openEnd = i.end
            } else if i.end > e {
                openEnd = i.end
            }
        }
        if let s = openStart, let e = openEnd { total += e.timeIntervalSince(s) }
        return total
    }

    /// Hours of the day in which the wrist recorded something.
    ///
    /// The original adapter answered this with `samples.isEmpty ? 0 : 24`, i.e.
    /// "if anything at all was recorded, assume the watch was worn all day" — a
    /// fabricated denominator underneath a hero number whose entire job is to be
    /// honest. This counts distinct hours containing at least one sample instead.
    /// It is a proxy, not a wear time, and a conservative one: an hour with a
    /// single beat counts as a whole hour worn. What recommends it is that every
    /// hour it counts was written by the device.
    ///
    /// **Which signals, and why those.** Heart rate plus sleep analysis, unioned;
    /// deliberately *not* step count. The test is whether the signal can only
    /// exist while the device is on a wrist:
    ///
    /// * **heart rate** — yes, and it is sampled every few minutes all day, which
    ///   makes it the one signal dense enough to resolve wear to the hour. It is
    ///   the primary and does nearly all the work.
    /// * **sleep analysis** — yes, and it *spans* hours rather than sampling
    ///   them, so it fills in a night the watch was worn but heart-rate sampling
    ///   was sparse. Reinforcement, not a substitute: it is already read for the
    ///   sleep feature, so it costs no extra permission.
    /// * **step count** — no. Steps are also written by the iPhone, so counting
    ///   step hours would credit "on your wrist" to a phone sitting in a bag.
    ///   That is the same class of error as the 24 it replaced, just smaller.
    ///
    /// - Returns: `nil` when we could not look at all — no resolvable type, or
    ///   every query failed — which must stay distinguishable from an empty
    ///   result. An empty result is a real, measured zero. The three-state
    ///   modelling of that lives in `MovementSummary.wearHours(hoursWithSamples:)`,
    ///   which this defers to rather than counting here.
    private func wearHours(forDay day: Date) async -> Double? {
        let start = startOfDay(day)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return nil }
        // Non-strict, so a sleep sample that began the previous evening still
        // contributes the hours of *this* day that it covers.
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)

        /// Hour indices of the day an interval touches. A heart-rate sample is
        /// instantaneous so this is one hour; a sleep sample is not, and counting
        /// only its start hour would report an eight-hour night as one hour worn.
        func hoursTouched(from: Date, to: Date) -> [Int] {
            let first = Int(floor(max(0, from.timeIntervalSince(start)) / 3600))
            let last = Int(floor(min(24 * 3600 - 1, max(0, to.timeIntervalSince(start))) / 3600))
            guard first <= last else { return [] }
            return Array(first...last)
        }

        var hours: Set<Int> = []
        var looked = false

        if let hrType = HKObjectType.quantityType(forIdentifier: .heartRate),
           let samples = try? await quantitySamples(hrType, predicate) {
            looked = true
            for s in samples { hours.formUnion(hoursTouched(from: s.startDate, to: s.endDate)) }
        }
        if let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
           let samples = try? await categorySamples(sleepType, predicate) {
            looked = true
            for s in samples where s.endDate > s.startDate {
                hours.formUnion(hoursTouched(from: s.startDate, to: s.endDate))
            }
        }
        // `nil` only when nothing could be asked. Note that a *denied* read looks
        // like a successful empty query here, which is why the value this feeds
        // is gated by `MovementSummary.permittedForm` rather than shown bare.
        return MovementSummary.wearHours(hoursWithSamples: looked ? hours : nil)
    }

    // MARK: - Movement

    /// Fills the three movement caches for one day: step buckets, active energy
    /// in kilojoules, and exercise minutes.
    ///
    /// Called by `refresh(day:)` *after* `nightReadings`, which is what fills the
    /// wear cache — `movementDay(on:at:)` needs all four, so the order matters.
    ///
    /// A failed query leaves its cache unfilled rather than caching an empty
    /// result, which is the same rule the sleep path follows and for the same
    /// reason: a framework error is not a day with no steps in it. The cost is
    /// that a persistently failing query re-primes on every read; that is
    /// deliberate, and preferable to a cached lie.
    private func refreshMovement(day: Date) async {
        guard HKHealthStore.isHealthDataAvailable() else {
            withLock { healthDataUnavailable = true }
            return
        }
        await ensureAuthorised()

        let key = startOfDay(day)
        let buckets = await stepBuckets(forDay: key)
        let kilojoules = await activeKilojoules(forDay: key)
        let exercise = await exerciseMinutes(forDay: key)

        withLock {
            // `.some(nil)` where a query succeeded and found nothing; the key is
            // left absent where the query itself failed.
            if let buckets { stepBucketsByDay[key] = .some(buckets.isEmpty ? nil : buckets) }
            if let kilojoules { activeKilojoulesByDay[key] = kilojoules }
            if let exercise { exerciseMinutesByDay[key] = exercise }
        }
    }

    /// The day's steps in five-minute buckets, oldest first.
    ///
    /// `HKStatisticsCollectionQuery` rather than a sample query: the buckets are
    /// what the sedentary detector wants, and doing the bucketing in HealthKit
    /// avoids re-implementing its overlap and source-priority rules here.
    ///
    /// **The zero-versus-absent decision, which matters.** HealthKit does not
    /// write zero-step samples, so a five minutes of genuine stillness has no
    /// samples in it and `statistics.sumQuantity()` comes back `nil`.
    /// `StepBucket`'s contract says an absent bucket is an *unobserved* interval
    /// and `MovementSummary` ends the run at one — so emitting nothing for those
    /// intervals would make every real sitting bout unmeasurable. They are
    /// therefore emitted as **0 steps**: inside a range we did query, no sample
    /// is evidence of no steps.
    ///
    /// That leaves the "was anything recording at all?" question unanswered here,
    /// on purpose. It is answered better one layer up, by the wear proxy, and
    /// `MovementSummary.permittedForm(hoursWorn:)` is what stops a day the watch
    /// spent on the charger — which does produce a long, technically-correct
    /// sitting run — from being said out loud.
    ///
    /// - Returns: `nil` if the query failed, so the caller can decline to cache
    ///   it. An empty array means the day genuinely has not started yet.
    private func stepBuckets(forDay day: Date) async -> [StepBucket]? {
        guard let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) else { return nil }
        let start = startOfDay(day)
        guard let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return nil }
        // Never past the end of the day, and never into the future: buckets for
        // time that has not happened are not evidence, and `MovementSummary`
        // drops them anyway.
        let end = min(dayEnd, Date())
        guard end > start else { return [] }

        let width = MovementSummary.defaultBucketMinutes
        var interval = DateComponents()
        interval.minute = width
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end,
                                                    options: [.strictStartDate])
        guard let collection = try? await statisticsCollection(
            stepType, predicate: predicate, anchor: start, interval: interval) else { return nil }

        var out: [StepBucket] = []
        collection.enumerateStatistics(from: start, to: end) { stats, _ in
            // See the note above: no sum means no samples, which inside this
            // window means no steps rather than no observation.
            let steps = stats.sumQuantity()?.doubleValue(for: HKUnit.count()) ?? 0
            out.append(StepBucket(start: stats.startDate, steps: Int(steps.rounded())))
        }
        return out
    }

    /// NFR14: kilojoules are the stored unit, so the conversion happens here at
    /// the boundary rather than being left for a view to get wrong.
    ///
    /// Read in `HKUnit.jouleUnit(with: .kilo)` rather than in
    /// `HKUnit.kilocalorie()` followed by a multiply. HealthKit stores energy in
    /// joules and converts on the way out, so asking it for kilojoules is one
    /// conversion instead of two — and the multiply we would have written uses
    /// 4.184 kJ/kcal, the same ratio `NutritionFacts.calories` and
    /// `OpenFoodFactsRepository` use, which is HealthKit's own. The two routes
    /// agree; this one has no constant to drift.
    ///
    /// - Returns: `nil` when the query failed, `.some(nil)` when it succeeded and
    ///   the day has no active energy in it — an untouched day, not a still one.
    private func activeKilojoules(forDay day: Date) async -> Double?? {
        guard let type = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) else { return nil }
        return await dayTotal(type, day: day, unit: HKUnit.jouleUnit(with: .kilo))
    }

    /// Apple's own exercise-minutes figure, not a re-derivation of it.
    ///
    /// `.appleExerciseTime` is a cumulative type in minutes, so this is a sum and
    /// not a bout detector. Kairo has no business second-guessing what counts as
    /// exercise; the ring the user already trusts is the honest figure to show.
    private func exerciseMinutes(forDay day: Date) async -> Int?? {
        guard let type = HKObjectType.quantityType(forIdentifier: .appleExerciseTime) else { return nil }
        guard let total = await dayTotal(type, day: day, unit: HKUnit.minute()) else { return nil }
        return .some(total.map { Int($0.rounded()) })
    }

    /// One cumulative type summed over one day.
    ///
    /// The double optional is the same three states as everywhere else in this
    /// file: outer `nil` = the query failed and must not be cached, inner `nil` =
    /// it succeeded and there was nothing there.
    private func dayTotal(_ type: HKQuantityType, day: Date, unit: HKUnit) async -> Double?? {
        let start = startOfDay(day)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end,
                                                    options: [.strictStartDate])
        do {
            let sum = try await statisticsSum(type, predicate: predicate)
            // No sum quantity is HealthKit's way of saying "no samples matched",
            // which is a measured absence rather than a measured zero.
            return .some(sum?.doubleValue(for: unit))
        } catch {
            return nil
        }
    }

    // MARK: - Queries

    /// `HKSampleQuery` wrapped so a failure is a thrown error rather than an
    /// empty array. The distinction matters more here than anywhere: an empty
    /// array is cached as "the watch was off the wrist", and a network-less,
    /// permission-less framework error is not that.
    private func categorySamples(_ type: HKCategoryType,
                                 _ predicate: NSPredicate) async throws -> [HKCategorySample] {
        try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, result, error in
                if let error {
                    cont.resume(throwing: HealthReadError.fetchFailed(error.localizedDescription))
                } else {
                    cont.resume(returning: (result as? [HKCategorySample]) ?? [])
                }
            }
            store.execute(q)
        }
    }

    private func quantitySamples(_ type: HKQuantityType,
                                 _ predicate: NSPredicate) async throws -> [HKQuantitySample] {
        try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, result, error in
                if let error {
                    cont.resume(throwing: HealthReadError.fetchFailed(error.localizedDescription))
                } else {
                    cont.resume(returning: (result as? [HKQuantitySample]) ?? [])
                }
            }
            store.execute(q)
        }
    }

    /// `HKStatisticsQuery` wrapped, for the cumulative day totals.
    ///
    /// Resolves to `nil` rather than throwing when nothing matched, because that
    /// is not a failure — it is the answer. Only a framework error throws.
    private func statisticsSum(_ type: HKQuantityType,
                               predicate: NSPredicate) async throws -> HKQuantity? {
        try await withCheckedThrowingContinuation { cont in
            let q = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate,
                                      options: .cumulativeSum) { _, stats, error in
                if let error {
                    cont.resume(throwing: HealthReadError.fetchFailed(error.localizedDescription))
                } else {
                    cont.resume(returning: stats?.sumQuantity())
                }
            }
            store.execute(q)
        }
    }

    /// `HKStatisticsCollectionQuery` wrapped.
    ///
    /// `initialResultsHandler` only, no `statisticsUpdateHandler`: this adapter's
    /// contract is a cache somebody refreshes, not a live subscription, and an
    /// update handler on a query nobody stops would keep firing into a
    /// continuation that has already resumed.
    private func statisticsCollection(_ type: HKQuantityType, predicate: NSPredicate,
                                      anchor: Date,
                                      interval: DateComponents) async throws -> HKStatisticsCollection {
        try await withCheckedThrowingContinuation { cont in
            let q = HKStatisticsCollectionQuery(quantityType: type,
                                                quantitySamplePredicate: predicate,
                                                options: .cumulativeSum,
                                                anchorDate: anchor,
                                                intervalComponents: interval)
            q.initialResultsHandler = { _, collection, error in
                if let collection {
                    cont.resume(returning: collection)
                } else {
                    cont.resume(throwing: HealthReadError.fetchFailed(
                        error?.localizedDescription ?? "no statistics collection returned"))
                }
            }
            store.execute(q)
        }
    }

    #else
    // No HealthKit on this platform. Every read refuses rather than answering a
    // plausible nothing, and no cache is filled, so a surface built against this
    // shows its not-measured state instead of an empty ring.
    public func requestAuthorization() async throws { throw HealthReadError.notAvailable }
    public func refresh(day: Date) async {}

    public func nightReadings(endingOn day: Date, nights: Int) async -> [NightReading] {
        withLock { healthDataUnavailable = true }
        return SleepSummary.slots(for: nightKeys(endingOn: day, nights: nights), observedHours: [:])
    }
    #endif

    private func finishedPriming(_ keys: [Date]) {
        withLock { keys.forEach { priming.remove($0) } }
    }
}
