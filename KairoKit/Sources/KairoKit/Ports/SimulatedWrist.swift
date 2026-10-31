import Foundation

/// A believable afternoon at a desk, one simulated minute at a time.
///
/// Demo mode only. Both the watch's Demo page and the phone's fallback stream
/// run this same script, so the agents see the same shape of day whichever one
/// is driving: the sitting run climbs past the thresholds the Lifestyle analyst
/// cares about, the wearer eventually stands and walks for a few minutes (heart
/// rate up, steps up, sitting back to zero), and then it starts again.
///
/// Deterministic — no random numbers — so a rehearsal and the real
/// presentation produce the same sequence, and a test can pin it.
public struct SimulatedWrist: Sendable, Equatable {
    public private(set) var minute = 0
    public private(set) var sittingMinutes: Int
    public private(set) var heartRateBPM: Int
    public private(set) var stepsToday: Int
    /// Sitting this long ends in a walk break.
    public var standUpAfter: Int
    /// A glass of water every this many simulated minutes. Only the phone's
    /// stream acts on it; on the watch, water stays a real tap.
    public var sipEvery: Int

    private var walkMinutesLeft = 0

    public static let restingHeartRate = 64
    public static let walkMinutes = 4

    public init(sittingMinutes: Int = 82, heartRateBPM: Int = 66,
                stepsToday: Int = 3_400, standUpAfter: Int = 105, sipEvery: Int = 35) {
        self.sittingMinutes = max(0, sittingMinutes)
        self.heartRateBPM = heartRateBPM
        self.stepsToday = max(0, stepsToday)
        self.standUpAfter = max(1, standUpAfter)
        self.sipEvery = max(1, sipEvery)
    }

    public struct Tick: Sendable, Equatable {
        public let readings: [SimulatedReading]
        /// Millilitres drunk this minute, if any.
        public let sipMillilitres: Int?
    }

    /// One simulated minute.
    public mutating func advance(at now: Date) -> Tick {
        minute += 1
        if walkMinutesLeft > 0 {
            walk()
        } else if sittingMinutes >= standUpAfter {
            walkMinutesLeft = Self.walkMinutes
            walk()
        } else {
            sittingMinutes += 1
            // Settles back towards resting after a walk rather than dropping
            // straight there, and wobbles a little so the line is not flat.
            let resting = Self.restingHeartRate + minute % 5
            heartRateBPM = max(resting, heartRateBPM - 6)
            if minute % 4 == 0 { stepsToday += 12 }
        }
        let sip = minute % sipEvery == 0 ? 250 : nil
        return Tick(readings: readings(at: now), sipMillilitres: sip)
    }

    /// The presenter's "sit longer" button: jumps the run forward.
    public mutating func sitLonger(by minutes: Int, at now: Date) -> [SimulatedReading] {
        walkMinutesLeft = 0
        sittingMinutes += max(0, minutes)
        heartRateBPM = Self.restingHeartRate + 2
        return readings(at: now)
    }

    /// The presenter's "stand up" button: starts a walk break now.
    public mutating func standUp(at now: Date) -> [SimulatedReading] {
        walkMinutesLeft = Self.walkMinutes
        walk()
        return readings(at: now)
    }

    /// The presenter's "heart rate spike" button, while still sitting — the
    /// reading that should make a careful agent cautious rather than pushy.
    public mutating func spikeHeartRate(at now: Date) -> [SimulatedReading] {
        heartRateBPM = 128
        return readings(at: now)
    }

    public func readings(at now: Date) -> [SimulatedReading] {
        [SimulatedReading(kind: .sittingMinutes, value: Double(sittingMinutes), at: now),
         SimulatedReading(kind: .heartRate, value: Double(heartRateBPM), at: now),
         SimulatedReading(kind: .stepsToday, value: Double(stepsToday), at: now)]
    }

    private mutating func walk() {
        walkMinutesLeft = max(0, walkMinutesLeft - 1)
        sittingMinutes = 0
        heartRateBPM = 98 + (minute % 3) * 4
        stepsToday += 110
    }
}
