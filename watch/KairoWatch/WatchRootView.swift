import SwiftUI
import KairoKit

/// The watch has two modes and they are meant to feel like opposites.
///
/// A pending nudge takes the whole screen, warm and loud, with one action and
/// three answers. The rest of the time - which is most of the time, by design -
/// the crown pages through three quiet, cool cards that ask nothing of you.
struct WatchRootView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        NavigationStack {
            if let nudge = model.pending {
                NudgeCard(nudge: nudge)
            } else {
                QuietView()
            }
        }
    }
}

// MARK: - The interruption

/// CF7 - what an interruption actually looks like on the wrist: one action,
/// three answers, no scrolling.
///
/// The phone arbitrates; this screen only renders the bid that won and reports
/// which of the three answers you gave. Those outcomes are what the receptivity
/// model learns from, so every button here has to report exactly one thing.
struct NudgeCard: View {
    @Environment(WatchModel.self) private var model
    let nudge: WatchModel.PendingNudge

    private var tint: Color { Kairo.colour(forNudgeClass: nudge.nudgeClass) }

    var body: some View {
        VStack(spacing: 0) {
            WatchPill(text: Kairo.title(forNudgeClass: nudge.nudgeClass),
                      icon: Kairo.icon(forNudgeClass: nudge.nudgeClass),
                      tint: tint)
                .padding(.bottom, 5)

            // The bid itself, and nothing competing with it.
            Text(nudge.text)
                .font(.wBid)
                .foregroundStyle(Kairo.ink)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .minimumScaleFactor(0.55)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let original = nudge.rewrittenFrom {
                substitutionNote(original)
            }

            answers.padding(.top, 7)
        }
        .padding(.horizontal, 2)
        .containerBackground(Kairo.nudgeWash(forNudgeClass: nudge.nudgeClass),
                             for: .navigation)
    }

    /// NFR11 - this nudge is not the one the role wrote; it was substituted
    /// because the original needed a capability the user does not have. A silent
    /// substitution would be the app quietly deciding what you can do, so it is
    /// stated on the same screen as the ask.
    private func substitutionNote(_ original: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 8, weight: .bold))
            Text("adapted from: \(original)")
        }
        .font(.wCaption)
        .foregroundStyle(Kairo.inkSoft)
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Adapted from: \(original). Substituted because it needed "
                            + "something you told Kairo you cannot do.")
    }

    private var answers: some View {
        // 38 + 38 + 48 plus gaps is 134pt - inside the 40mm content width with
        // room to spare, so nothing compresses and nothing scrolls sideways.
        HStack(spacing: 5) {
            AnswerButton(glyph: "xmark", label: "Dismiss", tint: Kairo.inkSoft) {
                model.dismiss()
            }
            AnswerButton(glyph: "clock", label: "Snooze", tint: Kairo.amber) {
                model.snooze()
            }
            AnswerButton(glyph: "checkmark", label: "Accept", tint: Kairo.leaf,
                         diameter: 48, prominent: true) {
                model.accept()
            }
        }
    }
}

/// One of the three answers. Circular, fingertip-sized on the smallest watch,
/// and labelled - the glyph is decoration, the label is the control's name.
private struct AnswerButton: View {
    let glyph: String
    let label: String
    var tint: Color = Kairo.inkSoft
    var diameter: CGFloat = 38
    /// The accept button carries the weight: filled, larger, and lit.
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: glyph)
                .font(.system(size: diameter * 0.38, weight: .bold))
                .foregroundStyle(prominent ? Color.black.opacity(0.85) : tint)
                .frame(width: diameter, height: diameter)
                .background {
                    Circle().fill(prominent ? AnyShapeStyle(tint)
                                            : AnyShapeStyle(tint.opacity(0.2)))
                }
                .overlay {
                    Circle().strokeBorder(tint.opacity(prominent ? 0 : 0.35), lineWidth: 1)
                }
                .shadow(color: prominent ? tint.opacity(0.45) : .clear, radius: 6)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - The quiet state

