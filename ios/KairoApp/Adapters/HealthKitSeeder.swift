import Foundation

/// Member B — CF4 / CF5 / CF6. Getting a week of data *into* HealthKit so the
/// read path can finally be executed rather than merely compiled.
///
/// ## Why this file exists
///
/// `HealthKitDataSource`'s own doc comment carried a section called "What has
/// never run", and it was accurate: the sleep bucketing, the wear proxy and now
/// the movement reads had all been reasoned about and compiled and never once
/// executed against data. That is the worst state for this particular adapter to
/// be in, because every bug it can have degrades to *silence* — an empty query
/// result is indistinguishable from a watch that was off the wrist, so a broken
/// predicate looks exactly like a truthful "not measured" and nothing ever
/// complains.
///
/// The simulator does have a real HealthKit store (`healthdb.sqlite` under the
/// device's data directory) and `HKHealthStore` works against it. What it does
/// not have is any data, and there is no `simctl` subcommand to import any: the
/// only automatable way in is `HKHealthStore.save(_:)` with share authorisation.
/// So this is that — a debug-only writer that puts a coherent, deliberately
/// incomplete week into the simulator's store so the reads can be run.
///
/// ## Why it is wrapped in quite so many guards
///
/// It writes to a real HealthKit database. On a real device that database is
/// somebody's medical record, and synthetic sleep and heart-rate samples in it
/// are not a test artefact, they are a corruption of a health record that other
/// apps and a doctor may read. Being *unable* to run anywhere it could do that
/// is therefore a hard requirement rather than a nicety, and one guard is not
/// enough because any single guard can be edited away by somebody who does not
/// know what it is for. In defence-in-depth order:
///
/// 1. **`#if targetEnvironment(simulator)`** — the implementation does not
///    compile for a device slice at all. A device build contains no writer, so
///    there is nothing on the device to invoke, misconfigure or reflect over.
/// 2. **`#if DEBUG`** — and not in a release simulator build either, so a
///    TestFlight or archive configuration cannot carry it even by accident.
/// 3. **A runtime simulator re-check** — `ProcessInfo`'s `SIMULATOR_UDID` is
///    present only in a simulator process. Belt and braces over guard 1: if
///    somebody ever lifts the `#if`, the runtime check still refuses.
/// 4. **Explicit opt-in** — nothing here runs on launch. `runIfRequested()` is
///    safe to call unconditionally and does nothing at all unless a launch
///    argument or environment variable asks for it. Merely running the app in
///    the simulator never writes a sample.
/// 5. **Every sample is marked synthetic** — a custom metadata key, so anything
///    this wrote can be found, told apart from real data, and deleted.
/// 6. **A matching delete** — `deleteSeededSamples()` removes exactly the
///    samples bearing that marker, via a metadata predicate, so a seeded store
///    can be returned to empty. HealthKit additionally only permits an app to
///    delete objects it saved itself, which means this cannot remove a real
///    sample even if the predicate were wrong.
/// 7. **Share scope limited to what it writes** — four types, requested once,
///    and no read scopes at all. The read scopes are the adapter's business,
///    and a writer that quietly widened them would be misrepresenting itself.
///
/// ## How to run it, and the one step that is not automatable
///
/// From a shell, with the app already built for the simulator:
///
/// ```
/// xcrun simctl install <device-udid> <path>/KairoApp.app
/// xcrun simctl launch --console-pty <device-udid> \
///     au.edu.sydney.elec5620.kairo -KairoSeedHealthKit
/// ```
///
/// The launch will then stop on iOS's **Health Access** sheet, which asks to let
/// Kairo write Active Energy, Heart Rate, Sleep and Steps — exactly
/// `writeTypes`, and nothing to read. Somebody has to tap *Turn On All* and
/// *Allow* once, and there is no way around that: `simctl privacy` has no health
/// service, HealthKit has no test hook for share authorisation, and the sheet is
/// SpringBoard's rather than the app's. The grant persists for the install, so
/// it is one tap per simulator, not one per run. `deleteSeededSamples()` needs
/// the same grant and therefore no further tap.
///
/// After the tap the seed writes and the report is printed to the console and to
/// `os_log` under subsystem `au.edu.sydney.elec5620.kairo`, category
/// `HealthKitSeeder`.
///
/// **What has been executed, honestly.** The no-opt-in path (guard 4) has been
/// run on simulator `ABE335D6-C88E-4CD1-BCF2-E8F6C1F2A492`: launching without
/// the flag logs "no seed requested" and writes nothing. The opt-in path has
/// been run as far as `requestAuthorization`, which is what caught the
/// `.appleExerciseTime` crash documented on `writeTypes`, and which then
/// presented the sheet listing exactly the four write types and no read scopes.
/// The `save` itself, and the read-back through `HealthKitDataSource`, are
/// **still unexecuted**: they are behind that one tap.
///
/// The outer shim below is compiled everywhere so that call sites need no `#if`
/// of their own. On a device, in release, or without the opt-in, it is a no-op
/// that returns `nil`. Keeping the conditional compilation entirely inside this
/// file is deliberate: a guard that every caller has to remember to repeat is a
/// guard that will eventually be forgotten.
enum KairoHealthSeeding {

