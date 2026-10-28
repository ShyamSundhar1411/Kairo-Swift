import SwiftUI
import KairoKit

/// What Kairo is, shown once, before the first screen that assumes you know.
///
/// Kairo's premise is unusual enough that the Today screen is confusing without
/// it: a wellness app that shows you four things it decided *not* to say reads
/// as a bug until you know that losing is the normal outcome of a contest. The
/// app previously opened straight onto that screen and explained none of it.
///
/// Four pages, because four is what the idea actually needs — the budget, the
/// roster, the contest, and where the reasoning is happening. It is skippable
/// from the first page and never shown again once finished; nobody should have
/// to sit through a tour twice to get to their own data.
struct WelcomeTour: View {
    /// Persisted rather than held in memory: a tour that reappears after every
    /// cold launch is worse than no tour.
    @AppStorage("kairo.tour.completed") private var completed = false
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private static let pageCount = 5

    var body: some View {
        VStack(spacing: 0) {
            header
            TabView(selection: $page) {
                budgetPage.tag(0)
                rosterPage.tag(1)
                contestPage.tag(2)
                wherePage.tag(3)
                healthPage.tag(4)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            footer
        }
        .background(Kairo.canvas.ignoresSafeArea())
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            KairoDots(count: Self.pageCount, active: page)
            Spacer()
            if page < Self.pageCount - 1 {
                Button("Skip") { finish() }
                    .font(.kairoCaption)
                    .foregroundStyle(Kairo.inkSoft)
                    .accessibilityHint("Skips the introduction. You can read it again from the agents screen.")
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
    }

    private var footer: some View {
        Button {
            if page < Self.pageCount - 1 {
                withAnimation(.snappy) { page += 1 }
            } else {
                finish()
            }
        } label: {
            Text(page < Self.pageCount - 1 ? "Next" : "Start")
                .font(.kairoHeadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 17)
                .background(Kairo.teal, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .foregroundStyle(Kairo.canvas)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 26)
    }

    private func finish() {
        completed = true
        dismiss()
    }

    // MARK: - Pages

    private var budgetPage: some View {
        TourPage(
            eyebrow: "The idea",
            title: "Your attention has a budget.",
            copy: """
            Most apps treat an interruption as free, so they send one whenever they \
            have something to say. Kairo starts from the opposite assumption: you can \
            be interrupted a small number of times a day before you stop listening \
            altogether.

            So it sets a ceiling — and spends against it.
            """
        ) {
            // The dial is the app's own component, drawn with a real budget.
            // Showing the thing itself beats an illustration of the thing.
            AttentionDial(spent: 2, total: 6, size: 150)
                .frame(height: 190)
        }
    }

    private var rosterPage: some View {
        TourPage(
            eyebrow: "Who is deciding",
            title: "Five specialists, one slot.",
            copy: """
            Each role watches a different part of your day and can ask to interrupt \
            you. They cannot see each other's requests, so what reaches you is the \
            winner of a contest rather than whoever spoke first.

            Two of them never ask for your attention at all: the Curator remembers \
            what you have told Kairo, and the Steward checks every message before it \
            is sent.
            """
        ) {
            VStack(alignment: .leading, spacing: 15) {
                ForEach(AgentID.allCases, id: \.self) { agent in
                    HStack(spacing: 14) {
                        Image(systemName: Kairo.icon(forAgent: agent.rawValue))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Kairo.canvas)
                            .frame(width: 38, height: 38)
                            .background(Kairo.colour(forAgent: agent.rawValue), in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(Kairo.shortName(forAgent: agent.rawValue))
                                .font(.kairoHeadline)
                            Text(Self.remit[agent] ?? "")
                                .font(.kairoCaption)
                                .foregroundStyle(Kairo.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var contestPage: some View {
        TourPage(
            eyebrow: "What you will see",
            title: "The ones that lost are listed too.",
            copy: """
            On Today, every request from this round appears on one shared scale — the \
            one that won at full strength, the rest faded, each with the reason it was \
            held back.

            Nothing is hidden from you, including the times Kairo decided the most \
            useful thing it could do was stay quiet. Tap any of them to see the full \
            record: which role asked, what it was looking at, and what the Steward did \
            with the wording.
            """
        ) {
            VStack(spacing: 11) {
                TourBar(name: "Nutrition", colour: Kairo.leaf, width: 0.92,
                        note: "delivered", noteColour: Kairo.teal)
                TourBar(name: "Coach", colour: Kairo.amber, width: 0.61,
                        note: "a more useful interruption won this slot")
                TourBar(name: "Memory", colour: Kairo.violet, width: 0.38,
                        note: "a similar interruption was already delivered")
            }
        }
    }

    private var wherePage: some View {
        TourPage(
            eyebrow: "Where the reasoning happens",
            title: "On your machine, if you want.",
            copy: """
            Kairo looks for an agent backend on this machine first and connects on its \
            own. If that backend is open — the usual case on your own Mac — there is \
            nothing to set up. If it asks for a token, paste it on the Agents screen; \
            a backend serving your phone over wifi always will, because the alternative \
            is leaving your habit memories open to the network.

            Either way the five roles do the reasoning there. A model running locally \
            costs nothing and sends nothing anywhere.

            If it finds none, the app still works: a smaller version of the same \
            arbiter runs on the phone. Today's header always says which of the two you \
            are getting, because five reasoning roles and a local heuristic should \
            never look identical.
            """
        ) {
            VStack(alignment: .leading, spacing: 12) {
                TourState(chip: "5 agents", colour: Kairo.teal,
                          meaning: "The roles are answering.")
                TourState(chip: "this phone", colour: Kairo.inkSoft,
                          meaning: "No backend found. On-device arbiter.")
                TourState(chip: "agents refusing", colour: Kairo.coral,
                          meaning: "Backend is up and says what is wrong.")
                TourState(chip: "needs a token", colour: Kairo.amber,
                          meaning: "Found one, but it wants a key. Agents screen.")
            }
        }
    }

    /// Last, immediately before iOS asks. A permission sheet is a bad place to
    /// learn what an app does with the data, and NFR5 — that the raw series
    /// never leave this phone — is the single most reassuring fact Kairo has.
    /// Saying it here, unprompted, is worth more than any wording in the sheet.
    private var healthPage: some View {
        TourPage(
            eyebrow: "One last thing",
            title: "Kairo needs to read your Health data.",
            copy: """
            Sleep, movement, heart rate and the energy you log. Without them the \
            roles have nothing to reason about and will correctly decide to say \
            nothing at all.

            The raw readings never leave this phone. What goes to the agents is a \
            short summary — how long you have been sitting, how far behind your water \
            you are — never the underlying series, and never a health-sensitive \
            memory. You can refuse, and the app will keep working with less to go on.

            Tapping Start will bring up iOS's own permission sheet.
            """
        ) {
            VStack(alignment: .leading, spacing: 12) {
                TourState(chip: "stays here", colour: Kairo.teal,
                          meaning: "Raw HealthKit series, your Memory Book, every correction.")
                TourState(chip: "goes out", colour: Kairo.amber,
                          meaning: "A summary: minutes sitting, ml behind, hours of sleep debt.")
            }
        }
    }

    private static let remit: [AgentID: String] = [
        .coach:     "Hydration, and whether a nudge is worth its cost.",
        .nutrition: "Meals, energy, and what to eat next.",
        .lifestyle: "Sleep debt, sitting, and movement.",
        .memory:    "Remembers your patterns. Never interrupts.",
        .steward:   "Screens every message. Can refuse one outright.",
    ]
}

// MARK: - Pieces

/// One page: fixed furniture, variable illustration. Scrolls because the body
/// copy is real prose and has to survive an accessibility text size.
private struct TourPage<Illustration: View>: View {
    let eyebrow: String
    let title: String
    let copy: String
    @ViewBuilder var illustration: Illustration

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(eyebrow.uppercased())
                    .font(.kairoLabel).tracking(2.6)
                    .foregroundStyle(Kairo.inkSoft)
                Text(title)
                    .font(.kairoTitle)
                    .fixedSize(horizontal: false, vertical: true)
                illustration
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(copy)
                    .font(.kairoBody)
                    .foregroundStyle(Kairo.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)
        }
    }
}

private struct TourBar: View {
    let name: String
    let colour: Color
    let width: Double
    let note: String
    var noteColour: Color = Kairo.inkSoft

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Text(name).font(.kairoCaption).foregroundStyle(colour)
                Spacer(minLength: 0)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Kairo.inkFaint.opacity(0.25))
                    Capsule().fill(colour).frame(width: geo.size.width * width)
                }
            }
            .frame(height: 9)
            Text(note)
                .font(.kairoCaption)
                .foregroundStyle(noteColour)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct TourState: View {
    let chip: String
    let colour: Color
    let meaning: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(chip)
                .font(.kairoCaption)
                .foregroundStyle(colour)
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(colour.opacity(0.14), in: Capsule())
            Text(meaning)
                .font(.kairoCaption)
                .foregroundStyle(Kairo.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct KairoDots: View {
    let count: Int
    let active: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == active ? Kairo.teal : Kairo.inkFaint.opacity(0.4))
                    .frame(width: i == active ? 22 : 7, height: 7)
            }
        }
        .animation(.snappy, value: active)
        .accessibilityLabel("Page \(active + 1) of \(count)")
    }
}
