import Foundation
import KairoKit

/// The composition root. Every port is bound here and nowhere else.
///
/// There used to be two configurations. `.preview` bound a `FixedClock` frozen at
/// 25 August 2026 15:40, a stub health source, three seeded memories and an
/// offline food table; `@main` bound it unconditionally, so the app on a real
/// phone opened on the report's Tuesday no matter whose wrist it was on. It is
/// gone. There is one configuration, and every port in it reaches something real:
///
/// | Port | Bound to |
/// |---|---|
/// | `clock` | the system clock |
/// | `health` | HealthKit, which asks for authorisation on first read |
/// | `memoryStore` | an empty on-device store; the book comes from the backend |
/// | `receptivity` | `ObservedReceptivityModel` over this phone's outcome log |
/// | `nutrition` | Open Food Facts |
/// | `channels` | notifications, and the paired watch |
///
/// What none of them do is invent a reading. A port that cannot answer returns
/// nothing, `Observations` reports it as not measured, and `DayCoverage` drops
/// what Kairo is permitted to assert. Silence on an unmeasured day is the
/// designed output, not a failure to populate the screen.
struct AppEnvironment {
    var clock: Clock
    var memoryStore: MemoryStore
    var health: HealthDataSource
    var receptivity: ReceptivityModel
    var channels: [NudgeChannel]
    var safety: SafetyGate
    var arbiter: NudgeArbiter
    /// Open Food Facts. A kilojoule figure carries the citation it came from, so
    /// a lookup that fails is reported as a lookup that failed rather than
    /// replaced with a plausible number.
    var nutrition: NutritionRepository
    /// The phone half of the watch link. Local IPC rather than network: with no
    /// watch paired it simply never delivers anything. `AppModel` attaches its
    /// handlers to it.
    var wrist: PhoneConnectivityBridge?
    /// What receptivity is learned from. Held here as well as inside the model so
    /// `AppModel` can append to it when the wrist reports an outcome.
    var outcomes: NudgeOutcomeLog

    static var live: AppEnvironment {
        // One session, shared: the bridge that receives from the wrist is the same
        // one the watch channel sends through. Two `WCSession` delegates would
        // fight over `WCSession.default`, and only the last one assigned would
        // ever hear anything.
        let wrist = PhoneConnectivityBridge()
        let outcomes = StoredOutcomeLog()
        let receptivity = ObservedReceptivityModel(log: outcomes)
        return AppEnvironment(
            clock: SystemClock(),
            memoryStore: InMemoryMemoryStore([]),
            health: HealthKitDataSource(),
            receptivity: receptivity,
            channels: [NotificationNudgeChannel(), WatchNudgeChannel(bridge: wrist)],
            safety: SafetyGate(),
            arbiter: NudgeArbiter(receptivity: receptivity),
            nutrition: OpenFoodFactsRepository(),
            wrist: wrist,
            outcomes: outcomes)
    }
}