    /// Seeds, deletes, or does nothing, according to the launch environment.
    ///
    /// Safe to call unconditionally from app start-up. Returns a line worth
    /// logging, or `nil` when it did nothing — which is the overwhelmingly
    /// common case and the intended default.
    @discardableResult
    static func runIfRequested() async -> String? {
        #if targetEnvironment(simulator)
        #if DEBUG
        return await HealthKitSeeder.runIfRequested()
        #else
        return nil
        #endif
        #else
        return nil
        #endif
    }

    /// True only in a Debug simulator build — the one place the writer exists.
    /// The Presenting section shows its buttons only when this is true.
    static var isAvailable: Bool {
        #if targetEnvironment(simulator) && DEBUG && canImport(HealthKit)
        return true
        #else
        return false
        #endif
    }

    /// The same seed as `-KairoSeedHealthKit`, from a button. Every guard in
    /// this file still applies; this only removes the need for a launch flag,
    /// which is awkward to pass in front of an audience. iOS still asks for the
    /// write permission once, in its own sheet.
    static func seedNow() async -> String {
        #if targetEnvironment(simulator) && DEBUG && canImport(HealthKit)
        do {
            return try await HealthKitSeeder.seed().summary
        } catch {
            return "HealthKit seed failed: \(error.localizedDescription)"
        }
        #else
        return "Seeding Health is only possible in a Debug simulator build."
        #endif
    }

    /// Removes exactly what `seedNow()` wrote.
    static func deleteNow() async -> String {
        #if targetEnvironment(simulator) && DEBUG && canImport(HealthKit)
        do {
            return try await HealthKitSeeder.deleteSeededSamples()
        } catch {
            return "HealthKit seed deletion failed: \(error.localizedDescription)"
        }
        #else
        return "Seeding Health is only possible in a Debug simulator build."
        #endif
    }

    /// The metadata key every seeded sample carries.
    ///
    /// Exposed outside the `#if` so that a diagnostic screen or a test can name
    /// it without having to be conditionally compiled itself. Reverse-DNS on the
    /// app's bundle prefix, per HealthKit's convention for custom metadata keys,
    /// so it cannot collide with Apple's or another app's.
    static let syntheticMetadataKey = "au.edu.sydney.elec5620.kairo.synthetic"

    /// Launch argument that asks for a seed: pass `-KairoSeedHealthKit` in the
    /// scheme's arguments, or set `KAIRO_SEED_HEALTHKIT=1`.
    static let seedFlag = "-KairoSeedHealthKit"
    /// Launch argument that asks for the seeded samples to be removed again:
    /// `-KairoDeleteSeededHealthKit`, or `KAIRO_SEED_HEALTHKIT=delete`.
    static let deleteFlag = "-KairoDeleteSeededHealthKit"
    /// Environment-variable name for the same opt-in, for the cases where an
    /// argument is awkward to inject (a `SIMCTL_CHILD_` prefixed variable, say).
    static let seedFlagEnvironmentName = "KAIRO_SEED_HEALTHKIT"
}

