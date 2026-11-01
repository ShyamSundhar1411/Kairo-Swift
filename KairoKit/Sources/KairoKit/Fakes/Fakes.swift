import Foundation

// In-memory implementations of every port. The whole system runs end-to-end on
// these: no network, no API key, no HealthKit, no simulator. Swap one out for a
// real adapter without touching the domain.

public final class InMemoryMemoryStore: MemoryStore, @unchecked Sendable {
    private var items: [String: MemoryItem] = [:]
    public init(_ seed: [MemoryItem] = []) { seed.forEach { items[$0.id] = $0 } }

    public func upsert(_ item: MemoryItem) throws { items[item.id] = item }

    public func query(_ text: String, k: Int, maxSensitivity: MemorySensitivity) throws -> [MemoryItem] {
        let terms = text.lowercased().split(separator: " ").map(String.init)
        return items.values
            .filter { $0.isRetrievable && $0.sensitivity <= maxSensitivity }
            .map { item -> (MemoryItem, Int) in
                let hits = terms.filter { item.text.lowercased().contains($0) }.count
                return (item, hits)
            }
            .filter { $0.1 > 0 || terms.isEmpty }
            .sorted { ($0.1, $0.0.confidence) > ($1.1, $1.0.confidence) }
            .prefix(k).map(\.0)
    }

    public func book(maxSensitivity: MemorySensitivity) throws -> [MemoryItem] {
        items.values
            .filter { $0.sensitivity <= maxSensitivity && $0.state != .deleted }
            .sorted { $0.confidence > $1.confidence }
    }

    public func supersede(id: String, with item: MemoryItem) throws {
        items[id] = nil
        items[item.id] = item
    }
    public func pin(id: String, by recordID: String) throws { items[id]?.pin(by: recordID) }
    public func delete(id: String) throws { items[id] = nil }
    public var all: [MemoryItem] { Array(items.values) }
}

/// Returns canned structured responses keyed by a substring of the prompt.
/// Deterministic, free, and offline - which is what the demo runs on.
public struct ScriptedLLMProvider: LLMProvider {
    /// A rule fires when *every* substring in `all` appears in the system prompt
    /// or the user prompt. Role prompts share a preamble and one role answers
    /// several different questions, so a single substring is rarely specific
    /// enough on its own.
    public struct Rule: Sendable {
        public let all: [String]
        public let response: String
        public init(_ all: [String], _ response: String) {
            self.all = all
            self.response = response
        }
    }

    public let name = "scripted"
    private let rules: [Rule]
    private let fallback: String

    public func model(for tier: ModelTier) -> String { "scripted-\(tier.rawValue)" }
    /// Free, so the cost ladder in Section 7.1 is exercised only when a test
    /// deliberately sets a ceiling of zero.
    public func estimatedCost(for tier: ModelTier) -> Money { .zero }

    public init(rules: [Rule], fallback: String = "") {
        self.rules = rules
        self.fallback = fallback
    }

    /// Convenience for single-substring rules. Longest key first, so a short key
    /// cannot shadow a more specific one.
    public init(_ script: [String: String], fallback: String = "") {
        self.rules = script.keys
            .sorted { $0.count > $1.count }
            .map { Rule([$0], script[$0]!) }
        self.fallback = fallback
    }

    public func complete(_ request: LLMRequest) async throws -> Completion {
        let haystack = (request.system ?? "") + "\n" + request.prompt
        for rule in rules where rule.all.allSatisfy(haystack.contains) {
            return Completion(text: rule.response, cost: .zero, model: model(for: request.tier))
        }
        return Completion(text: fallback, cost: .zero, model: model(for: request.tier))
    }
}

public final class RecordingNudgeChannel: NudgeChannel, @unchecked Sendable {
    public let kind: NudgeChannelKind
    public private(set) var deliveries: [Nudge] = []
    public init(kind: NudgeChannelKind = .watchHaptic) { self.kind = kind }

    public func canRender(_ bid: NudgeBid, for profile: CapabilityProfile) -> Bool {
        profile.satisfies(bid.requiredCapabilities)
    }
    public func deliver(_ nudge: Nudge) throws { deliveries.append(nudge) }
}

/// Fixed receptivity per nudge class, plus the one memory-driven rule the report
/// keeps citing: this user ignores anything before 9am.
public struct TableReceptivityModel: ReceptivityModel {
    private let table: [String: Double]
    public init(_ table: [String: Double]) { self.table = table }

    public func receptivity(nudgeClass: String, at t: Date, memories: [MemoryItem]) -> Double {
        var base = table[nudgeClass] ?? 0.5
        let ignoresEarly = memories.contains {
            $0.isRetrievable && $0.text.lowercased().contains("before 9am")
        }
        if ignoresEarly {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "Australia/Sydney") ?? .gmt
            if cal.component(.hour, from: t) < 9 { base *= 0.1 }
        }
        return min(1, max(0, base))
    }
}

public struct StubHealthDataSource: HealthDataSource {
    public let name = "stub"
    private let sleep: Double?
    private let wear: Double
    private let sedentary: Int
    public init(sleepHours: Double? = 7.2, wearHours: Double = 22, sedentaryMinutes: Int = 82) {
        self.sleep = sleepHours; self.wear = wearHours; self.sedentary = sedentaryMinutes
    }
    public func sleepHours(on day: Date) throws -> Double? { sleep }
    public func wearHours(on day: Date) throws -> Double { wear }
    public func sedentaryMinutes(at t: Date) throws -> Int { sedentary }
}

/// A food composition table with a handful of rows in it and nothing behind it.
///
/// Seeded from `FoodReference` values the caller writes out by hand, so a test
/// can exercise the barcode path - the one path that yields a measured number -
/// without a network call or an API key. Barcode lookup matches on `sourceID`,
/// because that is what the identifier of a barcode row *is*.
public struct InMemoryNutritionRepository: NutritionRepository {
    /// Deliberately not phrased as a citation. Attribution exists so the app can
    /// say where a number came from, and nothing here came from anywhere: these
    /// rows are fixtures, and displaying them as a source would be a lie.
    public let attribution = "in-memory fixture - not a food composition table"

    private let references: [FoodReference]

    public init(_ seed: [FoodReference] = []) { references = seed }

    public func byBarcode(_ code: String) async throws -> FoodReference {
        guard let hit = references.first(where: { $0.sourceID == code }) else {
            // A miss is a normal outcome, not a failure: it routes the entry to
            // the ungrounded branch (OF1) instead of to a guess.
            throw NutritionLookupError.notFound(code)
        }
        return hit
    }

    public func search(_ text: String, limit: Int) async throws -> [FoodReference] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // An empty query is not a match for everything. Returning the whole table
        // would let a caller show the user rows they never asked for.
        guard !needle.isEmpty, limit > 0 else { return [] }
        return references
            .filter {
                $0.name.lowercased().contains(needle)
                    || ($0.brand?.lowercased().contains(needle) ?? false)
            }
            .prefix(limit)
            .map { $0 }
    }
}
