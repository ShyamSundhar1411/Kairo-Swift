import Foundation
import KairoKit

/// Demo mode: a believable day for a phone that has none.
///
/// A presentation phone usually has no Apple Watch history, no sleep and no
/// meals, so every role is told "not measured" and correctly bids nothing.
/// That is right for a real user and useless in front of an audience.
///
/// What this replaces is only the **readings**. Everything downstream is real:
/// the readings go to `/v1/arbitrate` as they would from HealthKit, the five
/// roles reason over them with the bound model, the Steward screens the result,
/// and the backend's `/live` page draws all of it. Nothing about the agents'
/// answers is scripted.
///
/// It is never silent about itself. Today carries a banner while it is on, the
/// health source names itself "Demo scenario", the demo meals and sips are kept
/// out of storage, and switching it off removes every one of them.
enum DemoScenario {
    static let defaultsKey = "kairo.demoMode"
    /// Every sip and meal this writes has an id starting with this, so they can
    /// be found and removed again.
    static let prefix = "demo-"

    static let health = DemoHealthSource()

    /// A mid-week day for somebody training for a half marathon who is behind
    /// on sleep and water and has been at a desk since lunch. Chosen so that each
    /// bidder has something to say and they disagree about what matters most.
    static func meals(dayStart: Date, now: Date) -> [LoggedMeal] {
        [
            LoggedMeal(id: prefix + "breakfast", at: at(7, 50, dayStart, now),
                       title: "oats with banana and almond milk",
                       kilojoules: 1_520, confidence: 0.84, demo: true),
            LoggedMeal(id: prefix + "lunch", at: at(12, 40, dayStart, now),
                       title: "chicken burrito bowl",
                       kilojoules: 2_840, confidence: 0.72, demo: true),
        ]
    }

    static func sips(dayStart: Date, now: Date) -> [HydrationLog.Sip] {
        [
            HydrationLog.Sip(id: prefix + "sip-1", at: at(8, 10, dayStart, now), millilitres: 250),
            HydrationLog.Sip(id: prefix + "sip-2", at: at(10, 35, dayStart, now), millilitres: 300),
            HydrationLog.Sip(id: prefix + "sip-3", at: at(13, 5, dayStart, now), millilitres: 250),
        ]
    }

    /// What the demo user "tells" Kairo. Sent to `/v1/memories/extract`, where
    /// the Habit Memory Curator decides what is worth keeping - so the facts
    /// that appear in the Memory Book are the curator's, not this file's.
    static let aboutMe = """
        I'm training for a half marathon and I run before work on Tuesdays and \
        Thursdays. Coffee after 3pm keeps me awake, so I stop by early afternoon. \
        I'm lactose intolerant. On busy days I eat lunch late, around 2pm. \
        A short walk works better for me than a reminder while I'm at my desk.
        """

    /// Today at hh:mm, but never in the future - a demo run at 9am shows
    /// breakfast at 7:50 and lunch "just now" rather than a meal not yet eaten.
    private static func at(_ hour: Int, _ minute: Int, _ dayStart: Date, _ now: Date) -> Date {
        let t = dayStart.addingTimeInterval(TimeInterval(hour * 3_600 + minute * 60))
        return min(t, now)
    }
}

/// The demo's health port. Conforms to the same three protocols the HealthKit
/// adapter does, so every screen and every request reads it through exactly
/// the code path a real phone uses.
struct DemoHealthSource: HealthDataSource, MovementDaySource, SleepWindowSource {
    let name = "Demo scenario (not your Health data)"

    /// Hours asleep for the last seven nights, oldest first; the last is last
    /// night. Two nights are missing on purpose - the watch was on the charger -
    /// so the sleep-debt claim has to be qualified rather than asserted.
    static let week: [Double?] = [6.4, 5.9, nil, 7.1, 6.2, nil, 5.6]

    static let sittingMinutes = 82
    static let hoursWorn = 9.5

    func sleepHours(on day: Date) throws -> Double? {
        let cal = Calendar.current
        let back = cal.dateComponents([.day], from: cal.startOfDay(for: day),
                                      to: cal.startOfDay(for: Date())).day ?? 0
        return Self.hours(nightsBack: back)
    }

    func wearHours(on day: Date) throws -> Double { Self.hoursWorn }

    func sedentaryMinutes(at t: Date) throws -> Int { Self.sittingMinutes }

    func movementDay(on day: Date, at instant: Date) throws -> MovementDay {
        MovementDay(day: day, hoursWorn: Self.hoursWorn,
                    unbrokenSedentaryMinutes: Self.sittingMinutes,
                    activeKilojoules: 640, exerciseMinutes: 9)
    }

    func nightReadings(endingOn day: Date, nights: Int) async -> [NightReading] {
        let cal = Calendar.current
        let end = cal.startOfDay(for: day)
        return (0..<nights).reversed().compactMap { back -> NightReading? in
            guard let night = cal.date(byAdding: .day, value: -back, to: end) else { return nil }
            let hours = Self.hours(nightsBack: back)
            return NightReading(night: night, hoursAsleep: hours,
                                hoursWorn: hours.map { $0 + 1.2 } ?? 0)
        }
    }

    private static func hours(nightsBack: Int) -> Double? {
        let index = week.count - 1 - nightsBack
        return week.indices.contains(index) ? week[index] : nil
    }
}
