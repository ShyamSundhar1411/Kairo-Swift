import SwiftUI
import KairoKit

/// FR11.7 - the one screen in the app that exists to be used in a bad moment.
///
/// Everything else here argues that interrupting someone has a cost. This is the
/// exception: the gate has just decided a message should not be sent *because of
/// what it suggests about the person reading it*, and the worst possible next
/// move is a redacted bar and silence.
///
/// Three things it will not do:
///
/// - **Guess.** The service shown is the one the flag's type routes to, and the
///   `scope` line says what that service is for. A referral that explains why
///   this number and not another is a referral; one that prints a phone number
///   is a brush-off.
/// - **Bury 000.** The directory entry is the considered answer, but a person
///   may need emergency services before any helpline picks up, so it is on the
///   card rather than one screen further in.
/// - **Decide who you are.** `alternatives` are listed as alternatives. 13YARN
///   serves Aboriginal and Torres Strait Islander people and Kairo has no way of
///   knowing who that is, so it is offered, never selected.
struct ReferralCard: View {
    let service: EscalationService

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("If you want to talk to someone".uppercased())
                .font(.kairoLabel).tracking(1.1)
                .foregroundStyle(Kairo.inkSoft)

            entry(service, prominent: true)

            if !service.alternatives.isEmpty {
                Divider().overlay(Kairo.hairline.opacity(0.25))
                Text("Or, depending on who you are:")
                    .font(.caption).foregroundStyle(Kairo.inkSoft)
                ForEach(service.alternatives, id: \.telephone) { entry($0, prominent: false) }
            }

            Divider().overlay(Kairo.hairline.opacity(0.25))
            entry(Escalation.emergency, prominent: false)
        }
        .padding(18)
        .background(Kairo.teal.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Kairo.teal.opacity(0.22), lineWidth: 1))
    }

    /// The number is the control, not a label beside one. Tapping anywhere on
    /// the row dials: a person who needs this should not have to find the small
    /// blue text.
    @ViewBuilder
    private func entry(_ s: EscalationService, prominent: Bool) -> some View {
        Button {
            call(s.telephone)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(s.name)
                        .font(prominent ? .kairoHeadline : .kairoCaption)
                        .foregroundStyle(Kairo.ink)
                    Spacer(minLength: 6)
                    Text(s.telephone)
                        .font(prominent ? .kairoHeadline : .kairoCaption)
                        .foregroundStyle(Kairo.teal)
                        .monospacedDigit()
                    Image(systemName: "phone.fill")
                        .font(.system(size: prominent ? 13 : 11, weight: .semibold))
                        .foregroundStyle(Kairo.teal)
                }
                Text("\(s.scope) · \(s.hours)")
                    .font(.caption)
                    .foregroundStyle(Kairo.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Call \(s.name) on \(spelled(s.telephone))")
        .accessibilityHint("\(s.scope). Open \(s.hours).")
    }

    /// VoiceOver reads a run of digits as one large number - "thirteen eleven
    /// fourteen" becomes "one hundred and thirty-one thousand…". Spacing the
    /// digits out is the difference between a number somebody can dial and a
    /// number they have to ask a sighted person to read for them.
    private func spelled(_ number: String) -> String {
        number.compactMap { $0.isNumber ? String($0) : ($0 == " " ? "," : nil) }
            .joined(separator: " ")
    }

    private func call(_ number: String) {
        let digits = number.filter(\.isNumber)
        guard let url = URL(string: "tel://\(digits)") else { return }
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }
}
