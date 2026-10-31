import SwiftUI
import KairoKit

/// Member C — CF7. The attention ledger.
///
/// One question: what did Kairo decide about your attention, and who lost.
/// Everything on this screen answers it, and the things that did not — three
/// stat tiles restating their own neighbours, a movement card that belongs on
/// Body, four unrelated score gauges — are gone rather than rearranged.
///
/// Six sections, at most, in any state:
///   1. the header, with the provenance chip
///   2. the dial → the attention contract
///   3. the roster and the ledger, as one card
///   4. water, compact
///   5. the contract proposal, when the agents are holding one
///   6. the trust note
struct TodayView: View {
    @Environment(AppModel.self) private var model
    /// The two hero cards put a fixed-width graphic beside a block of prose. At
    /// an accessibility size the prose needs the whole 375 points, so the
    /// graphic goes above it rather than squeezing it into a column.
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Kairo.Space.stack) {
                    header
                    if model.demoMode {
                        demoBanner
                        liveSignalsCard
                    }
                    dial
                    BidLedgerCard(delivered: model.arbitration?.delivered ?? [],
                                  suppressed: model.arbitration?.suppressed ?? [],
                                  costing: model.arbitrationCosting,
                                  record: model.arbitration?.record)
                    waterStrip
                    mealStrip

                    if let c = model.contract, c.state == .proposed {
                        ContractProposalCard(contract: c)
                    }

                    // FR9.5. A contract the Steward refused never becomes a
                    // card asking for consent, so without this the user is
                    // never told it was considered. That is the same omission
                    // the losing-bid rows exist to prevent: a decision made
                    // about them, on evidence, that they cannot see.
                    if let c = model.contract, let why = c.stewardVetoReason {
                        StewardVetoNote(reason: why)
                    }

                    TrustNote(text: "Every bid that lost is listed above, with why. "
                              + "Nothing here was hidden from you, and a suppression made to "
                              + "save money is labelled as one.")
                }
                .padding(.horizontal, Kairo.Space.stack)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .background(KairoCanvas())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: - Header

    private var provenance: ArbitrationProvenance {
        ArbitrationProvenance(source: model.arbitrationSource,
                              costing: model.arbitrationCosting,
                              connection: model.backend.state)
    }

    private var header: some View {
        KairoHeader(eyebrow: dateLine, title: greeting) {
            NavigationLink { BackendSettingsView() } label: {
                ProvenanceChip(provenance: provenance)
            }
            .buttonStyle(.kairoPress)
        }
        .padding(.horizontal, 4)
    }

    private var dateLine: String {
        model.env.clock.now.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// The user's own morning, not Sydney's.
    ///
    /// This read `TimeZone(identifier: "Australia/Sydney")`, which is where the
    /// project was written. A user in Europe opened the app at breakfast and was
    /// greeted with "Good evening" — the one line on the screen that claims to
    /// know something about the person holding the phone, and it was about
    /// somebody else's afternoon.
    private var greeting: String {
        switch Calendar.current.component(.hour, from: model.env.clock.now) {
        case 0..<12:  "Good morning"
        case 12..<17: "Good afternoon"
        default:      "Good evening"
        }
    }

    // MARK: - The dial
    //
    // Tappable, and the only way into the attention contract. The ring is
    // `SegmentedRing` from the brand mark with the day's real numbers in it —
    // the logo *is* the data — so it earns the hero slot.

    private var dial: some View {
        NavigationLink { AttentionReceiptView() } label: {
            AdaptiveHeroRow(stacked: typeSize.isAccessibilitySize,
                            spacing: Kairo.Space.gutter) {
                AttentionDial(spent: model.schedule.spent, total: model.schedule.dailyBudget)
            } detail: {
                dialDetail
            } trailing: {
                Image(systemName: "chevron.right")
                    .font(.kairoGlyph(11))
                    .foregroundStyle(Kairo.inkFaint)
            }
            .kairoCard()
        }
        .buttonStyle(.kairoPress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dialAccessibilityLabel)
        .accessibilityHint("Opens your attention contract")
        .accessibilityAddTraits(.isButton)
    }

    /// Lifted out of `dial` for the same reason `provenanceSection` was split in
    /// BackendSettingsView: measured with `-warn-long-function-bodies`, this
    /// getter was the slowest thing left in the app at 368ms on Swift 6.4. CI
    /// runs Swift 6.1.2, where the equivalent expression next door had already
    /// crossed from slow into "unable to type-check in reasonable time" — so
    /// this is the one that fails next, on a build nobody has changed.
    private var dialDetail: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ATTENTION BUDGET")
                .font(.kairoLabel).tracking(1.1)
                .foregroundStyle(Kairo.inkFaint)
            Text("\(model.schedule.spent) of \(model.schedule.dailyBudget) spent")
                .font(.kairoHeadline)
                .foregroundStyle(Kairo.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Interruptions, not notifications. Tap to change the ceiling.")
                .font(.kairoCaption)
                .foregroundStyle(Kairo.inkSoft)
                .fixedSize(horizontal: false, vertical: true)

            if let c = model.contract, c.state == .active {
                Pill(text: "plan contract active", icon: "checkmark.seal.fill",
                     tint: Kairo.teal)
                    .padding(.top, 2)
            }
        }
    }

    private var dialAccessibilityLabel: String {
        "\(model.schedule.spent) of \(model.schedule.dailyBudget) interruptions spent today"
    }

    // MARK: - Water

    /// CF8, compact. The number the user came looking for, and one pill rather
    /// than three: the watch-link state and the coverage counts both belong to
    /// the reading, not to the headline, and at 375pt three pills in a row had
    /// nowhere to go.
    private var waterStrip: some View {
        let log = model.hydration
        let logged = !log.sips.isEmpty
        let tint = Kairo.colour(for: .hydration)

        return AdaptiveHeroRow(stacked: typeSize.isAccessibilitySize,
                               spacing: Kairo.Space.gutter) {
            MetricRing(progress: logged ? log.fractionOfTarget : 0,
                       tint: logged ? tint : Kairo.inkFaint,
                       icon: Kairo.icon(for: .hydration),
                       centreText: logged ? "\(Int(log.fractionOfTarget * 100))%" : nil,
                       size: 62)
        } detail: {
            VStack(alignment: .leading, spacing: 5) {
                Text("WATER")
                    .font(.kairoLabel).tracking(1.1)
                    .foregroundStyle(Kairo.inkFaint)

                if logged {
                    Text("\(log.totalMillilitres) of \(log.targetMillilitres) ml")
                        .font(.kairoHeadline)
                        .foregroundStyle(Kairo.ink)
                        .contentTransition(.numericText())
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Not measured is not zero. Drawing an untouched day as
                    // "0 ml" would present an absence of data as an achievement,
                    // which is the same claim the coverage gate would refuse in a
                    // sentence — so the card does not make it either.
                    Text("Nothing logged yet")
                        .font(.kairoHeadline)
                        .foregroundStyle(Kairo.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }

                PillWrap {
                    Pill(text: waterPill.text, icon: waterPill.icon, tint: waterPill.tint)
                }
                .padding(.top, 1)
            }
        }
        .kairoCard(tint: logged ? tint : Kairo.inkFaint)
        .accessibilityElement(children: .combine)
        // FR8.5. The old label read the totals, which is the *number*; the ring
        // was encoding the *position*, and position was the part with no
        // non-visual equivalent. NFR11's colour-only rule points at the same
        // gap: green-at-target was the only thing that said "you are done".
        .accessibilityLabel(logged ? waterSpoken : "No water logged yet today. \(emptyWaterHint)")
        .accessibilityValue(HydrationProgress.accessibilityValue(
            totalMillilitres: log.totalMillilitres,
            targetMillilitres: log.targetMillilitres,
            sipCount: log.sips.count))
    }

    // MARK: - Demo

    /// Said on the first screen, every time. An audience is about to watch the
    /// agents reason over this day, and they are owed the fact that the readings
    /// are a scenario — the reasoning over them is not.
    private var demoBanner: some View {
        NavigationLink { BackendSettingsView() } label: {
            HStack(spacing: 10) {
                Image(systemName: "theatermasks.fill")
                    .font(.kairoGlyph(13, weight: .semibold))
                    .foregroundStyle(Kairo.violet)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Demo mode")
                        .font(.kairoHeadline).foregroundStyle(Kairo.ink)
                    Text("Sleep, sitting, water and two meals are a scenario. "
                         + "The agents' answers are real.")
                        .font(.kairoCaption).foregroundStyle(Kairo.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.kairoGlyph(11))
                    .foregroundStyle(Kairo.inkFaint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .kairoCard(padding: 14, tint: Kairo.violet)
        }
        .buttonStyle(.kairoPress)
    }

    /// The demo's live wrist, with where each figure came from. In front of an
    /// audience "where did 97 minutes come from?" deserves an answer on screen.
    private var liveSignalsCard: some View {
        let live = model.live
        let source = live.source?.label ?? "scenario (nothing streaming)"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(live.source == nil ? Kairo.inkFaint : Kairo.leaf)
                    .frame(width: 7, height: 7)
                Text("LIVE SIGNALS")
                    .font(.kairoLabel).tracking(1.1)
                    .foregroundStyle(Kairo.inkFaint)
                Spacer(minLength: 4)
                Text(source)
                    .font(.kairoLabel)
                    .foregroundStyle(live.source == .watch ? Kairo.sky : Kairo.inkSoft)
            }
            HStack(spacing: 10) {
                signalTile(value: "\(model.observations.sedentaryMinutes ?? DemoHealthSource.sittingMinutes)",
                           unit: "min", caption: "sitting", tint: Kairo.amber)
                signalTile(value: live.heartRateBPM.map(String.init) ?? "—",
                           unit: "bpm", caption: "heart rate", tint: Kairo.coral)
                signalTile(value: live.stepsToday.map(String.init) ?? "—",
                           unit: "", caption: "steps", tint: Kairo.teal)
            }
            Text(model.sleepIsRecorded
                 ? "Sleep and the week: recorded Health (the simulator's seeded week)."
                 : "Sleep and the week: scenario. Seed the simulator's Health to use recorded data.")
                .font(.kairoCaption).foregroundStyle(Kairo.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kairoCard(padding: 14)
    }

    private func signalTile(value: String, unit: String, caption: String,
                            tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.kairoHeadline).monospacedDigit()
                    .foregroundStyle(Kairo.ink)
                    .contentTransition(.numericText())
                if !unit.isEmpty {
                    Text(unit).font(.kairoLabel).foregroundStyle(Kairo.inkFaint)
                }
            }
            Text(caption.uppercased())
                .font(.kairoLabel).tracking(0.8)
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Meals

    /// CF1 / CF2 — the day's ledger. This card did not exist, which is half of
    /// why a logged meal looked as though it had gone nowhere.
    private var mealStrip: some View {
        let logged = !model.meals.isEmpty
        let tint = Kairo.colour(for: .meals)
        let fraction = model.kilojoulesTarget > 0
            ? model.kilojoulesLogged / model.kilojoulesTarget : 0

        return VStack(alignment: .leading, spacing: 12) {
            AdaptiveHeroRow(stacked: typeSize.isAccessibilitySize,
                            spacing: Kairo.Space.gutter) {
                MetricRing(progress: logged ? fraction : 0,
                           tint: logged ? tint : Kairo.inkFaint,
                           icon: Kairo.icon(for: .meals),
                           centreText: logged ? "\(Int((fraction * 100).rounded()))%" : nil,
                           size: 62)
            } detail: {
                VStack(alignment: .leading, spacing: 5) {
                    Text("MEALS")
                        .font(.kairoLabel).tracking(1.1)
                        .foregroundStyle(Kairo.inkFaint)
                    if logged {
                        Text("\(Int(model.kilojoulesLogged.rounded())) of "
                             + "\(Int(model.kilojoulesTarget)) kJ")
                            .font(.kairoHeadline)
                            .foregroundStyle(Kairo.ink)
                            .contentTransition(.numericText())
                    } else {
                        Text("Nothing logged yet")
                            .font(.kairoHeadline)
                            .foregroundStyle(Kairo.inkSoft)
                    }
                    PillWrap {
                        Pill(text: logged
                                ? "\(model.meals.count) of \(AppModel.expectedMeals) meals seen"
                                : "log one from the Meals tab",
                             icon: logged ? "fork.knife" : "camera",
                             tint: logged ? tint : Kairo.inkFaint)
                    }
                }
            }

            if logged {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.meals) { meal in
                        mealRow(meal)
                    }
                }
            }

            suggestion
        }
        .kairoCard(tint: logged ? tint : Kairo.inkFaint)
    }

    private func mealRow(_ meal: LoggedMeal) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(meal.at.formatted(date: .omitted, time: .shortened))
                .font(.kairoMono)
                .foregroundStyle(Kairo.inkFaint)
                .frame(minWidth: 52, alignment: .leading)
            Text(meal.title)
                .font(.kairoCaption)
                .foregroundStyle(Kairo.ink)
                .lineLimit(2)
            Spacer(minLength: 6)
            Text("\(Int(meal.kilojoules.rounded())) kJ")
                .font(.kairoMono)
                .foregroundStyle(meal.confidence < 0.6 ? Kairo.coral : Kairo.inkSoft)
        }
        .accessibilityElement(children: .combine)
    }

    /// CF2 — the Nutrition role's next-meal suggestion, on request. Asked for
    /// rather than fetched on every launch: it is a model call, and a card that
    /// spends money just by being looked at is not one this app would ship.
    @ViewBuilder private var suggestion: some View {
        if let s = model.mealSuggestion, !s.suggestion.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.kairoGlyph(10))
                    Text("NEXT MEAL · NUTRITION ANALYST")
                        .font(.kairoLabel).tracking(0.9)
                }
                .foregroundStyle(Kairo.colour(for: .meals))
                Text(s.suggestion)
                    .font(.kairoHeadline).foregroundStyle(Kairo.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !s.reason.isEmpty {
                    Text(s.reason)
                        .font(.kairoCaption).foregroundStyle(Kairo.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if model.backend.client != nil {
            Button {
                Task { await model.suggestNextMeal() }
            } label: {
                HStack(spacing: 8) {
                    if model.suggestingMeal {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(model.suggestingMeal ? "Asking the Nutrition Analyst…"
                                              : "What should I eat next?")
                }
            }
            .buttonStyle(.kairoSoft(Kairo.colour(for: .meals)))
            .disabled(model.suggestingMeal)
        }
    }

    /// FR8.5's spoken form, from the one source the ring reads, so the two
    /// cannot drift apart.
    private var waterSpoken: String {
        HydrationProgress.spoken(totalMillilitres: model.hydration.totalMillilitres,
                                 targetMillilitres: model.hydration.targetMillilitres,
                                 sipCount: model.hydration.sips.count)
    }

    /// One pill, and it says the most useful thing available: how far there is
    /// to go once something has been logged, and where the number is supposed to
    /// come from before anything has.
    private var waterPill: (text: String, icon: String, tint: Color) {
        let log = model.hydration
        guard !log.sips.isEmpty else {
            return (model.wristAvailable && model.wristLinked ? "tap water on your watch"
                                                              : "nothing from the wrist yet",
                    model.wristLinked ? "applewatch.radiowaves.left.and.right" : "applewatch.slash",
                    Kairo.inkFaint)
        }
        if log.remainingMillilitres == 0 {
            return ("target reached — no more water nudges today",
                    "checkmark.seal.fill", Kairo.leaf)
        }
        return ("\(log.remainingMillilitres) ml to go", "drop.fill",
                Kairo.colour(for: .hydration))
    }

    /// Says where the number is supposed to come from, and — when there is no
    /// session at all — says that too rather than blaming the user for not
    /// tapping. VoiceOver only; the pill carries the short form.
    private var emptyWaterHint: String {
        guard model.wristAvailable else {
            return "This build has no watch link, so nothing can arrive from the wrist."
        }
        return model.wristLinked
            ? "Tap water on your watch and it lands here."
            : "Tap water on your watch; it arrives when the two are back in range."
    }
}

/// The state the app is in most of the time, given its own name and its own card
/// rather than an empty list.
///
/// When nothing won this takes the headline position inside the ledger card and
/// the losing bids sit underneath it unchanged — silence with four visible
/// losers underneath is a far stronger statement than silence alone.
struct SilenceCard: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "moon.zzz.fill")
                .font(.kairoGlyph(20, weight: .semibold))
                .foregroundStyle(Kairo.teal)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Kairo.teal.opacity(0.14)))
            VStack(alignment: .leading, spacing: 3) {
                Text("Nothing worth interrupting you for")
                    .font(.kairoHeadline).foregroundStyle(Kairo.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Kairo spent none of today's budget on this pass.")
                    .font(.kairoCaption).foregroundStyle(Kairo.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: Kairo.Radius.inner, style: .continuous)
                .fill(Kairo.teal.opacity(0.10))
        }
        .accessibilityElement(children: .combine)
    }
}
