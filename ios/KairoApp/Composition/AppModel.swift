import Foundation
import Observation
import os
import KairoKit

/// The single observable the SwiftUI tree reads. Feature views own their own
/// sub-state; anything crossing a member boundary lives here.
@Observable
final class AppModel {
    private static let log = Logger(subsystem: "au.edu.sydney.elec5620.kairo",
                                    category: "AppModel")

    let env: AppEnvironment

    private(set) var arbitration: ArbitrationResult?
    /// Stable per install, so the backend's per-user cost budget means something.
    let userID: String = {
        let key = "kairo.userID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString.prefix(8).lowercased()
        UserDefaults.standard.set(String(fresh), forKey: key)
        return String(fresh)
    }()
    private(set) var coverage: DayCoverage
    /// Today's movement, as actually read. nil until something has looked, which
    /// is deliberately distinct from a day with nothing in it.
    private(set) var movement: MovementDay?
    private(set) var contract: PlanContract?
    private(set) var memories: [MemoryItem] = []
    private(set) var records: [DecisionRecord] = []
    private(set) var lastError: String?

    /// CF8 - the day's water as a log of taps rather than a running integer, so a
    /// message WatchConnectivity re-delivers can be discarded by id instead of
    /// being counted twice.
    private(set) var hydration: HydrationLog

    /// CF1 / CF2 - today's confirmed meals. Before this, a confirmed meal reached
    /// `.logged` inside its capture screen and was never seen again: meal
    /// coverage stayed at zero and the agents were told energy was not measured.
    private(set) var meals: [LoggedMeal]
    /// A reference figure for the Nutrition role, stated as one on screen. It is
    /// the same 8,700 kJ the backend's recommendation route defaults to.
    let kilojoulesTarget: Double = 8_700
    var kilojoulesLogged: Double { meals.reduce(0) { $0 + $1.kilojoules } }

    /// The Nutrition Analyst's last next-meal suggestion, and whether one is
    /// being asked for.
    private(set) var mealSuggestion: RemoteAgentClient.MealSuggestion?
    private(set) var suggestingMeal = false
    /// What the curator did with the last thing it was told (CF10).
    private(set) var lastExtraction: String?
    private(set) var teaching = false

    /// Readings from `DemoScenario` instead of HealthKit, for a phone with no
    /// history in front of an audience. Persisted so a relaunch mid-demo does
    /// not drop back to an empty day; announced on Today whenever it is on.
    private(set) var demoMode: Bool = UserDefaults.standard.bool(forKey: DemoScenario.defaultsKey)

    /// The health port every reading goes through. One switch, so no screen
    /// can read HealthKit while the agents are being sent the demo day.
    ///
    /// In demo mode this is the blend: recorded Health where it has an answer,
    /// the live wrist for sitting, and the scenario for the rest.
    var health: HealthDataSource {
        demoMode ? demoHealth : env.health
    }

    private var demoHealth: DemoBlendHealth {
        DemoBlendHealth(recorded: useRecordedHealth ? env.health : nil, live: live)
    }

    // MARK: Demo signals

    /// The demo wrist's latest readings, from the watch or the phone simulator.
    private(set) var live = LiveSignals()
    /// Whether the phone's own simulated wrist is running.
    private(set) var phoneStreamOn = false
    /// Recorded Health takes precedence over the scenario in demo mode. On by
    /// default; off makes the demo the fixed scenario plus the live wrist.
    private(set) var useRecordedHealth: Bool =
        UserDefaults.standard.object(forKey: "kairo.demo.useRecordedHealth") as? Bool ?? true
    /// Where last night's sleep came from, for the screens to say so.
    private(set) var sleepIsRecorded = false
    /// What the simulator's Health seeder last did, in its own words.
    private(set) var seedReport: String?

    private var simulatedWrist = SimulatedWrist()
    private var streamTask: Task<Void, Never>?
    private var lastSignalPass = Date.distantPast
    private var lastWatchSignal = Date.distantPast
    /// Readings from the watch this recently mean the watch is driving, and the
    /// phone simulator holds still rather than talking over it.
    private static let watchPrecedence: TimeInterval = 10
    /// The fewest seconds between two passes the signals ask for. A pass is
    /// five model calls; a stream must not turn into a bill.
    private static let signalPassSpacing: TimeInterval = 20
    /// Real seconds per simulated minute on the phone's stream.
    private static let streamTickInterval: UInt64 = 2_000_000_000

    /// What is actually happening right now, as the agents see it. Nothing filled
    /// this in before: the roles have bid on `hydrationML` since day one and were
    /// handed nil every time.
    private(set) var observations: Observations = .none

    /// Whether the wrist can be reached right now. Only meaningful when
    /// `wristAvailable` - in preview there is no session to be reachable.
    private(set) var wristLinked = false

    /// The link in the states the pairing screen needs apart (SCRUM-21's
    /// companion half). `wristLinked` stays as the one-bit answer the rest of
    /// the app asks for; this is the one a person is shown.
    private(set) var wristLink: WristLink = .connecting

    /// True when this configuration has a phone/watch session at all. False in
    /// preview, and false on a phone with no watch paired, which are different
    /// situations from "linked but out of range".
    var wristAvailable: Bool { env.wrist != nil }

    /// CF7. Set in `init` from the bound clock, not here: as a property
    /// initialiser this carried the report's 25 August and four interruptions
    /// already spent, so a phone that had delivered nothing opened on "5 of 6
    /// spent" and had one interruption left for the whole day it had not yet had.
    var schedule: NudgeSchedule

    /// SCRUM-21. The primary user's settings (AS-3: there is one).
    ///
    /// Held here and persisted locally as well as on the server, because AG-1's
    /// ceiling is a grant the user made and NFR9 says the app keeps working with
    /// no network. A preference that only exists on a backend is one that
    /// vanishes the moment the backend does - and the ceiling is the single
    /// setting whose job is to be respected when nothing else is working.
    private(set) var userProfile: RemoteAgentClient.UserProfile = ProfileStore.load()
    var profile: CapabilityProfile = .unrestricted

    /// Where the agent backend is, and whether it is answering.
    let backend: BackendConnection

    /// What produced the arbitration currently on screen. The UI says so, because
    /// five reasoning roles and a local heuristic must not be indistinguishable.
    enum Source: Equatable { case agents(recordID: String), onDevice }
    private(set) var arbitrationSource: Source = .onDevice
    /// Which roles contributed, when the backend served it.
    private(set) var contributingRoles: [String] = []

