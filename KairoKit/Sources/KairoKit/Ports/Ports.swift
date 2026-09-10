import Foundation

// Every boundary the app crosses is a protocol with an in-memory fake, so the
// domain builds and the whole system runs end-to-end with no network, no
// HealthKit and no API key.  Four people can work in parallel from day one and
// the demo never depends on a server being up.

// MARK: - Agents

public enum AgentID: String, Sendable, CaseIterable {
    case coach = "WellnessCoach"
    case nutrition = "NutritionAnalyst"
    case lifestyle = "LifestyleSignalAnalyst"
    case memory = "HabitMemoryCurator"
    case steward = "WellbeingSteward"
}

/// What is actually happening right now.
///
/// Without this an agent is asked to bid for the user's attention while being
/// told only the date and the data coverage, and correctly answers "nothing" —
/// which looks like the arbiter is broken when it is the prompt that is empty.
public struct Observations: Sendable {
    public var sedentaryMinutes: Int?
    public var hydrationML: Int?
    public var hydrationTargetML: Int?
    public var sleepHoursLastNight: Double?
    public var sleepDebtHours: Double?
    public var kilojoulesLogged: Double?
    public var kilojoulesTarget: Double?
    public var minutesSinceLastNudge: Int?
    public var inMeeting: Bool?

    public init(sedentaryMinutes: Int? = nil, hydrationML: Int? = nil,
                hydrationTargetML: Int? = nil, sleepHoursLastNight: Double? = nil,
                sleepDebtHours: Double? = nil, kilojoulesLogged: Double? = nil,
                kilojoulesTarget: Double? = nil, minutesSinceLastNudge: Int? = nil,
                inMeeting: Bool? = nil) {
        self.sedentaryMinutes = sedentaryMinutes
        self.hydrationML = hydrationML
        self.hydrationTargetML = hydrationTargetML
        self.sleepHoursLastNight = sleepHoursLastNight
        self.sleepDebtHours = sleepDebtHours
        self.kilojoulesLogged = kilojoulesLogged
        self.kilojoulesTarget = kilojoulesTarget
        self.minutesSinceLastNudge = minutesSinceLastNudge
        self.inMeeting = inMeeting
    }

    public static let none = Observations()

    /// Rendered for the prompt. Absent readings are stated as absent rather than
    /// omitted, so the model can tell "zero" from "not measured".
    public var lines: [String] {
        var out: [String] = []
        out.append("sitting: " + (sedentaryMinutes.map { "\($0) minutes unbroken" } ?? "not measured"))
        if let ml = hydrationML {
            let target = hydrationTargetML.map { " of a \($0) ml target" } ?? ""
            out.append("water: \(ml) ml\(target)")
        } else {
            out.append("water: not measured")
        }
        out.append("sleep last night: " + (sleepHoursLastNight.map { String(format: "%.1f hours", $0) } ?? "not recorded"))
        if let debt = sleepDebtHours { out.append(String(format: "sleep debt: %.1f hours", debt)) }
        // Stated as absent, like sitting and water above, rather than omitted.
        // Omitted, the Nutrition role saw no line about food at all and filled the
        // silence — "No meals logged today" is a claim about somebody's day that
        // nothing here measured. Absent and zero have to stay distinguishable in
        // every domain, not just the three that happened to be written that way.
        if let kj = kilojoulesLogged {
            let target = kilojoulesTarget.map { " against a \(Int($0)) kJ target" } ?? ""
            out.append("energy logged: \(Int(kj)) kJ\(target)")
        } else {
            out.append("energy logged: not measured — this service cannot see the meal log")
        }
        if let mins = minutesSinceLastNudge { out.append("last interrupted: \(mins) minutes ago") }
        if let meeting = inMeeting, meeting { out.append("currently in a calendar event") }
        return out
    }
}

public struct AgentContext: Sendable {
    public let now: Date
    public let memories: [MemoryItem]
    public let coverage: DayCoverage
    public let activeContract: PlanContract?
    public let observations: Observations

    public init(now: Date, memories: [MemoryItem], coverage: DayCoverage,
                activeContract: PlanContract? = nil,
                observations: Observations = .none) {
        self.now = now
        self.memories = memories
        self.coverage = coverage
        self.activeContract = activeContract
        self.observations = observations
    }
}

public protocol AgentRole: Sendable {
    var id: AgentID { get }
    var promptVersion: String { get }
    /// Locales this role has actually been validated in (NFR7). Anything outside
    /// this set must be translated-then-screened, reduced, or held for a human.
    var competentLocales: Set<String> { get }
    func bid(_ ctx: AgentContext) -> [NudgeBid]
    func position(on topic: String, _ ctx: AgentContext) -> Position?
}

public extension AgentRole {
    var competentLocales: Set<String> { ["en-AU", "en"] }
    func bid(_ ctx: AgentContext) -> [NudgeBid] { [] }
    func position(on topic: String, _ ctx: AgentContext) -> Position? { nil }
}

// MARK: - Memory

public protocol MemoryStore: Sendable {
    func upsert(_ item: MemoryItem) throws
    /// What the agents may retrieve: active and unconfirmed facts only.
    func query(_ text: String, k: Int, maxSensitivity: MemorySensitivity) throws -> [MemoryItem]
    /// What the user sees in the Memory Book: everything, including facts that
    /// are contradicted and waiting for them to adjudicate. A contradiction the
    /// user cannot see is a contradiction they cannot resolve.
    func book(maxSensitivity: MemorySensitivity) throws -> [MemoryItem]
    func supersede(id: String, with item: MemoryItem) throws
    func pin(id: String, by recordID: String) throws
    func delete(id: String) throws
}

