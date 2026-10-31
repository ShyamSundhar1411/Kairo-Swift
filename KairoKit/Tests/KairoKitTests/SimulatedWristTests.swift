import Testing
import Foundation
@testable import KairoKit

/// Demo mode's simulated wrist. What matters for a presentation is that the
/// script reaches the moments the agents react to — a long sitting run, a walk
/// break, a heart-rate spike — and does so the same way every run.
@Suite("Simulated wrist — the demo's signal script")
struct SimulatedWristTests {
    let t = DateHelp.at(2026, 9, 7, 15, 0)

    @Test("a tick of readings survives the phone/watch envelope")
    func readingsRoundTrip() throws {
        var wrist = SimulatedWrist()
        let sent = WristEvent.simulatedReadings(wrist.advance(at: t).readings)
        let back = try WristSync.unwrap(WristEvent.self, from: try WristSync.envelope(sent))
        #expect(back == sent)
    }

    @Test("sitting climbs one minute per tick until the walk break")
    func sittingClimbsThenBreaks() {
        var wrist = SimulatedWrist(sittingMinutes: 100, standUpAfter: 105)
        for _ in 0..<5 { _ = wrist.advance(at: t) }
        #expect(wrist.sittingMinutes == 105)

        let steps = wrist.stepsToday
        _ = wrist.advance(at: t)
        #expect(wrist.sittingMinutes == 0)
        #expect(wrist.heartRateBPM >= 98)
        #expect(wrist.stepsToday == steps + 110)
    }

    @Test("the walk lasts four minutes and then the run starts again")
    func walkThenSitAgain() {
        var wrist = SimulatedWrist()
        _ = wrist.standUp(at: t)
        for _ in 0..<(SimulatedWrist.walkMinutes - 1) {
            _ = wrist.advance(at: t)
            #expect(wrist.sittingMinutes == 0)
        }
        _ = wrist.advance(at: t)
        #expect(wrist.sittingMinutes == 1)
    }

    @Test("the same start gives the same afternoon")
    func deterministic() {
        var a = SimulatedWrist(), b = SimulatedWrist()
        for _ in 0..<200 {
            let first = a.advance(at: t)
            let second = b.advance(at: t)
            #expect(first == second)
        }
    }

    @Test("a sip arrives on schedule")
    func sips() {
        var wrist = SimulatedWrist(sipEvery: 3)
        let sips = (0..<9).compactMap { _ in wrist.advance(at: t).sipMillilitres }
        #expect(sips == [250, 250, 250])
    }

    @Test("the observation lines carry heart rate and steps only when present")
    func observationLines() {
        #expect(!Observations(sedentaryMinutes: 82).lines.contains { $0.contains("heart rate") })
        let obs = Observations(sedentaryMinutes: 82, heartRateBPM: 104, stepsToday: 4_210)
        #expect(obs.lines.contains("heart rate: 104 bpm now"))
        #expect(obs.lines.contains("steps today: 4210"))
    }
}
