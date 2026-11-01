import SwiftUI
import KairoKit

/// CF3 / UC2, SCRUM-44. The roles disagreed, and here is what each of them
/// said.
///
/// The whole server half of this existed and had no screen: `POST /v1/dissent`,
/// `DisagreementCase`, the Figure 34 machine, the precedence policy. A second
/// opinion nobody can read is a log line, so this is the reading surface.
///
/// It shows **every** position, not just the one that won. An opinion card that
/// printed only the winner would be the thing the feature exists to replace,
/// which is why the backend was changed to carry them all.
struct SecondOpinionCard: View {
    let app: AppModel
    /// The disagreement to put to the roles. Defaulted to the report's own
    /// scenario so the demo has one tap rather than a form.
    var topic = "possible clinical deterioration"
    var roles = ["WellbeingSteward", "WellnessCoach"]

    @State private var opinion: RemoteAgentClient.SecondOpinion?
    @State private var asking = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Kairo.Space.stack) {
            header
            if let opinion {
                outcomeBanner(opinion)
                ForEach(opinion.positions) { position in
                    positionRow(position, won: position.agent == opinion.winner?.agent)
                }
                if opinion.positions.isEmpty {
                    Text("No role produced a position. Nothing was decided, and "
                         + "that is recorded rather than filled in.")
                        .font(.kairoCaption)
                        .foregroundStyle(Kairo.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let failure {
                errorRow(failure)
            } else {
                Text("Put a question to two roles with different objectives and "
                     + "see what each one says before anything is decided.")
                    .font(.kairoCaption)
                    .foregroundStyle(Kairo.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            askButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kairoCard()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "Second opinion", icon: "person.2.wave.2",
                          trailing: nil, tint: Kairo.violet)
            Text(topic)
                .font(.kairoHeadline)
                .foregroundStyle(Kairo.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The outcome in the vocabulary the domain uses, said in English.
    @ViewBuilder
    private func outcomeBanner(_ o: RemoteAgentClient.SecondOpinion) -> some View {
        let tint: Color = o.wentToAHuman ? Kairo.coral : (o.wasRuled ? Kairo.amber : Kairo.leaf)
        VStack(alignment: .leading, spacing: 5) {
            Label(headline(o), systemImage: o.wentToAHuman ? "person.badge.shield.checkmark"
                                                           : "checkmark.seal")
                .font(.kairoHeadline)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            if let reason = o.reason, !reason.isEmpty {
                Text(reason)
                    .font(.kairoCaption)
                    .foregroundStyle(Kairo.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let policy = o.policy, !policy.isEmpty {
                // The written rule, shown verbatim. A ruling whose policy is
                // paraphrased is a ruling nobody can check.
                Text("Ruled under: \(policy)")
                    .font(.kairoCaption.monospaced())
                    .foregroundStyle(Kairo.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headline(_ o: RemoteAgentClient.SecondOpinion) -> String {
        if o.wentToAHuman { return "Sent to a person. No AI ruled on this." }
        if o.wasRuled { return "The Steward ruled." }
        return "The roles agreed."
    }

    private func positionRow(_ p: RemoteAgentClient.Position, won: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(p.agent)
                    .font(.kairoLabel).tracking(1.1)
                    .foregroundStyle(Kairo.inkFaint)
                Pill(text: p.objective, icon: nil, tint: objectiveTint(p.objective))
                Spacer(minLength: 0)
                if won {
                    Text("carried")
                        .font(.kairoCaption.weight(.semibold))
                        .foregroundStyle(Kairo.leaf)
                }
            }
            Text(p.claim)
                .font(.kairoBody)
                .foregroundStyle(Kairo.ink)
                .fixedSize(horizontal: false, vertical: true)
            // Confidence and cost-if-wrong together, because the precedence
            // policy weighs them together: a cheap mistake held confidently and
            // an expensive one held tentatively are not the same bid.
            Text("confidence \(Int(p.confidence * 100))% · cost if wrong \(Int(p.costIfWrong * 100))%")
                .font(.kairoCaption)
                .foregroundStyle(Kairo.inkSoft)
            if !p.evidence.isEmpty {
                Text("cites: " + p.evidence.joined(separator: ", "))
                    .font(.kairoCaption)
                    .foregroundStyle(Kairo.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
        .padding(.leading, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(won ? Kairo.leaf : Kairo.inkFaint.opacity(0.4))
                .frame(width: 4)
                .clipShape(Capsule())
        }
        .accessibilityElement(children: .combine)
    }

    private func objectiveTint(_ objective: String) -> Color {
        switch objective {
        case "safety":    Kairo.coral
        case "accuracy":  Kairo.leaf
        case "adherence": Kairo.amber
        default:          Kairo.inkFaint
        }
    }

    private func errorRow(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.kairoCaption)
            .foregroundStyle(Kairo.amber)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var askButton: some View {
        Button {
            Task { await ask() }
        } label: {
            HStack {
                Text(opinion == nil ? "Ask both roles" : "Ask again")
                if asking { Spacer(); ProgressView() }
            }
        }
        .buttonStyle(.kairoSoft)
        .disabled(asking || app.backend.client == nil)
    }

    private func ask() async {
        guard let client = app.backend.client else {
            failure = "No agent backend is connected, so there is nobody to ask."
            return
        }
        asking = true
        failure = nil
        defer { asking = false }
        do {
            opinion = try await client.dissent(userID: app.userID, topic: topic,
                                               roles: roles, coverage: app.coverage)
        } catch {
            // Said plainly. The roles disagreeing is the feature; the request
            // failing is not, and the two must not look alike.
            opinion = nil
            failure = "Could not reach the roles: \(String(describing: error))"
        }
    }
}
