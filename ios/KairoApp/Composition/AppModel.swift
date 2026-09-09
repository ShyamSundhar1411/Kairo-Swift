import Foundation
import Observation
import KairoKit

/// The single observable the SwiftUI tree reads. Feature views own their own
/// sub-state; anything crossing a member boundary lives here.
@Observable
final class AppModel {
    let env: AppEnvironment

    private(set) var arbitration: ArbitrationResult?
    private(set) var coverage: DayCoverage
    /// Today's movement, as actually read. nil until something has looked, which
    /// is deliberately distinct from a day with nothing in it.
    private(set) var movement: MovementDay?
    private(set) var contract: PlanContract?
    private(set) var memories: [MemoryItem] = []
    private(set) var records: [DecisionRecord] = []
    private(set) var lastError: String?

    /// CF8 — the day's water as a log of taps rather than a running integer, so a
    /// message WatchConnectivity re-delivers can be discarded by id instead of
    /// being counted twice.
    private(set) var hydration: HydrationLog

    /// What is actually happening right now, as the agents see it. Nothing filled
    /// this in before: the roles have bid on `hydrationML` since day one and were
    /// handed nil every time.
    private(set) var observations: Observations = .none

    /// Whether the wrist can be reached right now. Only meaningful when
    /// `wristAvailable` — in preview there is no session to be reachable.
    private(set) var wristLinked = false

    /// True when this configuration has a phone/watch session at all. False in
    /// preview, and false on a phone with no watch paired, which are different
    /// situations from "linked but out of range".
    var wristAvailable: Bool { env.wrist != nil }

    var schedule = NudgeSchedule(dayStart: DateHelp.at(2026, 8, 25), dailyBudget: 6, spent: 4)
    var profile: CapabilityProfile = .unrestricted

    init(environment: AppEnvironment) {
        self.env = environment
        let dayStart = Calendar.current.startOfDay(for: environment.clock.now)
        self.hydration = HydrationLog(dayStart: dayStart)

        var c = DayCoverage(dayStart: dayStart)
        c.record(CoverageMetric(domain: .meals, observedCount: 2, expectedCount: 3))
        c.record(CoverageMetric(domain: .sleep, observedCount: 1, expectedCount: 1))
        c.record(CoverageMetric(domain: .movement, observedCount: 20, expectedCount: 24))
        // The Stage 1 scenario the report documents, and the figure the app opens
        // on. It is a seed, not a measurement: the first sip that actually arrives
        // from the wrist replaces it with `hydration.coverageMetric()`, which will
        // read lower and honestly so — four of five sips was never observed.
        c.record(CoverageMetric(domain: .hydration, observedCount: 4, expectedCount: 5))
        self.coverage = c
    }

    func bootstrap() async {
        reloadMemories()
        refreshObservations()
        attachWrist()
        runArbitration()
        // The wrist may have been showing its own local guess since the last
        // launch. Tell it what the phone thinks before it has to ask.
        pushDayState()
        // And the day's digest, for the same reason: the watch deliberately
        // keeps no log across launches, so on a cold start it has nothing to
        // show until this arrives. Sent after `runArbitration()` so an
        // interruption this pass allocated is already in it.
        pushDayLog()
    }

    func reloadMemories() {
        memories = ((try? env.memoryStore.query("", k: 50, maxSensitivity: .health)) ?? [])
            .sorted { $0.confidence > $1.confidence }
    }

    /// CF7 — one pass of the attention budget. Called on launch, on a new bid, and
    /// whenever the user changes their attention contract (OF3).
    func runArbitration() {
        let now = env.clock.now
        let input = ArbitrationInput(
            now: now, schedule: schedule,
            bids: SeedData.bids(at: now, observations: observations),
            memories: memories, profile: profile,
            activeContract: contract, quietHours: false)
        do {
            let result = try env.arbiter.arbitrate(input, recordID: "dr-\(records.count + 41)")
            arbitration = result
            schedule = result.schedule
            records.append(result.record)
            for n in result.delivered {
                if let ch = env.channels.first(where: { $0.kind == n.channel }) {
                    try? ch.deliver(n)
                }
            }
        } catch {
            lastError = String(describing: error)
        }
    }

    /// CF9 — the Lifestyle Analyst raises signals; the contract is only ever
    /// *proposed*, never applied silently.
    func proposeContract(kind: DisruptionKind, sources: [String], userConfirmed: Bool) {
        let now = env.clock.now
        var c = PlanContract(id: "pc-\(Int(now.timeIntervalSince1970))")
        c.kind = kind
        for s in sources {
            c.observe(DisruptionSignal(kind: kind, source: s, observedAt: now, strength: 0.7))
        }
        do {
            try c.lifecycle.transition(on: "signalDetected", to: .disruptionSuspected, at: now)
            guard c.isCorroborated(userConfirmed: userConfirmed) else {
                try c.lifecycle.transition(on: "insufficientEvidence", to: .standard, at: now)
                contract = nil
                return
            }
            try c.lifecycle.transition(on: "corroborated", to: .proposed, at: now)
            c.targetReduction = 0.3
            c.suspended = [SuspendedNudgeClass("sedentary")]
            c.expiresAt = now.addingTimeInterval(3 * 86_400)
            contract = c
        } catch {
            lastError = String(describing: error)
        }
    }

    func acceptContract() {
        guard var c = contract else { return }
        try? c.lifecycle.transition(on: "userAccepted", to: .active, at: env.clock.now)
        contract = c
        runArbitration()
    }

    func declineContract() {
        guard var c = contract else { return }
        try? c.lifecycle.transition(on: "userDeclined", to: .declined, at: env.clock.now)
        try? c.lifecycle.transition(on: "returnToStandard", to: .standard, at: env.clock.now)
        contract = nil
    }

