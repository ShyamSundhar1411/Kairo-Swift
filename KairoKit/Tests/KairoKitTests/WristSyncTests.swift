import Testing
import Foundation
@testable import KairoKit

/// The phone/watch wire format. The bug these tests exist for is a real one: the
/// watch hand-rolled its own dictionaries with bare string keys, the phone had no
/// receiver at all, and a glass of water logged on the wrist silently went
/// nowhere. Now there is one envelope, and it is worth proving both directions of
/// it survive the trip.
@Suite("Wrist sync - the wire format")
struct WristSyncEnvelopeTests {
    /// ISO-8601 keeps whole seconds, not sub-second precision, so a date that
    /// survives the round trip lands within a second of where it started rather
    /// than exactly on it.
    static let dateTolerance: TimeInterval = 1

    let t = DateHelp.at(2026, 9, 7, 14, 25)

    @Test("a logged glass of water survives the round trip")
    func waterLoggedRoundTrips() throws {
        let sent = WristEvent.waterLogged(millilitres: 350, at: t, id: "sip-1")
        let back = try WristSync.unwrap(WristEvent.self, from: try WristSync.envelope(sent))
        guard case let .waterLogged(ml, at, id) = back else {
            Issue.record("expected a waterLogged event"); return
        }
        #expect(ml == 350)
        #expect(id == "sip-1")
        #expect(abs(at.timeIntervalSince(t)) < Self.dateTolerance)
    }

    @Test("all three nudge outcomes survive the round trip verbatim")
    func nudgeOutcomeRoundTrips() throws {
        // These three strings are what the receptivity model learns from, so the
        // transport is not allowed to normalise, lowercase or rename them.
        for outcome in ["userAccepted", "userSnoozed", "userDismissed"] {
            let sent = WristEvent.nudgeOutcome(bidID: "bid-7", outcome: outcome, at: t)
            let back = try WristSync.unwrap(WristEvent.self, from: try WristSync.envelope(sent))
            #expect(back == sent)
            guard case let .nudgeOutcome(bidID, decoded, at) = back else {
                Issue.record("expected a nudgeOutcome event"); return
            }
            #expect(bidID == "bid-7")
            #expect(decoded == outcome)
            #expect(abs(at.timeIntervalSince(t)) < Self.dateTolerance)
        }
    }

    @Test("a substituted nudge carries what it was substituted from (NFR11)")
    func nudgeRoundTripsWithSubstitution() throws {
        let sent = PhoneEvent.nudge(bidID: "bid-9",
                                    text: "Stand and stretch for two minutes.",
                                    nudgeClass: "sedentary",
                                    rewrittenFrom: "Take a brisk five-minute walk")
        let back = try WristSync.unwrap(PhoneEvent.self, from: try WristSync.envelope(sent))
        #expect(back == sent)
    }

    @Test("a nudge that was never substituted arrives with nil, not an empty string")
    func nudgeRoundTripsWithoutSubstitution() throws {
        // The watch shows the substitution note only when this is non-nil, so nil
        // collapsing to "" would put an empty "adapted from:" line on the wrist.
        let sent = PhoneEvent.nudge(bidID: "bid-10", text: "A glass of water now.",
                                    nudgeClass: "hydration", rewrittenFrom: nil)
        let back = try WristSync.unwrap(PhoneEvent.self, from: try WristSync.envelope(sent))
        guard case let .nudge(_, _, _, rewrittenFrom) = back else {
            Issue.record("expected a nudge event"); return
        }
        #expect(rewrittenFrom == nil)
    }

    @Test("the day the phone counted survives the round trip")
    func dayStateRoundTrips() throws {
        let sent = PhoneEvent.dayState(DayState(waterMillilitres: 1_450,
                                                waterTargetMillilitres: 2_400,
                                                sedentaryMinutes: 52,
                                                interruptionsSpent: 3,
                                                dailyBudget: 6))
        let back = try WristSync.unwrap(PhoneEvent.self, from: try WristSync.envelope(sent))
        #expect(back == sent)
    }

    @Test("unmeasured sitting stays nil rather than becoming zero")
    func dayStateKeepsNilSedentaryDistinctFromZero() throws {
        let unmeasured = DayState(waterMillilitres: 0, waterTargetMillilitres: 2_000,
                                  sedentaryMinutes: nil)
        let measuredZero = DayState(waterMillilitres: 0, waterTargetMillilitres: 2_000,
                                    sedentaryMinutes: 0)
        // "your phone has not measured this" and "you have not been sitting" are
        // different answers, and the watch shows a different screen for each.
        #expect(unmeasured != measuredZero)

        let back = try WristSync.unwrap(PhoneEvent.self,
                                        from: try WristSync.envelope(PhoneEvent.dayState(unmeasured)))
        guard case let .dayState(decoded) = back else {
            Issue.record("expected a dayState event"); return
        }
        #expect(decoded.sedentaryMinutes == nil)
        #expect(decoded != measuredZero)
    }

