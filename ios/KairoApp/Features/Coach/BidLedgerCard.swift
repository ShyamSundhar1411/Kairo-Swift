import SwiftUI
import KairoKit

/// Five agents bid; four lost. One card, two parts.
///
/// This replaces `deliveredSection` + `suppressedSection`, which were two
/// separate stacks each drawing its own `ScoreMeter` on its own 0–1 track. Four
/// gauges side by side imply four unrelated measurements; there was a contest,
/// and nothing on the screen showed it. Here every bid from the pass — won and
/// lost — is one row on **one shared horizontal axis**, ordered by score. The
/// longest bar won. That is the picture, rather than a caption under four
/// independent dials saying a contest happened.
///
/// Part A is the roster: five discs, always five, dimmed where a role stayed
/// silent. It is the only thing on any screen that makes "five bid and four
/// lost" *checkable* instead of a slogan — you can count the dim ones.
struct BidLedgerCard: View {
    let delivered: [Nudge]
    let suppressed: [Nudge]
    let costing: SuppressionCopy.Costing
    /// Tapping a row opens the decision record for this pass. nil while no pass
    /// has been recorded, which is the only state where a row is not tappable.
    let record: DecisionRecord?

    private var all: [Nudge] { (delivered + suppressed).sorted { $0.score > $1.score } }
    private var deliveredIDs: Set<String> { Set(delivered.map(\.bid.id)) }

    /// The axis every bar is drawn against. The top score, never less than the
    /// winner's — so the longest bar is the highest score and two bids at 0.71
    /// and 0.22 differ by the ~3.2× they actually differ by, rather than both
    /// being drawn against 1.0 and looking like two thirds of nothing.
    private var axis: Double { max(all.first?.score ?? 1, 0.0001) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            roster

            if delivered.isEmpty { SilenceCard() }

            if all.isEmpty {
                nothingBid
            } else {
                Rectangle().fill(Kairo.hairline.opacity(0.08)).frame(height: 0.5)
                ledger
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kairoCard(tint: delivered.isEmpty ? Kairo.teal : Kairo.amber)
    }

    // MARK: - Part A, the roster

    /// Always five. A role that bid is lit in its own colour; a role that stayed
    /// silent is drawn at a quarter opacity and still occupies its place, which
    /// is the whole point — an absence you cannot see is not evidence of
    /// restraint.
    private var roster: some View {
        let bidding = Set(all.map(\.bid.originAgent))
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("WHO BID").font(.kairoLabel).tracking(1.1)
                Spacer(minLength: 4)
                Text(bidding.isEmpty ? "none of five"
                     : "\(bidding.count) of \(AgentID.allCases.count)")
                    .font(.kairoLabel).tracking(0.6)
            }
            .foregroundStyle(Kairo.inkFaint)

            HStack(spacing: 10) {
                ForEach(AgentID.allCases, id: \.self) { agent in
                    AgentChip(agent: agent.rawValue, compact: true)
                        .opacity(bidding.contains(agent.rawValue) ? 1 : 0.25)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(rosterLabel(bidding))
        }
    }

    private func rosterLabel(_ bidding: Set<String>) -> String {
        let spoke = AgentID.allCases.filter { bidding.contains($0.rawValue) }
            .map { Kairo.shortName(forAgent: $0.rawValue) }
        let silent = AgentID.allCases.filter { !bidding.contains($0.rawValue) }
            .map { Kairo.shortName(forAgent: $0.rawValue) }
        if spoke.isEmpty { return "None of the five roles bid for your attention." }
        return "\(spoke.joined(separator: ", ")) bid. "
             + (silent.isEmpty ? "All five bid." : "\(silent.joined(separator: ", ")) stayed silent.")
    }

    // MARK: - Part B, the ledger

    private var ledger: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(delivered.isEmpty ? "WHAT IT HELD BACK" : "THE CONTEST")
                    .font(.kairoLabel).tracking(1.1)
                Spacer(minLength: 4)
                Text(all.count == 1 ? "1 bid" : "\(all.count) bids")
                    .font(.kairoLabel).tracking(0.6)
            }
            .foregroundStyle(Kairo.inkFaint)