/// The screen the user sees most of the time, and deliberately so.
///
/// Four vertical pages under the crown: what you have drunk, how long you have
/// been sitting, what the phone has consolidated for today, and a statement that
/// the silence is the product. Nothing here asks for attention, and the cool wash
/// behind it says as much.
///
/// The log sits third rather than last on purpose: the silence page is the
/// closing statement about restraint, and putting a scrolling list after it would
/// bury the one page that explains why the others are so quiet.
struct QuietView: View {
    var body: some View {
        TabView {
            HydrationPage()
            SittingPage()
            LogPage()
            SilencePage()
            DemoWristPage()
        }
        .tabViewStyle(.verticalPage)
    }
}

// MARK: - Demo wrist

/// Demo mode's signal source, on the wrist. Last in the stack and labelled
/// DEMO, so it is never mistaken for a reading this watch measured.
///
/// Stream sends a simulated minute every two seconds; the three buttons jump
/// the script to the moments worth showing an audience. The phone ignores all
/// of it unless its own Demo day is on.
private struct DemoWristPage: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                WatchPill(text: "Demo wrist", icon: "theatermasks.fill", tint: Kairo.violet)

                HStack(spacing: 6) {
                    reading("\(model.demo.sittingMinutes)", "MIN", Kairo.amber)
                    reading("\(model.demo.heartRateBPM)", "BPM", Kairo.coral)
                    reading(stepsText, "STEPS", Kairo.teal)
                }

                Button {
                    model.setDemoStreaming(!model.demoStreaming)
                } label: {
                    Label(model.demoStreaming ? "Stop stream" : "Stream",
                          systemImage: model.demoStreaming ? "stop.fill" : "dot.radiowaves.left.and.right")
                        .font(.wButton)
                        .frame(maxWidth: .infinity)
                }
                .tint(model.demoStreaming ? Kairo.coral : Kairo.leaf)

                HStack(spacing: 5) {
                    demoButton("chair.fill", "+15 min sitting") { model.demoSitLonger() }
                    demoButton("figure.walk", "Stand up") { model.demoStandUp() }
                    demoButton("heart.fill", "Heart rate spike") { model.demoHeartRateSpike() }
                }

                Text(model.demoDelivered
                     ? "Simulated readings. Your phone needs Demo day on."
                     : "Phone out of reach: that reading was not sent.")
                    .font(.wMicro)
                    .foregroundStyle(model.demoDelivered ? Kairo.inkFaint : Kairo.coral)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 2)
        }
        .navigationTitle("Demo")
        .containerBackground(Kairo.quietWash, for: .navigation)
    }

    private var stepsText: String {
        let s = model.demo.stepsToday
        return s >= 1_000 ? String(format: "%.1fk", Double(s) / 1_000) : "\(s)"
    }

    private func reading(_ value: String, _ unit: String, _ tint: Color) -> some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.wTitle).monospacedDigit()
                .foregroundStyle(Kairo.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            Text(unit).font(.wMicro).foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func demoButton(_ icon: String, _ label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 30)
        }
        .accessibilityLabel(label)
    }
}

/// CF8 - one tap, no keyboard, no confirmation screen.
private struct HydrationPage: View {
    @Environment(WatchModel.self) private var model

    private let quickLogs = [200, 350, 500]

