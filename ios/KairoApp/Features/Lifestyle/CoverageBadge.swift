import SwiftUI
import KairoKit

/// Member B — CF6. Renders what the evidence actually supports. The badge is not
/// decoration: it is the same `AssertionForm` the Steward enforces on the text.
///
/// `AssertionForm` is an ordered ladder, so the badge draws it as one — a word for
/// the rung and five dots for how high that rung sits. "partial" on its own does
/// not tell you it is one step short of a bare number; the dots do.
struct CoverageBadge: View {
    let form: AssertionForm
    /// The five-step strength indicator. Turn it off where the pill has to fit in
    /// a very tight row.
    var showsLadder = true

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
            Text(label)
                .font(.kairoLabel).tracking(0.4)
            if showsLadder { ladder }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .foregroundStyle(tint)
        .background { Capsule().fill(tint.opacity(0.14)) }
        .overlay { Capsule().strokeBorder(tint.opacity(0.24), lineWidth: 0.5) }
        .accessibilityElement()
        .accessibilityLabel("Evidence: \(label)")
    }

    /// One dot per rung, filled up to and including the rung this form sits on:
    /// `forbidden` is one of five, `assertion` is five of five.
    private var ladder: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                Circle()
                    .fill(i <= form.rawValue ? tint : tint.opacity(0.22))
                    .frame(width: 3.5, height: 3.5)
            }
        }
        .accessibilityHidden(true)
    }

    private var label: String {
        switch form {
        case .assertion: "complete"
        case .qualified: "partial"
        case .range:     "sparse"
        case .question:  "almost none"
        case .forbidden: "no data"
        }
    }

    private var icon: String {
        switch form {
        case .assertion: "checkmark.seal.fill"
        case .qualified: "circle.lefthalf.filled"
        case .range:     "circle.dotted"
        case .question:  "questionmark.circle"
        case .forbidden: "eye.slash"
        }
    }

    private var tint: Color {
        switch form {
        case .assertion: Kairo.leaf
        case .qualified: Kairo.teal
        case .range:     Kairo.amber
        case .question:  Kairo.coral
        case .forbidden: Kairo.inkFaint
        }
    }
}

/// A claim rendered at whatever strength the evidence permits. Views never print
/// a bare number themselves — they ask the gate first.
///
/// Each verdict gets its own card treatment, because "we softened this", "we
/// rewrote this" and "we refused to say this" are different events and must not
/// look alike. The gate's decision is the content, not a footnote under it.
struct GatedClaim: View {
    @Environment(AppModel.self) private var model
    let text: String
    let domain: CoverageDomain

    var body: some View {
        let verdict = model.screened(text, domain: domain)
        claim(for: verdict)
            .frame(maxWidth: .infinity, alignment: .leading)
            .kairoCard(tint: accent(verdict))
    }

    @ViewBuilder
    private func claim(for verdict: ScreeningVerdict) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch verdict {
            case let .pass(t):
                stamp("the evidence carries this", icon: "checkmark.seal.fill", tint: Kairo.leaf)
                headline(t)

            case let .downgraded(t, form):
                stamp("said as softly as the evidence allows",
                      icon: "arrow.down.right.circle.fill", tint: Kairo.teal)
                headline(t)
                reason("I could not see enough of your \(domain.rawValue) today to say more.",
                       tint: Kairo.inkSoft)
                CoverageBadge(form: form)

            case let .rewritten(t, why):
                stamp("rewritten before it reached you", icon: "pencil.and.outline",
                      tint: Kairo.sky)
                headline(t)
                reason(why, tint: Kairo.inkSoft)

            case let .blocked(why):
                stamp("not said at all", icon: "hand.raised.fill", tint: Kairo.coral)
                redaction
                reason(why, tint: Kairo.coral)

            case let .heldForHuman(why):
                stamp("held for a person to check",
                      icon: "person.crop.circle.badge.exclamationmark", tint: Kairo.amber)
                redaction
                reason(why, tint: Kairo.amber)
            }
        }
    }

    /// What the gate did, and which domain's coverage it did it on.
    private func stamp(_ title: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold))
            Text(title.uppercased()).font(.kairoLabel).tracking(1.1)
            Spacer(minLength: 6)
            Pill(text: domain.rawValue, icon: Kairo.icon(for: domain),
                 tint: Kairo.colour(for: domain))
        }
        .foregroundStyle(tint)
    }

    private func headline(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 19, weight: .semibold, design: .rounded))
            .foregroundStyle(Kairo.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func reason(_ t: String, tint: Color) -> some View {
        Text(t)
            .font(.caption)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The shape of a sentence that is not there. A withheld claim leaves a mark,
    /// so the user can see something was held back rather than never existed.
    private var redaction: some View {
        HStack(spacing: 6) {
            ForEach([CGFloat(62), 36, 50], id: \.self) { w in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Kairo.hairline.opacity(0.12))
                    .frame(width: w, height: 12)
            }
        }
        .accessibilityHidden(true)
    }

    private func accent(_ v: ScreeningVerdict) -> Color? {
        switch v {
        case .pass:         return nil
        case .downgraded:   return Kairo.teal
        case .rewritten:    return Kairo.sky
        case .blocked:      return Kairo.coral
        case .heldForHuman: return Kairo.amber
        }
    }
}
