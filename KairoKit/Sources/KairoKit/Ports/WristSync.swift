import Foundation

/// The phone/watch wire format, defined once for both targets.
///
/// Both apps link `KairoKit`, so this is the only place the message shape
/// exists. It previously lived as bare string literals on the watch side with
/// no counterpart on the phone at all — no `WCSession`, no receiver — which is
/// why a glass of water logged on the wrist went nowhere and the watch could
/// never be shown a nudge the arbiter had actually allocated.
///
/// Nothing here talks to WatchConnectivity. It is a codable envelope; the two
/// bridges in the app targets do the transport.

// MARK: - Watch to phone

public enum WristEvent: Codable, Sendable, Equatable {
    /// CF8 — one tap on the wrist. The phone owns the day's tally; this is a
    /// delta, not a total, so a message arriving late or twice can be reasoned
    /// about rather than silently overwriting the day.
    case waterLogged(millilitres: Int, at: Date, id: String)
    /// CF7 — what the user did with an interruption. The receptivity model
    /// learns from these, so losing one is worse than delivering it late.
    case nudgeOutcome(bidID: String, outcome: String, at: Date)
}

// MARK: - Phone to watch

public enum PhoneEvent: Codable, Sendable, Equatable {
    case nudge(bidID: String, text: String, nudgeClass: String, rewrittenFrom: String?)
    /// The phone arbitrates and the phone counts. The watch renders this rather
    /// than its own local tally, which is what makes the two agree.
    case dayState(DayState)
    /// What has been logged today, consolidated on the phone. The wrist gets a
    /// read-only digest so a glance can answer "what have I done today?"
    /// without the watch having to hold or recompute any of it.
    case log(DayLog)
}

/// The day, already summarised, for a screen 40mm wide.
///
/// The lines are rendered on the phone on purpose. The phone is the only side
/// that knows where a figure came from and what the evidence gate permits to be
/// said about it, so composing the sentence there stops the watch from
/// inventing a confident phrasing the phone would have refused.
public struct DayLog: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public enum Kind: String, Codable, Sendable {
            case water, meal, sleep, interruption
        }

        public let id: String
        public let kind: Kind
        public let at: Date
        public let headline: String
        /// The figure, already formatted with its unit — "350 ml", "1,180 kJ".
        /// nil when the entry has no number, which is not the same as zero.
        public let detail: String?
        /// What that figure is worth, 0...1. Travels so the wrist can show a
        /// weak reading as weak instead of laundering it into a clean number.
        public let confidence: Double?

        public init(id: String, kind: Kind, at: Date, headline: String,
                    detail: String? = nil, confidence: Double? = nil) {
            self.id = id
            self.kind = kind
            self.at = at
            self.headline = headline
            self.detail = detail
            self.confidence = confidence
        }
    }

    public var generatedAt: Date
    /// Newest first, and deliberately capped — this crosses a constrained
    /// transport to a screen that can only show a handful.
    public var entries: [Entry]
    public var waterMillilitres: Int
    public var waterTargetMillilitres: Int
    /// nil where nothing has been logged or measured, so the wrist can say
    /// "not measured" rather than drawing a zero.
    public var kilojoulesLogged: Double?
    public var kilojoulesTarget: Double?
    public var sleepHoursLastNight: Double?
    public var interruptionsSpent: Int
    public var dailyBudget: Int

    public static let entryLimit = 12

    public init(generatedAt: Date, entries: [Entry] = [],
                waterMillilitres: Int = 0, waterTargetMillilitres: Int = 2_000,
                kilojoulesLogged: Double? = nil, kilojoulesTarget: Double? = nil,
                sleepHoursLastNight: Double? = nil,
                interruptionsSpent: Int = 0, dailyBudget: Int = 6) {
        self.generatedAt = generatedAt
        self.entries = Array(entries.sorted { $0.at > $1.at }.prefix(Self.entryLimit))
        self.waterMillilitres = waterMillilitres
        self.waterTargetMillilitres = waterTargetMillilitres
        self.kilojoulesLogged = kilojoulesLogged
        self.kilojoulesTarget = kilojoulesTarget
        self.sleepHoursLastNight = sleepHoursLastNight
        self.interruptionsSpent = interruptionsSpent
        self.dailyBudget = dailyBudget
    }

    public var isEmpty: Bool { entries.isEmpty }
}