    private var progress: Double {
        Double(model.waterMillilitres) / Double(max(model.waterTargetMillilitres, 1))
    }

    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)

            WatchRing(progress: progress, tint: Kairo.sky, to: Kairo.teal,
                      size: 82, lineWidth: 8) {
                VStack(spacing: -3) {
                    Text("\(model.waterMillilitres)")
                        .font(.wNumber)
                        .foregroundStyle(Kairo.ink)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text("ML")
                        .font(.wLabel).tracking(1.2)
                        .foregroundStyle(Kairo.inkFaint)
                }
                .padding(.horizontal, 4)
            }
            .animation(.snappy, value: model.waterMillilitres)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(model.waterMillilitres) of "
                                + "\(model.waterTargetMillilitres) millilitres")

            // The target comes from the phone with the total, so the caption is
            // never measuring against a number the phone does not share.
            HStack(spacing: 3) {
                Text("of \(model.waterTargetMillilitres) ml")
                // A tap ahead of the phone is stated, quietly and without
                // motion: CF8 is one tap and done, so this is a mark on the
                // caption rather than anything that spins or blocks.
                if model.hasUnacknowledgedWater {
                    Image(systemName: "arrow.up.circle")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .font(.wCaption)
            .foregroundStyle(Kairo.inkFaint)
            // The ring above already reads out the total and the target, so this
            // line is only worth announcing when it is saying something new.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Your last tap has not reached your phone yet.")
            .accessibilityHidden(!model.hasUnacknowledgedWater)

            HStack(spacing: 5) {
                ForEach(quickLogs, id: \.self) { ml in
                    Button {
                        model.logWater(ml)
                    } label: {
                        Text("+\(ml)")
                            .font(.wButton)
                            .foregroundStyle(Kairo.sky)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .background(Capsule().fill(Kairo.sky.opacity(0.2)))
                            .overlay(Capsule().strokeBorder(Kairo.sky.opacity(0.35),
                                                            lineWidth: 0.5))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Log \(ml) millilitres")
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .navigationTitle("Water")
        .containerBackground(Kairo.quietWash, for: .navigation)
    }
}

/// Sitting time against the hour that earns a break.
///
/// The phone measures sitting, not the watch, and it now says so over the wire:
/// this page renders `DayState.sedentaryMinutes`. nil and zero are different
/// answers and read differently - nil is "your phone has not told us", zero is
/// "you have not been sitting" - so an unmeasured day never borrows the look of
/// a measured one.
private struct SittingPage: View {
    @Environment(WatchModel.self) private var model

    private let breakThreshold = 60

    /// nil until the phone sends a figure.
    private var minutes: Int? { model.sedentaryMinutes }

    private func tint(_ m: Int) -> Color {
        if m > breakThreshold { return Kairo.coral }
        if m >= 45 { return Kairo.amber }
        return Kairo.teal
    }

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)

            WatchRing(progress: minutes.map { Double($0) / Double(breakThreshold) } ?? 0,
                      tint: minutes.map(tint) ?? Kairo.inkFaint,
                      size: 82, lineWidth: 8) {
                if let m = minutes {
                    VStack(spacing: -3) {
                        Text("\(m)")
                            .font(.wNumber)
                            .foregroundStyle(Kairo.ink)
                            .contentTransition(.numericText())
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text("MIN")
                            .font(.wLabel).tracking(1.2)
                            .foregroundStyle(Kairo.inkFaint)
                    }
                } else {
                    Image(systemName: "figure.stand")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Kairo.inkFaint)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(minutes.map {
                "\($0) minutes sitting, break at \(breakThreshold)"
            } ?? "Your phone has not sent a sitting time yet")

            if let m = minutes {
                Text(m > breakThreshold
                     ? "past the \(breakThreshold)-minute break"
                     : "of \(breakThreshold) min before a break")
                    .font(.wCaption)
                    .foregroundStyle(m > breakThreshold ? Kairo.coral : Kairo.inkFaint)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
            } else {
                VStack(spacing: 2) {
                    Text("Nothing logged from your phone yet.")
                        .font(.wCaption)
                        .foregroundStyle(Kairo.inkSoft)
                    Text("The phone measures sitting, not the watch.")
                        .font(.wCaption)
                        .foregroundStyle(Kairo.inkFaint)
                }
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 6)
            }

            Spacer(minLength: 0)
        }
        .navigationTitle("Sitting")
        .containerBackground(Kairo.quietWash, for: .navigation)
    }
}

// MARK: - The day's log