    /// CF6 + CF11 — anything the Coach wants to say passes the gate first.
    func screened(_ text: String, domain: CoverageDomain?, locale: String = "en-AU") -> ScreeningVerdict {
        env.safety.screen(text, locale: locale, claimDomain: domain, coverage: coverage)
    }

    // MARK: - The wrist

    /// Attaches this model to the phone half of the watch link.
    ///
    /// A no-op in preview, where `env.wrist` is nil — which is what keeps the
    /// recorded demo offline and identical on every run. Every handler below is
    /// invoked on the main queue by the bridge, which is the contract that lets
    /// them mutate observable state from what began as a delegate callback.
    private func attachWrist() {
        guard let wrist = env.wrist else { return }
        wrist.onWristEvent = { [weak self] event in self?.handle(event) }
        wrist.onReachabilityChange = { [weak self] reachable in self?.wristLinked = reachable }
        // Worth showing rather than swallowing: this fires when a phone and a
        // watch are on builds that disagree about the envelope version, and the
        // symptom without it is silence that looks exactly like the old bug.
        wrist.onDecodeFailure = { [weak self] why in self?.lastError = why }
    }

    /// CF7 / CF8 — one message from the wrist.
    ///
    /// Internal rather than private so a preview or a test can drive it directly
    /// without a paired watch.
    func handle(_ event: WristEvent) {
        switch event {
        case let .waterLogged(millilitres, at, id):
            // `record` returns false for a sip already in the log. WatchConnectivity
            // re-delivers the current application context on every activation, so
            // the same tap genuinely does arrive more than once — and a total that
            // double-counts is worse than one that arrives late.
            let isNew = hydration.record(
                HydrationLog.Sip(id: id, at: at, millilitres: millilitres))

            if isNew {
                // Coverage stops being a seeded figure the moment there is a real
                // one, because everything downstream of the gate is entitled to
                // know how much of the day was actually observed.
                coverage.record(hydration.coverageMetric())
                refreshObservations()
                // New evidence is precisely when a finite budget should be
                // reconsidered: the hydration bid is now either cheaper to justify
                // or gone entirely.
                runArbitration()
            }

            // Pushed either way. A duplicate usually means the watch was not sure
            // the phone heard it, which is exactly when the wrist most needs the
            // authoritative total.
            pushDayState()
            // The digest has to move with the total, or the log page would show
            // a glass the water page has already counted.
            pushDayLog()

        case let .nudgeOutcome(bidID, outcome, at):
            recordOutcome(bidID: bidID, outcome: outcome, at: at)
        }
    }

    /// CF7 — what the user did with an interruption on the wrist.
    ///
    /// Deliberately minimal, and here is what is **not** wired: there is no
    /// outcome store. `ReceptivityModel` is a read-only port and its only
    /// implementation is a fixed table, so nothing in this app learns from an
    /// outcome yet, and inventing a path that looked like learning would be worse
    /// than admitting it. Nor does this survive a relaunch — `records` is
    /// in-memory.
    ///
    /// What it does do is real: the outcome is appended to the current decision
    /// record, which is append-only after sealing and is already shown to the user
    /// in WhyView. So a dismissal on the wrist is at least visible in the receipt
    /// for the pass that spent the interruption.
    private func recordOutcome(bidID: String, outcome: String, at: Date) {
        guard let i = records.indices.last else {
            lastError = "the wrist reported \(outcome) for \(bidID) before any pass had run"
            return
        }
        records[i].annotate(Annotation(
            at: at, author: "watch", text: "\(bidID): \(outcome) on the wrist"))
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

        // CF8 — one entry per tap, which is what `hydration` actually holds.
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

        // CF7 — what the attention budget was actually spent on.
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
                // is — and a real one is worth more than `Date()`.
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

        return DayLog(
            generatedAt: env.clock.now,
            entries: entries,
            waterMillilitres: hydration.totalMillilitres,
            waterTargetMillilitres: hydration.targetMillilitres,
            // HOOK — the day's meal ledger. Both of these are nil, and nil on
            // purpose: nothing in `AppModel` holds an `EnergyLedger`.
            // `MealLogModel` owns a single in-flight `MealEntry` and is built per
            // capture screen, so the phone genuinely does not know what was eaten
            // today. When a day's ledger lives on this model, this is where
            // `EnergySummary.observations(for:)` supplies these two figures and
            // where the `.meal` entries above come from. Until then the wrist is
            // told "not measured", because a plausible number invented to fill
            // the gap is exactly the failure this project refuses.
            kilojoulesLogged: nil,
            kilojoulesTarget: nil,
            // A real reading or nothing. This is `HealthDataSource.sleepHours`
            // by way of `refreshObservations()` — the same port, and the same
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
        observations = Observations(
            // Prefer the movement read's own figure: it is derived from step
            // buckets against a wear denominator, where the port's getter has
            // only the instant. Falls back to the port so a fake still answers.
            sedentaryMinutes: movement?.unbrokenSedentaryMinutes
                ?? (try? env.health.sedentaryMinutes(at: now)),
            hydrationML: hydration.sips.isEmpty ? nil : hydration.totalMillilitres,
            hydrationTargetML: hydration.targetMillilitres,
            sleepHoursLastNight: (try? env.health.sleepHours(on: now)) ?? nil)
    }

    /// The richer movement read lives on the concrete adapter rather than on the
    /// `HealthDataSource` port, because widening that port would break every
    /// in-memory fake the domain is tested against. So it is asked for by
    /// conformance, and simply absent when the bound source cannot answer.
    private func refreshMovement() {
        guard let source = env.health as? MovementDaySource else {
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
