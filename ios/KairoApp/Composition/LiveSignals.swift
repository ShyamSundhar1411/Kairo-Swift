import Foundation
import KairoKit

/// What the demo's wrist is reporting right now, and who reported it.
///
/// Demo mode only. Filled by the watch's Demo page when it streams, and by the
/// phone's own `SimulatedWrist` when it does not — the phone stands down while
/// the watch is talking, because the wrist is the better-placed source.
struct LiveSignals: Equatable {
    enum Source: String, Equatable {
        case watch, phone

        var label: String {
            switch self {
            case .watch: "from the watch"
            case .phone: "phone simulator"
            }
        }
    }

    var sittingMinutes: Int?
    var heartRateBPM: Int?
    var stepsToday: Int?
    var source: Source?
    var updatedAt: Date?

    mutating func apply(_ reading: SimulatedReading, from source: Source) {
        let value = Int(reading.value.rounded())
        switch reading.kind {
        case .sittingMinutes: sittingMinutes = max(0, value)
        case .heartRate:      heartRateBPM = max(0, value)
        case .stepsToday:     stepsToday = max(0, value)
        }
        self.source = source
        updatedAt = reading.at
    }

    /// Whether a change from `old` is worth asking the agents about again.
    ///
    /// Every tick refreshes the readings, which is free. A pass is five model
    /// calls, so it is spent only on the moments that should change a decision:
    /// the sitting run crossing a threshold the Lifestyle analyst cares about,
    /// the wearer standing up, or the heart rate jumping.
    static func isSignificant(from old: LiveSignals, to new: LiveSignals) -> Bool {
        let before = old.sittingMinutes ?? 0, after = new.sittingMinutes ?? 0
        if [30, 45, 60, 90, 120].contains(where: { before < $0 && after >= $0 }) { return true }
        if before - after >= 10 { return true }
        if (old.heartRateBPM ?? 0) < 110 && (new.heartRateBPM ?? 0) >= 110 { return true }
        return false
    }
}

/// The demo's health port: recorded Health first, then the live wrist, then
/// the fixed scenario for whatever is still missing.
///
/// - **Sleep and the week** come from HealthKit when it has them. In a
///   simulator that is the seeded week (`KairoHealthSeeding`), read through the
///   app's real HealthKit adapter, so the read path is exercised for real.
/// - **Sitting** comes from the live wrist when one is streaming.
/// - **Anything else** falls back to `DemoScenario`, so a phone with nothing
///   recorded and nothing streaming still has a day to show.
///
/// `recorded` is nil when the presenter has switched recorded Health off.
struct DemoBlendHealth: HealthDataSource, MovementDaySource, SleepWindowSource {
    let recorded: HealthDataSource?
    let live: LiveSignals

    var name: String { "Demo blend (recorded Health, live wrist, scenario)" }

    private var scenario: DemoHealthSource { DemoScenario.health }

    /// Whether last night's sleep is coming from recorded Health. The screens
    /// say where every figure came from, so this is asked rather than assumed.
    func sleepIsRecorded(on day: Date) -> Bool {
        guard let recorded else { return false }
        return ((try? recorded.sleepHours(on: day)) ?? nil) != nil
    }

    func sleepHours(on day: Date) throws -> Double? {
        if let recorded, let hours = (try? recorded.sleepHours(on: day)) ?? nil { return hours }
        return try scenario.sleepHours(on: day)
    }

    func wearHours(on day: Date) throws -> Double {
        if let recorded, let worn = try? recorded.wearHours(on: day), worn > 0 { return worn }
        return try scenario.wearHours(on: day)
    }

    func sedentaryMinutes(at t: Date) throws -> Int {
        if let sitting = live.sittingMinutes { return sitting }
        return try scenario.sedentaryMinutes(at: t)
    }

    func movementDay(on day: Date, at instant: Date) throws -> MovementDay {
        var base = try scenario.movementDay(on: day, at: instant)
        if let source = recorded as? MovementDaySource,
           let real = try? source.movementDay(on: day, at: instant), real.isObserved {
            base = real
        }
        return MovementDay(day: base.day, hoursWorn: base.hoursWorn,
                           unbrokenSedentaryMinutes: live.sittingMinutes ?? base.unbrokenSedentaryMinutes,
                           activeKilojoules: base.activeKilojoules,
                           exerciseMinutes: base.exerciseMinutes)
    }

    func nightReadings(endingOn day: Date, nights: Int) async -> [NightReading] {
        if let window = recorded as? SleepWindowSource {
            let real = await window.nightReadings(endingOn: day, nights: nights)
            if real.contains(where: { $0.isObserved }) { return real }
        }
        return await scenario.nightReadings(endingOn: day, nights: nights)
    }
}