/// Today, as the phone has it.
///
/// Read-only by design. The wrist consolidates nothing: every line here - the
/// headline and the already-formatted figure beside it - was composed on the
/// phone, which is the only side that knows where a number came from and what
/// the evidence gate permits to be said about it. The header states that out
/// loud, because "this is your phone's figure" is precisely what makes the two
/// screens agree instead of quietly disagreeing.
///
/// There is no motion on this page - no `contentTransition`, no `symbolEffect`.
/// A list that re-animates every time the phone re-sends the same digest is
/// noise, and Reduce Motion would have to switch it off anyway; the only moving
/// thing is the connecting mark in the empty state, which already stands still
/// under Reduce Motion.
private struct LogPage: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        // Read the clock once per render so every row in the list measures its
        // "14 min ago" from the same instant.
        let now = Date()

        return ScrollView {
            if let log = model.log, !log.isEmpty {
                VStack(spacing: 4) {
                    header(log)
                    ForEach(log.entries) { entry in
                        LogRow(entry: entry, now: now)
                    }
                }
                .padding(.horizontal, 2)
            } else {
                emptyState
                    .padding(.horizontal, 4)
                    .padding(.top, 10)
            }
        }
        .navigationTitle("Today")
        .containerBackground(Kairo.quietWash, for: .navigation)
    }

    // MARK: The summary

    private func header(_ log: DayLog) -> some View {
        VStack(spacing: 3) {
            // Whose figures these are, said before any of them are shown. The
            // watch holds no history of its own, and a total presented without
            // its owner is how the two screens ended up looking like two days.
            WatchPill(text: "from your phone", icon: "iphone", tint: Kairo.inkSoft)

            HStack(spacing: 4) {
                Image(systemName: "drop.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Kairo.sky)
                Text("\(log.waterMillilitres) of \(log.waterTargetMillilitres) ml")
                    .font(.wCaption)
                    .foregroundStyle(Kairo.ink)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Your phone counts \(log.waterMillilitres) of "
                                + "\(log.waterTargetMillilitres) millilitres")

            // nil is "not measured" and never a zero. A morning nobody logged is
            // not a morning without food, and a night nothing recorded is not a
            // night without sleep - so the absent case says so in words rather
            // than drawing a confident 0.
            summaryLine(icon: "flame.fill", tint: Kairo.leaf,
                        figure: log.kilojoulesLogged.map { kj in
                            log.kilojoulesTarget.map { "\(Int(kj)) of \(Int($0)) kJ" }
                                ?? "\(Int(kj)) kJ"
                        },
                        absent: "energy not measured")

            summaryLine(icon: "moon.fill", tint: Kairo.violet,
                        figure: log.sleepHoursLastNight.map {
                            String(format: "%.1f h last night", $0)
                        },
                        absent: "sleep not measured")

            // CF7 - what the day actually cost you in attention. The one figure
            // on this page that is about Kairo rather than about the user, and
            // the only one with no absent case: both halves are non-optional on
            // `DayLog`, because the phone always knows what it has spent.
            summaryLine(icon: "bell.fill", tint: Kairo.amber,
                        figure: "\(log.interruptionsSpent) of \(log.dailyBudget) interruptions")

            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 0.5)
                .padding(.top, 2)
        }
    }

    /// One secondary figure, or an honest statement that there is none.
    private func summaryLine(icon: String, tint: Color,
                             figure: String?,
                             absent: String = "not measured") -> some View {
        let measured = figure != nil
        return HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(measured ? tint : Kairo.inkFaint)
                .frame(width: 11)
            Text(figure ?? absent)
                .font(.wMicro)
                // The unmeasured line is dimmer than the measured one, so a gap
                // in the evidence never borrows the look of a reading.
                .foregroundStyle(measured ? Kairo.inkSoft : Kairo.inkFaint)
        }
        .lineLimit(1)
        // 0.85 rather than lower: this line is already 9pt, and shrinking it
        // further to fit a long phrase would trade a readable figure for an
        // unreadable one. Every phrase here measures inside 40mm as written.
        .minimumScaleFactor(0.85)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: The two silences

    /// "The phone has not sent anything yet" and "nothing was logged today" are
    /// not the same answer, and this page is not allowed to collapse them: the
    /// first is about the link, the second is a claim about the user's day. The
    /// model knows its `linkState`, so the link cases can be told apart too -
    /// still connecting is genuinely still loading, out of range is not.
    private var emptyState: some View {
        VStack(spacing: 7) {
            if model.log == nil, model.linkState == .activating {
                WatchMarkLoader(size: 38)
            } else if model.log == nil {
                WatchMark(size: 38, monochrome: Kairo.inkSoft)
            } else {
                Image(systemName: "tray")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Kairo.teal)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Kairo.teal.opacity(0.16)))
            }

            Text(emptyTitle)
                .font(.wTitle)
                .foregroundStyle(Kairo.ink)

            Text(emptyNote)
                .font(.wCaption)
                .foregroundStyle(Kairo.inkSoft)
        }
        .multilineTextAlignment(.center)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity)
    }

    private var emptyTitle: String {
        guard model.log != nil else { return "No log from your phone yet." }
        // A digest that arrived and is empty is a real answer about the day.
        return "Nothing logged today."
    }

    private var emptyNote: String {
        guard model.log != nil else {
            switch model.linkState {
            case .activating:
                return "Still connecting. The day's log lives on your phone."
            case .unreachable:
                return "Your phone is out of range right now."
            case .linked:
                return "Your phone is connected and has not sent one."
            }
        }
        return "That is your phone's account of today, and it is empty."
    }
}