#if targetEnvironment(simulator)
#if DEBUG
#if canImport(HealthKit)
import HealthKit
import KairoKit
import os

/// The writer itself. See `KairoHealthSeeding` for why it is buried this deep.
enum HealthKitSeeder {

    private static let log = Logger(subsystem: "au.edu.sydney.elec5620.kairo", category: "HealthKitSeeder")

    // MARK: - The shape of the week

    /// Nights the seeded week deliberately leaves empty, as offsets back from
    /// today (0 = the night that ended this morning).
    ///
    /// **The gaps are the point.** `SleepSummary` excludes unobserved nights from
    /// the debt rather than zero-filling them, `SleepDebt.isLowerBound` goes true
    /// when any are missing, and `SleepSummary.permittedForm` downgrades the
    /// claim accordingly — and none of that had ever been exercised against real
    /// HealthKit data, because a complete week never reaches it. A fully seeded
    /// week would test the arithmetic and skip the entire feature.
    ///
    /// Four observed nights of seven is chosen for where it lands: a coverage
    /// fraction of 0.571, just *under* the 0.6 floor, so the coverage ladder says
    /// `.range` while `SleepSummary.windowForm(observedNights: 4)` says
    /// `.qualified`. The weaker wins, so the seeded week must render as a range
    /// and never as a bare number. If it renders as a number on screen, something
    /// downstream is ignoring the gate, and that is exactly the bug worth
    /// catching.
    private static let unobservedNightOffsets: Set<Int> = [2, 4, 5]

    /// Hours asleep for each observed night, keyed by offset back from today.
    ///
    /// Round quarter-hours on purpose, so the debt can be checked by eye:
    /// against the 8 h reference the shortfalls are 0.5 + 2.0 + 0 + 3.0 = **5.5 h
    /// across four observed nights**, and the night at offset 3 is a surplus that
    /// must *not* cancel any of it (`NightReading.shortfall` clamps at zero).
    private static let sleepHoursByOffset: [Int: Double] = [
        0: 7.5,   // last night
        1: 6.0,
        3: 8.25,  // a surplus, which cancels nothing
        6: 5.0,
    ]

    /// Minutes at the end of today with no step samples at all, which is what
    /// produces the unbroken sitting run.
    ///
    /// 75 minutes, so the run lands well above any plausible nudge threshold and
    /// is obviously not a rounding artefact. The bucket immediately before this
    /// window gets a deliberate 300-step sample so the run has a definite start:
    /// without it the run would extend back through the morning's quiet desk
    /// buckets and the number would depend on the seeded pattern rather than
    /// being pinned by it.
    private static let quietTailMinutes = 75

    /// Hours of today the watch is pretended to be off the wrist, as
    /// hour-of-day indices.
    ///
    /// A deliberate hole in the heart-rate series so the wear proxy comes back at
    /// something less than the whole day. A wear figure of 24 is the value the
    /// original adapter fabricated, so a seed that happened to produce 24 would
    /// be unable to tell the fix from the bug.
    private static let offWristHours: Set<Int> = [13, 14]

    // MARK: - Guard 3: the runtime re-check

    /// True only inside a simulator process.
    ///
    /// `SIMULATOR_UDID` is injected into the environment of every simulator
    /// process and exists nowhere else. Redundant with the `#if` this code is
    /// already inside, and that is the entire value of it: the `#if` protects
    /// against the code shipping, this protects against the `#if` being removed.
    private static var isSimulator: Bool {
        ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil
    }

    // MARK: - Guard 4: the opt-in

    private enum Request { case seed, delete, none }

    private static var request: Request {
        let info = ProcessInfo.processInfo
        let args = info.arguments
        let env = info.environment[KairoHealthSeeding.seedFlagEnvironmentName]?.lowercased()
        // Delete is checked first so that asking for both does the safe thing.
        if args.contains(KairoHealthSeeding.deleteFlag) || env == "delete" { return .delete }
        if args.contains(KairoHealthSeeding.seedFlag) || env == "1" || env == "true" { return .seed }
        return .none
    }

    // MARK: - What it writes