// MARK: - Language model

public struct Money: Sendable, Equatable, Comparable, AdditiveArithmetic {
    public let cents: Int
    public init(cents: Int) { self.cents = cents }
    public static let zero = Money(cents: 0)
    public static func < (l: Money, r: Money) -> Bool { l.cents < r.cents }
    public static func + (l: Money, r: Money) -> Money { Money(cents: l.cents + r.cents) }
    public static func - (l: Money, r: Money) -> Money { Money(cents: l.cents - r.cents) }
}

public struct TokenUsage: Sendable, Equatable {
    public let input: Int
    public let output: Int
    /// Reasoning models bill their chain of thought as output tokens. Tracking it
    /// separately is the only way to see where the budget actually went.
    public let reasoning: Int
    public let cachedInput: Int

    public init(input: Int, output: Int, reasoning: Int = 0, cachedInput: Int = 0) {
        self.input = input
        self.output = output
        self.reasoning = reasoning
        self.cachedInput = cachedInput
    }
    public static let zero = TokenUsage(input: 0, output: 0)

    public static func + (l: TokenUsage, r: TokenUsage) -> TokenUsage {
        TokenUsage(input: l.input + r.input, output: l.output + r.output,
                   reasoning: l.reasoning + r.reasoning,
                   cachedInput: l.cachedInput + r.cachedInput)
    }
}

public struct Completion: Sendable {
    public let text: String
    public let cost: Money
    public let usage: TokenUsage
    /// Non-nil when the model declined or was cut off before producing content.
    /// Callers must check this before reading `text`.
    public let refusal: String?
    public let model: String

    public init(text: String, cost: Money, usage: TokenUsage = .zero,
                refusal: String? = nil, model: String = "") {
        self.text = text
        self.cost = cost
        self.usage = usage
        self.refusal = refusal
        self.model = model
    }
}

/// Which class of model a request needs. The provider maps this onto a concrete
/// model id, so callers never name one and the roster can be retuned in one place.
public enum ModelTier: String, Sendable, CaseIterable {
    /// Cheap and fast. Bidding, extraction, routine classification.
    case fast
    /// Slower and more expensive. Dissent positions, safety judgement, planning.
    case deep
    /// Accepts an image. Meal photographs.
    case vision
}

public struct ImagePayload: Sendable {
    public let base64: String
    public let mediaType: String
    public init(base64: String, mediaType: String = "image/jpeg") {
        self.base64 = base64
        self.mediaType = mediaType
    }
}

public struct LLMRequest: Sendable {
    public var system: String?
    public var prompt: String
    /// Raw JSON Schema text. The provider either enforces it natively or, where
    /// the API only offers a generic JSON mode, appends it to the prompt.
    /// Kept as a string so the request stays Sendable.
    public var jsonSchema: String?
    public var tier: ModelTier
    public var maxTokens: Int
    public var image: ImagePayload?

    public init(prompt: String, system: String? = nil, jsonSchema: String? = nil,
                tier: ModelTier = .fast, maxTokens: Int = 8_000,
                image: ImagePayload? = nil) {
        self.prompt = prompt
        self.system = system
        self.jsonSchema = jsonSchema
        self.tier = tier
        self.maxTokens = maxTokens
        self.image = image
    }
}

public protocol LLMProvider: Sendable {
    var name: String { get }
    func model(for tier: ModelTier) -> String
    /// Nominal per-call cost, used to reserve budget *before* a call is made.
    /// The real cost comes back on the Completion and is what gets charged.
    func estimatedCost(for tier: ModelTier) -> Money
    func complete(_ request: LLMRequest) async throws -> Completion
}

// MARK: - Delivery

public protocol NudgeChannel: Sendable {
    var kind: NudgeChannelKind { get }
    /// NFR11: a channel declares what it can render, and the arbiter may not
    /// deliver a nudge the user cannot act on.
    func canRender(_ bid: NudgeBid, for profile: CapabilityProfile) -> Bool
    func deliver(_ nudge: Nudge) throws
}

public struct CapabilityProfile: Sendable {
    public let available: Set<Capability>
    /// Substitutions the user has confirmed, e.g. standing -> a roll break.
    public let equivalents: [Capability: String]
    public init(available: Set<Capability>, equivalents: [Capability: String] = [:]) {
        self.available = available
        self.equivalents = equivalents
    }
    public static let unrestricted = CapabilityProfile(available: Set(Capability.allCases))
    public func satisfies(_ required: Set<Capability>) -> Bool { required.isSubset(of: available) }
}

// MARK: - Health data

public protocol HealthDataSource: Sendable {
    var name: String { get }
    func sleepHours(on day: Date) throws -> Double?
    func wearHours(on day: Date) throws -> Double
    func sedentaryMinutes(at t: Date) throws -> Int
}

// MARK: - Receptivity

/// Learned from the outcome history of past nudges (CF7). Kept as a port so the
/// arbiter can be tested against a fixed model.
public protocol ReceptivityModel: Sendable {
    func receptivity(nudgeClass: String, at: Date, memories: [MemoryItem]) -> Double
}
