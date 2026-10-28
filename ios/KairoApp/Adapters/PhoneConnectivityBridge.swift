import Foundation
import KairoKit
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// Member C — CF7 / CF8. The phone half of the phone <-> watch link.
///
/// The watch has had a bridge since the first prototype; the phone had nothing —
/// no `WCSession`, no delegate, no receiver. So a glass of water tapped on the
/// wrist was encoded, sent, and dropped on the floor, and an interruption the
/// arbiter had actually allocated could never reach the wrist. This file is the
/// other end of that wire.
///
/// It knows nothing about hydration or nudges beyond the two envelope types in
/// `KairoKit.WristSync`, which is deliberately the only place the wire format
/// exists: two hand-rolled dictionaries drifting apart is what broke this in the
/// first place.
///
/// **Threading.** Every `WCSessionDelegate` callback arrives on a private
/// WatchConnectivity queue, and the handlers below end up mutating the app's
/// `@Observable` model. So nothing is invoked inline: every callback is hopped to
/// the main queue first. Assign the handler properties from the main actor only
/// (the composition root does, once, in `AppModel.bootstrap()`); they are then
/// only ever read on the main queue, which is what keeps that access safe.
final class PhoneConnectivityBridge: NSObject, @unchecked Sendable {

    /// A decoded message from the wrist. Called on the main queue, so the handler
    /// may touch observable state directly.
    var onWristEvent: ((WristEvent) -> Void)?

    /// Activation finished, or reachability changed. Main queue.
    var onReachabilityChange: ((Bool) -> Void)?

    /// The link state changed in any way the pairing screen cares about —
    /// including a watch being paired or the app being installed on it, which
    /// `onReachabilityChange` does not cover. Main queue.
    var onLinkChange: ((WristLink) -> Void)?

    /// Something arrived that this build could not read — a version mismatch
    /// between a phone and a watch on different builds, most likely. Surfaced
    /// rather than swallowed, because a silently ignored message is exactly the
    /// failure this whole file exists to fix. Main queue.
    var onDecodeFailure: ((String) -> Void)?

    #if canImport(WatchConnectivity)
    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    /// Whether the wrist can be reached *right now*. False also covers "no watch
    /// paired at all", which is the common case and is not an error.
    var isReachable: Bool {
        guard let session, session.activationState == .activated else { return false }
        return session.isReachable
    }

    /// The link, in the four states a person can actually do something about.
    ///
    /// `isReachable` alone could not tell "you have no watch" from "your watch
    /// is in the other room", and those are opposite instructions — one is
    /// *this feature is not for you*, the other is *wait a moment*. The pairing
    /// screen needs them apart, so the bridge draws the distinction rather than
    /// the view guessing from a boolean.
    var link: WristLink {
        guard let session else { return .unsupported }
        guard session.activationState == .activated else { return .connecting }
        if !session.isPaired { return .noWatch }
        if !session.isWatchAppInstalled { return .appNotInstalled }
        return session.isReachable ? .connected : .outOfReach
    }

    override init() {
        super.init()
        // Activated on init rather than lazily: the watch may already be trying
        // to hand over messages it queued while the phone was away, and those are
        // only delivered to an activated session with a delegate attached.
        session?.delegate = self
        session?.activate()
    }

    /// Phone -> watch.
    ///
    /// `sendMessage` when the wrist is reachable, because that is immediate and
    /// an interruption is worth nothing late. Otherwise the application context,
    /// which the system hands over the next time the watch wakes.
    ///
    /// Caveat worth stating plainly: the application context holds exactly one
    /// payload, last write wins. That is right for `dayState` — it is a total, so
    /// the newest one is the only one that matters — but it means a queued nudge
    /// can be overwritten by the next day-state push. A nudge that arrives an
    /// hour late is not one we want anyway; the day state is the message that has
    /// to survive, and it does.
    func send(_ event: PhoneEvent) {
        guard let session, session.activationState == .activated else { return }
        guard let payload = try? WristSync.envelope(event) else { return }

        guard session.isReachable else {
            try? session.updateApplicationContext(payload)
            return
        }
        session.sendMessage(payload, replyHandler: nil) { [weak self] _ in
            // The link dropped mid-flight. Fall back to the queue rather than
            // losing the message, and re-read reachability instead of trusting
            // the value we checked a moment ago.
            self?.queueAsContext(payload)
        }
    }

    private func queueAsContext(_ payload: [String: Any]) {
        try? session?.updateApplicationContext(payload)
    }
    #else
    /// No framework linked means no watch on the other end. Reads as unreachable
    /// rather than as an error, and sends go nowhere by design.
    var isReachable: Bool { false }
    override init() { super.init() }
    func send(_ event: PhoneEvent) {}
    #endif
}

#if canImport(WatchConnectivity)
extension PhoneConnectivityBridge: WCSessionDelegate {

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if let error {
            report("watch session did not activate: \(error.localizedDescription)")
        }
        let reachable = error == nil && activationState == .activated && session.isReachable
        hop { self.onReachabilityChange?(reachable); self.onLinkChange?(self.link) }
    }

    /// A watch was paired, unpaired, or had the app installed or removed.
    /// Reachability does not change for any of those, so without this the
    /// pairing screen would sit on "no watch" while one was being set up two
    /// feet away.
    func sessionWatchStateDidChange(_ session: WCSession) {
        hop { self.onLinkChange?(self.link) }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        hop { self.onReachabilityChange?(reachable) }
    }

    // MARK: - Watch to phone

    /// The live path: the watch was able to reach us.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receive(message)
    }

    /// The same message sent *with* a reply handler. iOS calls this variant
    /// instead of the one above when the sender supplied one, so both have to
    /// exist or half the messages land nowhere depending on how the watch sent
    /// them. The reply is an empty acknowledgement — the watch is not waiting on
    /// a value, only on confirmation that someone was home.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        receive(message)
        replyHandler([:])
    }

    /// The queued path, and the one whose absence loses data.
    ///
    /// The watch falls back to `updateApplicationContext` whenever the phone is
    /// unreachable — screen off, app not running, out of range — so this is where
    /// every sip logged while the phone was away arrives. Ignoring it would lose
    /// exactly the messages the fallback was written to protect.
    ///
    /// The system re-delivers the current context on each activation, so the same
    /// sip can arrive several times. That is safe: `HydrationLog.record(_:)`
    /// discards by id, which is why `WristEvent.waterLogged` carries one.
    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        receive(context)
    }

    /// The watch may instead use `transferUserInfo`, which queues FIFO and loses
    /// nothing rather than collapsing to a single latest payload. Handled here so
    /// that if the watch side moves to it, the phone already listens.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        receive(userInfo)
    }

    // MARK: - Mandatory on iOS

    // Both of these are required by `WCSessionDelegate` on iOS — the app traps at
    // launch without them. They exist because one phone can be re-paired to a
    // different watch while running: the session deactivates, and reactivating is
    // what re-attaches us to the new one.
    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    // MARK: - Plumbing

    private func receive(_ message: [String: Any]) {
        do {
            let event = try WristSync.unwrap(WristEvent.self, from: message)
            hop { self.onWristEvent?(event) }
        } catch {
            report("wrist message could not be read: \(error)")
        }
    }

    private func report(_ why: String) {
        hop { self.onDecodeFailure?(why) }
    }

    /// Always asynchronous, never a "already on main" shortcut: a conditional hop
    /// would let a message that arrived second be handled first, and the day's
    /// water is an ordered log.
    private func hop(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }
}
#endif