    /// Whether the cost ceiling behind the arbitration on screen stands for a
    /// bill. Carried from `/v1/arbitrate`'s `budget` object, which arrives on
    /// every pass, so the suppression sentence costs no extra request. The
    /// on-device arbiter has no service cost at all, so its ladder is notional
    /// by construction.
    private(set) var arbitrationCosting: SuppressionCopy.Costing = .notional

    /// Which backend sealed the record on screen, and the FAST-tier model that
    /// did the bidding in it. Settings facts - a user does not need to know
    /// they are talking to a particular model to drink water - so these are
    /// held for the agents sheet and read nowhere else.
    private(set) var servingProvider: String?
    private(set) var servingModelID: String?

    /// OF3 - how much each class is worth an interruption, 0...1.
    ///
    /// Read by `runArbitration()` on both paths: it scales the bids the local
    /// source raises, and it is sent to the agents so the roles bid against the
    /// same weights. Zero is a real position, and the one the screen promises
    /// about: a class at zero raises no bid here and any bid the agents return
    /// for it is suppressed as `classSuspended` before it reaches the ledger.
    var priorities: [String: Double] = Dictionary(
        uniqueKeysWithValues: NudgeClassVocabulary.known.map { ($0, 0.6) })

    /// - Parameter seedingScenario: whether to open on the reference coverage the
    ///   report documents. True for `.demo`, false for a real phone.
    ///
    ///   These four numbers were unconditional, which made them the last piece of
    ///   the report's scenario still on screen after the clock and the health port
    ///   became real: a phone that had measured nothing still displayed "seen 4 of
    ///   5". Coverage is what `SafetyGate` consults to decide how strongly Kairo
    ///   may speak, so a seeded figure does not merely mislead the reader - it
    ///   licenses assertions the readings never supported.
    ///
    ///   Unseeded, a domain nothing has measured reports a fraction of zero and
    ///   `permittedForm` drops to its most restrictive rung. Silence about an
    ///   unmeasured day is the correct output.
    init(environment: AppEnvironment,
         backend: BackendConnection = BackendConnection(),
         seedingScenario: Bool = false) {
        self.env = environment
        self.backend = backend
        let dayStart = Calendar.current.startOfDay(for: environment.clock.now)
        self.hydration = HydrationLog(dayStart: dayStart)
        let todaysMeals = MealDiary.load(dayStart: dayStart)
        self.meals = todaysMeals

        // The report's Tuesday opens mid-afternoon with four interruptions
        // already behind it; a real day starts at zero and is spent as it goes.
        self.schedule = NudgeSchedule(dayStart: dayStart, dailyBudget: 6,
                                      spent: seedingScenario ? 4 : 0)

        var c = DayCoverage(dayStart: dayStart)
        if seedingScenario {
            c.record(CoverageMetric(domain: .meals, observedCount: 2, expectedCount: 3))
            c.record(CoverageMetric(domain: .sleep, observedCount: 1, expectedCount: 1))
            c.record(CoverageMetric(domain: .movement, observedCount: 20, expectedCount: 24))
            // The first sip that actually arrives from the wrist replaces this
            // with `hydration.coverageMetric()`, which will read lower and
            // honestly so - four of five sips was never observed.
            c.record(CoverageMetric(domain: .hydration, observedCount: 4, expectedCount: 5))
        }
        if !todaysMeals.isEmpty {
            c.record(CoverageMetric(domain: .meals, observedCount: todaysMeals.count,
                                    expectedCount: Self.expectedMeals))
        }
        self.coverage = c
    }

    /// Three meals is the day coverage is measured against.
    static let expectedMeals = 3

    @MainActor
    func bootstrap() async {
        // So the connection can retry on its own - on a settings edit, or when
        // the app comes back and the backend that was down is now up.
        backend.userIDForRecheck = { [userID] in userID }
        // Reconnects on its own if the backend starts late or blips mid-demo.
        backend.startAutoRetry()
        applyProfile(userProfile)
        await reloadMemories()
        if demoMode {
            seedDemoDay()
            await primeRecordedHealth()
        }
        refreshObservations()
        attachWrist()
        // Ask the backend who it is before arbitrating, so the first pass either
        // comes from the agents or is honestly labelled as not having.
        await backend.check(userID: userID)
        await reloadProfile()
        await reloadContract()
        await runArbitration()
        // The wrist may have been showing its own local guess since the last
        // launch. Tell it what the phone thinks before it has to ask.
        pushDayState()
        // And the day's digest, for the same reason: the watch deliberately
        // keeps no log across launches, so on a cold start it has nothing to
        // show until this arrives. Sent after `runArbitration()` so an
        // interruption this pass allocated is already in it.
        pushDayLog()
    }

    /// SCRUM-21. The server's copy wins when there is one - it is the record
    /// another device would read - and the local copy is what the app runs on
    /// until it answers.
    @MainActor
    func reloadProfile() async {
        guard let client = backend.client else { return }
        do {
            let remote = try await client.profile()
            userProfile = remote
            ProfileStore.save(remote)
            applyProfile(remote)
        } catch {
            // Not worth surfacing: the locally stored profile is already in
            // force, and a backend that cannot answer this is already being
            // reported by the provenance chip for a better reason.
            Self.log.error("profile reload failed: \(String(describing: error))")
        }
    }

    /// Write one change through. Local first, so the setting holds even if the
    /// request fails - the user moved a control and the app has to behave as
    /// though they did.
    @MainActor
    func updateProfile(_ change: (inout RemoteAgentClient.UserProfile) -> Void,
                       patch: [String: Any]) async {
        var updated = userProfile
        change(&updated)
        userProfile = updated
        ProfileStore.save(updated)
        applyProfile(updated)

        guard let client = backend.client else { return }
        do {
            let confirmed = try await client.updateProfile(patch)
            userProfile = confirmed
            ProfileStore.save(confirmed)
            applyProfile(confirmed)
        } catch {
            Self.log.error("profile update failed: \(String(describing: error))")
        }
    }

    /// AG-1. The ceiling the user set is the one the day is spent against.
    @MainActor
    private func applyProfile(_ p: RemoteAgentClient.UserProfile) {
        guard schedule.dailyBudget != p.dailyInterruptionCeiling else { return }
        schedule = NudgeSchedule(dayStart: schedule.dayStart,
                                 dailyBudget: p.dailyInterruptionCeiling,
                                 spent: schedule.spent)
    }

