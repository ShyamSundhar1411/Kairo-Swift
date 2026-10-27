import Foundation
import Observation
import KairoKit
#if canImport(WatchKit)
import WatchKit
#endif

/// The watch holds one pending nudge at a time and the day's water.
///
/// Arbitration happens on the phone and so does counting: the wrist is a remote
/// control with an opinion about the last few seconds, not a second source of
/// truth. So the model keeps two things — the phone's last `DayState`, which is
/// the truth, and the taps the phone has not accounted for yet, which are added
/// on top so a tap still lands instantly (CF8).
@Observable
final class WatchModel {
    private(set) var pending: PendingNudge?
    /// The state of the phone link, so the watch can stop claiming "nothing sent
    /// yet" when the truth is that it has not finished connecting or the phone is
    /// out of range.
    private(set) var linkState: LinkState = .activating

    /// The phone's account of today, once it has sent one. nil until then, which
    /// is not the same as a phone that has told us zero.
    private(set) var day: DayState?

    /// The phone's consolidated account of today, once it has sent one. nil until
    /// then, which the log page tells apart from a day with nothing in it.
    ///
    /// Deliberately **not** persisted, for exactly the reason `day` is not (see
    /// `init`): a `DayLog` restored from a previous launch could be yesterday's,
    /// and drawing a stale day as today's is the same class of error as
    /// double-counting a glass of water. The phone re-sends on bootstrap and
    /// after every water event, so the gap is a moment, not a day.
    private(set) var log: DayLog?

    /// NFR10 / SCRUM-19. Counts what this companion does that costs energy, so
    /// a regression is visible the day it lands rather than the day somebody
    /// runs Instruments. **Not a battery measurement** — watchOS gives an app
    /// its own `batteryLevel`, never its own share of the drain, so any number
    /// computed here would be the whole watch's consumption wearing this app's
    /// name. `docs/NFR10-BATTERY.md` has the procedure for the real one.
    private(set) var energy = WatchEnergyBudget(dayStart: Calendar.current.startOfDay(for: Date()))

    /// Sips tapped on this wrist that the phone's total does not yet cover.
    ///
    /// This is both the optimistic overlay on the display and the outbox: each
    /// one is re-sent, with its original id, whenever the link comes back, and
    /// the phone's `HydrationLog.record` throws the duplicates away.
    private(set) var unacknowledgedSips: [HydrationLog.Sip] = []

    /// Bids already answered, so a re-delivered application context cannot buzz
    /// the wrist a second time for a nudge the user has dealt with.
    private var answeredBidIDs: Set<String> = []

    private let bridge = WatchConnectivityBridge()

    /// A tap the phone has still not counted after this long was lost in transit
    /// rather than merely slow. At that point the phone's total is the better
    /// answer than our guess, so the sip is dropped from the overlay: losing one
    /// glass from the display is bounded and honest, whereas carrying a phantom
    /// 200 ml for the rest of the day is neither.
    private static let sipStaleAfter: TimeInterval = 15 * 60
    /// A cap so an all-day outage cannot grow the outbox without limit.
    private static let outboxLimit = 40
    /// Used until the phone says what it wants the target to be.
    private static let defaultWaterTarget = 2_000

    // MARK: - What the screens read

    /// CF8 — the phone's total plus the taps it has not confirmed. Before the
    /// first `DayState` this is simply what has been tapped here, which is the
    /// only number the watch legitimately has.
    var waterMillilitres: Int {
        (day?.waterMillilitres ?? 0) + unacknowledgedSips.reduce(0) { $0 + $1.millilitres }
    }

    var waterTargetMillilitres: Int {
        day?.waterTargetMillilitres ?? Self.defaultWaterTarget
    }

    /// nil when the phone has not measured sitting, which is different from zero
    /// minutes of it — the sitting page says two different things for the two.
    var sedentaryMinutes: Int? { day?.sedentaryMinutes }

    /// True while a tap is still ahead of the phone. Worth stating quietly; not
    /// worth a spinner.
    var hasUnacknowledgedWater: Bool { !unacknowledgedSips.isEmpty }

