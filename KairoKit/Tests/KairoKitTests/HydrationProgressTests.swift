import Testing
import Foundation
@testable import KairoKit

@Suite("FR8.5 — hydration progress without looking at it")
struct HydrationProgressTests {

    // MARK: - Milestones

    @Test("crossing a quarter boundary is reported once")
    func reportedOnce() {
        #expect(HydrationProgress.crossed(from: 400, to: 600, target: 2000) == .quarter)
        // Same glass re-delivered by WatchConnectivity: no second buzz.
        #expect(HydrationProgress.crossed(from: 600, to: 600, target: 2000) == nil)
    }

    @Test("a glass that jumps two boundaries reports the one it reached")
    func reportsTheHigher() {
        // 20% to 60% has passed halfway; reporting the quarter would be telling
        // somebody about the boundary they left behind.
        #expect(HydrationProgress.crossed(from: 400, to: 1200, target: 2000) == .half)
    }

    @Test("reaching the target is its own milestone")
    func targetIsItsOwn() {
        #expect(HydrationProgress.crossed(from: 1800, to: 2000, target: 2000) == .target)
        #expect(HydrationProgress.crossed(from: 2000, to: 2400, target: 2000) == nil)
    }

    @Test("a decreasing or zero total crosses nothing")
    func noPhantomCrossings() {
        #expect(HydrationProgress.crossed(from: 1000, to: 500, target: 2000) == nil)
        #expect(HydrationProgress.crossed(from: 0, to: 100, target: 0) == nil)
    }

    @Test("boundaries are inclusive at the bottom and exclusive at the top")
    func boundaryArithmetic() {
        #expect(HydrationProgress.crossed(from: 499, to: 500, target: 2000) == .quarter)
        #expect(HydrationProgress.crossed(from: 500, to: 999, target: 2000) == nil)
    }

    // MARK: - Spoken

    @Test("nothing logged is never read as zero of a target")
    func absenceIsNotZero() {
        let said = HydrationProgress.spoken(totalMillilitres: 0, targetMillilitres: 2000,
                                            sipCount: 0)
        #expect(said == "No water logged yet today.")
        #expect(!said.contains("0 of 2000"))
    }

    @Test("position comes first, because position is what the ring encoded")
    func positionFirst() {
        let said = HydrationProgress.spoken(totalMillilitres: 1000,
                                            targetMillilitres: 2000, sipCount: 4)
        #expect(said.hasPrefix("Halfway."))
        #expect(said.contains("1000 of 2000 millilitres"))
        #expect(said.contains("1000 to go"))
    }

    @Test("the target being met is said in words, not in colour")
    func targetInWords() {
        let said = HydrationProgress.spoken(totalMillilitres: 2000,
                                            targetMillilitres: 2000, sipCount: 8)
        #expect(said.hasPrefix("Target reached."))
        #expect(!said.contains("to go"))
    }

    @Test("a first sip under a quarter says it has started, not that it is nowhere")
    func justStarted() {
        let said = HydrationProgress.spoken(totalMillilitres: 200,
                                            targetMillilitres: 2000, sipCount: 1)
        #expect(said.hasPrefix("Just started."))
    }

    // MARK: - The value

    @Test("the value is the percentage only, so VoiceOver does not say it twice")
    func valueIsTerse() {
        #expect(HydrationProgress.accessibilityValue(
            totalMillilitres: 660, targetMillilitres: 2000, sipCount: 3)
                == "33 percent of today's target")
    }

    @Test("an unmeasured day has no percentage")
    func unmeasuredHasNoValue() {
        #expect(HydrationProgress.accessibilityValue(
            totalMillilitres: 0, targetMillilitres: 2000, sipCount: 0) == "not measured")
    }

    @Test("percentages round down, so 99.9 percent is never announced as done")
    func roundsDown() {
        #expect(HydrationProgress.percent(1999, of: 2000) == 99)
        #expect(HydrationProgress.percent(2001, of: 2000) == 100)
    }

    // MARK: - Agreement with the visual channel

    @Test("the spoken form and the ring never disagree")
    func oneSourceOfTruth() {
        var log = HydrationLog(dayStart: DateHelp.at(2026, 8, 25), targetMillilitres: 2000)
        log.record(.init(id: "a", at: DateHelp.at(2026, 8, 25, 9), millilitres: 1000))
        let ringPercent = Int(log.fractionOfTarget * 100)
        let spokenValue = HydrationProgress.accessibilityValue(
            totalMillilitres: log.totalMillilitres,
            targetMillilitres: log.targetMillilitres, sipCount: log.sips.count)
        #expect(spokenValue.hasPrefix("\(ringPercent) percent"))
    }
}

@Suite("FR8.2 — a photographed volume is weaker evidence than a tap")
struct SipProvenanceTests {

    @Test("a tap is the default, so nothing already logged changes meaning")
    func tapIsDefault() {
        let sip = HydrationLog.Sip(id: "a", at: DateHelp.at(2026, 8, 25), millilitres: 250)
        #expect(sip.source == .tap)
    }

    @Test("a sip written before provenance existed decodes as the tap it was")
    func backwardCompatible() throws {
        // A watch that has not been updated sends exactly this shape, and a
        // decode failure would drop a glass somebody logged.
        let old = #"{"id":"a","at":780000000,"millilitres":250}"#
        let sip = try JSONDecoder().decode(HydrationLog.Sip.self,
                                           from: Data(old.utf8))
        #expect(sip.source == .tap)
        #expect(sip.millilitres == 250)
    }

    @Test("the day's total says how much of it came off a photograph")
    func provenanceIsAnswerable() {
        var log = HydrationLog(dayStart: DateHelp.at(2026, 8, 25), targetMillilitres: 2000)
        log.record(.init(id: "tap", at: DateHelp.at(2026, 8, 25, 9), millilitres: 300))
        log.record(.init(id: "shot", at: DateHelp.at(2026, 8, 25, 13),
                         millilitres: 250, source: .photo))
        #expect(log.totalMillilitres == 550)
        #expect(log.photographedMillilitres == 250)
    }

    @Test("a photographed sip still cannot be counted twice")
    func noDoubleCount() {
        var log = HydrationLog(dayStart: DateHelp.at(2026, 8, 25))
        let sip = HydrationLog.Sip(id: "photo-1", at: DateHelp.at(2026, 8, 25, 13),
                                   millilitres: 250, source: .photo)
        // Hoisted: `#expect` evaluates its argument in a closure that captures
        // immutably, so a mutating call cannot live inside one.
        let first = log.record(sip)
        let second = log.record(sip)
        #expect(first)
        #expect(!second, "accepting the same offer twice must not add 500 ml")
        #expect(log.totalMillilitres == 250)
    }

    @Test("there is no case for an unconfirmed inference")
    func onlyConfirmedInferencesExist() {
        // The log has no way to hold a drink the user has not accepted, which
        // is the point: FR8.2 offers, it does not write.
        #expect(HydrationLog.Source.allCases.count == 2)
    }
}