    @Test("an envelope from another version is refused, not guessed at")
    func wrongVersionThrows() throws {
        var message = try WristSync.envelope(WristEvent.waterLogged(millilitres: 200,
                                                                    at: t, id: "sip-2"))
        message[WristSync.versionKey] = WristSync.version + 1
        #expect(throws: WristSync.SyncError.wrongVersion(WristSync.version + 1)) {
            try WristSync.unwrap(WristEvent.self, from: message)
        }
    }

    @Test("a message with no version at all is refused")
    func missingVersionThrows() throws {
        var message = try WristSync.envelope(WristEvent.waterLogged(millilitres: 200,
                                                                    at: t, id: "sip-3"))
        message.removeValue(forKey: WristSync.versionKey)
        #expect(throws: WristSync.SyncError.wrongVersion(nil)) {
            try WristSync.unwrap(WristEvent.self, from: message)
        }
        // Not ours at all - WatchConnectivity delivers whatever was sent.
        #expect(throws: WristSync.SyncError.wrongVersion(nil)) {
            try WristSync.unwrap(WristEvent.self, from: ["something": "else"])
        }
    }

    @Test("a versioned envelope with nothing in it is refused")
    func missingPayloadThrows() throws {
        var message = try WristSync.envelope(WristEvent.waterLogged(millilitres: 200,
                                                                    at: t, id: "sip-4"))
        message.removeValue(forKey: WristSync.payloadKey)
        #expect(throws: WristSync.SyncError.missingPayload) {
            try WristSync.unwrap(WristEvent.self, from: message)
        }
    }
}

/// CF8 - hydration as a log of taps rather than a running integer. The reason it
/// is a log is that WatchConnectivity re-delivers queued messages, so the total
/// has to be able to recognise a glass it has already counted.
@Suite("Wrist sync - the day's water")
struct HydrationLogTests {
    let dayStart = DateHelp.at(2026, 9, 7, 0, 0)

    private func sip(_ id: String, _ ml: Int, minutes: Int = 0) -> HydrationLog.Sip {
        HydrationLog.Sip(id: id, at: dayStart.addingTimeInterval(Double(minutes) * 60),
                         millilitres: ml)
    }

    @Test("a re-delivered glass is refused and the total does not move")
    func duplicateIDsAreRejected() {
        var log = HydrationLog(dayStart: dayStart)
        // Bound rather than inlined: `#expect` rewrites the call it is given, and
        // it cannot rewrite one that mutates.
        let first = log.record(sip("sip-1", 350))
        #expect(first)
        #expect(log.totalMillilitres == 350)

        // The same tap arriving a second time - the watch re-sends its outbox on
        // reconnect, deliberately, because a lost sip is worse than a repeat one.
        let again = log.record(sip("sip-1", 350))
        #expect(again == false)
        #expect(log.totalMillilitres == 350)
        #expect(log.sips.count == 1)
    }

    @Test("two different taps of the same size are both counted")
    func distinctIDsBothCount() {
        var log = HydrationLog(dayStart: dayStart)
        let a = log.record(sip("sip-1", 200))
        let b = log.record(sip("sip-2", 200, minutes: 90))
        #expect(a)
        #expect(b)
        #expect(log.totalMillilitres == 400)
        #expect(log.sips.count == 2)
    }

    @Test("what is left of the target, and never a negative")
    func remainingClampsAtZero() {
        var log = HydrationLog(dayStart: dayStart, targetMillilitres: 2_000)
        log.record(sip("sip-1", 500))
        #expect(log.remainingMillilitres == 1_500)

        log.record(sip("sip-2", 1_800, minutes: 60))
        #expect(log.totalMillilitres == 2_300)
        // Over the target is a finished target, not a debt owed the other way.
        #expect(log.remainingMillilitres == 0)
    }

    @Test("the ring fills to full and stops there")
    func fractionClampsAtOne() {
        var log = HydrationLog(dayStart: dayStart, targetMillilitres: 2_000)
        #expect(log.fractionOfTarget == 0)

        log.record(sip("sip-1", 500))
        #expect(abs(log.fractionOfTarget - 0.25) < 0.0001)

        log.record(sip("sip-2", 3_000, minutes: 30))
        #expect(log.fractionOfTarget == 1)
    }

