import Foundation

/// Figure 40 (UC8) - the outbound advice screening lifecycle.
///
/// Screening already worked. What it did not have was a *lifecycle*, and the
/// difference is what the record can say afterwards. `blocked` told you a
/// message was stopped; it could not tell you whether the classifier was
/// unreachable, whether a red flag halted delivery, or whether a person was
/// ever shown the result - three outcomes with the same name and completely
/// different obligations attached.
///
/// The separations are load-bearing:
///
/// - `failClosed` is the classifier being unreachable (A2, FR11.1). Nothing
///   was sent and nothing was judged. It is not a finding about the message.
/// - `escalated` is a red flag or clinical disagreement halting delivery (A3).
///   Its entry actions are the obligations: open an escalation case with the
///   evidence trail (FR11.6), route to the directory entry for the flag type
///   (FR11.7), notify the founder.
/// - `heldForHuman` is reached only from `translating`, and only when there is
///   no safe translation (FR11.2). Holding a message Kairo cannot read is not
///   the same as refusing one it read and disliked.
///
/// Mirrors `backend/kairo/domain/advice.py`.
public enum AdviceScreeningState: String, LifecycleState {
    case submitted, screening, failClosed, rewritten, translating
    case escalated, rejected, approved, heldForHuman, released, humanDecided

    public static let machineName = "AdviceScreening"
    public static let initial: AdviceScreeningState = .submitted
    public var isTerminal: Bool {
        self == .failClosed || self == .released || self == .humanDecided
    }

    public static let transitions: [Transition<AdviceScreeningState>] = [
        .init(.submitted, "classifierUnreachable", .failClosed,
              guardText: "nothing sent (A2, FR11.1)"),
        .init(.submitted, "classifierReachable", .screening),
        .init(.screening, "unsafeRewritable", .rewritten,
              guardText: "rewrite or downgrade (FR11.4)"),
        .init(.screening, "outsideLanguageCompetence", .translating, guardText: "FR11.2"),
        .init(.screening, "redFlagOrClinicalDisagreement", .escalated,
              guardText: "halt delivery (A3)"),
        .init(.screening, "unsafeNotRewritable", .rejected,
              guardText: "request revision (A1)"),
        .init(.screening, "safeAndSupported", .approved),
        .init(.rewritten, "safeAndSupported", .approved),
        .init(.translating, "translated", .approved, guardText: "log provenance"),
        .init(.translating, "noSafeTranslation", .heldForHuman,
              guardText: "hold, never pass unscreened"),
        // The only cycle in the machine, and the diagram draws it: a message
        // that is unsafe and cannot be rewritten goes back for revision
        // rather than being thrown away.
        .init(.rejected, "revised", .submitted, guardText: "resubmit"),
        .init(.escalated, "clinicianDecided", .humanDecided,
              guardText: "record decision - outranks all AI (AG-5)"),
        .init(.heldForHuman, "humanReviews", .humanDecided),
        .init(.approved, "release", .released,
              guardText: "seal verdict into DecisionRecord (FR12.1)"),
    ]
}
