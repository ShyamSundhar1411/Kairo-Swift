import SwiftUI
import KairoKit

/// Member D — CF12. The direct answer to "are your five roles just five prompts?".
///
/// The record is append-only, so this screen never edits it — it lays out what
/// each role actually contributed, what Kairo believed about the user at the
/// moment it decided, and what it chose not to say. Five roles are drawn as five
/// visibly different sources, because that is the claim being audited.
struct WhyView: View {
    let record: DecisionRecord

    var body: some View {
        ScrollView {
            VStack(spacing: Kairo.Space.stack) {
                summary

                if !record.fragments.isEmpty { contributions }
                if !record.citations.isEmpty { citations }
                if !record.rejectedAlternatives.isEmpty { rejected }
                if !record.annotations.isEmpty { corrections }
                if isBare { bareNote }

                TrustNote(text: "This record cannot be edited — corrections are appended. "
                          + "Generation is not deterministic, so this explains the inputs "
                          + "and the routing, not a replay.",
                          icon: "doc.text.magnifyingglass")
            }
            .padding(.horizontal, Kairo.Space.stack)
            .padding(.top, 4)
            .padding(.bottom, 28)
        }
        .background(KairoCanvas())
        .navigationTitle("Why did you say that?")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    /// A sealed record with nothing in it is a real state; it gets a sentence
    /// rather than three empty titled sections.
    private var isBare: Bool {
        record.fragments.isEmpty
            && record.citations.isEmpty
            && record.rejectedAlternatives.isEmpty
    }

    // MARK: - Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("DECISION RECORD")
                        .font(.kairoLabel).tracking(1.1)
                        .foregroundStyle(Kairo.inkFaint)
                    Text(record.id)
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Kairo.ink)
                    Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(Kairo.inkSoft)
                }
                Spacer(minLength: 8)
                Image(systemName: record.isSealed ? "lock.fill" : "pencil.and.outline")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Kairo.violet)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Kairo.violet.opacity(0.14)))
            }

            PillWrap {
                Pill(text: spacedStateName(record.state.name),
                     icon: "circle.dashed", tint: Kairo.violet)
                if record.isSealed {
                    if record.state != .sealed {
                        Pill(text: "sealed", icon: "lock.fill", tint: Kairo.violet)
                    }
                } else {
                    Pill(text: "not sealed yet", icon: "pencil", tint: Kairo.amber)
                }
                if let verdict = record.safetyVerdict {
                    Pill(text: "safety \(verdict)", icon: "shield.lefthalf.filled",
                         tint: verdict == "pass" ? Kairo.leaf : Kairo.coral)
                }
                if let tier = record.serviceTier {
                    Pill(text: "tier \(tier)", icon: "cpu", tint: Kairo.sky)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kairoCard(tint: Kairo.violet)
    }

    private var bareNote: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Kairo.inkSoft)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Kairo.hairline.opacity(0.06)))
            Text("Nothing was recorded against this decision — no role contributed, "
                 + "nothing was cited, and no bid was turned down.")
                .font(.subheadline)
                .foregroundStyle(Kairo.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .kairoCard(padding: 14, radius: Kairo.Radius.inner)
    }

    // MARK: - Contributions

    private var contributions: some View {
        VStack(spacing: 8) {
            SectionHeader(title: "What each role contributed", icon: "person.2",
                          trailing: "\(record.fragments.count)", tint: Kairo.violet)

            VStack(spacing: 0) {
                ForEach(Array(record.fragments.enumerated()), id: \.offset) { i, f in
                    FragmentRow(fragment: f,
                                isFirst: i == 0,
                                isLast: i == record.fragments.count - 1)
                }
            }
            .kairoCard()
        }
    }

    // MARK: - Citations

    private var citations: some View {
        VStack(spacing: 8) {
            SectionHeader(title: "What it knew about you at the time", icon: "book.closed",
                          trailing: "\(record.citations.count)", tint: Kairo.teal)

            VStack(spacing: 14) {
                ForEach(Array(record.citations.enumerated()), id: \.offset) { _, c in
                    CitationRow(citation: c)
                }

                Rectangle()
                    .fill(Kairo.hairline.opacity(0.08))
                    .frame(height: 1)

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Kairo.inkFaint)
                        .padding(.top, 2)
                    Text("These are the confidences held when the decision was made, "
                         + "not the ones held now.")
                        .font(.caption)
                        .foregroundStyle(Kairo.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .kairoCard()
        }
    }

    // MARK: - Rejected

    private var rejected: some View {
        VStack(spacing: 8) {
            SectionHeader(title: "What it decided not to tell you", icon: "hand.raised",
                          trailing: "\(record.rejectedAlternatives.count)", tint: Kairo.teal)

            ForEach(Array(record.rejectedAlternatives.enumerated()), id: \.offset) { _, r in
                RejectedRow(alternative: r)
            }
        }
    }

    // MARK: - Corrections

    private var corrections: some View {
        VStack(spacing: 8) {
            SectionHeader(title: "Corrections since", icon: "text.append",
                          trailing: "\(record.annotations.count)", tint: Kairo.sky)

            VStack(spacing: 0) {
                ForEach(Array(record.annotations.enumerated()), id: \.offset) { i, a in
                    AnnotationRow(annotation: a,
                                  isFirst: i == 0,
                                  isLast: i == record.annotations.count - 1)
                }
            }
            .kairoCard(tint: Kairo.sky)
        }
    }
}

// MARK: - One role's contribution

