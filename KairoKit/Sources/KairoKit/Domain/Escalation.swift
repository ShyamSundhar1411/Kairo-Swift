import Foundation

/// FR11.7 - where a red flag actually goes, on the device.
///
/// This exists on both sides for the same reason the arbiter does: NFR9 says
/// logging and scheduled nudges keep working with no backend, so the on-device
/// gate blocks messages in a room with no network - and a block that names
/// nowhere to go is the gap this whole feature closes. A referral that only
/// works when the server is reachable is a referral that fails in the one
/// situation where nobody can look anything up for themselves.
///
/// Kept deliberately identical to `backend/kairo/domain/escalation.py`, entry
/// for entry. `EscalationParityTests` compares the two rather than trusting
/// this comment, because a phone number that drifts on one side only is the
/// precise harm NFR14 describes.
public enum FlagType: String, Sendable, CaseIterable, Codable {
    case eatingDisorder
    case selfHarm
    case mentalHealth
    /// The Steward raised a flag in its own words and no pattern claimed it.
    /// Not a synonym for "general crisis": it routes broadly *because* nothing
    /// narrower was established.
    case unclassified
}

public struct EscalationService: Sendable, Equatable, Codable {
    public let name: String
    public let telephone: String
    public let hours: String
    /// Shown to the person, not just stored. Being told why *this* service was
    /// chosen is what separates a referral from a brush-off.
    public let scope: String
    public let url: String
    /// Offered beside the primary service, never instead of it. These depend on
    /// who the caller is - something this system does not know and will not guess.
    public let alternatives: [EscalationService]

    public init(name: String, telephone: String, hours: String, scope: String,
                url: String, alternatives: [EscalationService] = []) {
        self.name = name
        self.telephone = telephone
        self.hours = hours
        self.scope = scope
        self.url = url
        self.alternatives = alternatives
    }
}

public enum Escalation {

    /// Not in the directory and not routed to: 000 answers immediate danger,
    /// which is the person's judgement to make and not a keyword's. Carried here
    /// so every referral can show it without a second lookup.
    public static let emergency = EscalationService(
        name: "Emergency services", telephone: "000", hours: "24 hours",
        scope: "immediate danger to life",
        url: "https://www.triplezero.gov.au/")

    static let thirteenYarn = EscalationService(
        name: "13YARN", telephone: "13 92 76", hours: "24 hours, 7 days",
        scope: "crisis support for Aboriginal and Torres Strait Islander people",
        url: "https://www.13yarn.org.au/")

    static let kidsHelpline = EscalationService(
        name: "Kids Helpline", telephone: "1800 55 1800", hours: "24 hours, 7 days",
        scope: "counselling for people aged 5 to 25",
        url: "https://kidshelpline.com.au/")

    static let butterfly = EscalationService(
        name: "Butterfly Foundation National Helpline", telephone: "1800 33 4673",
        hours: "8am to midnight AEST/AEDT, 7 days",
        scope: "eating disorders and body image",
        url: "https://butterfly.org.au/get-support/helpline/")

    static let lifeline = EscalationService(
        name: "Lifeline", telephone: "13 11 14", hours: "24 hours, 7 days",
        scope: "crisis support and suicide prevention",
        url: "https://www.lifeline.org.au/",
        alternatives: [thirteenYarn, kidsHelpline])

    static let beyondBlue = EscalationService(
        name: "Beyond Blue", telephone: "1300 22 4636", hours: "24 hours, 7 days",
        scope: "anxiety, depression and general mental wellbeing",
        url: "https://www.beyondblue.org.au/",
        alternatives: [thirteenYarn])

    /// The routing table. Australian, because NFR7 declares the classifier
    /// validated for en-AU and a directory is only as portable as the classifier
    /// feeding it - a locale this gate cannot screen is held for a human rather
    /// than handed an Australian phone number.
    public static let directory: [FlagType: EscalationService] = [
        .eatingDisorder: butterfly,
        .selfHarm: lifeline,
        .mentalHealth: beyondBlue,
        .unclassified: lifeline,
    ]

    /// The entry for a flag, or nothing when there is no flag. Nothing is also
    /// the right answer for a message held for an operational reason: a locale
    /// outside competence is a fact about the classifier, not a finding about
    /// the person who wrote the message.
    public static func referral(for flag: FlagType?) -> EscalationService? {
        flag.flatMap { directory[$0] }
    }
}

/// A pattern and what it means. The list used to be four bare strings, so every
/// match produced the same undifferentiated `blocked` and the thing NFR14 warns
/// about could not even be expressed.
public struct RedFlag: Sendable, Equatable {
    public let pattern: String
    public let type: FlagType

    public init(_ pattern: String, _ type: FlagType) {
        self.pattern = pattern
        self.type = type
    }

    /// Deliberately narrow, and deliberately not widened here. Every entry is an
    /// eating-disorder pattern because that is what this list has always
    /// detected - naming the type adds routing, not detection. Adding self-harm
    /// or mental-health patterns is a clinical decision about false positives
    /// and false negatives, and it belongs to whoever owns NFR14.
    public static let defaults: [RedFlag] = [
        RedFlag("skip meals", .eatingDisorder),
        RedFlag("starve", .eatingDisorder),
        RedFlag("purge", .eatingDisorder),
        RedFlag("lose 5kg this week", .eatingDisorder),
    ]
}