    /// Exactly the four types this writes, and therefore exactly the share scope
    /// it asks for. Nothing here requests a *read* scope: the adapter asks for
    /// those, for its own reasons, and a writer that quietly widened the app's
    /// read permissions would be misrepresenting itself to the user.
    ///
    /// ## Do not add a reserved type to this list
    ///
    /// Learned by crashing the app on the simulator, which is the honest way to
    /// have learned it. `.appleExerciseTime` was in this list; HealthKit reserves
    /// the activity-ring types (`appleExerciseTime`, `appleStandTime`,
    /// `appleMoveTime`) to itself and refuses share authorisation for them —
    /// **as an uncatchable Objective-C exception**, not a Swift error:
    ///
    /// ```
    /// NSInvalidArgumentException: Authorization to share the following types is
    /// disallowed: HKQuantityTypeIdentifierAppleExerciseTime
    ///   -[HKHealthStoreImplementation _throwIfAuthorizationDisallowedForSharing:types:]
    /// ```
    ///
    /// `requestAuthorization` throws it before returning, so no `try`/`catch`
    /// anywhere in this file can contain it and the process dies. There is no
    /// API that reports whether a type is shareable, so the only defence is this
    /// list being right. Consequently exercise minutes are **not seeded** — see
    /// `seed(days:)` — and the adapter's `exerciseMinutes(forDay:)` read will
    /// come back "measured, nothing there" against a seeded store. That is a
    /// genuine limitation of the simulator route, not a gap in the read.
    private static var writeTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = []
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
        for id: HKQuantityTypeIdentifier in [.stepCount, .heartRate, .activeEnergyBurned] {
            if let t = HKObjectType.quantityType(forIdentifier: id) { types.insert(t) }
        }
        return types
    }

    /// Attached to every single sample written from here.
    ///
    /// `HKMetadataKeyWasUserEntered` as well as the custom marker, because it is
    /// the standard key other apps and the Health app itself look at, and because
    /// these samples are emphatically not device measurements.
    private static var syntheticMetadata: [String: Any] {
        [
            KairoHealthSeeding.syntheticMetadataKey: true,
            HKMetadataKeyWasUserEntered: true,
        ]
    }

    // MARK: - Entry point

    @discardableResult
    static func runIfRequested() async -> String? {
        guard isSimulator else {
            // Should be unreachable; see guard 3. Logged rather than silent so
            // that if it ever *is* reached, somebody finds out.
            log.error("HealthKitSeeder reached outside a simulator process. Refusing.")
            return nil
        }
        switch request {
        case .none:
            return nil
        case .seed:
            do {
                let report = try await seed()
                log.notice("\(report.summary, privacy: .public)")
                return report.summary
            } catch {
                let line = "HealthKit seed failed: \(error.localizedDescription)"
                log.error("\(line, privacy: .public)")
                return line
            }
        case .delete:
            do {
                let report = try await deleteSeededSamples()
                log.notice("\(report, privacy: .public)")
                return report
            } catch {
                let line = "HealthKit seed deletion failed: \(error.localizedDescription)"
                log.error("\(line, privacy: .public)")
                return line
            }
        }
    }

    // MARK: - Seeding

    struct Report {
        var sleepSamples = 0
        var stepSamples = 0
        var heartRateSamples = 0
        var energySamples = 0
        var observedNights = 0
        var unobservedNights = 0
        var expectedSittingMinutes = 0
        var stepsToday = 0
        var kilojoulesToday: Double = 0

        var summary: String {
            """
            HealthKit seed written (all samples marked \(KairoHealthSeeding.syntheticMetadataKey)):
              sleep        \(sleepSamples) samples across \(observedNights) nights, \
            \(unobservedNights) nights deliberately left empty
              steps        \(stepSamples) samples, \(stepsToday) steps today, \
            last \(expectedSittingMinutes) min deliberately empty
              heart rate   \(heartRateSamples) samples, off-wrist hours \
            \(offWristHours.sorted().map(String.init).joined(separator: ","))
              energy       \(energySamples) samples, \(Int(kilojoulesToday)) kJ today
              exercise     not seeded — HealthKit reserves .appleExerciseTime, \
            see HealthKitSeeder.writeTypes
            Remove it again with \(KairoHealthSeeding.deleteFlag).
            """
        }
    }

    /// Writes a coherent, deliberately incomplete week.
    ///
    /// "Coherent" means the signals agree with each other: the heart-rate series
    /// covers the hours the step series has activity in, sleep sits in the hours
    /// the heart-rate series is quiet, and nothing is written into the future.
    /// A week of independently random samples would exercise the queries but not
    /// the interpretation — a wear figure that contradicts the step data would
    /// produce nonsense downstream and nobody could tell whether the nonsense was
    /// the seed's or the adapter's.
    @discardableResult
    static func seed(days: Int = 7) async throws -> Report {
        guard isSimulator else { throw SeedError.notASimulator }
        guard HKHealthStore.isHealthDataAvailable() else { throw SeedError.noHealthStore }

        let store = HKHealthStore()
        // Guard 7: exactly the types written, no read scopes.
        try await store.requestAuthorization(toShare: writeTypes, read: [])

        var report = Report()
        var objects: [HKObject] = []
        let now = Date()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)

        for offset in 0..<max(1, days) {
            guard let dayStart = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let isToday = offset == 0
            // Never into the future. HealthKit rejects a sample whose end date is
            // ahead of now, and a seed that half-succeeded would be worse than
            // one that failed outright.
            let dayEnd = min(calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart, now)
            guard dayEnd > dayStart else { continue }

            // --- Sleep, with the deliberate gaps ---
            if unobservedNightOffsets.contains(offset) {
                report.unobservedNights += 1
            } else if let hours = sleepHoursByOffset[offset] {
                let samples = sleepSamples(wakingOn: dayStart, hoursAsleep: hours, notAfter: now)
                objects += samples
                report.sleepSamples += samples.count
                report.observedNights += 1
            } else {
                report.unobservedNights += 1
            }

            // --- Steps ---
            let steps = stepSamples(on: dayStart, isToday: isToday, notAfter: now)
            objects += steps.samples
            report.stepSamples += steps.samples.count
            if isToday {
                report.stepsToday = steps.total
                report.expectedSittingMinutes = steps.quietTailMinutes
            }

            // --- Heart rate, for the wear proxy ---
            let hr = heartRateSamples(on: dayStart, notAfter: dayEnd)
            objects += hr
            report.heartRateSamples += hr.count

            // --- Active energy, in kilojoules ---
            let energy = energySamples(on: dayStart, notAfter: dayEnd)
            objects += energy.samples
            report.energySamples += energy.samples.count
            if isToday { report.kilojoulesToday = energy.totalKilojoules }

            // --- Exercise minutes: deliberately not seeded ---
            // `.appleExerciseTime` is reserved to HealthKit and cannot be
            // written by a third-party app; asking for share authorisation for
            // it terminates the process. See `writeTypes`. The adapter still
            // reads it, and against a seeded store that read correctly reports a
            // measured absence rather than zero — which at least exercises the
            // `.some(nil)` branch of the cache.
        }

        try await save(objects, to: store)
        return report
    }

    // MARK: - Sleep

    /// One night: an `inBed` envelope plus contiguous asleep stages summing to
    /// exactly `hoursAsleep`.
    ///
    /// Exactness matters for verification. The adapter sums only the asleep
    /// stages — `inBed` is time in bed, not sleep — so a night seeded at 7.5 h
    /// must read back as 7.5 h. Anything else and the stage filter is wrong.
    ///
    /// Waking at 06:45 on `morning`, so the sample crosses midnight and lands in
    /// the bucketing rule the adapter's own note flags as the first thing to
    /// check: a sample belongs to the night it *ends* in.
    private static func sleepSamples(wakingOn morning: Date, hoursAsleep: Double,
                                     notAfter limit: Date) -> [HKCategorySample] {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let calendar = Calendar.current
        guard let wake = calendar.date(bySettingHour: 6, minute: 45, second: 0, of: morning),
              wake <= limit else { return [] }
        let asleepStart = wake.addingTimeInterval(-hoursAsleep * 3600)

        // Fractions of the night per stage, summing to 1 so the total is exact.
        // Roughly the proportions a watch reports, and round enough to check.
        let stages: [(HKCategoryValueSleepAnalysis, Double)] = [
            (.asleepCore, 0.40),
            (.asleepDeep, 0.20),
            (.asleepREM, 0.25),
            (.asleepCore, 0.15),
        ]

        var out: [HKCategorySample] = []
        // The envelope: fifteen minutes settling before, ten reading after. This
        // is the sample that would inflate the night by 25 minutes if the adapter
        // ever counted `inBed` as sleep again.
        out.append(HKCategorySample(type: type,
                                    value: HKCategoryValueSleepAnalysis.inBed.rawValue,
                                    start: asleepStart.addingTimeInterval(-15 * 60),
                                    end: min(wake.addingTimeInterval(10 * 60), limit),
                                    metadata: syntheticMetadata))
        var cursor = asleepStart
        for (stage, fraction) in stages {
            let end = cursor.addingTimeInterval(hoursAsleep * 3600 * fraction)
            out.append(HKCategorySample(type: type, value: stage.rawValue,
                                        start: cursor, end: min(end, limit),
                                        metadata: syntheticMetadata))
            cursor = end
        }
        return out.filter { $0.endDate > $0.startDate }
    }

    // MARK: - Steps

    /// The day's step samples, and today's deliberate quiet tail.
    ///
    /// Each sample is one minute wide and sits strictly inside a single
    /// five-minute bucket, so `HKStatisticsCollectionQuery` cannot split one
    /// across two buckets and the run the adapter computes is pinned by the seed
    /// rather than by HealthKit's overlap rules.
    ///
    /// The quiet window is **snapped down to a bucket boundary** before anything
    /// is placed relative to it. It has to be: the seeder runs at whatever second
    /// of the day somebody launched the app, so an unsnapped boundary puts the
    /// run's opening marker astride two buckets, half its steps land in the first
    /// quiet bucket, and the run the adapter reports comes out short for reasons
    /// that have nothing to do with the code under test. The returned
    /// `quietTailMinutes` is the snapped figure, so the report says what was
    /// actually seeded rather than what was asked for.
    private static func stepSamples(on dayStart: Date, isToday: Bool,
                                    notAfter now: Date) -> (samples: [HKQuantitySample],
                                                            total: Int,
                                                            quietTailMinutes: Int) {
        guard let type = HKObjectType.quantityType(forIdentifier: .stepCount) else { return ([], 0, 0) }

        let bucketSeconds = Double(MovementSummary.defaultBucketMinutes) * 60
        let dayLimit = min(dayStart.addingTimeInterval(24 * 3600), now)
        // Today's quiet tail cannot be longer than the day so far. Very early in
        // the morning the run is simply shorter, and honestly so.
        let elapsedMinutes = Int(dayLimit.timeIntervalSince(dayStart) / 60)
        let requested = isToday ? min(quietTailMinutes, max(0, elapsedMinutes - 10)) : 0
        // Snapped to the bucket the adapter will use, anchored on the same
        // start-of-day it anchors on.
        let rawQuietStart = dayLimit.addingTimeInterval(-Double(requested) * 60)
        let bucketIndex = floor(rawQuietStart.timeIntervalSince(dayStart) / bucketSeconds)
        let quietStart = dayStart.addingTimeInterval(bucketIndex * bucketSeconds)
        let quiet = requested > 0 ? Int(dayLimit.timeIntervalSince(quietStart) / 60) : 0

        /// (minute-of-day, steps) for the day's activity. A desk day: a walk to
        /// the station, a mostly-still morning with a few trips, a lunch walk,
        /// then a still afternoon.
        var pattern: [(minute: Int, steps: Int)] = []
        func walk(from: Int, to: Int, perBucket: Int) {
            for m in stride(from: from, to: to, by: 5) { pattern.append((m, perBucket)) }
        }
        walk(from: 7 * 60, to: 8 * 60 + 30, perBucket: 480)      // out of the house
        for m in stride(from: 8 * 60 + 30, to: 12 * 60 + 30, by: 45) {
            pattern.append((m, 90))                               // occasional trips
        }
        walk(from: 12 * 60 + 30, to: 13 * 60, perBucket: 420)     // lunch walk
        for m in stride(from: 13 * 60, to: 17 * 60 + 30, by: 45) {
            pattern.append((m, 70))
        }
        walk(from: 17 * 60 + 30, to: 18 * 60 + 30, perBucket: 450) // home again
        if !isToday {
            walk(from: 19 * 60, to: 19 * 60 + 20, perBucket: 300)  // an evening stroll
        }

        var out: [HKQuantitySample] = []
        var total = 0
        for (minute, steps) in pattern {
            let start = dayStart.addingTimeInterval(Double(minute) * 60)
            let end = start.addingTimeInterval(60)
            guard end <= dayLimit else { continue }
            // The quiet tail: nothing at all inside it, which is what makes the
            // buckets there read as zero and the sitting run open.
            guard quiet == 0 || end <= quietStart else { continue }
            out.append(sample(type, Double(steps), unit: .count(), from: start, to: end))
            total += steps
        }

        // The definite start of the run. Without this the run would reach back
        // through the afternoon's sparse buckets and its length would be an
        // accident of the pattern above rather than a fact about the seed.
        //
        // Placed in the middle of the bucket immediately before the quiet
        // window, thirty seconds clear of both its edges, so it cannot leak a
        // single step into the first quiet bucket.
        if quiet > 0 {
            let start = quietStart.addingTimeInterval(-bucketSeconds + 30)
            let end = quietStart.addingTimeInterval(-30)
            if start > dayStart, end <= dayLimit {
                out.append(sample(type, 300, unit: .count(), from: start, to: end))
                total += 300
            }
        }
        return (out, total, quiet)
    }

    // MARK: - Heart rate

    /// A heart-rate sample every ten minutes, with `offWristHours` left empty.
    ///
    /// Ten minutes is roughly what a watch writes when it is not exercising, and
    /// it is dense enough that the adapter's hour-counting proxy resolves every
    /// worn hour. The night is covered too — the watch is worn to sleep in this
    /// fixture — so the wear figure and the sleep figure agree, and a night that
    /// reads as slept but not worn would be a real inconsistency rather than a
    /// gap in the seed.
    private static func heartRateSamples(on dayStart: Date, notAfter limit: Date) -> [HKQuantitySample] {
        guard let type = HKObjectType.quantityType(forIdentifier: .heartRate) else { return [] }
        let unit = HKUnit.count().unitDivided(by: .minute())
        var out: [HKQuantitySample] = []
        for minute in stride(from: 0, to: 24 * 60, by: 10) {
            let hour = minute / 60
            guard !offWristHours.contains(hour) else { continue }
            let start = dayStart.addingTimeInterval(Double(minute) * 60)
            let end = start.addingTimeInterval(60)
            guard end <= limit else { break }
            // A plausible diurnal shape rather than one flat number: low
            // overnight, higher across the day. Deterministic, so two runs of the
            // seeder produce the same store.
            let bpm: Double = (hour < 7 || hour >= 23) ? 52 : (hour >= 12 && hour < 14 ? 88 : 68)
            out.append(sample(type, bpm, unit: unit, from: start, to: end))
        }
        return out
    }

    // MARK: - Active energy

    /// Hourly active-energy samples, written in kilojoules.
    ///
    /// NFR14 again: kJ is this project's stored unit, HealthKit stores energy in
    /// joules, and `HKUnit.jouleUnit(with: .kilo)` writes it with no conversion
    /// on either side. The adapter reads it back in the same unit, so if the
    /// number that comes out is not the number that went in, the fault is in the
    /// query and not in an arithmetic constant.
    private static func energySamples(on dayStart: Date,
                                      notAfter limit: Date) -> (samples: [HKQuantitySample],
                                                                totalKilojoules: Double) {
        guard let type = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) else { return ([], 0) }
        let unit = HKUnit.jouleUnit(with: .kilo)
        var out: [HKQuantitySample] = []
        var total: Double = 0
        for hour in 0..<24 {
            // Round hundreds so the day's total is checkable by eye: 200 kJ an
            // hour awake, 600 in the two commute hours, nothing while asleep.
            let kilojoules: Double
            switch hour {
            case 0..<7, 23: kilojoules = 0
            case 7, 17: kilojoules = 600
            default: kilojoules = 200
            }
            guard kilojoules > 0 else { continue }
            let start = dayStart.addingTimeInterval(Double(hour) * 3600)
            let end = start.addingTimeInterval(3600)
            guard end <= limit else { break }
            out.append(sample(type, kilojoules, unit: unit, from: start, to: end))
            total += kilojoules
        }
        return (out, total)
    }

    // MARK: - Deleting, guard 6

    /// Removes every sample bearing the synthetic marker, and nothing else.
    ///
    /// Two independent limits on the blast radius:
    ///
    /// 1. **The predicate.** `HKQuery.predicateForObjects(withMetadataKey:
    ///    operatorType:value:)` matches only objects whose metadata carries the
    ///    marker set to `true`. A real sample from a watch has no such key.
    /// 2. **HealthKit's own rule.** An app may only delete objects it saved
    ///    itself; `deleteObjects` fails on anything else. So even a predicate
    ///    that matched everything could not remove another source's data.
    ///
    /// Together those mean the worst this can do is delete samples that this
    /// seeder wrote — which is the entire intent.
    @discardableResult
    static func deleteSeededSamples() async throws -> String {
        guard isSimulator else { throw SeedError.notASimulator }
        guard HKHealthStore.isHealthDataAvailable() else { throw SeedError.noHealthStore }

        let store = HKHealthStore()
        // Deleting requires share authorisation for the same types, and nothing
        // more than those types.
        try await store.requestAuthorization(toShare: writeTypes, read: [])

        let predicate = HKQuery.predicateForObjects(
            withMetadataKey: KairoHealthSeeding.syntheticMetadataKey,
            operatorType: .equalTo, value: true)

        var deleted = 0
        var failures: [String] = []
        for type in writeTypes {
            do {
                deleted += try await delete(of: type, matching: predicate, in: store)
            } catch {
                // Reported rather than swallowed: a type that would not clear is
                // exactly the thing somebody needs to know about, since it means
                // synthetic samples are still in the store.
                failures.append("\(type.identifier): \(error.localizedDescription)")
            }
        }
        let tail = failures.isEmpty ? "" : "\n  could not clear: " + failures.joined(separator: "; ")
        return "HealthKit seed deleted: \(deleted) synthetic samples removed.\(tail)"
    }

    // MARK: - Plumbing

    enum SeedError: Error, LocalizedError {
        case notASimulator
        case noHealthStore

        var errorDescription: String? {
            switch self {
            case .notASimulator:
                return "The HealthKit seeder refuses to run outside a simulator."
            case .noHealthStore:
                return "No HealthKit store is available here."
            }
        }
    }

    private static func sample(_ type: HKQuantityType, _ value: Double, unit: HKUnit,
                               from start: Date, to end: Date) -> HKQuantitySample {
        HKQuantitySample(type: type,
                         quantity: HKQuantity(unit: unit, doubleValue: value),
                         start: start, end: end,
                         metadata: syntheticMetadata)
    }

    /// Saved in one call rather than per sample: HealthKit's own guidance, and it
    /// makes the write atomic enough that a failure leaves nothing half-seeded.
    private static func save(_ objects: [HKObject], to store: HKHealthStore) async throws {
        guard !objects.isEmpty else { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            store.save(objects) { _, error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    private static func delete(of type: HKSampleType, matching predicate: NSPredicate,
                               in store: HKHealthStore) async throws -> Int {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, Error>) in
            store.delete(of: type, predicate: predicate) { _, count, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: count) }
            }
        }
    }
}

private extension HKHealthStore {
    /// Named wrapper so the call above reads in the same order as the predicate
    /// it takes. `deleteObjects(of:predicate:withCompletion:)` is the underlying
    /// API; nothing is changed but the argument order.
    func delete(of type: HKSampleType, predicate: NSPredicate,
                completion: @escaping (Bool, Int, Error?) -> Void) {
        deleteObjects(of: type, predicate: predicate, withCompletion: completion)
    }
}

#endif
#endif
#endif
