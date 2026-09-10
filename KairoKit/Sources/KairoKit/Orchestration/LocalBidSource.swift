import Foundation

/// CF7. The bids the phone raises for itself when the agents cannot be reached.
///
/// This replaces a fixture. The app used to fall back to three hard-coded bids —
/// a sitting run of 82 minutes, "You are 340 ml behind today", and a wind-down
/// window pinned to the evening of 25 August 2026 — so a phone with no backend
/// and no readings still displayed a full day's worth of advice about someone
/// else's Tuesday.
///
/// Every bid here is derived from a reading, and a reading that is absent
/// produces no bid. That makes silence the default rather than the exception: a
/// phone that has measured nothing has nothing to say, which is the honest
/// output and is what `SafetyGate` and `DayCoverage` already assume everywhere
/// else in this project.
///
/// The numbers below are thresholds and priors, not observations. They are stated
/// here as constants so they can be argued with, and none of them invents a
/// reading — they only decide when a real reading is worth an interruption.
public enum LocalBidSource {

    /// Sitting runs shorter than this are not worth an interruption. Chosen to sit
    /// just under the hour so a meeting-length block is caught once, not twice.
    public static let sedentaryFloorMinutes = 50

    /// Below this fraction of the day's water target, water is worth mentioning.
    /// Above it the gap is small enough that saying so costs more attention than
    /// it saves.
    public static let hydrationFloorFraction = 0.75

    /// How short a night has to be before the next evening's wind-down is worth an
    /// interruption, relative to `SleepSummary.defaultNightlyNeedHours`.
    public static let sleepShortfallHours: Double = 1.0

    /// Bids for whatever the readings actually support, in the user's local day.
    ///
    /// - Parameters:
    ///   - now: the current instant, from the bound clock.
    ///   - observations: what was measured. Absent fields yield no bid.
    ///   - calendar: injected so the evening window is computed in the user's
    ///     own day rather than UTC.
    public static func bids(at now: Date,
                            observations: Observations,
                            calendar: Calendar = .current) -> [NudgeBid] {
        var out: [NudgeBid] = []
        if let bid = sedentaryBid(at: now, observations: observations) { out.append(bid) }
        if let bid = hydrationBid(at: now, observations: observations) { out.append(bid) }
        if let bid = bedtimeBid(at: now, observations: observations, calendar: calendar) {
            out.append(bid)
        }
        return out
    }

    // MARK: - One reading, one bid

    private static func sedentaryBid(at now: Date, observations: Observations) -> NudgeBid? {
        guard let minutes = observations.sedentaryMinutes,
              minutes >= sedentaryFloorMinutes else { return nil }

        // Urgency climbs with the run and saturates: at some point another
        // minute of sitting does not make the interruption more worth having.
        let over = Double(minutes - sedentaryFloorMinutes)
        let urgency = min(0.9, 0.4 + over / 100)
        return NudgeBid(
            id: "local-sedentary-\(minutes)",
            nudgeClass: "sedentary",
            originAgent: AgentID.lifestyle.rawValue,
            expectedBenefit: 0.7,
            urgency: urgency,
            windowOpens: now.addingTimeInterval(-600),
            windowCloses: now.addingTimeInterval(1800),
            requiredCapabilities: [.standing, .walking],
            text: "\(minutes) minutes sitting unbroken. Ninety seconds on your feet?")
    }

    private static func hydrationBid(at now: Date, observations: Observations) -> NudgeBid? {
        // Both halves required. Millilitres with no target cannot be judged, and a
        // target with nothing logged is a morning nobody has drunk in yet rather
        // than a morning of no water — `Observations` is explicit that its job is
        // to keep "zero" and "not measured" apart, and this is where that matters.
        guard let logged = observations.hydrationML,
              let target = observations.hydrationTargetML, target > 0 else { return nil }

        let fraction = Double(logged) / Double(target)
        guard fraction < hydrationFloorFraction else { return nil }

        let behind = target - logged
        let urgency = min(0.8, 0.2 + (hydrationFloorFraction - fraction))
        return NudgeBid(
            id: "local-hydration-\(logged)",
            nudgeClass: "hydration",
            originAgent: AgentID.coach.rawValue,
            expectedBenefit: 0.55,
            urgency: urgency,
            windowOpens: now.addingTimeInterval(-1800),
            windowCloses: now.addingTimeInterval(3600),
            text: "\(behind) ml behind your \(target) ml target.")
    }

    /// Only after a short night, and only for this evening.
    ///
    /// The window is computed from the user's calendar rather than written as a
    /// literal date. The fixture this replaces had `2026-08-25 21:30`, which on
    /// any other day is a window that has already closed — so the bid was raised,
    /// suppressed as `windowNotOpen`, and shown to the user as restraint the
    /// arbiter had never actually exercised.
    private static func bedtimeBid(at now: Date,
                                   observations: Observations,
                                   calendar: Calendar) -> NudgeBid? {
        guard let slept = observations.sleepHoursLastNight,
              slept < SleepSummary.defaultNightlyNeedHours - sleepShortfallHours,
              let opens = calendar.date(bySettingHour: 21, minute: 30, second: 0, of: now),
              let closes = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: now),
              now <= closes else { return nil }

        let short = SleepSummary.defaultNightlyNeedHours - slept
        return NudgeBid(
            id: "local-bedtime-\(Int(slept * 10))",
            nudgeClass: "bedtimePrep",
            originAgent: AgentID.lifestyle.rawValue,
            expectedBenefit: 0.5,
            urgency: 0.25,
            windowOpens: opens,
            windowCloses: closes,
            text: String(format: "%.1f hours last night, %.1f short. Start winding down.",
                         slept, short))
    }
}
