import SwiftUI
import KairoKit

/// Member B — CF4 + CF6. The number and, inseparably, what it is worth.
///
/// The hero never prints the hours without the evidence badge beside them, because
/// the badge *is* what the number is worth: the same `AssertionForm` the Steward
/// enforces on any sentence about sleep. When the watch was off the wrist there is
/// nothing to draw, so the screen says so rather than drawing an empty ring.
struct SleepView: View {
    @Environment(AppModel.self) private var model
    /// Absent and not-yet-read are different facts, and this screen is the one
    /// that must not confuse them: rendering an unread port as nil told the user
    /// "the watch was off your wrist" on the first frame, before anything had
    /// been looked at. The whole app's claim is that it says what it does not
    /// know, so a reading has three states, not two.
    private enum Reading {
        case reading
        case read(Double?)
    }

    @State private var night: Reading = .reading
    /// Both of these are three-state too, for the same reason `night` is: `nil`
    /// means the port has not answered yet, `.some(nil)` means it answered and
    /// there was nothing there. The old code collapsed that with `?? 0` and drew
    /// an unmeasured day as a confident zero.
    @State private var wearHours: Double??
    @State private var sedentaryMinutes: Int??
    /// The week the debt is computed over. `nil` while it is being read.
    ///
    /// Held locally because `AppModel` is somebody else's file this week; see
    /// `load()` for where this belongs once the integration lands.
    @State private var debt: SleepDebt?

