import Foundation
import KairoKit

/// Member C - CF7. Delivers an allocated nudge to the wrist.
///
/// The watch has had a nudge card since the first prototype and it could never
/// appear from real arbitration, because nothing on the phone ever pushed one.
/// This channel is the missing half: the arbiter allocates, and the winning
/// interruption goes out over `PhoneEvent.nudge`.
///
/// Like `NotificationNudgeChannel`, this delivers whatever it is handed. NFR8's
/// ceiling is the arbiter's job - a channel that quietly dropped nudges would
/// corrupt the outcome history the receptivity model is meant to learn from.
final class WatchNudgeChannel: NudgeChannel, @unchecked Sendable {
    let kind: NudgeChannelKind = .watchHaptic

    private let bridge: PhoneConnectivityBridge

    init(bridge: PhoneConnectivityBridge) {
        self.bridge = bridge
    }

    /// NFR11, the same test `RecordingNudgeChannel` applies: a bid that needs a
    /// capability this user does not have must not be delivered as written. The
    /// arbiter still gets to substitute a confirmed equivalent - this only
    /// declares what the wrist can render unaided.
    func canRender(_ bid: NudgeBid, for profile: CapabilityProfile) -> Bool {
        profile.satisfies(bid.requiredCapabilities)
    }

    func deliver(_ nudge: Nudge) throws {
        // `rewrittenFrom` is nil, honestly rather than lazily: nothing in the
        // pipeline rewrites a bid's text yet. `NudgeArbiter` checks that a
        // confirmed equivalent *exists* and then lets the original through
        // unchanged, so there is no substitution to disclose. When the rewrite
        // lands, the original belongs here so the watch can say what it replaced.
        bridge.send(.nudge(bidID: nudge.bid.id,
                           text: nudge.bid.text,
                           nudgeClass: nudge.bid.nudgeClass,
                           rewrittenFrom: nil))
    }
}
