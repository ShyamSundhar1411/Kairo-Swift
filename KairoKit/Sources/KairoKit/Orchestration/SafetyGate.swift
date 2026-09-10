import Foundation

/// Member D — CF11. Fail-closed, and honest about the limit of that claim.
public enum ScreeningVerdict: Sendable, Equatable {
    case pass(String)
    case rewritten(String, why: String)
    case downgraded(String, to: AssertionForm)
    case blocked(why: String)
    case heldForHuman(why: String)
}

public struct SafetyGate: Sendable {
    /// Locales the red-flag classifier has actually been validated in (NFR7).
    /// An unqualified "100% screened" claim is false the moment a user writes
    /// in a language nobody tested.
    public let competentLocales: Set<String>
    private let redFlags: [String]

    public init(competentLocales: Set<String> = ["en-AU", "en"],
                redFlags: [String] = ["skip meals", "starve", "purge", "lose 5kg this week"]) {
        self.competentLocales = competentLocales
        self.redFlags = redFlags
    }

    /// `coverage` is Member B's gate: the Steward rejects the Coach's own message
    /// and returns a downgraded form when the evidence does not support it.
    public func screen(_ text: String, locale: String,
                       claimDomain: CoverageDomain? = nil,
                       coverage: DayCoverage? = nil,
                       classifierAvailable: Bool = true) -> ScreeningVerdict {
        guard classifierAvailable else {
            return .heldForHuman(why: "screening unavailable — fail closed, nothing is sent")
        }
        guard competentLocales.contains(locale) else {
            return .heldForHuman(why: "locale \(locale) is outside declared competence; translate-then-screen or hold")
        }
        let lower = text.lowercased()
        if let hit = redFlags.first(where: { lower.contains($0) }) {
            return .blocked(why: "red-flag pattern: \(hit)")
        }
        if let d = claimDomain, let cov = coverage {
            let form = cov.permittedForm(for: d)
            // Nothing measured means nothing may be said, digits or not. The
            // number test used to guard this branch too, so "No meals logged
            // today" — a categorical claim about a day nothing was measured of —
            // passed a gate whose whole purpose is to stop exactly that. Numbers
            // are where an *over*claim usually shows up, not where a claim starts.
            if form == .forbidden {
                return .blocked(why: "no evidence for any claim about \(d.rawValue)")
            }
            if form < .assertion && containsBareNumber(text) {
                return .downgraded(downgrade(text, to: form, domain: d), to: form)
            }
        }
        return .pass(text)
    }

    private func containsBareNumber(_ s: String) -> Bool {
        s.rangeOfCharacter(from: .decimalDigits) != nil
    }

    private func downgrade(_ text: String, to form: AssertionForm, domain: CoverageDomain) -> String {
        switch form {
        case .question:  return "I only saw part of your \(domain.rawValue) today — did I miss something?"
        case .range:     return "Based on partial \(domain.rawValue) data, this is a rough range rather than a total."
        case .qualified: return "\(text) (on the days I could actually see)"
        default:         return text
        }
    }
}
