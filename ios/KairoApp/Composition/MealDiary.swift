import Foundation
import KairoKit

/// One meal the user confirmed today, as the day remembers it.
///
/// `MealLogModel` owns a single in-flight `MealEntry` and is rebuilt for every
/// capture, so before this existed a confirmed meal reached `.logged` and then
/// went nowhere: no coverage, no `kilojoulesLogged` on the wire, nothing on
/// Today. The Nutrition role was told "energy logged: not measured" about a day
/// on which the user had just logged lunch.
struct LoggedMeal: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let at: Date
    /// The items, in words — "grilled salmon, steamed rice".
    let title: String
    let kilojoules: Double
    /// The weakest item's confidence, which is what the whole estimate is worth.
    let confidence: Double
    let taught: Bool
    /// True for the demo scenario's meals. They are never written to disk, so
    /// turning demo mode off cannot leave a fictional lunch in a real day.
    let demo: Bool

    init(id: String, at: Date, title: String, kilojoules: Double,
         confidence: Double, taught: Bool = false, demo: Bool = false) {
        self.id = id
        self.at = at
        self.title = title
        self.kilojoules = kilojoules
        self.confidence = confidence
        self.taught = taught
        self.demo = demo
    }

    init(entry: MealEntry, at: Date) {
        let names = entry.items.map(\.name).filter { !$0.isEmpty }
        self.init(id: entry.id, at: at,
                  title: names.isEmpty ? "a meal" : names.joined(separator: ", "),
                  kilojoules: entry.totalKilojoules,
                  confidence: entry.confidence,
                  taught: entry.taughtByUser)
    }
}

/// Today's real meals, kept across a relaunch.
///
/// One day only, on purpose: the day's ledger is what coverage and the agents'
/// `kilojoulesLogged` are about, and a history is a different feature with
/// different privacy obligations. Yesterday's file is simply not read back.
enum MealDiary {
    private static let key = "kairo.meals.today"

    private struct Stored: Codable {
        let dayStart: Date
        let meals: [LoggedMeal]
    }

    static func load(dayStart: Date) -> [LoggedMeal] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.dayStart == dayStart
        else { return [] }
        return stored.meals.filter { !$0.demo }
    }

    static func save(_ meals: [LoggedMeal], dayStart: Date) {
        let stored = Stored(dayStart: dayStart, meals: meals.filter { !$0.demo })
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
