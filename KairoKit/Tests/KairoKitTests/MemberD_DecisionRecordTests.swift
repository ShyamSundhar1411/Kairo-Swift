import Testing
import Foundation
@testable import KairoKit

/// Member D - CF12. The modelling point: sealed content is append-only.
@Suite("Member D - decision records")
struct DecisionRecordTests {
    let t = DateHelp.at(2026, 8, 25, 15, 40)

    func sealed() throws -> DecisionRecord {
        var r = DecisionRecord(id: "dr-1", createdAt: t)
        try r.add(ContributionFragment(agentID: AgentID.lifestyle.rawValue, promptVersion: "v1",
                                       claim: "82 minutes unbroken sitting", confidence: 0.79))
        try r.add(ContributionFragment(agentID: AgentID.coach.rawValue, promptVersion: "v1",
                                       claim: "deliver a 90 second walk prompt", confidence: 0.71))
        try r.cite(MemoryCitation(memoryID: "m17", confidenceAtCitation: 0.81))
        try r.setSafetyVerdict("pass", tier: "Healthy")
        try r.lifecycle.transition(on: "allFragmentsCollected", to: .sealed, at: t)
        return r
    }

    @Test("a sealed record refuses new content")
    func sealedRefusesWrites() throws {
        var r = try sealed()
        #expect(throws: DecisionRecord.SealError.self) {
            try r.add(ContributionFragment(agentID: "x", promptVersion: "v1", claim: "y", confidence: 1))
        }
        #expect(throws: DecisionRecord.SealError.self) {
            try r.cite(MemoryCitation(memoryID: "m99", confidenceAtCitation: 0.5))
        }
    }

    @Test("a correction appends an annotation, it never rewrites history")
    func correctionAppends() throws {
        var r = try sealed()
        let before = r.fragments
        r.annotate(Annotation(at: t, author: "user", text: "the sitting bout included a drive"))
        #expect(r.fragments == before, "sealed content must be untouched")
        #expect(r.annotations.count == 1)
    }

    @Test("the record names which role produced which claim")
    func rolesAreAttributable() throws {
        let r = try sealed()
        #expect(r.contributingAgents.contains(AgentID.lifestyle.rawValue))
        #expect(r.contributingAgents.contains(AgentID.coach.rawValue))
        #expect(r.citations.first?.confidenceAtCitation == 0.81,
                "the confidence cited is the one held at the time, not the one held now")
    }

    @Test("the why-did-you-say-that path returns to published")
    func whyPath() throws {
        var r = try sealed()
        try r.lifecycle.transition(on: "deliveredToUser", to: .published, at: t)
        try r.lifecycle.transition(on: "userAskedWhy", to: .queried, at: t)
        try r.lifecycle.transition(on: "closed", to: .published, at: t)
        #expect(r.state == .published)
    }

    @Test("a dispute can only be resolved by annotation")
    func disputeAnnotates() throws {
        var r = try sealed()
        try r.lifecycle.transition(on: "deliveredToUser", to: .published, at: t)
        try r.lifecycle.transition(on: "userDisputed", to: .disputed, at: t)
        try r.lifecycle.transition(on: "openedForReview", to: .underReview, at: t)
        #expect(throws: LifecycleError<DecisionRecordState>.self) {
            try r.lifecycle.transition(on: "closed", to: .published, at: t)
        }
        try r.lifecycle.transition(on: "annotationAppended", to: .amendedByAnnotation, at: t)
        #expect(r.state == .amendedByAnnotation)
    }
}

/// Member D - CF10.
@Suite("Member D - habit memory")
struct MemoryTests {
    let t = DateHelp.at(2026, 8, 25)

    @Test("a memory cited by a sealed record stays retrievable after it decays")
    func pinnedMemorySurvivesDecay() throws {
        var m = MemoryItem(id: "m17", text: "ignores nudges before 9am", confidence: 0.81, sourceRef: "outcomes")
        try m.lifecycle.transition(on: "userConfirmed", to: .verified, at: t)
        try m.lifecycle.transition(on: "promoted", to: .active, at: t)
        m.pin(by: "dr-1")
        try m.lifecycle.transition(on: "noLongerObserved", to: .unconfirmed, at: t)
        try m.lifecycle.transition(on: "decayWindowPassed", to: .decaying, at: t)
        try m.lifecycle.transition(on: "confidenceFloorReached", to: .expired, at: t)
        #expect(m.isRetrievable, "decay must not rewrite what a sealed record cited")
    }

    @Test("a hard dietary constraint is exempt from decay")
    func hardConstraintIsExempt() {
        let m = MemoryItem(id: "m23", text: "lactose intolerant", confidence: 0.97,
                           sensitivity: .health, sourceRef: "user", decayExempt: true)
        #expect(m.decayExempt)
        #expect(m.sensitivity.mustStayOnDevice, "NFR5: health-sensitive memories never leave the device")
    }

    @Test("the store never returns a health memory to a cloud-scoped query")
    func sensitivityScoping() throws {
        let store = InMemoryMemoryStore([
            {
                var a = MemoryItem(id: "m1", text: "hates running", confidence: 0.8, sourceRef: "chat")
                _ = try? a.lifecycle.transition(on: "userConfirmed", to: .verified, at: t)
                _ = try? a.lifecycle.transition(on: "promoted", to: .active, at: t)
                return a
            }(),
            {
                var b = MemoryItem(id: "m2", text: "running causes knee pain", confidence: 0.9,
                                   sensitivity: .health, sourceRef: "chat")
                _ = try? b.lifecycle.transition(on: "userConfirmed", to: .verified, at: t)
                _ = try? b.lifecycle.transition(on: "promoted", to: .active, at: t)
                return b
            }(),
        ])
        let cloudScoped = try store.query("running", k: 5, maxSensitivity: .personal)
        #expect(cloudScoped.map(\.id) == ["m1"])
        let onDevice = try store.query("running", k: 5, maxSensitivity: .health)
        #expect(onDevice.count == 2)
    }
}
