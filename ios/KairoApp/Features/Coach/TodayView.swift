import SwiftUI
import KairoKit

/// Member C — CF7. The screen that makes the thesis visible: a finite budget,
/// bids competing for it, and the ones that lost with the reason they lost.
struct TodayView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Kairo.Space.stack) {
                    header
                    budgetHero
                    hydrationCard
                    movementCard
                    tiles

                    if let c = model.contract, c.state == .proposed {
                        VStack(spacing: 8) {
                            SectionHeader(title: "A smaller plan", icon: "arrow.down.right.circle",
                                          tint: Kairo.teal)
                            ContractProposalCard(contract: c)
                        }
                    }

                    deliveredSection
                    suppressedSection

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

    private var header: some View {
        KairoHeader(eyebrow: dateLine, title: greeting) {
            NavigationLink {
                AttentionReceiptView()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .bold))
                    Text("Attention").font(.kairoLabel).tracking(0.5)
                }
                .foregroundStyle(Kairo.amber)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Capsule().fill(Kairo.amber.opacity(0.14)))
                .overlay(Capsule().strokeBorder(Kairo.amber.opacity(0.25), lineWidth: 0.5))
            }
        }
        .padding(.horizontal, 4)
    }

    private var dateLine: String {
        model.env.clock.now.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    private var greeting: String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Australia/Sydney") ?? .current
        return switch cal.component(.hour, from: model.env.clock.now) {
        case 0..<12:  "Good morning"
        case 12..<17: "Good afternoon"
        default:      "Good evening"
        }
    }

    // MARK: - Budget

    private var budgetHero: some View {
        HStack(alignment: .center, spacing: Kairo.Space.gutter) {
            AttentionDial(spent: model.schedule.spent, total: model.schedule.dailyBudget)

            VStack(alignment: .leading, spacing: 6) {
                Text("ATTENTION BUDGET")
                    .font(.kairoLabel).tracking(1.1)
                    .foregroundStyle(Kairo.inkFaint)
                Text("\(model.schedule.spent) of \(model.schedule.dailyBudget) spent")
                    .font(.kairoHeadline)
                    .foregroundStyle(Kairo.ink)
                Text("Interruptions, not notifications. Kairo may spend none at all.")
                    .font(.caption)
                    .foregroundStyle(Kairo.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)

                if let c = model.contract, c.state == .active {
                    Pill(text: "plan contract active", icon: "checkmark.seal.fill", tint: Kairo.teal)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .kairoCard()
    }

    // MARK: - Water

    /// CF8. The number the user came looking for.
    ///
    /// A glass logged on the wrist has to be visible here or the round trip might
    /// as well not exist — "I add water and it doesn't go up in the app" was the
    /// whole complaint. Millilitres against the target, and the count of taps
    /// beside it, because the tap count is what coverage is measured on: one
    /// 800 ml bottle is not the same evidence as four glasses across a day.
    /// CF5 — movement, as read rather than as seeded. Every figure here is
    /// optional on purpose: the whole point of the movement read was to stop
    /// showing a constant where there was no measurement, so an absent value
    /// says so instead of drawing a zero.
    @ViewBuilder private var movementCard: some View {
        if let m = model.movement {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "figure.walk")
                        .font(.system(size: 11, weight: .bold))
                    Text("MOVEMENT").font(.kairoLabel).tracking(1.1)
                    Spacer(minLength: 0)
                    CoverageBadge(form: m.permittedForm())
                }
                .foregroundStyle(Kairo.amber)

                HStack(spacing: 10) {
                    StatTile(value: m.unbrokenSedentaryMinutes.map { "\($0) min" },
                             caption: "sitting unbroken",
                             icon: "figure.stand", tint: Kairo.amber)
                    StatTile(value: m.activeKilojoules.map { "\(Int($0)) kJ" },
                             caption: "burned today",
                             icon: "flame.fill", tint: Kairo.coral)
                    StatTile(value: m.hoursWorn.map { String(format: "%.0f h", $0) },
                             caption: "on your wrist",
                             icon: "applewatch", tint: Kairo.teal)
                }

                if !m.isObserved {
                    Text("No wear reading yet, so nothing here is measured against "
                         + "anything. Kairo will not put a figure on a day it could "
                         + "not see.")
                        .font(.caption)
                        .foregroundStyle(Kairo.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .kairoCard()
        }
    }

    private var hydrationCard: some View {
        let log = model.hydration
        let logged = !log.sips.isEmpty
        let tint = Kairo.colour(for: .hydration)

        return HStack(alignment: .center, spacing: Kairo.Space.gutter) {
            MetricRing(progress: logged ? log.fractionOfTarget : 0,
                       tint: logged ? tint : Kairo.inkFaint,
                       icon: Kairo.icon(for: .hydration),
                       centreText: logged ? "\(Int(log.fractionOfTarget * 100))%" : nil,
                       size: 68)

            VStack(alignment: .leading, spacing: 6) {
                Text("WATER")
                    .font(.kairoLabel).tracking(1.1)
                    .foregroundStyle(Kairo.inkFaint)

                if logged {
                    Text("\(log.totalMillilitres) of \(log.targetMillilitres) ml")
                        .font(.kairoHeadline)
                        .foregroundStyle(Kairo.ink)
                        .contentTransition(.numericText())
                    Text(log.remainingMillilitres == 0
                         ? "Target reached. Kairo will not nudge you about water again today."
                         : "\(log.remainingMillilitres) ml to go.")
                        .font(.caption)
                        .foregroundStyle(Kairo.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Not measured is not zero. Drawing an untouched day as
                    // "0 ml" would present an absence of data as an achievement,
                    // which is the same claim the coverage gate would refuse in a
                    // sentence — so the card does not make it either.
                    Text("Nothing logged yet")
                        .font(.kairoHeadline)
                        .foregroundStyle(Kairo.inkSoft)
                    Text(emptyWaterHint)
                        .font(.caption)
                        .foregroundStyle(Kairo.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 6) {
                    if logged {
                        Pill(text: log.sips.count == 1 ? "logged once" : "logged \(log.sips.count) times",
                             icon: "drop.fill", tint: tint)
                    }
                    if let m = model.coverage.metrics[.hydration] {
                        Pill(text: "seen \(m.observedCount) of \(m.expectedCount)",
                             icon: "eye", tint: Kairo.teal)
                    }
                    if model.wristAvailable {
                        Pill(text: model.wristLinked ? "watch linked" : "watch out of range",
                             icon: model.wristLinked
                                 ? "applewatch.radiowaves.left.and.right" : "applewatch.slash",
                             tint: model.wristLinked ? Kairo.leaf : Kairo.inkFaint)
                    }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .kairoCard(tint: logged ? tint : Kairo.inkFaint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(logged
            ? "\(log.totalMillilitres) of \(log.targetMillilitres) millilitres of water, logged \(log.sips.count) times"
            : "No water logged yet today")
    }

    /// Says where the number is supposed to come from, and — when there is no
    /// session at all — says that too rather than blaming the user for not
    /// tapping.
    private var emptyWaterHint: String {
        guard model.wristAvailable else {
            return "This build has no watch link, so nothing can arrive from the wrist."
        }
        return model.wristLinked
            ? "Tap water on your watch and it lands here."
            : "Tap water on your watch; it arrives when the two are back in range."
    }

    private var tiles: some View {
        HStack(spacing: 10) {
            StatTile(value: "\(model.arbitration?.delivered.count ?? 0)",
                     caption: "delivered now", icon: "bell.badge.fill", tint: Kairo.amber)
            StatTile(value: "\(model.arbitration?.suppressed.count ?? 0)",
                     caption: "held back", icon: "hand.raised.fill", tint: Kairo.teal)
            StatTile(value: "\(biddingRoles)",
                     caption: "roles bidding", icon: "person.2.fill", tint: Kairo.violet)
        }
    }

    private var biddingRoles: Int {
        let all = (model.arbitration?.delivered ?? []) + (model.arbitration?.suppressed ?? [])
        return Set(all.map(\.bid.originAgent)).count
    }

    // MARK: - Sections

    @ViewBuilder private var deliveredSection: some View {
        VStack(spacing: 8) {
            SectionHeader(title: "Now", icon: "bell.badge", tint: Kairo.amber)
            if let delivered = model.arbitration?.delivered, !delivered.isEmpty {
                ForEach(delivered, id: \.bid.id) { NudgeCard(nudge: $0) }
            } else {
                SilenceCard()
            }
        }
    }

    @ViewBuilder private var suppressedSection: some View {
        if let held = model.arbitration?.suppressed, !held.isEmpty {
            VStack(spacing: 8) {
                SectionHeader(title: "Why you weren't interrupted",
                              icon: "hand.raised", trailing: "\(held.count)", tint: Kairo.teal)
                ForEach(held, id: \.bid.id) { SuppressedCard(nudge: $0) }
            }
        }
    }
}

// MARK: - Delivered

struct NudgeCard: View {
    let nudge: Nudge

    private var tint: Color { Kairo.colour(forNudgeClass: nudge.bid.nudgeClass) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                AgentChip(agent: nudge.bid.originAgent)
                Pill(text: Kairo.title(forNudgeClass: nudge.bid.nudgeClass),
                     icon: Kairo.icon(forNudgeClass: nudge.bid.nudgeClass), tint: tint)
                Spacer(minLength: 0)
                if let c = nudge.channel {
                    Pill(text: channelName(c), icon: channelIcon(c), tint: Kairo.inkSoft)
                }
            }

            Text(nudge.bid.text)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(Kairo.ink)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                ScoreMeter(value: nudge.score, tint: tint)
                HStack {
                    Text(String(format: "score %.2f", nudge.score))
                    Spacer()
                    Text(String(format: "receptivity %.0f%%", nudge.receptivity * 100))
                }
                .font(.kairoMono)
                .foregroundStyle(Kairo.inkFaint)
            }

            HStack(spacing: 5) {
                Image(systemName: "clock").font(.system(size: 10, weight: .bold))
                Text("useful until \(nudge.bid.windowCloses.formatted(date: .omitted, time: .shortened))")
            }
            .font(.caption2)
            .foregroundStyle(Kairo.inkFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kairoCard(tint: tint)
    }

    private func channelName(_ c: NudgeChannelKind) -> String {
        switch c {
        case .watchHaptic: "watch"
        case .push:        "push"
        case .inApp:       "in app"
        case .silentHold:  "silent"
        }
    }

    private func channelIcon(_ c: NudgeChannelKind) -> String {
        switch c {
        case .watchHaptic: "applewatch.radiowaves.left.and.right"
        case .push:        "iphone.radiowaves.left.and.right"
        case .inApp:       "app.badge"
        case .silentHold:  "speaker.slash"
        }
    }
}

/// The state the app is in most of the time, given its own name and its own card
/// rather than an empty list.
struct SilenceCard: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Kairo.teal)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Kairo.teal.opacity(0.14)))
            VStack(alignment: .leading, spacing: 3) {
                Text("Nothing worth interrupting you for")
                    .font(.kairoHeadline).foregroundStyle(Kairo.ink)
                Text("Kairo spent none of today's budget on this pass.")
                    .font(.caption).foregroundStyle(Kairo.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .kairoCard(tint: Kairo.teal)
    }
}

// MARK: - Suppressed

struct SuppressedCard: View {
    let nudge: Nudge

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Capsule()
                .fill(reasonTint)
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    AgentChip(agent: nudge.bid.originAgent, compact: true)
                    Text(Kairo.title(forNudgeClass: nudge.bid.nudgeClass))
                        .font(.kairoLabel).tracking(0.5)
                        .foregroundStyle(Kairo.colour(forNudgeClass: nudge.bid.nudgeClass))
                    Spacer(minLength: 0)
                    if isCost {
                        Pill(text: "cost", icon: "dollarsign.circle.fill",
                             tint: Kairo.coral, solid: true)
                    }
                    Text(String(format: "%.2f", nudge.score))
                        .font(.kairoMono).foregroundStyle(Kairo.inkFaint)
                }

                Text(nudge.bid.text)
                    .font(.subheadline)
                    .foregroundStyle(Kairo.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 5) {
                    Image(systemName: reasonIcon).font(.system(size: 9, weight: .bold))
                    Text(explanation)
                }
                .font(.caption2)
                .foregroundStyle(reasonTint)

                ScoreMeter(value: nudge.score, tint: reasonTint, height: 4)
                    .opacity(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kairoCard(padding: 14, radius: Kairo.Radius.inner)
    }

    private var isCost: Bool { nudge.suppressionReason == .costCeiling }

    /// Section 7.1: a cost suppression is labelled as one. It is never dressed up
    /// to the user as restraint — which is also why it is the only reason drawn
    /// in the warning colour.
    private var explanation: String {
        switch nudge.suppressionReason {
        case .budgetExhausted: "today's interruption budget was already spent"
        case .quietHours:      "quiet hours"
        case .outranked:       "a more useful interruption won this slot"
        case .costCeiling:     "held back to stay inside this month's service cost"
        case .classSuspended:  "suspended by your current plan contract"
        case .windowNotOpen:   "not due yet"
        case .windowClosed:    "the useful moment passed"
        case .inaccessible:    "could not be delivered in a form you can act on"
        case .duplicateClass:  "a similar interruption was already delivered"
        case .ungrounded:      "nothing was measured here today, so nothing was claimed"
        case .none:            "no reason recorded"
        }
    }

    private var reasonIcon: String {
        switch nudge.suppressionReason {
        case .budgetExhausted: "gauge.with.dots.needle.0percent"
        case .quietHours:      "moon.fill"
        case .outranked:       "arrow.up.arrow.down"
        case .costCeiling:     "dollarsign.circle"
        case .classSuspended:  "pause.circle"
        case .windowNotOpen:   "clock.badge.questionmark"
        case .windowClosed:    "clock.badge.xmark"
        case .inaccessible:    "figure.roll"
        case .duplicateClass:  "square.on.square"
        case .ungrounded:      "eye.slash"
        case .none:            "questionmark.circle"
        }
    }

    private var reasonTint: Color {
        switch nudge.suppressionReason {
        case .costCeiling, .inaccessible: Kairo.coral
        case .budgetExhausted:            Kairo.amber
        case .quietHours:                 Kairo.violet
        case .classSuspended:             Kairo.teal
        default:                          Kairo.inkFaint
        }
    }
}
