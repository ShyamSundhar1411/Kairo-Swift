import Foundation

/// Member A — CF1 Photo-based meal logging, CF3 dissent, OF1 ungrounded-dish protocol.
///
/// The `ungrounded` branch is the feature: when the analyst cannot ground a dish it
/// says so and asks to be taught, instead of publishing a plausible wrong number.
public enum MealEntryState: String, LifecycleState {
    case captured, classifying, ungrounded, awaitingTeaching
    case awaitingClarification, estimated, confirmed, logged, corrected
    case archived, failed

    public static let machineName = "MealEntry"
    public static let initial: MealEntryState = .captured

    public var isTerminal: Bool { self == .archived || self == .failed }

    public static let transitions: [Transition<MealEntryState>] = [
        .init(.captured, "beginRecognition", .classifying),
        .init(.classifying, "recognitionFailed", .failed),
        .init(.classifying, "noGroundingFound", .ungrounded,
              guardText: "no reference entry for this dish"),
        .init(.classifying, "confidenceBelowThreshold", .awaitingClarification,
              guardText: "confidence < threshold && question budget available"),
        .init(.classifying, "confidenceAccepted", .estimated,
              guardText: "confidence >= threshold"),
        .init(.ungrounded, "teachRequested", .awaitingTeaching),
        .init(.ungrounded, "userSkipped", .failed),
        .init(.awaitingTeaching, "dishTaught", .estimated,
              guardText: "barcode | label OCR | guided description"),
        .init(.awaitingTeaching, "userAbandoned", .failed),
        .init(.awaitingClarification, "userAnswered", .estimated),
        .init(.awaitingClarification, "questionExpired", .estimated,
              guardText: "fall back to the low-confidence estimate, flagged"),
        .init(.estimated, "userConfirmed", .confirmed),
        .init(.confirmed, "written", .logged),
        .init(.logged, "userCorrected", .corrected),
        .init(.corrected, "rewritten", .logged),
        .init(.logged, "dayClosed", .archived),
    ]
}

public struct NutritionFacts: Sendable, Equatable {
    public let kilojoules: Double
    public let proteinGrams: Double
    public let carbGrams: Double
    public let fatGrams: Double
    public init(kilojoules: Double, proteinGrams: Double = 0, carbGrams: Double = 0, fatGrams: Double = 0) {
        self.kilojoules = kilojoules
        self.proteinGrams = proteinGrams
        self.carbGrams = carbGrams
        self.fatGrams = fatGrams
    }
    /// NFR14: Australian labels are in kilojoules. Calories are a derived display unit, never the stored one.
    public var calories: Double { kilojoules / 4.184 }
}

public struct FoodItem: Sendable, Equatable {
    public let name: String
    public let grams: Double
    public let facts: NutritionFacts
    /// 0...1. Surfaced to the user, never hidden.
    public let confidence: Double
    public init(name: String, grams: Double, facts: NutritionFacts, confidence: Double) {
        self.name = name
        self.grams = grams
        self.facts = facts
        self.confidence = confidence
    }
}

public struct MealEntry: Sendable {
    public let id: String
    public var lifecycle: Lifecycle<MealEntryState>
    public var items: [FoodItem]
    public let capturedAt: Date
    /// Set when the entry was resolved through the ungrounded/teach-once path (OF1).
    public var taughtByUser: Bool = false

    public init(id: String, capturedAt: Date, items: [FoodItem] = []) {
        self.id = id
        self.capturedAt = capturedAt
        self.items = items
        self.lifecycle = Lifecycle()
    }

    public var state: MealEntryState { lifecycle.state }
    public var totalKilojoules: Double { items.reduce(0) { $0 + $1.facts.kilojoules } }
    /// The estimate is only as good as its weakest item.
    public var confidence: Double { items.map(\.confidence).min() ?? 0 }
}
