import Testing
import Foundation
@testable import KairoKit

/// FR11.7 — that a blocked message names somewhere to go, and the right one.
///
/// The assertion that matters is not "a referral was produced". NFR14 calls
/// misrouting an eating-disorder flag a harm rather than a defect, so the one
/// worth writing down is that it routed to Butterfly and *not* to Lifeline.
@Suite("Member D — escalation routing")
struct EscalationDirectoryTests {

    // MARK: - The one NFR14 is about

    @Test("an eating-disorder flag routes to the eating-disorder service",
          arguments: ["Try to skip meals tomorrow.",
                      "You could starve for a day to catch up.",
                      "Just purge after dinner.",
                      "You can lose 5kg this week if you try."])
    func eatingDisorderRouting(text: String) throws {
        guard case let .blocked(_, referral) = SafetyGate().screen(text, locale: "en-AU") else {
            Issue.record("expected a block for \(text)"); return
        }
        let service = try #require(referral)
        #expect(service.name.contains("Butterfly"))
        #expect(service != Escalation.directory[.selfHarm])
    }

    // MARK: - Only a clinical flag gets a clinical referral

    @Test("a locale outside competence is held without a referral")
    func localeHoldCarriesNoReferral() {
        // NFR7 holds this because Kairo cannot read it. That is a fact about the
        // classifier, not a finding about the person who wrote it, and handing
        // them a helpline on the strength of it would be an invention.
        guard case .heldForHuman = SafetyGate().screen("我最近都不太想吃东西", locale: "zh-Hans") else {
            Issue.record("expected heldForHuman"); return
        }
    }

    @Test("a block for missing evidence carries no referral")
    func coverageBlockCarriesNoReferral() {
        let coverage = DayCoverage(dayStart: DateHelp.at(2026, 8, 25, 0, 0))
        guard case let .blocked(_, referral) = SafetyGate().screen(
            "No meals logged today.", locale: "en-AU",
            claimDomain: .meals, coverage: coverage) else {
            Issue.record("expected a block"); return
        }
        #expect(referral == nil)
    }

    @Test("an ordinary message carries no referral")
    func passCarriesNoReferral() {
        guard case .pass = SafetyGate().screen("You are 300 ml behind on water.",
                                               locale: "en-AU") else {
            Issue.record("expected a pass"); return
        }
    }

    // MARK: - The directory itself

    @Test("every flag type resolves to a service")
    func everyFlagResolves() {
        // A type with no entry would surface as nil at the exact moment somebody
        // needed a phone number.
        for flag in FlagType.allCases {
            #expect(Escalation.referral(for: flag) != nil)
        }
        #expect(Escalation.referral(for: nil) == nil)
    }

    @Test("services that depend on who the caller is are never routed to")
    func identityDependentServicesAreOfferedNotChosen() {
        // 13YARN serves Aboriginal and Torres Strait Islander people. Kairo
        // cannot know who that is, so it is offered alongside and never selected.
        let routed = Escalation.directory.values
        let alternatives = routed.flatMap(\.alternatives)
        #expect(alternatives.contains { $0.name.contains("13YARN") })
        #expect(!routed.contains { $0.name.contains("13YARN") })
    }

    @Test("emergency is not in the routing table")
    func emergencyIsNotRouted() {
        // 000 answers immediate danger, which is the person's judgement to make
        // and not a keyword's.
        #expect(!Escalation.directory.values.contains(Escalation.emergency))
    }

    // MARK: - The two halves agree

    @Test("the directory matches the shared source")
    func matchesSharedSource() throws {
        // `docs/escalation-directory.json` is the single source both halves pin
        // to. The arbiter's cross-language conformance is two mirrored assertion
        // lists, which is fine for a score that would fail visibly. It is not
        // fine for a phone number: a digit that drifts on one side only looks
        // correct on both and is wrong in exactly the situation the number
        // exists for. The backend's `test_the_directory_matches_the_shared_source`
        // reads the same file.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // KairoKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // KairoKit
            .deletingLastPathComponent()   // mobile
            .deletingLastPathComponent()   // <repo root>
        let source = root.appending(path: "docs/escalation-directory.json")
        let doc = try JSONSerialization.jsonObject(
            with: Data(contentsOf: source)) as! [String: Any]

        func flatten(_ s: EscalationService) -> [String: Any] {
            ["name": s.name, "telephone": s.telephone, "hours": s.hours,
             "scope": s.scope, "url": s.url,
             "alternatives": s.alternatives.map(flatten)]
        }
        func same(_ a: [String: Any], _ b: [String: Any]) -> Bool {
            NSDictionary(dictionary: a).isEqual(to: b)
        }

        #expect(same(flatten(Escalation.emergency), doc["emergency"] as! [String: Any]))
        let expected = doc["directory"] as! [String: Any]
        for flag in FlagType.allCases {
            let mine = flatten(try #require(Escalation.directory[flag]))
            #expect(same(mine, expected[flag.rawValue] as! [String: Any]),
                    "\(flag.rawValue) differs from docs/escalation-directory.json")
        }
    }
}
