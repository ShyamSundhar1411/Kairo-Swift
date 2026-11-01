import Foundation

/// NFR10 / SCRUM-19 - making the 3% daily battery budget something that can be
/// checked rather than asserted.
///
/// **This does not measure battery, and nothing in this repository can.**
/// watchOS gives an app its own `batteryLevel`, not its own *share* of the
/// drain, so a number computed here would be the whole watch's consumption
/// wearing this app's name. The honest instrument is a different one: count the
/// things the companion does that cost energy, and compare that count against a
/// budget, so a regression is visible the day it lands instead of the day
/// somebody runs Instruments.
///
/// The three counted events are the ones the companion actually initiates:
///
/// - **wakes** - foreground sessions and background refreshes. The dominant
///   cost on a watch, because each one spins up the display and the radio.
/// - **transmissions** - WatchConnectivity sends. The outbox re-sends on
///   reconnect, so this is the number that grows when the link is flapping.
/// - **haptics** - cheap individually and worth counting because FR8.5 added
///   some, and "we added milestone haptics" is exactly the kind of change that
///   should have to show its cost.
///
/// `budget` is per day and is a *tripwire, not a measurement*: exceeding it does
/// not mean NFR10 was breached, it means the companion is doing more than the
/// design assumed and the real measurement is now worth running. The procedure
/// for that is in `docs/NFR10-BATTERY.md`.
public struct WatchEnergyBudget: Sendable, Equatable, Codable {

    /// What the design assumes a day looks like. Each is generous against the
    /// intended behaviour, so crossing one is a signal rather than noise.
    public enum Budget {
        /// Six interruptions (AG-1) plus the user opening the app a handful of
        /// times, plus hourly-ish background refreshes while worn.
        public static let wakes = 40
        /// One per water tap, one per nudge response, plus outbox re-sends.
        public static let transmissions = 60
        /// One per tap and one per milestone; FR8.5 adds at most four of the
        /// second kind per day.
        public static let haptics = 50
    }

    public private(set) var dayStart: Date
    public private(set) var wakes = 0
    public private(set) var transmissions = 0
    public private(set) var haptics = 0

    public init(dayStart: Date) {
        self.dayStart = dayStart
    }

    public enum Event: String, Sendable, Codable, CaseIterable {
        case wake, transmission, haptic
    }

    /// Records one event, rolling the ledger over at the day boundary.
    ///
    /// Rolling here rather than on a timer because a watch app is not running
    /// at midnight: the first event of a new day is the only reliable moment to
    /// notice that the day changed, and a ledger that only rolled while the app
    /// happened to be open would attribute a morning's events to yesterday.
    public mutating func record(_ event: Event, at: Date,
                                calendar: Calendar = .current) {
        if !calendar.isDate(at, inSameDayAs: dayStart) {
            self = WatchEnergyBudget(dayStart: calendar.startOfDay(for: at))
        }
        switch event {
        case .wake:         wakes += 1
        case .transmission: transmissions += 1
        case .haptic:       haptics += 1
        }
    }

    /// Which budgets this day has crossed. Empty is the expected answer.
    public var exceeded: [Event] {
        var out: [Event] = []
        if wakes > Budget.wakes { out.append(.wake) }
        if transmissions > Budget.transmissions { out.append(.transmission) }
        if haptics > Budget.haptics { out.append(.haptic) }
        return out
    }

    public var withinBudget: Bool { exceeded.isEmpty }

    /// For the diagnostics screen and for a bug report. Says plainly that it is
    /// not a battery reading, because a line of counters on a screen headed
    /// "battery" would be read as one.
    public var summary: String {
        let state = withinBudget
            ? "within the assumed daily budget"
            : "over budget on " + exceeded.map(\.rawValue).joined(separator: ", ")
        return "\(wakes) wakes, \(transmissions) sends, \(haptics) haptics - \(state). "
             + "Activity counts, not a battery measurement (NFR10 needs Instruments)."
    }
}
