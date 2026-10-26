import SwiftUI
import KairoKit

/// FR9.5 — the contract that was considered and refused.
///
/// A vetoed contract never becomes a proposal card, so without this the user is
/// simply never told the conversation happened: the agents saw two corroborating
/// signals, drafted an easier week, and the Steward stopped it. That is a
/// decision made about them, on their own readings, and hiding it is the exact
/// omission the losing-bid rows on Today exist to prevent.
///
/// Written to be read in the second person and without alarm. The Steward's
/// sentence is shown verbatim — it was composed for a person, and paraphrasing a
/// safety judgement is how a precise statement becomes a vague worry.
struct StewardVetoNote: View {
    let reason: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Kairo.amber)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 5) {
                Text("A gentler week was considered, and held back")
                    .font(.kairoHeadline)
                    .foregroundStyle(Kairo.ink)
                Text(reason)
                    .font(.kairoCaption)
                    .foregroundStyle(Kairo.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Your targets are unchanged. Nothing was suspended.")
                    .font(.caption)
                    .foregroundStyle(Kairo.inkSoft)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kairoCard(tint: Kairo.amber)
        .accessibilityElement(children: .combine)
    }
}