    /// A flat reference night, stated as a reference wherever it is drawn. It is
    /// not a goal Kairo invented for this user.
    private let referenceHours: Double = 8

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Kairo.Space.stack) {
                    KairoHeader(eyebrow: "last night", title: "Sleep")
                        .padding(.horizontal, 4)

                    hero
                    tiles
                    debtSection
                    coverageSection

                    TrustNote(text: "Kairo will not draw a trend line through days it "
                              + "could not see. Every other tracker interpolates; this one says so.")
                }
                .padding(.horizontal, Kairo.Space.stack)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
            .background(KairoCanvas())
            .toolbar(.hidden, for: .navigationBar)
        }
        .task { await load() }
    }

    // MARK: - Hero

    /// The day's coverage, with the sleep domain filled in from what was actually
    /// read rather than from a constant.
    ///
    /// `AppModel` records `CoverageMetric(domain: .sleep, observedCount: 1,
    /// expectedCount: 1)` unconditionally — a permanent claim that last night was
    /// seen, made before anything had been looked at. `DayCoverage` is a value
    /// type with a public `record`, so this screen can overlay the truth on its
    /// own copy without touching the model: last night is either observed
    /// (one of one) or it is not (nought of one), and there is no third case for a
    /// single night.
    ///
    /// INTEGRATION: this overlay is a stand-in. Once `AppModel` records the
    /// day-level sleep metric itself, delete `dayCoverage` and read
    /// `model.coverage` directly — every use below is already written against a
    /// `DayCoverage`, so the diff is the four call sites and nothing else.
    private var dayCoverage: DayCoverage {
        guard case let .read(hours) = night else { return model.coverage }
        var c = model.coverage
        c.record(CoverageMetric(domain: .sleep,
                                observedCount: hours == nil ? 0 : 1,
                                expectedCount: 1))
        return c
    }

    /// What may be said about *last night*, which is a different question from
    /// what may be said about the week's debt. A single measured night is fully
    /// evidenced — downgrading it because the rest of the week is patchy would be
    /// under-claiming, which is its own kind of dishonesty — so the hero reads the
    /// day metric and the debt claim reads the week's.
    private var sleepForm: AssertionForm { dayCoverage.permittedForm(for: .sleep) }

    @ViewBuilder private var hero: some View {
        switch night {
        case .reading:
            readingHero
        case let .read(hours):
            readHero(hours)
        }
    }

    /// Holds the hero's exact shape while the port is being read, so the real
    /// number arrives in place rather than as a jump. With the stub health
    /// source this frame is never seen; with HealthKit behind it, it is.
    private var readingHero: some View {
        HStack(alignment: .center, spacing: Kairo.Space.gutter) {
            KairoLoader(size: 84, tint: Kairo.violet)
                .frame(width: 138, height: 138)
            VStack(alignment: .leading, spacing: 9) {
                Text("SLEPT")
                    .font(.kairoLabel).tracking(1.1)
                    .foregroundStyle(Kairo.inkFaint)
                KairoSkeleton(width: 104, height: 22)
                KairoSkeleton(width: 148, height: 12)
            }
            Spacer(minLength: 0)
        }
        .kairoCard()
        .accessibilityElement()
        .accessibilityLabel("Reading last night's sleep")
    }

    @ViewBuilder private func readHero(_ hours: Double?) -> some View {
        if let h = hours {
            HStack(alignment: .center, spacing: Kairo.Space.gutter) {
                ZStack {
                    MetricRing(progress: h / referenceHours, tint: Kairo.violet,
                               size: 138, lineWidth: 11)
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(String(format: "%.1f", h))
                            .font(.kairoDisplay)
                            .foregroundStyle(Kairo.ink)
                            .contentTransition(.numericText())
                        Text("h")
                            .font(.kairoNumber)
                            .foregroundStyle(Kairo.inkFaint)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .frame(width: 116)
                }
                .accessibilityElement()
                .accessibilityLabel(String(format: "Slept %.1f hours against an %.0f hour reference",
                                           h, referenceHours))

                // The badge belongs to the number, not to a row of its own.
                VStack(alignment: .leading, spacing: 9) {
                    Text("SLEPT")
                        .font(.kairoLabel).tracking(1.1)
                        .foregroundStyle(Kairo.inkFaint)
                    CoverageBadge(form: sleepForm)
                    Text("against a flat \(Int(referenceHours)) h reference")
                        .font(.caption)
                        .foregroundStyle(Kairo.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .kairoCard()
        } else {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "applewatch.slash")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Kairo.inkFaint)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Kairo.inkFaint.opacity(0.14)))
                VStack(alignment: .leading, spacing: 7) {
                    Text("No sleep recorded")
                        .font(.kairoHeadline)
                        .foregroundStyle(Kairo.ink)
                    Text("The watch was off your wrist, so there is no number to give you.")
                        .font(.caption)
                        .foregroundStyle(Kairo.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    CoverageBadge(form: sleepForm)
                }
                Spacer(minLength: 0)
            }
            .kairoCard(tint: Kairo.inkFaint)
        }
    }

    // MARK: - Stats

    /// `wearHours` is the honest denominator behind the hero: hours slept mean
    /// nothing without the hours the watch was actually on.
    private var tiles: some View {
        HStack(spacing: 10) {
            StatTile(value: measured(wearHours, shortHours), caption: "on your wrist",
                     icon: "applewatch", tint: Kairo.teal)
            StatTile(value: measured(sedentaryMinutes) { "\($0) min" },
                     caption: "sitting unbroken",
                     icon: "figure.stand", tint: Kairo.amber)
            StatTile(value: dayCoverage.state.rawValue.capitalized, caption: "coverage state",
                     icon: "calendar.badge.clock", tint: Kairo.violet)
        }
    }

    /// Three states onto the two a `StatTile` draws: still reading keeps the
    /// skeleton, and read-but-absent gets an em dash. The dash matters — the live
    /// adapter refuses the sitting question outright rather than answering a
    /// plausible zero, and "0 min" would have been a reassurance nobody measured.
    private func measured<V>(_ value: V??, _ format: (V) -> String) -> String? {
        guard let answered = value else { return nil }
        return answered.map(format) ?? "—"
    }

    private func shortHours(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v)) h" : String(format: "%.1f h", v)
    }

    // MARK: - The claim

    /// The debt, computed. This section used to read
    /// `GatedClaim(text: "Your sleep debt is 2.4 hours.", domain: .sleep)` — a
    /// string literal wearing the evidence badge of a reading, which is the exact
    /// thing the rest of this app exists to argue against. The number now comes
    /// from `SleepSummary.debt(over:)` over the nights the adapter could actually
    /// see, and the *sentence* is chosen by the form that debt permits.
    private var debtSection: some View {
        VStack(spacing: 8) {
            SectionHeader(title: "This week", icon: "moon.stars",
                          trailing: "screened", tint: Kairo.violet)
            if let debt {
                GatedClaim(text: debtClaim(debt), domain: .sleep)
                evidenceFootnote(debt)
            } else {
                // Same shape, so the claim lands in place rather than as a jump.
                VStack(alignment: .leading, spacing: 10) {
                    KairoSkeleton(width: 132, height: 12)
                    KairoSkeleton(width: 232, height: 18)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .kairoCard()
                .accessibilityElement()
                .accessibilityLabel("Working out this week's sleep debt")
            }
        }
    }

    /// The sentence the evidence permits, and no stronger one.
    ///
    /// Digits appear only at `.assertion` and `.qualified`. That is not a
    /// stylistic choice: `SafetyGate` downgrades any claim containing a bare
    /// number when the domain sits below full coverage, so a weaker form must
    /// carry its meaning in words or be rewritten out from under itself. Below
    /// `.qualified` the honest content is the *sign* of the debt rather than its
    /// size — three nights can show that someone is running short of the
    /// reference; they cannot total a week — and at `.question` there is nothing
    /// but a question to ask.
    ///
    /// No two-sided band is offered at `.range`, deliberately. A band with an
    /// upper end would have to assume the unseen nights resembled the seen ones,
    /// and that assumption is precisely the trend line through days Kairo could
    /// not see that the note at the bottom of this screen promises never to draw.
    /// A one-sided "at least" is all the arithmetic supports, because every
    /// excluded night could only have added shortfall.
    private func debtClaim(_ d: SleepDebt) -> String {
        let seen = nightsInWords(d.observedNights)
        let need = spelled(Int(d.nightlyNeedHours))
        switch d.permittedForm {
        case .assertion:
            guard let hours = d.hours else { return nothingSeenClaim(d) }
            return "Your sleep debt is \(oneDecimal(hours)) hours across the last "
                 + "\(nightsInWords(d.expectedNights))."

        case .qualified:
            guard let hours = d.hours else { return nothingSeenClaim(d) }
            // "at least", because the nights that are missing were left out of
            // the sum rather than counted as nights of perfect sleep.
            return "Your sleep debt is at least \(oneDecimal(hours)) hours, counting only "
                 + "the \(seen) I could see."

        case .range:
            guard let hours = d.hours else { return nothingSeenClaim(d) }
            // Two or three nights carry the sign of the debt but not its size.
            return hours > 0
                ? "On the \(seen) I could see, you are running short of the \(need)-hour "
                  + "reference. Too much of the week is missing to put a figure on the debt."
                : "On the \(seen) I could see, you met the \(need)-hour reference. "
                  + "Too much of the week is missing to speak for it as a whole."

        case .question:
            // One or two nights out of a week. There is nothing to accumulate,
            // so the screen asks instead of implying it knows.
            return "I have \(seen) of the last \(spelled(d.expectedNights)) to go on, "
                 + "which is not a week. Were you wearing your watch the rest of the time?"

        case .forbidden:
            return nothingSeenClaim(d)
        }
    }

    private func nothingSeenClaim(_ d: SleepDebt) -> String {
        "I could not see any of the last \(nightsInWords(d.expectedNights)), so there is "
        + "nothing I can tell you about a sleep debt."
    }

    /// One decimal place, matching the hero, and via `String(format:)` so the
    /// figure reads the same as every other hours figure on the screen.
    private func oneDecimal(_ v: Double) -> String { String(format: "%.1f", v) }

    /// The evidence behind the claim, in the same shape `CoverageRow` uses: the
    /// form on the left, the raw counts on the right. This is not itself a claim
    /// about the user's sleep — it is a statement about what Kairo saw — which is
    /// why it carries digits at every form.
    private func evidenceFootnote(_ d: SleepDebt) -> some View {
        HStack(spacing: 8) {
            CoverageBadge(form: d.permittedForm)
            Spacer(minLength: 0)
            Text("\(d.observedNights) of \(d.expectedNights) nights seen · "
                 + "\(Int(d.nightlyNeedHours)) h reference")
                .font(.caption2)
                .foregroundStyle(Kairo.inkFaint)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    /// Counts spelled out, so a weaker claim carries no digits for the gate to
    /// object to. Falls back to a word rather than a numeral past a fortnight,
    /// which is well beyond any window this screen asks for.
    private func spelled(_ n: Int) -> String {
        let words = ["no", "one", "two", "three", "four", "five", "six", "seven",
                     "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen"]
        return words.indices.contains(n) ? words[n] : "several"
    }

    /// "one night", "five nights". The singular matters: these sentences are the
    /// weak forms, and a sentence that reads as though a machine assembled it is
    /// not one a user will believe when it says it does not know.
    private func nightsInWords(_ n: Int) -> String {
        "\(spelled(n)) night" + (n == 1 ? "" : "s")
    }

    // MARK: - Coverage

    private var floorPercent: Int { Int((dayCoverage.floor * 100).rounded()) }

    private var coverageSection: some View {
        VStack(spacing: 8) {
            SectionHeader(title: "Coverage", icon: "circle.dotted",
                          trailing: "needs \(floorPercent)%")
            ForEach(CoverageDomain.allCases, id: \.self) { d in
                CoverageRow(domain: d, coverage: dayCoverage)
            }
            floorLegend
        }
    }

    /// The floor is the mechanism, so it gets said in words as well as drawn on
    /// every ring.
    private var floorLegend: some View {
        HStack(alignment: .top, spacing: 7) {
            Rectangle()
                .fill(Kairo.ink.opacity(0.6))
                .frame(width: 1.5, height: 10)
                .padding(.top, 2)
            Text("the tick on each ring is the \(floorPercent)% floor — a domain below it "
                 + "may not carry a bare number")
                .font(.caption2)
                .foregroundStyle(Kairo.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    // MARK: - Load

    /// INTEGRATION (AppModel / Observations) — this belongs upstream.
    ///
    /// The week is loaded here as local state only because `AppModel` is being
    /// edited elsewhere this week. When it lands, the two moves are:
    ///
    /// 1. `AppModel.bootstrap()` awaits the window once, records
    ///    `debt.coverageMetric` (or, for the day-level ring, one-of-one against
    ///    last night's reading — see `dayCoverage` above) and merges
    ///    `SleepSummary.observations(for: window)` into `observations`, which is
    ///    what finally fills the `sleepHoursLastNight` and `sleepDebtHours`
    ///    fields the Lifestyle analyst has been bidding on since day one with
    ///    nothing behind them.
    /// 2. This screen then reads `model.debt` instead of loading its own, and
    ///    `GatedClaim` starts screening the sentence below against real sleep
    ///    coverage rather than against the hardcoded one-of-one — at which point
    ///    the gate independently enforces the same limit `debtClaim` already
    ///    respects, which is the check worth having.
    ///
    /// Every port call the screen made before is still made, in the same order.
    private func load() async {
        let day = Calendar.current.startOfDay(for: model.env.clock.now)

        // The window first. With the HealthKit adapter this is also what primes
        // the day-level caches the three port reads below draw on, so the sync
        // getters have something to answer with — that missing prime was the
        // whole reason live sleep read as nil forever.
        debt = await week(endingOn: day).sleepDebt()

        night = .read(try? model.env.health.sleepHours(on: day))
        wearHours = .some(try? model.env.health.wearHours(on: day))
        sedentaryMinutes = .some(try? model.env.health.sedentaryMinutes(at: model.env.clock.now))
    }

    /// The last seven nights, blanks included.
    ///
    /// A source that can answer a multi-night question is asked one. A source
    /// that cannot — the stub the demo runs on, which knows a single day — gets
    /// asked for last night and the other six nights stay blank, because six
    /// copies of last night is exactly the fabricated week this app refuses to
    /// draw. That path is also the honest one for a first launch, and it is why
    /// the screen has to have something sensible to say from one night.
    private func week(endingOn day: Date) async -> [NightReading] {
        let nights = SleepSummary.defaultWindowNights
        if let windowed = model.env.health as? SleepWindowSource {
            return await windowed.nightReadings(endingOn: day, nights: nights)
        }
        let keys = (0..<nights).reversed().compactMap {
            Calendar.current.date(byAdding: .day, value: -$0, to: day)
        }
        var observed: [Date: Double] = [:]
        if let lastNight = try? model.env.health.sleepHours(on: day), let key = keys.last {
            observed[key] = lastNight
        }
        return SleepSummary.slots(for: keys, observedHours: observed)
    }
}

/// One domain, its evidence, and the line it has to clear. A percentage on its own
/// is a score; the ring, the floor tick, the raw counts and the badge together are
/// the gate the user is actually subject to.
private struct CoverageRow: View {
    let domain: CoverageDomain
    let coverage: DayCoverage

    private let ringSize: CGFloat = 48
    private let ringWidth: CGFloat = 5

    private var fraction: Double { coverage.fraction(domain) }
    private var metric: CoverageMetric? { coverage.metrics[domain] }
    private var tint: Color { Kairo.colour(for: domain) }
    private var clearsFloor: Bool { fraction >= coverage.floor }

    var body: some View {
        HStack(spacing: 12) {
            ring
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(domain.rawValue.capitalized)
                        .font(.kairoHeadline)
                        .foregroundStyle(Kairo.ink)
                    Spacer(minLength: 0)
                    Text(String(format: "%.0f%%", fraction * 100))
                        .font(.kairoMono)
                        .foregroundStyle(clearsFloor ? Kairo.inkSoft : Kairo.coral)
                }
                HStack(spacing: 8) {
                    CoverageBadge(form: coverage.permittedForm(for: domain))
                    Spacer(minLength: 0)
                    if let m = metric {
                        Text("\(m.observedCount) of \(m.expectedCount) seen")
                            .font(.caption2)
                            .foregroundStyle(Kairo.inkFaint)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kairoCard(padding: 14, radius: Kairo.Radius.inner,
                   tint: clearsFloor ? nil : Kairo.coral)
        .accessibilityElement(children: .combine)
    }

    /// The domain's own colour and icon, with the floor marked on the arc at the
    /// angle it sits at — so "60%" is a place on the ring, not a number in prose.
    private var ring: some View {
        ZStack {
            MetricRing(progress: fraction, tint: tint, icon: Kairo.icon(for: domain),
                       size: ringSize, lineWidth: ringWidth)
            ZStack {
                Rectangle()
                    .fill(Kairo.ink.opacity(0.6))
                    .frame(width: 1.5, height: ringWidth + 4)
                    .offset(y: -(ringSize - ringWidth) / 2)
            }
            .frame(width: ringSize, height: ringSize)
            .rotationEffect(.degrees(360 * coverage.floor))
        }
        .frame(width: ringSize, height: ringSize)
    }
}
