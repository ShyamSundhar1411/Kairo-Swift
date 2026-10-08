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
    /// The bid the user tapped to get here, when they came from the ledger. Its
    /// row is marked so the screen answers the question that was asked rather
    /// than presenting a list and leaving them to find their way back.
    var focus: String?

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

    /// The subject of this screen is what was decided. It used to be `record.id`
    /// at 22pt monospace — a database key as the headline of the one screen
    /// whose entire job is to be readable by the person it is about.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("WHAT KAIRO DECIDED")
                        .font(.kairoLabel).tracking(1.1)
                        .foregroundStyle(Kairo.inkFaint)
                    Text(headline)
                        .font(.kairoTitle)
                        .foregroundStyle(Kairo.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.kairoCaption)
                        .foregroundStyle(Kairo.inkSoft)
                }
                Spacer(minLength: 8)
                Image(systemName: record.isSealed ? "lock.fill" : "pencil.and.outline")
                    .font(.kairoGlyph(15, weight: .semibold))
                    .foregroundStyle(Kairo.violet)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Kairo.violet.opacity(0.14)))
            }

            PillWrap {
                if record.isSealed {
                    Pill(text: "sealed — cannot be edited", icon: "lock.fill", tint: Kairo.violet)
                } else {
                    Pill(text: "still being assembled", icon: "pencil", tint: Kairo.amber)
                }
                if let verdict = record.safetyVerdict {
                    Pill(text: safetyWords(verdict), icon: safetyIcon(verdict),
                         tint: safetyTint(verdict))
                }
            }

            if let tier = record.serviceTier {
                // The tier was drawn as `tier healthy` with a cpu glyph and no
                // explanation — a rung on the cost ladder, printed at a user
                // who has never been told there is a ladder. Either it is
                // explained or it goes; this explains it in one line.
                Text(tierExplanation(tier))
                    .font(.kairoCaption)
                    .foregroundStyle(Kairo.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kairoCard(tint: Kairo.violet)
    }

    /// One sentence naming the outcome, built from the record rather than from
    /// whatever screen pushed this one.
    private var headline: String {
        let rejected = record.rejectedAlternatives.count
        guard rejected > 0 else {
            return record.fragments.isEmpty
                ? "Nothing was decided in this pass"
                : "\(record.fragments.count) roles weighed in and nothing was worth saying"
        }
        return rejected == 1
            ? "One bid was turned down"
            : "\(rejected) bids were turned down"
    }

    /// The six-member safety enum, in words. `nothingToScreen` and `unscreened`
    /// are not passes: one means no message existed to judge, the other that no
    /// Steward was bound — and showing either as a green tick would be the app
    /// claiming a safety result nobody produced.
    private func safetyWords(_ verdict: String) -> String {
        switch verdict {
        case "pass":            "safety: cleared"
        case "rewritten":       "safety: rewritten before sending"
        case "blocked":         "safety: blocked"
        case "heldForHuman":    "safety: held for a person"
        case "nothingToScreen": "safety: nothing to screen"
        case "unscreened":      "safety: not screened"
        default:                "safety: \(spacedStateName(verdict))"
        }
    }

    private func safetyIcon(_ verdict: String) -> String {
        switch verdict {
        case "pass":            "checkmark.seal.fill"
        case "rewritten":       "pencil.and.outline"
        case "blocked":         "hand.raised.fill"
        case "heldForHuman":    "person.crop.circle.badge.exclamationmark"
        case "nothingToScreen": "tray"
        default:                "shield.slash"
        }
    }

    private func safetyTint(_ verdict: String) -> Color {
        switch verdict {
        case "pass":                      Kairo.leaf
        case "rewritten":                 Kairo.sky
        case "blocked", "heldForHuman":   Kairo.coral
        // Neither a pass nor a failure. Drawn as neither.
        case "nothingToScreen":           Kairo.inkFaint
        default:                          Kairo.amber
        }
    }

    private func tierExplanation(_ tier: String) -> String {
        "Decided at the \(tier) rung of the cost ladder — how much reasoning Kairo "
        + "is allowed to spend this month, which drops as the ceiling is approached. "
        + "Safety screening and your memory never degrade."
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
                RejectedRow(alternative: r, isFocused: r.bidID == focus)
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

                // A role that was recorded as contributing but said nothing is
                // drawn as exactly that. It used to be an empty line, which read
                // as a rendering bug rather than as a fact about the record.
                Text(fragment.claim.isEmpty
                     ? "contributed to this pass without a recorded claim"
                     : fragment.claim)
                    .font(.kairoBody)
                    .foregroundStyle(fragment.claim.isEmpty ? Kairo.inkFaint : Kairo.ink)
                    .fixedSize(horizontal: false, vertical: true)

                ScoreMeter(value: fragment.confidence, tint: tint, height: 5)

                PillWrap {
                    Text(String(format: "%.0f%% confident", fragment.confidence * 100))
                        .font(.kairoCaption)
                        .foregroundStyle(Kairo.inkSoft)
                    Text("prompt \(fragment.promptVersion)")
                        .font(.kairoMono)
                        .foregroundStyle(Kairo.inkFaint)
                }
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
                Text(String(format: "cited at %.0f%% confidence",
                            citation.confidenceAtCitation * 100))
                    .font(.kairoHeadline)
                    .foregroundStyle(Kairo.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(citation.memoryID)
                    .font(.kairoMono)
                    .foregroundStyle(Kairo.inkFaint)
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

/// Reads the same sentence the Today ledger reads, because it is the same
/// decision. Both go through `SuppressionCopy`, which is the only place in the
/// app that turns a `SuppressionReason` into English — there used to be two
/// copies of that switch and they had already drifted.
private struct RejectedRow: View {
    let alternative: RejectedAlternative
    /// True for the bid the user tapped to get here.
    var isFocused = false

    private var classTint: Color { Kairo.colour(forNudgeClass: alternative.nudgeClass) }
    private var copy: SuppressionCopy.Copy {
        // The record carries no costing of its own, so the sentence here is the
        // metered one. A notional ceiling is explained on Today, where the
        // budget object that says so actually arrives.
        SuppressionCopy.copy(for: alternative.reason, costing: .metered)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Capsule()
                .fill(copy.tint)
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 7) {
                PillWrap {
                    Pill(text: Kairo.title(forNudgeClass: alternative.nudgeClass),
                         icon: Kairo.icon(forNudgeClass: alternative.nudgeClass),
                         tint: classTint)
                    if let badge = copy.badge {
                        Pill(text: badge.text, icon: badge.icon, tint: copy.tint, solid: true)
                    }
                    if isFocused {
                        Pill(text: "the one you tapped", icon: "hand.tap.fill",
                             tint: Kairo.violet)
                    }
                }

                Text(copy.sentence)
                    .font(.kairoBody)
                    .foregroundStyle(Kairo.ink)
                    .fixedSize(horizontal: false, vertical: true)

                ScoreMeter(value: alternative.score, tint: copy.tint, height: 4)
                    .opacity(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kairoCard(padding: 14, radius: Kairo.Radius.inner,
                   tint: isFocused ? Kairo.violet : (copy.badge == nil ? nil : copy.tint))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Kairo.title(forNudgeClass: alternative.nudgeClass)): "
                            + copy.sentence)
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
