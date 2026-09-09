import Testing
import Foundation
@testable import KairoKit

/// Member C — CF9. The interesting part is what the machine refuses to do.
@Suite("Member C — disruption contract")
struct PlanContractTests {
    let t = DateHelp.at(2026, 8, 25, 8, 0)

    @Test("one signal is not enough to propose a contract")
    func singleSignalIsNotCorroborated() {
        var c = PlanContract(id: "pc-1")
        c.observe(DisruptionSignal(kind: .illness, source: "wristTemperature", observedAt: t, strength: 0.7))
        #expect(!c.isCorroborated(userConfirmed: false),
                "a wrong illness call is the failure that made competitors' users quit")
    }

    @Test("two independent sources corroborate")
    func twoSourcesCorroborate() {
        var c = PlanContract(id: "pc-2")
        c.observe(DisruptionSignal(kind: .illness, source: "wristTemperature", observedAt: t, strength: 0.7))
        c.observe(DisruptionSignal(kind: .illness, source: "restingHeartRate", observedAt: t, strength: 0.6))
        #expect(c.isCorroborated(userConfirmed: false))
    }

    @Test("two readings from the same sensor do not corroborate each other")
    func sameSourceTwiceIsStillOneSignal() {
        var c = PlanContract(id: "pc-3")
        c.observe(DisruptionSignal(kind: .illness, source: "wristTemperature", observedAt: t, strength: 0.7))
        c.observe(DisruptionSignal(kind: .illness, source: "wristTemperature", observedAt: t, strength: 0.8))
        #expect(!c.isCorroborated(userConfirmed: false))
    }

    @Test("the user saying so is always enough")
    func userConfirmationSuffices() {
        let c = PlanContract(id: "pc-4")
        #expect(c.isCorroborated(userConfirmed: true))
    }

    @Test("uncorroborated suspicion returns to standard rather than proposing")
    func insufficientEvidenceReverts() throws {
        var c = PlanContract(id: "pc-5")
        try c.lifecycle.transition(on: "signalDetected", to: .disruptionSuspected, at: t)
        try c.lifecycle.transition(on: "insufficientEvidence", to: .standard, at: t)
        #expect(c.state == .standard)
    }

    @Test("the third extension escalates instead of extending")
    func thirdExtensionEscalates() throws {
        var c = PlanContract(id: "pc-6")
        #expect(c.expiryDisposition == .autoExtend)
        c.noteExtension()
        #expect(c.expiryDisposition == .askUser)
        c.noteExtension()
        #expect(c.expiryDisposition == .escalate,
                "a fortnight of 'still unwell' is a signal, not a setting")

        try c.lifecycle.transition(on: "signalDetected", to: .disruptionSuspected, at: t)
        try c.lifecycle.transition(on: "corroborated", to: .proposed, at: t)
        try c.lifecycle.transition(on: "userAccepted", to: .active, at: t)
        try c.lifecycle.transition(on: "thirdExtensionRequested", to: .escalated, at: t)
        #expect(c.state == .escalated)
        #expect(c.lifecycle.isTerminal)
    }

    @Test("the Steward can veto a contract that would mask deterioration")
    func stewardVeto() throws {
        var c = PlanContract(id: "pc-7")
        try c.lifecycle.transition(on: "signalDetected", to: .disruptionSuspected, at: t)
        try c.lifecycle.transition(on: "corroborated", to: .proposed, at: t)
        try c.lifecycle.transition(on: "stewardVetoed", to: .standard, at: t)
        #expect(c.state == .standard)
    }
}