    /// NFR8 - "0 during quiet hours and Focus modes".
    ///
    /// This was hardcoded `false` on both arbitration paths, so the quiet-hours
    /// control on the attention contract screen set a value nothing read. The
    /// Focus half is still not here; a Focus mode is not readable from an app
    /// without an entitlement this project does not have, which is why the
    /// setting is a window the user states rather than one Kairo detects.
    var isQuietNow: Bool { userProfile.isQuiet(at: env.clock.now) }

    /// The app came back to the foreground.
    ///
    /// The ordinary way to see "backend unreachable" is to launch before
    /// starting the server; the ordinary fix is to start it. Without this the
    /// app had no reason to look again and held a stale verdict until somebody
    /// went and found the Connect button.
    @MainActor
    func returnedToForeground() async {
        await backend.recheckIfNotConnected()
        guard backend.state.isConnected else { return }
        await reloadProfile()
        await runArbitration()
    }

    /// Watch the link without starting the rest of the app.
    ///
    /// `attachWrist()` runs inside `bootstrap()`, and the tour deliberately runs
    /// *before* bootstrap - bootstrap reads HealthKit, and explaining the app
    /// before iOS asks for health data is the whole reason the tour exists. So
    /// the pairing page needs the link and nothing else: this wires that one
    /// observer and seeds the current value, and leaves events, arbitration and
    /// the day's state alone.
    ///
    /// Safe to call more than once; it only ever replaces the same handler.
    @MainActor
    func observeWristLink() {
        guard let wrist = env.wrist else {
            wristLink = .unsupported
            return
        }
        wrist.onLinkChange = { [weak self] link in self?.wristLink = link }
        wristLink = wrist.link
    }

    /// CF10. Read from wherever the agents retrieve, so the book and the facts
    /// the roles reason over cannot be two different lists.
    ///
    /// They were, until now: the screen rendered a locally seeded store while the
    /// backend reasoned over its own. A fact extracted on the server never showed
    /// up, and forgetting one here left it in every answer the roles gave.
    @MainActor
    func reloadMemories() async {
        if let client = backend.client {
            do {
                memories = try await client.memoryBook(at: env.clock.now)
                    .sorted { $0.confidence > $1.confidence }
                return
            } catch {
                backend.noteFailure(error)
            }
        }
        reloadLocalMemories()
    }

    /// The on-device store. In `.demo` this is the reference seed the report draws;
    /// in `.live` it is empty until the backend answers, and an empty book is the
    /// honest picture of a phone that has not talked to the agents yet.
    @MainActor
    func reloadLocalMemories() {
        memories = ((try? env.memoryStore.query("", k: 50, maxSensitivity: .health)) ?? [])
            .sorted { $0.confidence > $1.confidence }
    }

    /// CF10: the delete is real, and it happens where the retrieval happens.
    @MainActor
    /// FR10.6. `neverAgain` makes the deletion durable against the Curator,
    /// which would otherwise re-extract the same fact from the same material.
    func forget(_ memory: MemoryItem, neverAgain: Bool = false) async {
        if let client = backend.client {
            do {
                try await client.forget(memoryID: memory.id, neverAgain: neverAgain)
                await reloadMemories()
                await reloadSuppressed()
                return
            } catch {
                backend.noteFailure(error)
            }
        }
        try? env.memoryStore.delete(id: memory.id)
        reloadLocalMemories()
    }

    /// FR10.6. What the user has asked Kairo never to remember.
    private(set) var neverRemembered: [String] = []

    @MainActor
    func reloadSuppressed() async {
        guard let client = backend.client else { return }
        neverRemembered = (try? await client.neverRemembered()) ?? neverRemembered
    }

    @MainActor
    func allowAgain(_ text: String) async {
        guard let client = backend.client else { return }
        try? await client.allowAgain(text: text)
        await reloadSuppressed()
    }

    /// FR10.6's export. Returns nil rather than an empty file when there is no
    /// backend: handing somebody a file that silently is not their data would
    /// be worse than saying it could not be made.
    @MainActor
    func exportMemories() async -> Data? {
        guard let client = backend.client else { return nil }
        return try? await client.exportMemories()
    }

    // MARK: - CF1 / CF2 - the day's meals

    /// A meal the user confirmed. This is the step that was missing: the entry
    /// now changes meal coverage, travels to the agents as `kilojoulesLogged`
    /// on the next pass (which runs straight away), reaches the wrist's digest,
    /// and is handed to the curator as material for habit memory.
    ///
    /// Not `@MainActor`, like `record(_:)`: it is called synchronously from a
    /// button and touches nothing that needs the actor until the tasks it starts.
    func logMeal(_ entry: MealEntry) {
        guard entry.state == .logged,
              !meals.contains(where: { $0.id == entry.id }) else { return }
        let meal = LoggedMeal(entry: entry, at: env.clock.now)
        meals.append(meal)
        meals.sort { $0.at < $1.at }
        MealDiary.save(meals, dayStart: schedule.dayStart)
        recordMealCoverage()
        mealSuggestion = nil
        refreshObservations()
        pushDayLog()
        Task { await runArbitration() }
        Task { await remember(meal) }
    }

    private func recordMealCoverage() {
        coverage.record(CoverageMetric(domain: .meals, observedCount: meals.count,
                                       expectedCount: Self.expectedMeals))
    }

    /// FR10.1 - a logged meal is material for habit memory. The curator decides
    /// whether it says anything durable; most single meals do not, and the
    /// Memory Book shows that decision as well as any fact it keeps.
    @MainActor
    private func remember(_ meal: LoggedMeal) async {
        let time = meal.at.formatted(date: .omitted, time: .shortened)
        let material = "At \(time) today I ate \(meal.title), about "
            + "\(Int(meal.kilojoules)) kJ (an estimate \(Int(meal.confidence * 100))% confident)."
        _ = await teach(material)
    }

    /// CF2 - ask the Nutrition Analyst what to eat next, given the real ledger.
    @MainActor
    func suggestNextMeal() async {
        guard let client = backend.client else {
            lastError = "Connect to the backend first: suggestions come from the Nutrition role."
            return
        }
        suggestingMeal = true
        defer { suggestingMeal = false }
        do {
            mealSuggestion = try await client.recommendMeal(
                userID: userID, kilojoulesSoFar: kilojoulesLogged,
                targetKilojoules: kilojoulesTarget, coverage: coverage)
        } catch {
            backend.noteFailure(error)
        }
    }

    // MARK: - CF10 - telling Kairo something

