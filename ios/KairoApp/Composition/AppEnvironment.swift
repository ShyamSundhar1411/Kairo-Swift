import Foundation
import KairoKit

/// The composition root. Every port is bound here and nowhere else, which is what
/// lets the whole app run on fakes with no network, no HealthKit and no API key.
///
/// `.preview` is the configuration the demo and the recorded video use: fully
/// deterministic, offline, and reproducible. `.live` swaps in the real adapters.
struct AppEnvironment {
    var clock: Clock
    var memoryStore: MemoryStore
    var health: HealthDataSource
    var receptivity: ReceptivityModel
    var channels: [NudgeChannel]
    var safety: SafetyGate
    var arbiter: NudgeArbiter
    /// Where a kilojoule figure is allowed to come from. Preview reads the
    /// bundled Open Food Facts extract, so the demo needs no network; live goes
    /// to Open Food Facts itself. Same port either way, same citation either way.
    var nutrition: NutritionRepository
    /// nil in preview: the agents answer from the scripted provider instead.
    var remote: RemoteAgentClient?
    /// The phone half of the watch link. nil in preview for the same reason
    /// `remote` is: the recorded demo runs with no server and no paired watch, and
    /// a `WCSession` would make it depend on whichever hardware is in the room.
    /// Live owns the session, and `AppModel` attaches its handlers to it.
    var wrist: PhoneConnectivityBridge?

    static var preview: AppEnvironment {
        let clock = FixedClock(DateHelp.at(2026, 8, 25, 15, 40))
        let receptivity = TableReceptivityModel([
            "hydration": 0.70, "sedentary": 0.90, "bedtimePrep": 0.60,
        ])
        // The wrist bridge belongs in preview too. It is local IPC, not network:
        // with no watch paired it simply never delivers anything, so preview
        // stays offline and deterministic — but a paired watch can actually
        // reach the phone. Leaving it nil here is what shipped, and it is why
        // water logged on the wrist had nowhere to arrive: `@main` binds
        // `.preview`, so the receiving end was never constructed.
        let wrist = PhoneConnectivityBridge()
        return AppEnvironment(
            clock: clock,
            memoryStore: InMemoryMemoryStore(SeedData.memories(at: clock.now)),
            health: StubHealthDataSource(),
            receptivity: receptivity,
            channels: [WatchNudgeChannel(bridge: wrist), RecordingNudgeChannel(kind: .inApp)],
            safety: SafetyGate(),
            arbiter: NudgeArbiter(receptivity: receptivity),
            nutrition: BundledNutritionRepository(),
            remote: nil,
            wrist: wrist)
    }

    static func live(serverBaseURL: URL) -> AppEnvironment {
        var env = preview
        env.clock = SystemClock()
        env.health = HealthKitDataSource()
        env.nutrition = OpenFoodFactsRepository()
        env.remote = RemoteAgentClient(baseURL: serverBaseURL)

        // One session, shared: the bridge that receives from the wrist is the same
        // one the watch channel sends through. Two `WCSession` delegates would
        // fight over `WCSession.default`, and only the last one assigned would
        // ever hear anything — which is also why this reuses the bridge preview
        // already built rather than making a second.
        let bridge = env.wrist ?? PhoneConnectivityBridge()
        env.wrist = bridge
        env.channels = [NotificationNudgeChannel(), WatchNudgeChannel(bridge: bridge)]
        return env
    }
}

/// The scenario drawn in the Stage 1 object diagram, so the app opens on the
/// exact state the report describes.
enum SeedData {
    static func memories(at now: Date) -> [MemoryItem] {
        var m17 = MemoryItem(id: "m17", text: "ignores nudges before 9am",
                             confidence: 0.81, sourceRef: "nudge-outcomes")
        _ = try? m17.lifecycle.transition(on: "corroboratedByBehaviour", to: .verified, at: now)
        _ = try? m17.lifecycle.transition(on: "promoted", to: .active, at: now)

        var m23 = MemoryItem(id: "m23", text: "lactose intolerant", confidence: 0.97,
                             sensitivity: .health, sourceRef: "user", decayExempt: true)
        _ = try? m23.lifecycle.transition(on: "userConfirmed", to: .verified, at: now)
        _ = try? m23.lifecycle.transition(on: "promoted", to: .active, at: now)

        var m31 = MemoryItem(id: "m31", text: "walks the dog at 7pm on weekdays",
                             confidence: 0.64, sourceRef: "motion-pattern")
        _ = try? m31.lifecycle.transition(on: "corroboratedByBehaviour", to: .verified, at: now)
        _ = try? m31.lifecycle.transition(on: "promoted", to: .active, at: now)
        return [m17, m23, m31]
    }

    /// The three bids the report's object diagram shows, with their text taken
    /// from `observations` where a real reading exists.
    ///
    /// With no observations this returns the documented Stage 1 scenario verbatim,
    /// which is what `.preview` and the recorded demo open on. Once the wrist has
    /// actually logged something the hydration figure is the real one — a card
    /// that says "340 ml behind" while the user is looking at a glass they just
    /// logged is the same bug in a different place.
    static func bids(at now: Date, observations: Observations = .none) -> [NudgeBid] {
        var out: [NudgeBid] = []

        if let text = hydrationBidText(observations) {
            out.append(NudgeBid(id: "b1", nudgeClass: "hydration",
                                originAgent: AgentID.coach.rawValue,
                                expectedBenefit: 0.60, urgency: 0.3,
                                windowOpens: now.addingTimeInterval(-3600),
                                windowCloses: now.addingTimeInterval(3600),
                                text: text))
        }

        let sitting = observations.sedentaryMinutes ?? 82
        out.append(NudgeBid(id: "b2", nudgeClass: "sedentary",
                            originAgent: AgentID.lifestyle.rawValue,
                            expectedBenefit: 0.79, urgency: 0.7,
                            windowOpens: now.addingTimeInterval(-600),
                            windowCloses: now.addingTimeInterval(1800),
                            requiredCapabilities: [.standing, .walking],
                            text: "\(sitting) minutes unbroken. Ninety seconds on your feet?"))

        out.append(NudgeBid(id: "b3", nudgeClass: "bedtimePrep",
                            originAgent: AgentID.lifestyle.rawValue,
                            expectedBenefit: 0.55, urgency: 0.2,
                            windowOpens: DateHelp.at(2026, 8, 25, 21, 30),
                            windowCloses: DateHelp.at(2026, 8, 25, 23, 0),
                            text: "Start winding down."))
        return out
    }

    /// nil when there is nothing to say about water.
    ///
    /// Someone who has already hit their target does not get interrupted about it:
    /// dropping the bid is the honest answer, and it also means the arbiter's
    /// silence on the Today screen is earned rather than staged.
    private static func hydrationBidText(_ observations: Observations) -> String? {
        guard let logged = observations.hydrationML,
              let target = observations.hydrationTargetML else {
            // Not measured. The Stage 1 figure, unchanged.
            return "You are 340 ml behind today."
        }
        let behind = target - logged
        guard behind > 0 else { return nil }
        return "You are \(behind) ml behind today."
    }
}
