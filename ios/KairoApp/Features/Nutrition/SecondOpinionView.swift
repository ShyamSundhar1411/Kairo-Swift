import SwiftUI
import KairoKit

/// Member A — CF3. The card that shows the roles disagreeing rather than
/// averaging them into one bland sentence.
///
/// Both positions get the same amount of room and the same legibility. Only the
/// badge and the ruling say which one carried, because the claim being made here
/// is that Kairo shows you the disagreement instead of blending it away.
struct SecondOpinionView: View {
    let disagreement: DisagreementCase
    let outcome: DisagreementOutcome

    var body: some View {
        VStack(alignment: .leading, spacing: Kairo.Space.stack) {
            topicCard

            ForEach(Array(disagreement.positions.enumerated()), id: \.offset) { _, p in
                PositionRow(position: p, isWinner: p == winner)
            }

            rulingCard
        }
    }

    // MARK: - Topic

    private var topicCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Kairo.violet)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Kairo.violet.opacity(0.14)))
                Text("Two of my roles disagreed")
                    .font(.kairoHeadline)
                    .foregroundStyle(Kairo.ink)
                Spacer(minLength: 0)
            }

            Text(disagreement.topic)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(Kairo.ink)
                .fixedSize(horizontal: false, vertical: true)

            // The written policy that decides it, shown rather than described.
            VStack(alignment: .leading, spacing: 6) {
                Text("PRECEDENCE POLICY")
                    .font(.kairoLabel).tracking(1.1)
                    .foregroundStyle(Kairo.inkFaint)
                HStack(spacing: 5) {
                    ForEach(Array(Objective.byPrecedence.enumerated()), id: \.offset) { i, o in
                        if i > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Kairo.inkFaint)
                        }
                        Pill(text: o.rawValue, icon: o.icon, tint: o.tint)
                    }
                    Spacer(minLength: 0)
                }
            }

            Text("\(disagreement.rounds) rebuttal rounds · capped at \(DisagreementCase.maxRounds)")
                .font(.kairoMono)
                .foregroundStyle(Kairo.inkFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kairoCard(tint: Kairo.violet)
    }

    // MARK: - Ruling

    private var rulingCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: rulingIcon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(rulingTint)
                .frame(width: 42, height: 42)
                .background(Circle().fill(rulingTint.opacity(0.14)))

            VStack(alignment: .leading, spacing: 4) {
                Text(rulingTitle)
                    .font(.kairoHeadline)
                    .foregroundStyle(Kairo.ink)
                Text(rulingText)
                    .font(.footnote)
                    .foregroundStyle(Kairo.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kairoCard(tint: rulingTint)
    }

    private var winner: Position? {
        switch outcome {
        case let .converged(w), let .ruled(w, _): w
        case .referredToFounder: nil
        }
    }

    private var rulingText: String {
        switch outcome {
        case .converged:
            "They agreed after one round."
        case let .ruled(_, policy):
            "Resolved under the written precedence policy: \(policy)."
        case let .referredToFounder(reason):
            "Not mine to settle — sent to a human. \(reason)."
        }
    }

    private var rulingTitle: String {
        switch outcome {
        case .converged:         "They converged"
        case .ruled:             "Ruled on the record"
        case .referredToFounder: "Escalated to a human"
        }
    }

    private var rulingIcon: String {
        switch outcome {
        case .converged:         "arrow.triangle.merge"
        case .ruled:             "checkmark.seal.fill"
        case .referredToFounder: "person.crop.circle.badge.exclamationmark"
        }
    }

    private var rulingTint: Color {
        switch outcome {
        case let .converged(w):  Kairo.colour(forAgent: w.agent.rawValue)
        case let .ruled(w, _):   Kairo.colour(forAgent: w.agent.rawValue)
        case .referredToFounder: Kairo.amber
        }
    }
}

// MARK: - One position

/// One role's side of the argument, in that role's colour, so a screen of claims
/// reads as coming from two different places rather than one voice.
struct PositionRow: View {
    let position: Position
    let isWinner: Bool

    private var tint: Color { Kairo.colour(forAgent: position.agent.rawValue) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                AgentChip(agent: position.agent.rawValue)
                Pill(text: "for \(position.objective.rawValue)",
                     icon: position.objective.icon,
                     tint: position.objective.tint)
                Spacer(minLength: 0)
                if isWinner {
                    Pill(text: "carried", icon: "checkmark.seal.fill", tint: tint, solid: true)
                }
            }

            Text(position.claim)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Kairo.ink)
                .fixedSize(horizontal: false, vertical: true)

            if !position.evidence.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("EVIDENCE")
                        .font(.kairoLabel).tracking(1.1)
                        .foregroundStyle(Kairo.inkFaint)
                    ForEach(Array(position.evidence.enumerated()), id: \.offset) { _, e in
                        HStack(alignment: .top, spacing: 7) {
                            Circle()
                                .fill(tint.opacity(0.7))
                                .frame(width: 4, height: 4)
                                .padding(.top, 6)
                            Text(e)
                                .font(.caption)
                                .foregroundStyle(Kairo.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            VStack(spacing: 6) {
                ScoreMeter(value: position.confidence, tint: tint, height: 5)
                HStack {
                    Text(String(format: "confidence %.0f%%", position.confidence * 100))
                    Spacer()
                    Text(String(format: "cost if wrong %.2f", position.costIfWrong))
                }
                .font(.kairoMono)
                .foregroundStyle(Kairo.inkFaint)
            }

            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 9, weight: .bold))
                Text("Acting on this and being wrong costs \(costWord).")
            }
            .font(.caption2)
            .foregroundStyle(costTint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kairoCard(tint: tint)
        // The loser is dimmed nowhere. Averaging it away and greying it out are
        // the same mistake.
        .overlay(alignment: .topTrailing) {
            if isWinner {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(tint)
                    .padding(3)
                    .background(Circle().fill(Kairo.canvasLift))
                    .offset(x: 7, y: -7)
                    .accessibilityLabel("This position carried")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(Kairo.shortName(forAgent: position.agent.rawValue)) role, "
                            + "optimising for \(position.objective.rawValue)"
                            + (isWinner ? ", this position carried" : ""))
    }

    private var costWord: String {
        if position.costIfWrong >= 0.7 { return "a lot" }
        if position.costIfWrong >= 0.4 { return "a fair amount" }
        return "little"
    }

    private var costTint: Color {
        if position.costIfWrong >= 0.7 { return Kairo.coral }
        if position.costIfWrong >= 0.4 { return Kairo.amber }
        return Kairo.inkFaint
    }
}

// MARK: - Objective styling

private extension Objective {
    /// In the order the written policy ranks them.
    static var byPrecedence: [Objective] {
        allCases.sorted { $0.precedence < $1.precedence }
    }

    var tint: Color {
        switch self {
        case .safety:    Kairo.coral
        case .accuracy:  Kairo.sky
        case .adherence: Kairo.violet
        }
    }

    var icon: String {
        switch self {
        case .safety:    "shield.lefthalf.filled"
        case .accuracy:  "ruler"
        case .adherence: "repeat"
        }
    }
}
