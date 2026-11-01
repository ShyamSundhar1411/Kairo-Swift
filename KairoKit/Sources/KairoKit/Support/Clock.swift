import Foundation

/// The domain never calls `Date()`.
///
/// `PlanContract` has `after(n days)` transitions and `MemoryItem` decays;
/// neither is testable against a wall clock, and a demo that depends on the
/// real date cannot be replayed.
public protocol Clock: Sendable {
    var now: Date { get }
}

public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
}

/// Deterministic clock for tests, demos and the recorded video.
public final class FixedClock: Clock, @unchecked Sendable {
    private var current: Date
    public init(_ start: Date) { current = start }
    public var now: Date { current }
    public func advance(days: Int) { current = current.addingTimeInterval(TimeInterval(days) * 86_400) }
    public func advance(hours: Double) { current = current.addingTimeInterval(hours * 3_600) }
    public func set(_ d: Date) { current = d }
}

public enum DateHelp {
    /// The calendar every fixture date is built in.
    ///
    /// Exposed, not private, and that is the whole point. A fixture pinned to
    /// Australia/Sydney handed to code reading `Calendar.current` agrees only on
    /// a machine in Sydney: two KairoKit tests passed here for a year and failed
    /// on the first CI run, in UTC, because `DateHelp.at(…, 23, 30)` is 13:30 to
    /// a runner and 13:30 is inside an evening window that 23:30 is past.
    ///
    /// The production default stays `.current` - the evening window belongs to
    /// the user's own day, not to ours. It is the *tests* that have to say which
    /// day they mean, so they pass this wherever they pass a `DateHelp` date.
    public static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Australia/Sydney") ?? .gmt
        return cal
    }()

    /// `DateHelp.at(2026, 8, 25, 15, 40)` - used to pin the object-diagram scenario.
    public static func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        return calendar.date(from: c)!
    }
}
