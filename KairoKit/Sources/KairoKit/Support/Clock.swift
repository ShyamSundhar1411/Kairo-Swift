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
    /// `DateHelp.at(2026, 8, 25, 15, 40)` — used to pin the object-diagram scenario.
    public static func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Australia/Sydney") ?? .gmt
        return cal.date(from: c)!
    }
}