/// One logged thing: what it was, when, and the figure the phone put on it.
private struct LogRow: View {
    let entry: DayLog.Entry
    let now: Date

    /// Below this the figure was not arrived at by measuring. The number is
    /// `EnergySummary.portionForm`'s own floor - under 0.65 a day's energy may
    /// only be spoken as a range, never as a point - so a point figure resting on
    /// evidence that weak has to *look* weak here, or the wrist has laundered a
    /// guess into a clean number.
    private static let weakConfidence = 0.65

    private var isWeak: Bool {
        guard let c = entry.confidence else { return false }
        return c < Self.weakConfidence
    }

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            Image(systemName: Kairo.icon(for: entry.kind))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Kairo.colour(for: entry.kind))
                // A fixed box, so a wide glyph cannot shove the text sideways and
                // a narrow one cannot leave the column ragged. Nothing here is
                // allowed to clip or to scroll horizontally.
                .frame(width: 15)

            VStack(alignment: .leading, spacing: 0) {
                Text(entry.headline)
                    .font(.wCaption)
                    .foregroundStyle(Kairo.ink)
                Text(Self.relative(entry.at, from: now))
                    .font(.wMicro)
                    .foregroundStyle(Kairo.inkFaint)
            }
            .lineLimit(1)
            // The longest headline the phone composes is "Wind down nudge", which
            // fits beside the widest figure at full size on a 40mm screen. This
            // is a floor for an unusually long one, not the normal case, and it
            // stops at 0.8 because the timestamp under it is only 9pt.
            .minimumScaleFactor(0.8)

            Spacer(minLength: 3)

            if let detail = entry.detail {
                // A weak figure is shown as weak rather than dressed up: dimmed,
                // and prefixed so it reads as "about that" instead of "that".
                Text(isWeak ? "≈\(detail)" : detail)
                    .font(.wCaption)
                    .foregroundStyle(isWeak ? Kairo.inkFaint : Kairo.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.white.opacity(0.06)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var out = entry.headline
        if let detail = entry.detail {
            // VoiceOver gets the hedge as a word. A dimmed number reads as a
            // number when it is spoken, so "roughly" has to be said.
            out += isWeak ? ", roughly \(detail)" : ", \(detail)"
        }
        return out + ", " + Self.relative(entry.at, from: now)
    }

    /// Hand-rolled rather than `RelativeDateTimeFormatter`, for two reasons: the
    /// formatter's short styles put a full stop inside the phrase ("14 min. ago"),
    /// and its output length varies enough to push a row off a 40mm screen. The
    /// app's copy is written in Australian English throughout, so a fixed phrasing
    /// is no less honest than a localised one here.
    static func relative(_ then: Date, from now: Date) -> String {
        let seconds = now.timeIntervalSince(then)
        // A timestamp from the phone can sit a second or two ahead of the watch's
        // clock. "In 2 seconds" would be nonsense, so the future rounds to now.
        guard seconds >= 60 else { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) h ago" }
        return "\(hours / 24) d ago"
    }
}

/// The silence, stated. Kairo makes a promise about restraint on the phone; the
/// wrist is where that promise is either kept or broken, so it says so here.
/// Arbitration happens on the phone - the watch buzzes only when a bid wins.
private struct SilencePage: View {
    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)

            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Kairo.teal)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Kairo.teal.opacity(0.16)))
                .overlay(Circle().strokeBorder(Kairo.teal.opacity(0.3), lineWidth: 0.5))
                .symbolEffect(.pulse)

            Text("Nothing worth interrupting you for right now.")
                .font(.wTitle)
                .foregroundStyle(Kairo.ink)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)

            Text("That is the app working, not the app broken.")
                .font(.wCaption)
                .foregroundStyle(Kairo.inkSoft)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .navigationTitle("Kairo")
        .containerBackground(Kairo.quietWash, for: .navigation)
    }
}

// MARK: - Previews