    @Test("a target of zero does not divide by zero")
    func zeroTargetIsSafe() {
        var log = HydrationLog(dayStart: dayStart, targetMillilitres: 0)
        log.record(sip("sip-1", 250))
        #expect(log.fractionOfTarget == 0)
        #expect(log.remainingMillilitres == 0)
    }

    @Test("coverage counts taps, not millilitres")
    func coverageCountsSipsNotVolume() {
        var log = HydrationLog(dayStart: dayStart)
        // One enormous glass is one observation. Coverage is about how much of the
        // day Kairo could actually see, so a single tap must not buy the evidence
        // gate a full day of confidence.
        log.record(sip("sip-1", 5_000))
        let one = log.coverageMetric(expectedSips: 5)
        #expect(one.observedCount == 1)
        #expect(one.expectedCount == 5)
        #expect(abs(one.observedFraction - 0.2) < 0.0001)
        #expect(one.domain == .hydration)

        for i in 2...5 { log.record(sip("sip-\(i)", 50, minutes: i * 30)) }
        let five = log.coverageMetric(expectedSips: 5)
        #expect(five.observedCount == 5)
        #expect(five.observedFraction == 1)
    }

    @Test("an expectation of zero sips cannot make coverage undefined")
    func expectedSipsNeverZero() {
        let log = HydrationLog(dayStart: dayStart)
        #expect(log.coverageMetric(expectedSips: 0).expectedCount == 1)
    }
}

/// The consolidated digest the wrist reads.
///
/// The whole point of `DayLog` is that the phone composes every line - it is the
/// only side that knows where a figure came from and what the evidence gate lets
/// it be called. So these tests are about two things: what survives the trip
/// verbatim, and what the initialiser is allowed to throw away.
@Suite("Wrist sync - the day's log")
struct DayLogTests {
    /// ISO-8601 keeps whole seconds, so a date lands within a second of where it
    /// started rather than exactly on it.
    static let dateTolerance: TimeInterval = 1

    let t = DateHelp.at(2026, 9, 7, 14, 25)

    private func entry(_ id: String, minutesAgo: Int) -> DayLog.Entry {
        DayLog.Entry(id: id, kind: .water,
                     at: t.addingTimeInterval(-Double(minutesAgo) * 60),
                     headline: "Water", detail: "350 ml")
    }

    @Test("a day the phone consolidated survives the round trip")
    func logRoundTrips() throws {
        let sent = PhoneEvent.log(DayLog(
            generatedAt: t,
            entries: [
                entry("sip-1", minutesAgo: 14),
                // No `detail`: an interruption has no number, which is not the
                // same as having a blank one.
                DayLog.Entry(id: "nudge-b2", kind: .interruption,
                             at: t.addingTimeInterval(-52 * 60),
                             headline: "Sitting nudge"),
                DayLog.Entry(id: "meal-1", kind: .meal,
                             at: t.addingTimeInterval(-3 * 3_600),
                             headline: "Lunch", detail: "2,410 kJ", confidence: 0.45),
            ],
            waterMillilitres: 1_450, waterTargetMillilitres: 2_000,
            kilojoulesLogged: 4_820, kilojoulesTarget: 8_700,
            sleepHoursLastNight: 7.2,
            interruptionsSpent: 2, dailyBudget: 6))

        let back = try WristSync.unwrap(PhoneEvent.self, from: try WristSync.envelope(sent))
        #expect(back == sent)

        guard case let .log(decoded) = back else {
            Issue.record("expected a log event"); return
        }
        // The phone's rendered lines arrive as written. The watch is not allowed
        // to phrase one itself, so the transport must not reword them either.
        #expect(decoded.entries.map(\.headline) == ["Water", "Sitting nudge", "Lunch"])
        #expect(decoded.entries[0].detail == "350 ml")
        #expect(decoded.entries[1].detail == nil)
        #expect(decoded.entries[1].kind == .interruption)
        // A weak figure has to arrive weak, or the wrist shows a guess as clean.
        #expect(decoded.entries[2].confidence == 0.45)
        #expect(decoded.entries[2].kind == .meal)

        #expect(decoded.waterMillilitres == 1_450)
        #expect(decoded.waterTargetMillilitres == 2_000)
        #expect(decoded.kilojoulesLogged == 4_820)
        #expect(decoded.kilojoulesTarget == 8_700)
        #expect(decoded.sleepHoursLastNight == 7.2)
        #expect(decoded.interruptionsSpent == 2)
        #expect(decoded.dailyBudget == 6)
        #expect(abs(decoded.generatedAt.timeIntervalSince(t)) < Self.dateTolerance)
    }