    struct PendingNudge: Sendable, Equatable {
        let bidID: String
        let text: String
        let nudgeClass: String
        /// Substituted text when the original required a capability the user
        /// does not have (NFR11) — shown so the substitution is never silent.
        let rewrittenFrom: String?
    }

    /// The three situations the watch has to tell apart.
    enum LinkState: Sendable, Equatable {
        /// The WatchConnectivity session has not finished activating: genuinely
        /// still loading, and the only state that earns a loader.
        case activating
        /// Activated, but the phone is not reachable right now.
        case unreachable
        /// Activated and the phone is reachable. Silence here means the phone has
        /// nothing to say, not that anything is broken.
        case linked
    }

    init() {

        // Today's un-confirmed taps, recovered from disk. The total itself is not
        // restored: a `DayState` kept from a previous launch could be yesterday's,
        // and showing a stale total as today's is worse than showing the taps we
        // know about and waiting a moment for the phone.
        unacknowledgedSips = WaterOutbox.loadForToday()

        bridge.onPhoneEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        bridge.onLinkState = { [weak self] state in
            Task { @MainActor in
                self?.linkState = state
                if state == .linked { self?.flushOutbox() }
            }
        }
        // Read the link once up front: activation may already have completed
        // before the callback above was wired in.
        linkState = bridge.linkState
        if linkState == .linked { flushOutbox() }
    }

    // MARK: - Inbound

    private func handle(_ event: PhoneEvent) {
        switch event {
        case let .nudge(bidID, text, nudgeClass, rewrittenFrom):
            // Application context is re-delivered, so the same winning bid can
            // arrive twice. Buzzing again for a nudge already answered would be
            // Kairo spending an interruption it never earned (CF7).
            guard !answeredBidIDs.contains(bidID), pending?.bidID != bidID else { return }
            pending = PendingNudge(bidID: bidID, text: text,
                                   nudgeClass: nudgeClass, rewrittenFrom: rewrittenFrom)
            haptic(.notification)

        case let .dayState(state):
            adopt(state)

        case let .log(digest):
            // Nothing to reconcile here, unlike `dayState`. The digest is
            // read-only and the phone is its only author, so the newest one
            // simply replaces the last — there is no local overlay that could
            // disagree with it, and no tally for a repeat delivery to inflate.
            log = digest
        }
    }

    /// The phone's total is the truth; the question is which of our taps it has
    /// already counted.
    ///
    /// `DayState` carries a total, not the ids behind it, and a state computed a
    /// moment before a sip arrived would scrub the tap the user just made. What
    /// we do know is that the phone's log only ever appends over a day, so the
    /// *growth* since the last state we saw is millilitres it has newly counted.
    /// That growth is spent against our outstanding sips oldest-first, and
    /// whatever it does not cover stays added on top of the display.
    ///
    /// The bias is deliberate: if the phone logged something itself we may retire
    /// one of our sips early and briefly under-state by a glass, corrected by the
    /// next state. Under-stating hydration for a few seconds is recoverable;
    /// double-counting it is the thing that makes the number untrustworthy.
    ///
    /// A lower total than the one we hold is taken as the phone having started a
    /// new day, so it re-bases rather than being discarded. `DayState` carries no
    /// timestamp, so that is indistinguishable from two states arriving out of
    /// order — the phone sends them over an ordered session and its queued
    /// fallback is last-write-wins, which is what makes the assumption safe.
    private func adopt(_ state: DayState) {
        let previous = day?.waterMillilitres ?? 0
        var growth = max(0, state.waterMillilitres - previous)
        day = state

        while let oldest = unacknowledgedSips.first, growth >= oldest.millilitres {
            growth -= oldest.millilitres
            unacknowledgedSips.removeFirst()
        }

        // Anything left that is this old never made it. See `sipStaleAfter`.
        let cutoff = Date().addingTimeInterval(-Self.sipStaleAfter)
        unacknowledgedSips.removeAll { $0.at < cutoff }
        WaterOutbox.save(unacknowledgedSips)
    }

    // MARK: - Outbound

    func accept() {
        report("userAccepted")
        haptic(.success)
    }

    func snooze() {
        report("userSnoozed")
    }

    func dismiss() {
        report("userDismissed")
    }

