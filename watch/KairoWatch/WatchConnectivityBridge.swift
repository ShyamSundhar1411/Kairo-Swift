import Foundation
import KairoKit
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// Phone <-> watch transport. The phone arbitrates and pushes the winning nudge
/// plus the day as it counts it; the watch pushes outcomes and quick logs back.
///
/// The wire format is not written here. It lives once, in `KairoKit`'s
/// `WristSync`, and both apps link it — hand-rolled dictionaries with bare
/// string keys on each side is exactly how the two ends drifted apart and how a
/// glass of water logged on the wrist ended up going nowhere. This file is
/// transport only: one envelope out, one decoded event in.
///
/// The bridge also reports the state of the link itself, because the watch has
/// three genuinely different situations to tell apart and they are not the same
/// screen: the session still activating, an activated session with the phone out
/// of range, and a live link with nothing sent yet.
final class WatchConnectivityBridge: NSObject {
    /// Anything the phone said, already decoded. Turning an event into screen
    /// state is the model's job, not the transport's.
    var onPhoneEvent: ((PhoneEvent) -> Void)?
    /// Called whenever activation completes or reachability changes.
    var onLinkState: ((WatchModel.LinkState) -> Void)?

    #if canImport(WatchConnectivity)
    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    /// The link as it stands right now, for the first read before any callback.
    var linkState: WatchModel.LinkState {
        // No session at all is not a link that is coming back, so it reads as
        // out of range rather than as still loading.
        guard let session else { return .unreachable }
        switch session.activationState {
        case .activated: return session.isReachable ? .linked : .unreachable
        default:         return .activating
        }
    }

    override init() {
        super.init()
        session?.delegate = self
        session?.activate()
    }

    func send(_ event: WristEvent) {
        guard let payload = try? WristSync.envelope(event) else { return }
        guard let session, session.isReachable else {
            // Queue for the next time the phone is reachable rather than dropping
            // the event: a dismissed nudge the receptivity model never learns from
            // is worse than a late one. Application context holds one payload, so
            // the most recent send wins — which is why the model keeps its own
            // outbox of sips and re-sends them when the link comes back, with the
            // same ids so the phone can discard the duplicates.
            try? session?.updateApplicationContext(payload)
            return
        }
        session.sendMessage(payload, replyHandler: nil) { _ in }
    }
    #else
    /// Without the framework there is no phone on the other end to wait for.
    var linkState: WatchModel.LinkState { .unreachable }

    override init() { super.init() }
    func send(_ event: WristEvent) {}
    #endif

    /// The one place an inbound dictionary becomes an event, shared by both
    /// delivery paths.
    fileprivate func deliver(_ message: [String: Any]) {
        do {
            onPhoneEvent?(try WristSync.unwrap(PhoneEvent.self, from: message))
        } catch {
            // A payload this build cannot read — a newer phone, or something that
            // is not ours at all — is dropped rather than fatal: the watch's job
            // is to keep working with the last state it understood.
            #if DEBUG
            print("WatchConnectivityBridge: ignoring inbound message — \(error)")
            #endif
        }
    }
}

#if canImport(WatchConnectivity)
extension WatchConnectivityBridge: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                 error: Error?) {
        // Activation finished — either the link is live or the phone is simply
        // not in range. Both are better news than "still loading".
        onLinkState?(error == nil && state == .activated
                     ? (session.isReachable ? .linked : .unreachable)
                     : .unreachable)

        // Context that arrived while this app was not running is never delivered
        // as a callback; it is just sitting on the session. Replaying it here is
        // what stops the day's water reading zero after a relaunch.
        let stored = session.receivedApplicationContext
        if !stored.isEmpty { deliver(stored) }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        onLinkState?(session.isReachable ? .linked : .unreachable)
    }

    /// The live path: the phone is reachable and pushed something now.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        deliver(message)
    }

    /// The queued path: the phone updated its application context because the
    /// watch was unreachable at the time. Ignoring this loses precisely the
    /// messages that were queued for being important enough to keep.
    func session(_ session: WCSession, didReceiveApplicationContext
                 applicationContext: [String: Any]) {
        deliver(applicationContext)
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif
}
#endif