#Preview("Nudge") {
    NavigationStack {
        NudgeCard(nudge: WatchModel.PendingNudge(
            bidID: "preview-sedentary",
            text: "You've been sitting an hour. Stand and stretch for two minutes.",
            nudgeClass: "sedentary",
            rewrittenFrom: "Take a brisk five-minute walk"))
    }
    .environment(WatchModel())
}

#Preview("Nudge, not substituted") {
    NavigationStack {
        NudgeCard(nudge: WatchModel.PendingNudge(
            bidID: "preview-hydration",
            text: "A glass of water now would put you back on track.",
            nudgeClass: "hydration",
            rewrittenFrom: nil))
    }
    .environment(WatchModel())
}

#Preview("Quiet, nothing from the phone") {
    NavigationStack {
        QuietView()
    }
    .environment(WatchModel())
}

#Preview("Quiet, phone counting") {
    NavigationStack {
        QuietView()
    }
    .environment(WatchModel.preview(linkState: .linked, water: 1_200,
                                    sedentaryMinutes: 52))
}

/// The window between a tap and the phone confirming it: the total already
/// includes the sip, and the caption says it has not landed yet.
#Preview("Quiet, tap ahead of the phone") {
    NavigationStack {
        QuietView()
    }
    .environment(WatchModel.preview(linkState: .unreachable, water: 1_200,
                                    sedentaryMinutes: 0, unacknowledged: 350))
}

// MARK: Log page previews

/// A day the phone has something to say about, including the two cases the page
/// exists to get right: an unmeasured figure stated as unmeasured, and a weak
/// figure shown as weak.
#Preview("Log, a real day") {
    NavigationStack {
        LogPage()
    }
    .environment(WatchModel.preview(linkState: .linked, log: PreviewLog.day))
}

/// The phone answered, and the answer is that nothing has been logged. Different
/// from the phone not having answered.
#Preview("Log, nothing logged today") {
    NavigationStack {
        LogPage()
    }
    .environment(WatchModel.preview(linkState: .linked, log: PreviewLog.empty))
}

#Preview("Log, phone has not sent one") {
    NavigationStack {
        LogPage()
    }
    .environment(WatchModel.preview(linkState: .linked))
}

#Preview("Log, still connecting") {
    NavigationStack {
        LogPage()
    }
    .environment(WatchModel.preview(linkState: .activating))
}

#Preview("Log, phone out of range") {
    NavigationStack {
        LogPage()
    }
    .environment(WatchModel.preview(linkState: .unreachable))
}

/// Fixtures, and labelled as such: these are what the *phone* would compose, not
/// figures the watch is capable of producing. The `.meal` and `.sleep` entries
/// exist here to prove the row renders them - the live phone sends neither yet,
/// because it holds no meal ledger. See `AppModel.dayLog()`.
///
/// Guarded to match `WatchModel.preview`, so no fixture is ever compiled into a
/// shipping watch app.
#if DEBUG
private enum PreviewLog {
    static var day: DayLog {
        let now = Date()
        return DayLog(
            generatedAt: now,
            entries: [
                .init(id: "1", kind: .water, at: now.addingTimeInterval(-14 * 60),
                      headline: "Water", detail: "350 ml"),
                .init(id: "2", kind: .interruption, at: now.addingTimeInterval(-52 * 60),
                      headline: "Sitting nudge"),
                // A figure that came from an eyeballed portion: shown dimmed and
                // hedged rather than as a clean number.
                .init(id: "3", kind: .meal, at: now.addingTimeInterval(-3 * 3_600),
                      headline: "Lunch", detail: "2,410 kJ", confidence: 0.45),
                .init(id: "4", kind: .water, at: now.addingTimeInterval(-4 * 3_600),
                      headline: "Water", detail: "500 ml"),
                .init(id: "5", kind: .sleep, at: now.addingTimeInterval(-9 * 3_600),
                      headline: "Woke", detail: "7.2 h", confidence: 0.9),
            ],
            waterMillilitres: 1_450,
            waterTargetMillilitres: 2_000,
            // nil on both, exactly as the live phone sends them today.
            kilojoulesLogged: nil,
            kilojoulesTarget: nil,
            sleepHoursLastNight: 7.2,
            interruptionsSpent: 2,
            dailyBudget: 6)
    }

    static var empty: DayLog {
        DayLog(generatedAt: Date(), waterMillilitres: 0, waterTargetMillilitres: 2_000)
    }
}
#endif