            VStack(spacing: 0) {
                ForEach(Array(all.enumerated()), id: \.element.bid.id) { i, nudge in
                    BidRow(nudge: nudge,
                           won: deliveredIDs.contains(nudge.bid.id),
                           axis: axis,
                           costing: costing,
                           record: record)
                    if i < all.count - 1 {
                        Rectangle().fill(Kairo.hairline.opacity(0.06)).frame(height: 0.5)
                    }
                }
            }
        }
    }

    private var nothingBid: some View {
        Text("No role raised a bid this pass. Nothing was measured that was worth "
             + "an interruption.")
            .font(.kairoCaption)
            .foregroundStyle(Kairo.inkSoft)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - One bid

/// The winner at full weight with its text at headline size; losers at body
/// weight and reduced opacity, each with its reason and its agent's colour as a
/// left rail. One row component, used for both — because a contest drawn with
/// two different row designs is two lists that happen to be adjacent.
///
/// The chevron is FR12.4. Before this, `WhyView` was referenced exactly once in
/// the whole app — from the Memory tab — so the decision record for the pass the
/// user was looking at was two taps away behind a different screen.
struct BidRow: View {
    let nudge: Nudge
    let won: Bool
    /// The top score in the pass. Every bar in the ledger is drawn against this
    /// one number, which is what makes the lengths comparable.
    let axis: Double
    let costing: SuppressionCopy.Costing
    let record: DecisionRecord?

    private var classTint: Color { Kairo.colour(forNudgeClass: nudge.bid.nudgeClass) }
    private var railTint: Color { Kairo.colour(forAgent: nudge.bid.originAgent) }
    private var copy: SuppressionCopy.Copy {
        SuppressionCopy.copy(for: nudge.suppressionReason, costing: costing)
    }

    var body: some View {
        Group {
            if let record {
                NavigationLink { WhyView(record: record, focus: nudge.bid.id) } label: { row }
                    .buttonStyle(.kairoPress)
            } else {
                row
            }
        }
        .accessibilityElement(children: .ignore)
        // Criterion: role, bid text, then delivered-or-why — in that order, one
        // element per bid, so a VoiceOver user hears the contest as a list of
        // outcomes rather than as a pile of meters.
        .accessibilityLabel("\(Kairo.shortName(forAgent: nudge.bid.originAgent)). "
                            + "\(nudge.bid.text). "
                            + (won ? "Delivered." : "Not delivered: \(copy.sentence)."))
        .accessibilityAddTraits(record == nil ? [] : .isButton)
        .accessibilityHint(record == nil ? "" : "Opens the full decision record")
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 11) {
            Capsule()
                .fill(railTint.opacity(won ? 1 : 0.55))
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 7) {
                PillWrap {
                    AgentChip(agent: nudge.bid.originAgent)
                    Pill(text: Kairo.title(forNudgeClass: nudge.bid.nudgeClass),
                         icon: Kairo.icon(forNudgeClass: nudge.bid.nudgeClass), tint: classTint)
                    if won {
                        Pill(text: "delivered", icon: "bell.badge.fill",
                             tint: Kairo.amber, solid: true)
                    } else if let badge = copy.badge {
                        Pill(text: badge.text, icon: badge.icon, tint: copy.tint, solid: true)
                    }
                }

                Text(nudge.bid.text)
                    .font(won ? .kairoSubject : .kairoBody)
                    .foregroundStyle(Kairo.ink)
                    .fixedSize(horizontal: false, vertical: true)

                bar

                if !won {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: copy.icon).font(.kairoGlyph(9))
                            .padding(.top, 2)
                        Text(copy.sentence)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.kairoCaption)
                    .foregroundStyle(copy.tint)
                }
            }
            .opacity(won ? 1 : 0.72)

            if record != nil {
                Image(systemName: "chevron.right")
                    .font(.kairoGlyph(11))
                    .foregroundStyle(Kairo.inkFaint)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    /// The bar, against the pass's own top score rather than against 1.0. No
    /// number beside it: the bid's *rank* is what the user can act on, and 0.43
    /// is a float the user has no mental model for — and set in monospace it
    /// read as a debug build.
    private var bar: some View {
        ScoreMeter(value: nudge.score / axis,
                   tint: won ? Kairo.amber : railTint,
                   height: won ? 7 : 5)
            .opacity(won ? 1 : 0.75)
    }
}