    @Test("an unmeasured figure arrives as nil, never as zero")
    func logKeepsNilOptionalsDistinctFromZero() throws {
        // This is what the phone genuinely sends today: it holds no meal ledger,
        // so both energy figures are absent. Nothing on the wire may turn that
        // into a confident 0 - a day nobody logged is not a day without food.
        let unmeasured = DayLog(generatedAt: t,
                                entries: [entry("sip-1", minutesAgo: 5)],
                                waterMillilitres: 350, waterTargetMillilitres: 2_000,
                                kilojoulesLogged: nil, kilojoulesTarget: nil,
                                sleepHoursLastNight: nil)
        var measuredZero = unmeasured
        measuredZero.kilojoulesLogged = 0
        measuredZero.kilojoulesTarget = 0
        measuredZero.sleepHoursLastNight = 0
        // "your phone has not measured this" and "you had none of it" are
        // different answers, and the log page says a different thing for each.
        #expect(unmeasured != measuredZero)

        let back = try WristSync.unwrap(
            PhoneEvent.self, from: try WristSync.envelope(PhoneEvent.log(unmeasured)))
        guard case let .log(decoded) = back else {
            Issue.record("expected a log event"); return
        }
        #expect(decoded.kilojoulesLogged == nil)
        #expect(decoded.kilojoulesTarget == nil)
        #expect(decoded.sleepHoursLastNight == nil)
        #expect(decoded != measuredZero)
        // An entry's own optionals go the same way: a tap is exact, so it carries
        // no confidence rather than a fabricated 1.0.
        #expect(decoded.entries[0].confidence == nil)
        #expect(decoded.entries[0].detail == "350 ml")
    }

    @Test("the digest keeps the newest entries and caps at the limit")
    func entriesAreSortedNewestFirstAndCapped() {
        // More than fit, in the wrong order, which is the real case: a day's sips
        // are appended oldest-first and the wrist can only show a handful.
        let count = DayLog.entryLimit + 5
        // `sip-0` is the newest; each subsequent one is seven minutes older.
        let entries = (0..<count).map { entry("sip-\($0)", minutesAgo: $0 * 7) }
        let log = DayLog(generatedAt: t, entries: entries.shuffled())

        #expect(log.entries.count == DayLog.entryLimit)
        // The newest survived, and it is first - the cap must never be a plain
        // prefix of whatever order the caller happened to build.
        #expect(log.entries.first?.id == "sip-0")
        // What was dropped is the oldest end, not an arbitrary slice.
        #expect(log.entries.last?.id == "sip-\(DayLog.entryLimit - 1)")
        #expect(log.entries.contains { $0.id == "sip-\(count - 1)" } == false)

        let times = log.entries.map(\.at)
        #expect(times == times.sorted(by: >))
    }

    @Test("an empty digest is a real answer about the day, not a missing one")
    func isEmptyReflectsEntriesOnly() {
        // The watch draws two different screens for these, and the distinction it
        // needs is "the phone sent nothing" - a nil `DayLog` - versus "the phone
        // sent a day with nothing in it", which is this.
        #expect(DayLog(generatedAt: t).isEmpty)

        // Totals without a listed entry still leave the list empty: `isEmpty` is
        // about the entries and nothing else.
        let totalsOnly = DayLog(generatedAt: t, waterMillilitres: 500,
                                waterTargetMillilitres: 2_000)
        #expect(totalsOnly.isEmpty)

        let oneSip = DayLog(generatedAt: t, entries: [entry("sip-1", minutesAgo: 2)])
        #expect(oneSip.isEmpty == false)
    }
}

@Suite("The wrist link, in the states a person can act on")
struct WristLinkTests {

    @Test("a watch in the next room still carries what was tapped on it")
    func outOfReachIsNotLost() {
        // The outbox re-sends on reconnect, so a glass logged on a walk is late
        // rather than gone. A screen that treated this as a failure would be
        // telling the truth about the radio and a lie about the data.
        #expect(WristLink.outOfReach.carriesTaps)
        #expect(WristLink.connected.carriesTaps)
    }

    @Test("not owning a watch is not a failure state")
    func noWatchCarriesNothingAndIsNotActionable() {
        #expect(!WristLink.noWatch.carriesTaps)
        #expect(!WristLink.unsupported.carriesTaps)
    }

    @Test("only the two live states carry taps")
    func carryingIsNarrow() {
        let carrying = WristLink.allCases.filter(\.carriesTaps)
        #expect(Set(carrying) == [.connected, .outOfReach])
    }

    @Test("connecting is transient, and not drawn as a failure")
    func connectingIsNeither() {
        // The page says "this takes a second" here, not "error".
        #expect(!WristLink.connecting.carriesTaps)
    }
}