    /// CF8 — one tap, no keyboard, no confirmation screen. The number moves now;
    /// the phone confirms it when it can.
    func logWater(_ ml: Int) {
        // A stable id per tap, minted once and kept: WatchConnectivity re-delivers
        // queued messages, and the phone de-duplicates on this id rather than
        // counting the same glass twice.
        // FR8.5. Captured before the append, because the milestone is a
        // property of the *change* — testing the new total instead would buzz
        // again on every later sip inside the same quarter.
        let before = waterMillilitres
        let sip = HydrationLog.Sip(id: UUID().uuidString, at: Date(), millilitres: ml)
        unacknowledgedSips.append(sip)
        if unacknowledgedSips.count > Self.outboxLimit { unacknowledgedSips.removeFirst() }
        WaterOutbox.save(unacknowledgedSips)

        send(.waterLogged(millilitres: sip.millilitres, at: sip.at, id: sip.id))

        // FR8.5 — the non-visual channel that works with the screen off and the
        // phone in another room, which is the situation one-tap logging exists
        // for. `.click` confirms the tap; a milestone gets something the user
        // can tell apart from it without looking.
        if let milestone = HydrationProgress.crossed(from: before, to: waterMillilitres,
                                                     target: waterTargetMillilitres) {
            haptic(milestone == .target ? .success : .directionUp)
        } else {
            haptic(.click)
        }
    }

    /// Re-offer every tap the phone has not accounted for. Safe to repeat: the
    /// ids are stable, so the phone discards what it already has.
    private func flushOutbox() {
        for sip in unacknowledgedSips {
            send(.waterLogged(millilitres: sip.millilitres, at: sip.at, id: sip.id))
        }
    }

    private func report(_ outcome: String) {
        guard let p = pending else { return }
        // These three strings are what the receptivity model learns from, so they
        // travel exactly as they are.
        send(.nudgeOutcome(bidID: p.bidID, outcome: outcome, at: Date()))
        answeredBidIDs.insert(p.bidID)
        pending = nil
    }

    #if canImport(WatchKit)
    /// One door out, so NFR10's transmission count cannot miss a caller. The
    /// outbox re-sends on reconnect, so this is the number that grows when the
    /// link is flapping — which is exactly the case worth noticing.
    private func send(_ payload: WristEvent) {
        energy.record(.transmission, at: Date())
        bridge.send(payload)
    }

    private func haptic(_ type: WKHapticType) {
        energy.record(.haptic, at: Date())
        WKInterfaceDevice.current().play(type)
    }
    #else
    private enum WKHapticType { case notification, success, click }
    private func haptic(_ type: WKHapticType) { energy.record(.haptic, at: Date()) }
    #endif

    #if DEBUG
    /// Previews only: a model parked in one state, so each screen can be seen
    /// without a paired phone.
    static func preview(linkState: LinkState,
                        water: Int = 0,
                        target: Int = 2_000,
                        sedentaryMinutes: Int? = nil,
                        unacknowledged: Int = 0,
                        log: DayLog? = nil) -> WatchModel {
        let model = WatchModel()
        model.linkState = linkState
        model.day = DayState(waterMillilitres: water,
                             waterTargetMillilitres: target,
                             sedentaryMinutes: sedentaryMinutes)
        // nil by default, so the default preview shows the "your phone has not
        // sent anything" state rather than an invented day.
        model.log = log
        model.unacknowledgedSips = unacknowledged > 0
            ? [HydrationLog.Sip(id: "preview-sip", at: Date(), millilitres: unacknowledged)]
            : []
        return model
    }
    #endif
}

// MARK: - The outbox on disk

/// Un-confirmed taps, kept across launches.
///
/// Only today's are restored: a sip from yesterday belongs to a day the phone has
/// already closed, and adding it to this morning's total would be the same class
/// of error as double-counting.
private enum WaterOutbox {
    private static let key = "kairo.watch.waterOutbox"

    static func loadForToday() -> [HydrationLog.Sip] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let sips = try? JSONDecoder().decode([HydrationLog.Sip].self, from: data)
        else { return [] }
        return sips.filter { Calendar.current.isDateInToday($0.at) }
    }

    static func save(_ sips: [HydrationLog.Sip]) {
        guard let data = try? JSONEncoder().encode(sips) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