/// A node on a vertical timeline. The rail is what makes five claims read as
/// five separate sources arriving in order, rather than one paragraph.
private struct FragmentRow: View {
    let fragment: ContributionFragment
    let isFirst: Bool
    let isLast: Bool

    private var tint: Color { Kairo.colour(forAgent: fragment.agentID) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Kairo.hairline.opacity(isFirst ? 0 : 0.12))
                    .frame(width: 1.5, height: 6)
                AgentChip(agent: fragment.agentID, compact: true)
                Rectangle()
                    .fill(Kairo.hairline.opacity(isLast ? 0 : 0.12))
                    .frame(width: 1.5)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 7) {
                Text(Kairo.shortName(forAgent: fragment.agentID))
                    .font(.kairoLabel).tracking(0.6)
                    .foregroundStyle(tint)

                Text(fragment.claim)
                    .font(.kairoBody)
                    .foregroundStyle(Kairo.ink)
                    .fixedSize(horizontal: false, vertical: true)

                ScoreMeter(value: fragment.confidence, tint: tint, height: 5)

                HStack(spacing: 6) {
                    Text("prompt \(fragment.promptVersion)")
                    Spacer(minLength: 4)
                    Text(String(format: "%.0f%% confident", fragment.confidence * 100))
                }
                .font(.kairoMono)
                .foregroundStyle(Kairo.inkFaint)
            }
            .padding(.bottom, isLast ? 0 : 18)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Kairo.shortName(forAgent: fragment.agentID)) said "
                            + "\(fragment.claim), "
                            + String(format: "%.0f per cent confident", fragment.confidence * 100)
                            + ", prompt \(fragment.promptVersion)")
    }
}

// MARK: - One citation

private struct CitationRow: View {
    let citation: MemoryCitation

    var body: some View {
        HStack(spacing: 12) {
            MetricRing(progress: citation.confidenceAtCitation,
                       tint: Kairo.teal,
                       centreText: "\(Int((citation.confidenceAtCitation * 100).rounded()))",
                       size: 42, lineWidth: 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(citation.memoryID)
                    .font(.kairoMono)
                    .foregroundStyle(Kairo.ink)
                Text(String(format: "cited at %.0f%% confidence",
                            citation.confidenceAtCitation * 100))
                    .font(.caption)
                    .foregroundStyle(Kairo.inkSoft)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Memory \(citation.memoryID), cited at "
                            + String(format: "%.0f per cent confidence",
                                     citation.confidenceAtCitation * 100))
    }
}

// MARK: - One rejected alternative

/// Mirrors `SuppressedCard` on Today deliberately: the same reason must read the
/// same way in the live view and in the record. In particular a cost decision is
/// labelled as a cost decision in the warning colour — it is never presented to
/// the user as restraint (Section 7.1).
private struct RejectedRow: View {
    let alternative: RejectedAlternative

    private var classTint: Color { Kairo.colour(forNudgeClass: alternative.nudgeClass) }
    private var isCost: Bool { alternative.reason == .costCeiling }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Capsule()
                .fill(reasonTint)
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: Kairo.icon(forNudgeClass: alternative.nudgeClass))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(classTint)
                    Text(Kairo.title(forNudgeClass: alternative.nudgeClass))
                        .font(.kairoHeadline)
                        .foregroundStyle(Kairo.ink)
                    Spacer(minLength: 0)
                    if isCost {
                        Pill(text: "cost", icon: "dollarsign.circle.fill",
                             tint: Kairo.coral, solid: true)
                    }
                    Text(String(format: "%.2f", alternative.score))
                        .font(.kairoMono)
                        .foregroundStyle(Kairo.inkFaint)
                }

                Text(explanation)
                    .font(.subheadline)
                    .foregroundStyle(Kairo.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)

                PillWrap {
                    Pill(text: spacedStateName(alternative.reason.rawValue),
                         icon: reasonIcon, tint: reasonTint)
                    Pill(text: alternative.bidID, icon: "number", tint: Kairo.inkFaint)
                }

                ScoreMeter(value: alternative.score, tint: reasonTint, height: 4)
                    .opacity(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kairoCard(padding: 14, radius: Kairo.Radius.inner, tint: isCost ? Kairo.coral : nil)
    }

    private var explanation: String {
        switch alternative.reason {
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
        }
    }

    private var reasonIcon: String {
        switch alternative.reason {
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
        }
    }

    private var reasonTint: Color {
        switch alternative.reason {
        case .costCeiling, .inaccessible: Kairo.coral
        case .budgetExhausted:            Kairo.amber
        case .quietHours:                 Kairo.violet
        case .classSuspended:             Kairo.teal
        default:                          Kairo.inkFaint
        }
    }
}

// MARK: - One correction

/// Append-only, so the trail grows downwards and nothing above it ever changes.
private struct AnnotationRow: View {
    let annotation: Annotation
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Kairo.hairline.opacity(isFirst ? 0 : 0.12))
                    .frame(width: 1.5, height: 6)
                Image(systemName: "plus")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Kairo.sky))
                Rectangle()
                    .fill(Kairo.hairline.opacity(isLast ? 0 : 0.12))
                    .frame(width: 1.5)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(annotation.text)
                    .font(.subheadline)
                    .foregroundStyle(Kairo.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(annotation.author) · "
                     + annotation.at.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(Kairo.inkFaint)
            }
            .padding(.bottom, isLast ? 0 : 16)

            Spacer(minLength: 0)
        }
    }
}