    /// Sends `material` to the Habit Memory Curator and reloads the book. The
    /// phone never writes a fact itself; it hands over what was said and shows
    /// what the curator kept. Returns the curator's answer in words.
    @MainActor
    @discardableResult
    func teach(_ material: String) async -> String {
        let text = material.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "Nothing to send." }
        guard let client = backend.client else {
            let why = "Not connected to the agents. Facts are learned by the curator on "
                + "the backend, so nothing can be remembered offline."
            lastExtraction = why
            return why
        }
        teaching = true
        defer { teaching = false }
        do {
            let result = try await client.extractMemories(userID: userID, material: text,
                                                          coverage: coverage)
            lastExtraction = result.summary
            await reloadMemories()
            return result.summary
        } catch {
            backend.noteFailure(error)
            let why = "The curator could not be reached: \(error.localizedDescription)"
            lastExtraction = why
            return why
        }
    }

    // MARK: - Demo mode

    /// Switches the readings between HealthKit and `DemoScenario`, then runs a
    /// real pass so the agents react to the change straight away.
    @MainActor
    func setDemoMode(_ on: Bool) async {
        guard on != demoMode else { return }
        demoMode = on
        UserDefaults.standard.set(on, forKey: DemoScenario.defaultsKey)
        if on {
            seedDemoDay()
            await primeRecordedHealth()
        } else {
            setPhoneStream(false)
            live = LiveSignals()
            clearDemoDay()
        }
        mealSuggestion = nil
        refreshObservations()
        pushDayState()
        pushDayLog()
        await runArbitration()
    }

    // MARK: - Demo signals: the watch, the phone simulator, recorded Health

    /// Option 2 - the phone's own simulated wrist, one simulated minute every
    /// two seconds. It starts from wherever the readings already are, so
    /// switching it on mid-demo continues the day rather than restarting it.
    @MainActor
    func setPhoneStream(_ on: Bool) {
        streamTask?.cancel()
        streamTask = nil
        phoneStreamOn = on && demoMode
        guard phoneStreamOn else { return }
        simulatedWrist = SimulatedWrist(
            sittingMinutes: live.sittingMinutes ?? DemoHealthSource.sittingMinutes,
            heartRateBPM: live.heartRateBPM ?? 66,
            stepsToday: live.stepsToday ?? 3_400)
        streamTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.streamTickInterval)
                guard let self, !Task.isCancelled else { return }
                self.streamTick()
            }
        }
    }

    @MainActor
    private func streamTick() {
        // The watch is streaming: it is the better-placed source, so the phone
        // holds still rather than talking over it, and resumes when it stops.
        guard Date().timeIntervalSince(lastWatchSignal) > Self.watchPrecedence else { return }
        let now = env.clock.now
        let tick = simulatedWrist.advance(at: now)
        apply(tick.readings, from: .phone)
        if let ml = tick.sipMillilitres {
            // `record` runs its own pass: new water is new evidence.
            record(HydrationLog.Sip(id: "\(DemoScenario.prefix)stream-\(simulatedWrist.minute)",
                                    at: now, millilitres: ml))
            pushDayState()
        }
    }

    /// Option 1 - readings from the watch's Demo page, or from the phone's own
    /// stream. Every tick refreshes what the agents would be sent; only a
    /// significant change spends a pass, and never more often than
    /// `signalPassSpacing`.
    private func apply(_ readings: [SimulatedReading], from source: LiveSignals.Source) {
        let before = live
        for reading in readings { live.apply(reading, from: source) }
        refreshObservations()
        let significant = LiveSignals.isSignificant(from: before, to: live)
        // The wrist's own sitting page reads the phone's figure, so it is told
        // when that figure moves meaningfully, and every few minutes otherwise.
        if significant || simulatedWrist.minute % 5 == 0 { pushDayState() }
        guard significant,
              Date().timeIntervalSince(lastSignalPass) >= Self.signalPassSpacing else { return }
        lastSignalPass = Date()
        Task { await runArbitration() }
    }

    /// Option 3 - recorded Health first. Off makes the demo the fixed scenario
    /// plus the live wrist, which is the dependable choice on a phone whose own
    /// Health data should not be on a projector.
    @MainActor
    func setUseRecordedHealth(_ on: Bool) async {
        useRecordedHealth = on
        UserDefaults.standard.set(on, forKey: "kairo.demo.useRecordedHealth")
        await primeRecordedHealth()
        refreshObservations()
        await runArbitration()
    }

    /// Writes the seeder's synthetic week into this simulator's Health store,
    /// then reads it back through the real HealthKit adapter.
    @MainActor
    func seedSimulatorHealth() async {
        seedReport = "Writing a week of samples…"
        seedReport = await KairoHealthSeeding.seedNow()
        await primeRecordedHealth()
        refreshObservations()
        await runArbitration()
    }

    @MainActor
    func removeSeededHealth() async {
        seedReport = await KairoHealthSeeding.deleteNow()
        await primeRecordedHealth()
        refreshObservations()
        await runArbitration()
    }

    /// The HealthKit adapter answers its synchronous getters from caches that
    /// a window read fills, so the week is read once before anything asks for
    /// last night. Without this the blend would see "no sleep" and fall back to
    /// the scenario even with a seeded store.
    @MainActor
    private func primeRecordedHealth() async {
        guard demoMode, useRecordedHealth,
              let window = env.health as? SleepWindowSource else { return }
        let day = Calendar.current.startOfDay(for: env.clock.now)
        _ = await window.nightReadings(endingOn: day, nights: SleepSummary.defaultWindowNights)
    }

    /// The demo day's sips and meals, added beside anything real. Ids carry
    /// `DemoScenario.prefix`, so `record` de-duplicates a second seeding and
    /// `clearDemoDay` can find every one of them.
    @MainActor
    private func seedDemoDay() {
        let now = env.clock.now
        for sip in DemoScenario.sips(dayStart: schedule.dayStart, now: now) {
            hydration.record(sip)
        }
        coverage.record(hydration.coverageMetric())
        for meal in DemoScenario.meals(dayStart: schedule.dayStart, now: now)
        where !meals.contains(where: { $0.id == meal.id }) {
            meals.append(meal)
        }
        meals.sort { $0.at < $1.at }
        recordMealCoverage()
    }

    /// Removes exactly what `seedDemoDay` added. Real taps and real meals stay.
    @MainActor
    private func clearDemoDay() {
        var kept = HydrationLog(dayStart: hydration.dayStart,
                                targetMillilitres: hydration.targetMillilitres)
        for sip in hydration.sips where !sip.id.hasPrefix(DemoScenario.prefix) {
            kept.record(sip)
        }
        hydration = kept
        meals.removeAll { $0.demo }
        coverage.record(hydration.coverageMetric())
        recordMealCoverage()
        // The demo's wear hours must not outlive it. `refreshMovement` puts a
        // real figure back if HealthKit has one.
        coverage.record(MovementSummary.coverageMetric(observedHours: 0))
    }

    /// CF7 - one pass of the attention budget. Called on launch, on a new bid, and
    /// whenever the user changes their attention contract (OF3).
    /// CF7. The five roles bid when the backend is reachable; the on-device
    /// arbiter does when it is not.
    ///
    /// The fallback is not a degraded copy - it is the same allocation policy,
    /// which is what NFR9 requires and what the cross-language conformance test
    /// pins. What differs is where the *bids* come from: real reasoning over the
    /// current readings, or the seeded ones. That difference is reported rather
    /// than hidden.
    @MainActor
    func runArbitration() async {
        if let client = backend.client {
            do {
                try await arbitrateRemotely(client)
                return
            } catch {
                // Keep working, but say so. An app that silently drops from the
                // agents to a local heuristic and looks identical either way is
                // exactly the failure this project keeps arguing against.
                backend.noteFailure(error)
            }
        }
        arbitrateOnDevice()
    }

    @MainActor
    private func arbitrateRemotely(_ client: RemoteAgentClient) async throws {
        let result = try await client.arbitrate(
            userID: userID, now: env.clock.now, schedule: schedule, coverage: coverage,
            observations: observations, quietHours: isQuietNow, profile: profile,
            priorities: priorities)

        // Replay the backend's decision through the device's own state machine
        // rather than rendering the JSON directly. The views then need no second
        // code path, and `Lifecycle` rejects any combination the machine does not
        // allow - a backend that claimed a nudge was both suppressed and
        // delivered would be caught here instead of drawn.
        let now = env.clock.now
        let local = try replay(result, at: now)

        arbitration = local
        schedule = NudgeSchedule(dayStart: schedule.dayStart,
                                 dailyBudget: schedule.dailyBudget,
                                 spent: max(0, result.spent - (result.delivered.count - local.delivered.count)))
        arbitrationSource = .agents(recordID: result.recordID)
        contributingRoles = result.contributingRoles
        arbitrationCosting = result.costIsNotional || result.costing == "shadow"
            ? .notional : .metered
        servingProvider = result.provider
        servingModelID = result.biddingModelID
        records.append(local.record)
        backend.noteServed()

        for nudge in local.delivered {
            if let ch = env.channels.first(where: { $0.kind == nudge.channel }) {
                try? ch.deliver(nudge)
            }
        }
    }

    /// Turns the backend's answer back into domain values.
    private func replay(_ result: RemoteAgentClient.Arbitration,
                        at now: Date) throws -> ArbitrationResult {
        func nudge(_ remote: RemoteAgentClient.RemoteNudge,
                   delivered: Bool,
                   overriding reason: SuppressionReason? = nil) throws -> Nudge {
            var n = Nudge(bid: NudgeBid(
                id: remote.id, nudgeClass: remote.nudgeClass, originAgent: remote.originAgent,
                expectedBenefit: remote.score, urgency: remote.receptivity,
                windowOpens: now.addingTimeInterval(-60),
                windowCloses: now.addingTimeInterval(1800),
                text: remote.text))
            n.score = remote.score
            n.receptivity = remote.receptivity
            n.channel = remote.channel
            n.suppressionReason = reason ?? remote.suppressionReason
            try n.lifecycle.transition(on: "admitted", to: .queued, at: now)
            try n.lifecycle.transition(on: "scoredByReceptivity", to: .scored, at: now)
            if delivered {
                try n.lifecycle.transition(on: "allocated", to: .scheduled, at: now)
            } else {
                try n.lifecycle.transition(on: event(for: n.suppressionReason),
                                           to: .suppressed, at: now)
            }
            return n
        }

        // OF3 on the remote path. The roles are sent the weights and bid
        // against them, but the promise the contract screen makes - a class at
        // zero is never worth an interruption - has to hold even against a
        // backend that ignored them, so it is enforced on the way in. A bid
        // demoted here is shown in the ledger as suspended rather than dropped,
        // and the interruption it would have spent is handed back below.
        let demoted = result.delivered.filter { isSilenced($0.nudgeClass) }
        let allowed = result.delivered.filter { !isSilenced($0.nudgeClass) }

        let delivered = try allowed.map { try nudge($0, delivered: true) }
        let suppressed = try demoted.map { try nudge($0, delivered: false, overriding: .classSuspended) }
            + result.suppressed.map { try nudge($0, delivered: false) }

        var record = DecisionRecord(id: result.recordID, createdAt: now)
        // What each role said, not merely that it spoke. These three fields used
        // to be `("backend", "", 1)` - a blank claim at full confidence - so the
        // role timeline in `WhyView`, the screen whose entire purpose is to show
        // that five roles are not five relabelled prompts, rendered five empty
        // rows whenever the backend served the pass. The data was on the wire
        // the whole time.
        for role in result.contributions {
            try record.add(ContributionFragment(agentID: role.agentID,
                                                promptVersion: role.promptVersion,
                                                claim: role.claim,
                                                confidence: role.confidence))
        }
        for cited in result.citedMemories {
            try record.cite(MemoryCitation(memoryID: cited.id,
                                           confidenceAtCitation: cited.confidence))
        }
        for n in suppressed {
            try record.reject(RejectedAlternative(
                bidID: n.bid.id, nudgeClass: n.bid.nudgeClass, score: n.score,
                reason: n.suppressionReason ?? .outranked))
        }
        // The backend's own verdict, not an assumed pass. `nothingToScreen` and
        // `unscreened` are members of the same six-value enum and neither is a
        // pass: one means no message existed to judge, the other that no Steward
        // was bound. Writing "pass" over either would be the app inventing a
        // safety result nobody produced.
        try record.setSafetyVerdict(result.safetyVerdict ?? "unscreened",
                                    tier: result.serviceTier)
        try record.lifecycle.transition(on: "allFragmentsCollected", to: .sealed, at: now)

        return ArbitrationResult(delivered: delivered, suppressed: suppressed,
                                 schedule: schedule, record: record)
    }

    /// OF3 - a class the user has turned off entirely.
    func isSilenced(_ nudgeClass: String) -> Bool { (priorities[nudgeClass] ?? 1) <= 0 }

    /// The bids the local source raised, scaled by what the user said each class
    /// is worth. A class at zero raises nothing at all rather than raising a bid
    /// scored to zero, because a bid scored to zero still occupies a row in the
    /// ledger as though it had competed.
    private func weighted(_ bids: [NudgeBid]) -> [NudgeBid] {
        bids.compactMap { bid in
            let weight = priorities[bid.nudgeClass] ?? 1
            guard weight > 0 else { return nil }
            guard weight != 1 else { return bid }
            return NudgeBid(id: bid.id, nudgeClass: bid.nudgeClass,
                            originAgent: bid.originAgent,
                            expectedBenefit: bid.expectedBenefit * weight,
                            urgency: bid.urgency,
                            windowOpens: bid.windowOpens, windowCloses: bid.windowCloses,
                            requiredCapabilities: bid.requiredCapabilities,
                            text: bid.text)
        }
    }

    /// OF3 - committed from the contract screen, which then re-runs the pass.
    @MainActor
    func setPriority(_ value: Double, for nudgeClass: String) {
        guard priorities[nudgeClass] != value else { return }
        priorities[nudgeClass] = value
    }

    private func event(for reason: SuppressionReason?) -> String {
        switch reason {
        case .budgetExhausted:  "budgetExhausted"
        case .quietHours:       "quietHours"
        case .costCeiling:      "costCeilingReached"
        case .classSuspended:   "classSuspendedByContract"
        case .windowNotOpen:    "windowNotOpen"
        case .duplicateClass:   "duplicateInClass"
        // The Steward refused the wording. There was no contest, so the machine
        // must not be told there was one.
        case .safetyRefused:    "evidenceInsufficient"
        case .ungrounded:       "evidenceInsufficient"
        default:                "outrankedByAnotherBid"
        }
    }

    @MainActor
    private func arbitrateOnDevice() {
        let now = env.clock.now
        let input = ArbitrationInput(
            now: now, schedule: schedule,
            bids: weighted(LocalBidSource.bids(at: now, observations: observations)),
            memories: memories, profile: profile,
            activeContract: contract, quietHours: isQuietNow)
        do {
            let result = try env.arbiter.arbitrate(input, recordID: "dr-\(records.count + 41)")
            arbitration = result
            schedule = result.schedule
            records.append(result.record)
            arbitrationSource = .onDevice
            contributingRoles = []
            // No service answered, so there is no service cost. The ladder the
            // arbiter walks on this phone is a stand-in in every deployment.
            arbitrationCosting = .notional
            servingProvider = nil
            servingModelID = nil
            for n in result.delivered {
                if let ch = env.channels.first(where: { $0.kind == n.channel }) {
                    try? ch.deliver(n)
                }
            }
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: - CF9

    /// The contract the agents are already holding for this user.
    ///
    /// This replaces `proposeContract(kind:sources:userConfirmed:)`, which was
    /// dead code: nothing in `ios/` ever called it, and it could not honestly be
    /// called from here. It built its own `DisruptionSignal`s out of strings
    /// handed to it by the caller, and the phone has no thermometer, no calendar
    /// and no time-zone watcher to derive one from - so every entry point that
    /// could have existed would have had to invent the corroborating evidence
    /// that CF9's two-signal rule exists to demand.
    ///
    /// What the phone can honestly do is ask. The roles evaluate disruption from
    /// the evidence they have; this reads the result, and `respond` records the
    /// user's answer where the agents can see it, so an accepted contract is not
    /// re-proposed on the next pass.
    @MainActor
    func reloadContract() async {
        guard let client = backend.client else { return }
        do {
            contract = try Self.replay(try await client.contract(userID: userID),
                                       at: env.clock.now)
        } catch {
            backend.noteFailure(error)
        }
    }

    /// Turns the backend's contract into a domain value by replaying it through
    /// the same state machine, so a state this app's machine does not declare is
    /// dropped rather than drawn.
    private static func replay(_ remote: RemoteAgentClient.RemoteContract?,
                               at now: Date) throws -> PlanContract? {
        guard let remote,
              let state = PlanContractState(rawValue: remote.state),
              let lifecycle = Lifecycle<PlanContractState>.replaying(to: state, at: now)
        else { return nil }
        var c = PlanContract(id: remote.id)
        c.lifecycle = lifecycle
        c.kind = remote.kind.flatMap(DisruptionKind.init(rawValue:))
        c.targetReduction = remote.targetReduction
        c.suspended = Set(remote.suspendedClasses.map(SuspendedNudgeClass.init))
        c.expiresAt = remote.expiresAt
        c.stewardVetoReason = remote.stewardVetoReason
        return c
    }

    /// Consent, recorded where the agents can see it.
    ///
    /// The old `acceptContract()` / `declineContract()` moved only the copy on
    /// the phone, so the backend went on proposing the same contract on every
    /// subsequent pass and a user who had already said no was asked again.
    @MainActor
    func respondToContract(accept: Bool) async {
        guard var c = contract else { return }
        let now = env.clock.now
        // Optimistic, but only where the machine allows it. These used to be
        // `try?` with the result dropped, so a refused transition left the
        // contract untouched and the next line showed it as accepted anyway -
        // and with no backend to correct it, the screen kept that answer.
        do {
            if accept {
                _ = try c.lifecycle.transition(on: "userAccepted", to: .active, at: now)
                contract = c
            } else {
                _ = try c.lifecycle.transition(on: "userDeclined", to: .declined, at: now)
                _ = try c.lifecycle.transition(on: "returnToStandard", to: .standard, at: now)
                contract = nil
            }
        } catch {
            // The machine does not allow this answer from the state it is in.
            // Leave what is on screen alone and let the backend be the one to
            // say what the contract became. Logged rather than asserted: this is
            // reachable when the contract moved on under the screen, and a
            // crashing demo is a worse answer than a stale row.
            Self.log.error("contract refused \(accept ? "accept" : "decline"): \(error)")
        }
        if let client = backend.client {
            do {
                contract = try Self.replay(
                    try await client.respondToContract(userID: userID, accept: accept), at: now)
            } catch {
                backend.noteFailure(error)
            }
        }
        // A suspended class changes what may be delivered, so the ledger on
        // Today has to be re-run rather than left showing the old contest.
        await runArbitration()
    }

    /// CF6 + CF11 - anything the Coach wants to say passes the gate first.
    func screened(_ text: String, domain: CoverageDomain?, locale: String = "en-AU") -> ScreeningVerdict {
        env.safety.screen(text, locale: locale, claimDomain: domain, coverage: coverage)
    }

    // MARK: - The wrist

    /// Attaches this model to the phone half of the watch link.
    ///
    /// A no-op in preview, where `env.wrist` is nil - which is what keeps the
    /// recorded demo offline and identical on every run. Every handler below is
    /// invoked on the main queue by the bridge, which is the contract that lets
    /// them mutate observable state from what began as a delegate callback.
    private func attachWrist() {
        guard let wrist = env.wrist else { return }
        wrist.onWristEvent = { [weak self] event in self?.handle(event) }
        wrist.onReachabilityChange = { [weak self] reachable in self?.wristLinked = reachable }
        wrist.onLinkChange = { [weak self] link in self?.wristLink = link }
        // Seeded rather than waited for: a watch already paired and reachable
        // fires no callback on launch, so a screen that only listened would
        // show "looking for your watch" at one that was right there.
        wristLink = wrist.link
        // Worth showing rather than swallowing: this fires when a phone and a
        // watch are on builds that disagree about the envelope version, and the
        // symptom without it is silence that looks exactly like the old bug.
        wrist.onDecodeFailure = { [weak self] why in self?.lastError = why }
    }

    /// CF7 / CF8 - one message from the wrist.
    ///
    /// Internal rather than private so a preview or a test can drive it directly
    /// without a paired watch.
    /// One door for every sip, whatever logged it (FR8.1, FR8.2).
    ///
    /// `record` returns false for a sip already in the log. WatchConnectivity
    /// re-delivers the current application context on every activation, so the
    /// same tap genuinely does arrive more than once - and a total that
    /// double-counts is worse than one that arrives late. A photographed drink
    /// the user accepted twice is the same hazard with a different cause, which
    /// is why both come through here.
    @discardableResult
    func record(_ sip: HydrationLog.Sip) -> Bool {
        let isNew = hydration.record(sip)
        guard isNew else { return false }
        // Coverage stops being a seeded figure the moment there is a real one,
        // because everything downstream of the gate is entitled to know how
        // much of the day was actually observed.
        coverage.record(hydration.coverageMetric())
        refreshObservations()
        // New evidence is precisely when a finite budget should be reconsidered:
        // the hydration bid is now either cheaper to justify or gone entirely.
        Task { await runArbitration() }
        return true
    }

    func handle(_ event: WristEvent) {
        switch event {
        case let .waterLogged(millilitres, at, id):
            // `record` returns false for a sip already in the log. WatchConnectivity
            // re-delivers the current application context on every activation, so
            // the same tap genuinely does arrive more than once - and a total that
            // double-counts is worse than one that arrives late.
            record(HydrationLog.Sip(id: id, at: at, millilitres: millilitres))

            // Pushed either way. A duplicate usually means the watch was not sure
            // the phone heard it, which is exactly when the wrist most needs the
            // authoritative total.
            pushDayState()
            // The digest has to move with the total, or the log page would show
            // a glass the water page has already counted.
            pushDayLog()

        case let .nudgeOutcome(bidID, outcome, at):
            recordOutcome(bidID: bidID, outcome: outcome, at: at)

        case let .simulatedReadings(readings):
            // Only ever accepted into a demo day. A watch left streaming after
            // the demo must not write a fictional reading into a real one.
            guard demoMode else {
                lastError = "The watch is streaming demo readings, but Demo day is off "
                    + "on this phone, so they were ignored."
                return
            }
            lastWatchSignal = Date()
            apply(readings, from: .watch)
        }
    }

    /// CF7 - what the user did with an interruption on the wrist.
    ///
    /// Two things happen, and they are different kinds of durable.
    ///
    /// The outcome is appended to the current decision record, which is
    /// append-only after sealing and is shown to the user in WhyView - so a
    /// dismissal is visible in the receipt for the pass that spent the
    /// interruption. That part does not survive a relaunch; `records` is
    /// in-memory until the backend seals them.
    ///
    /// It is also appended to the outcome log, which does survive, and which
    /// `ObservedReceptivityModel` reads. Until recently this was the honest gap
    /// in the app: `ReceptivityModel` documents itself as "learned from the
    /// outcome history of past nudges" and the only implementation was a fixed
    /// table, so a class the user dismissed every single time kept its 0.90 and
    /// kept winning. The class is recovered from the bid that produced it, since
    /// the wrist reports the bid id and receptivity is learned per class.
    private func recordOutcome(bidID: String, outcome: String, at: Date) {
        if let response = NudgeOutcome.Response(rawValue: outcome),
           let nudgeClass = nudgeClass(forBid: bidID) {
            let record = NudgeOutcome(nudgeClass: nudgeClass, response: response, at: at)
            env.outcomes.append(record)
            // And to the agents, who do the bidding. Best effort: an outcome that
            // cannot be reported is still learned from on this phone, and the
            // failure is surfaced the same way every other backend failure is
            // rather than retried behind the user's back.
            if let client = backend.client {
                Task { [userID] in
                    do { try await client.report(outcome: record, userID: userID) }
                    catch { await MainActor.run { backend.noteFailure(error) } }
                }
            }
        }
        guard let i = records.indices.last else {
            lastError = "the wrist reported \(outcome) for \(bidID) before any pass had run"
            return
        }
        records[i].annotate(Annotation(
            at: at, author: "watch", text: "\(bidID): \(outcome) on the wrist"))
    }

    /// The class of a bid this pass raised. Nil when the wrist reports on
    /// something this launch never saw - after a relaunch, say - in which case
    /// the outcome is recorded in the receipt but not learned from, because
    /// guessing the class would teach the model about the wrong one.
    private func nudgeClass(forBid bidID: String) -> String? {
        let all = (arbitration?.delivered ?? []) + (arbitration?.suppressed ?? [])
        return all.first { $0.bid.id == bidID }?.bid.nudgeClass
    }

    /// The phone counts, so the phone tells the watch the total. The watch showing
    /// its own local tally is how the two ended up disagreeing.
    private func pushDayState() {
        env.wrist?.send(.dayState(DayState(
            waterMillilitres: hydration.totalMillilitres,
            waterTargetMillilitres: hydration.targetMillilitres,
            sedentaryMinutes: observations.sedentaryMinutes,
            interruptionsSpent: schedule.spent,
            dailyBudget: schedule.dailyBudget)))
    }

    /// The day, consolidated for a 40mm screen.
    ///
    /// Composed here rather than on the wrist on purpose. The phone is the only
    /// side that knows where a figure came from and what the evidence gate
    /// permits to be said about it, so the headline and the already-formatted
    /// number are written on this side; the watch renders what it is given and
    /// never phrases a claim the phone would have refused.
    ///
    /// Internal rather than private so a preview or a test can read the digest
    /// without a paired watch.
    func dayLog() -> DayLog {
        var entries: [DayLog.Entry] = []

        // CF8 - one entry per tap, which is what `hydration` actually holds.
        // Trimmed here as well as in `DayLog`'s initialiser: the cap keeps the
        // screen readable, and trimming before encoding keeps the envelope small
        // on a transport that has to carry it while the watch is asleep.
        for sip in hydration.sips.suffix(DayLog.entryLimit) {
            entries.append(DayLog.Entry(
                id: "sip-\(sip.id)",
                kind: .water,
                at: sip.at,
                headline: "Water",
                detail: "\(sip.millilitres) ml"))
            // `confidence` is left nil deliberately. The user pressed a button
            // labelled 350 ml, so there is no weakness to disclose, and putting
            // a number here would have the wrist mark an exact figure as rough.
        }

        // CF7 - what the attention budget was actually spent on.
        //
        // This is the most recent pass only, because that is all the phone has:
        // `arbitration` is overwritten each pass and nothing stores delivered
        // nudges across them. Synthesising a day's worth of interruptions from
        // `records` would be inventing history, which is the one thing this
        // digest must not do.
        for nudge in arbitration?.delivered ?? [] {
            entries.append(DayLog.Entry(
                id: "nudge-\(nudge.bid.id)",
                kind: .interruption,
                // When the arbiter allocated it. `Nudge` carries no delivery
                // timestamp, so the lifecycle history is the only real one there
                // is - and a real one is worth more than `Date()`.
                at: nudge.lifecycle.history.last { $0.to == .scheduled }?.at
                    ?? nudge.bid.windowOpens,
                // The class, in the same words the phone uses for it. Reusing
                // `Kairo.title` keeps one vocabulary: the watch has the same
                // table, so the wrist says "Sitting" exactly where the phone does.
                headline: "\(Kairo.title(forNudgeClass: nudge.bid.nudgeClass)) nudge"))
            // No `detail`, so no `confidence`. `confidence` is what a *figure* is
            // worth; `nudge.score` is a receptivity score, not the precision of a
            // measurement, and passing it would have the wrist dim an
            // interruption as though it were a weak reading.
        }

        // CF1 - the meals actually confirmed today. `confidence` travels here,
        // unlike for water: a meal's kilojoules are an estimate, and the wrist
        // should show a weak one as weak.
        for meal in meals.suffix(DayLog.entryLimit) {
            entries.append(DayLog.Entry(
                id: "meal-\(meal.id)",
                kind: .meal,
                at: meal.at,
                headline: meal.title,
                detail: "\(Int(meal.kilojoules.rounded())) kJ",
                confidence: meal.confidence))
        }

        return DayLog(
            generatedAt: env.clock.now,
            entries: entries,
            waterMillilitres: hydration.totalMillilitres,
            waterTargetMillilitres: hydration.targetMillilitres,
            // The day's meal ledger, or "not measured" when nothing is logged -
            // never a zero standing in for a day nobody recorded.
            kilojoulesLogged: meals.isEmpty ? nil : kilojoulesLogged,
            kilojoulesTarget: meals.isEmpty ? nil : kilojoulesTarget,
            // A real reading or nothing. This is `HealthDataSource.sleepHours`
            // by way of `refreshObservations()` - the same port, and the same
            // nil-means-unmeasured contract, as the sitting figure already on the
            // wire. There is no fallback constant behind it.
            sleepHoursLastNight: observations.sleepHoursLastNight,
            interruptionsSpent: schedule.spent,
            dailyBudget: schedule.dailyBudget)
    }

    /// The wrist's read-only digest. Pushed alongside `pushDayState()` and never
    /// on its own schedule: two messages per water event is already the most this
    /// transport should be asked to carry.
    private func pushDayLog() {
        env.wrist?.send(.log(dayLog()))
    }

    /// Fills in what the agents are allowed to see.
    ///
    /// An empty log reports `hydrationML` as nil, not 0: `Observations.lines` is
    /// explicit that its job is to let a model tell "zero" from "not measured",
    /// and a morning nobody has logged yet is not a morning without water.
    private func refreshObservations() {
        let now = env.clock.now
        refreshMovement()
        let sleepHours = (try? health.sleepHours(on: now)) ?? nil
        // One night, either read or not. `nil` here means HealthKit returned
        // nothing - which is also the only signal a denied read ever produces -
        // so it is recorded as zero coverage rather than as a night of no sleep.
        coverage.record(CoverageMetric(domain: .sleep,
                                       observedCount: sleepHours == nil ? 0 : 1,
                                       expectedCount: 1))
        observations = Observations(
            // Prefer the movement read's own figure: it is derived from step
            // buckets against a wear denominator, where the port's getter has
            // only the instant. Falls back to the port so a fake still answers.
            sedentaryMinutes: movement?.unbrokenSedentaryMinutes
                ?? (try? health.sedentaryMinutes(at: now)),
            hydrationML: hydration.sips.isEmpty ? nil : hydration.totalMillilitres,
            hydrationTargetML: hydration.targetMillilitres,
            sleepHoursLastNight: sleepHours,
            // nil, not 0, before anything is logged - the same absent-versus-
            // zero rule as water. This was never filled in, so the Nutrition role
            // was told "energy logged: not measured" right after lunch was logged.
            kilojoulesLogged: meals.isEmpty ? nil : kilojoulesLogged,
            kilojoulesTarget: meals.isEmpty ? nil : kilojoulesTarget,
            // Only the demo's simulated wrist produces these. Never sent from a
            // real day, so a real user's prompt is unchanged by them.
            heartRateBPM: demoMode ? live.heartRateBPM : nil,
            stepsToday: demoMode ? live.stepsToday : nil)
        sleepIsRecorded = demoMode && demoHealth.sleepIsRecorded(on: now)
    }

    /// The richer movement read lives on the concrete adapter rather than on the
    /// `HealthDataSource` port, because widening that port would break every
    /// in-memory fake the domain is tested against. So it is asked for by
    /// conformance, and simply absent when the bound source cannot answer.
    private func refreshMovement() {
        guard let source = health as? MovementDaySource else {
            movement = nil
            return
        }
        let now = env.clock.now
        let day = Calendar.current.startOfDay(for: now)
        movement = try? source.movementDay(on: day, at: now)

        // Movement coverage stops being a constant the moment a real wear
        // figure exists. Left alone when nothing was read, so a failed query
        // does not quietly downgrade the day to zero coverage.
        if let observed = movement?.hoursWorn {
            coverage.record(MovementSummary.coverageMetric(observedHours: observed))
        }
    }
}