public struct DayState: Codable, Sendable, Equatable {
    public var waterMillilitres: Int
    public var waterTargetMillilitres: Int
    /// nil when the phone has not measured it, which is different from zero.
    public var sedentaryMinutes: Int?
    public var interruptionsSpent: Int
    public var dailyBudget: Int

    public init(waterMillilitres: Int, waterTargetMillilitres: Int,
                sedentaryMinutes: Int? = nil,
                interruptionsSpent: Int = 0, dailyBudget: Int = 6) {
        self.waterMillilitres = waterMillilitres
        self.waterTargetMillilitres = waterTargetMillilitres
        self.sedentaryMinutes = sedentaryMinutes
        self.interruptionsSpent = interruptionsSpent
        self.dailyBudget = dailyBudget
    }
}

// MARK: - Envelope

/// Wraps a message as a single `Data` value under one key.
///
/// WatchConnectivity dictionaries have to be property-list types, and a
/// hand-rolled dictionary per message type is how the two sides drifted apart
/// in the first place. One key, one codable payload, one version tag.
public enum WristSync {
    public static let payloadKey = "kairo.payload"
    public static let versionKey = "kairo.version"
    public static let version = 1

    public enum SyncError: Error, Equatable {
        case wrongVersion(Int?)
        case missingPayload
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public static func envelope<T: Encodable>(_ value: T) throws -> [String: Any] {
        [versionKey: version, payloadKey: try encoder.encode(value)]
    }

    public static func unwrap<T: Decodable>(_ type: T.Type,
                                            from message: [String: Any]) throws -> T {
        let sent = message[versionKey] as? Int
        guard sent == version else { throw SyncError.wrongVersion(sent) }
        guard let data = message[payloadKey] as? Data else { throw SyncError.missingPayload }
        return try decoder.decode(type, from: data)
    }
}

// MARK: - The day's water

/// CF8 — hydration as a log of what was actually tapped, not a running integer.
///
/// Kept as entries so a duplicate delivery can be discarded by id: WatchConnectivity
/// will re-deliver a queued message, and a total that double-counts is worse than
/// one that arrives late.
public struct HydrationLog: Sendable, Equatable {
    public struct Sip: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let at: Date
        public let millilitres: Int
        public init(id: String, at: Date, millilitres: Int) {
            self.id = id
            self.at = at
            self.millilitres = millilitres
        }
    }

    public let dayStart: Date
    public let targetMillilitres: Int
    public private(set) var sips: [Sip] = []

    public init(dayStart: Date, targetMillilitres: Int = 2_000) {
        self.dayStart = dayStart
        self.targetMillilitres = targetMillilitres
    }

    /// Returns false when the sip was a duplicate and nothing changed.
    @discardableResult
    public mutating func record(_ sip: Sip) -> Bool {
        guard !sips.contains(where: { $0.id == sip.id }) else { return false }
        sips.append(sip)
        return true
    }

    public var totalMillilitres: Int { sips.reduce(0) { $0 + $1.millilitres } }
    public var remainingMillilitres: Int { max(0, targetMillilitres - totalMillilitres) }

    public var fractionOfTarget: Double {
        targetMillilitres <= 0 ? 0 : min(1, Double(totalMillilitres) / Double(targetMillilitres))
    }

    /// What the evidence gate is allowed to see. `observedCount` is the number of
    /// times the user actually logged something, because coverage is about how
    /// much of the day Kairo could see — not how big the number got.
    public func coverageMetric(expectedSips: Int = 5) -> CoverageMetric {
        CoverageMetric(domain: .hydration,
                       observedCount: sips.count,
                       expectedCount: max(1, expectedSips))
    }
}
