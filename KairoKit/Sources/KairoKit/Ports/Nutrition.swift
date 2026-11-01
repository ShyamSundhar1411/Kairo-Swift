import Foundation

/// Member A - CF1 / CF2. Where a kilojoule figure is allowed to come from.
///
/// Energy is not recoverable from a photograph. It is `identity × portion`, and
/// the identity has to be looked up in a food composition table while the
/// portion has to be measured, read off a label, or asked for. Nothing in this
/// file predicts a number; it only resolves one that somebody else published,
/// and it carries the citation so the app can say where it came from.
///
/// This is why `FoodItem` already takes `grams` and `NutritionFacts` separately:
/// the reference is per 100 g and the portion is the user's.

/// A published entry in a food composition table, per 100 g.
public struct FoodReference: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let brand: String?
    /// Always per 100 g, whatever the source quoted, so callers scale one way.
    public let per100g: NutritionFacts
    /// The serving the label declares, in grams, when it declares one. This is
    /// the only portion figure that is measured rather than estimated.
    public let declaredServingGrams: Double?
    /// Where this came from, in words, for display. Attribution is a licence
    /// condition for some sources and good manners for all of them.
    public let source: String
    /// The identifier within that source - a barcode, a food code - so any
    /// number in this app can be traced back to a row somebody else published.
    public let sourceID: String

    public init(id: String, name: String, brand: String? = nil,
                per100g: NutritionFacts, declaredServingGrams: Double? = nil,
                source: String, sourceID: String) {
        self.id = id
        self.name = name
        self.brand = brand
        self.per100g = per100g
        self.declaredServingGrams = declaredServingGrams
        self.source = source
        self.sourceID = sourceID
    }

    /// The reference scaled to an actual portion.
    ///
    /// `confidence` belongs to the *portion*, not to the table: the composition
    /// figures are published, and the uncertainty is in how much of it is on the
    /// plate. A weighed portion is 1.0; a household measure is lower; an eyeball
    /// guess is lower still.
    public func item(grams: Double, portionConfidence: Double) -> FoodItem {
        let factor = grams / 100
        return FoodItem(
            name: brand.map { "\(name) (\($0))" } ?? name,
            grams: grams,
            facts: NutritionFacts(
                kilojoules: per100g.kilojoules * factor,
                proteinGrams: per100g.proteinGrams * factor,
                carbGrams: per100g.carbGrams * factor,
                fatGrams: per100g.fatGrams * factor),
            confidence: min(max(portionConfidence, 0), 1))
    }
}

/// How a portion was arrived at, which is the only real source of error once the
/// composition table is doing the arithmetic.
public enum PortionBasis: String, Sendable, CaseIterable {
    /// Read from the label's declared serving.
    case declaredServing
    /// Weighed on scales.
    case weighed
    /// A cup, a slice, a tablespoon - a real measure with real variance.
    case householdMeasure
    /// The user's estimate by eye.
    case estimated

    /// What a portion arrived at this way is worth. These become the
    /// `confidence` on a `FoodItem`, which the evidence gate then reads.
    public var confidence: Double {
        switch self {
        case .weighed:          1.00
        case .declaredServing:  0.90
        case .householdMeasure: 0.70
        case .estimated:        0.45
        }
    }

    public var describedInWords: String {
        switch self {
        case .weighed:          "weighed"
        case .declaredServing:  "one declared serving"
        case .householdMeasure: "a household measure"
        case .estimated:        "your estimate"
        }
    }
}

public enum NutritionLookupError: Error, Equatable {
    case notFound(String)
    case noEnergyPublished(String)
    case offline
}

/// The boundary a food composition table sits behind.
///
/// Barcode lookup is the path that yields a measured number, so it is the one
/// the app leans on. Text search is a convenience and is allowed to return
/// nothing - which routes the entry to the ungrounded branch rather than to a
/// guess.
public protocol NutritionRepository: Sendable {
    var attribution: String { get }
    func byBarcode(_ code: String) async throws -> FoodReference
    func search(_ text: String, limit: Int) async throws -> [FoodReference]
}

public extension NutritionRepository {
    func search(_ text: String) async throws -> [FoodReference] {
        try await search(text, limit: 10)
    }
}

/// A day's logged energy, which is the thing "tracking calories" actually means.
///
/// `Observations.kilojoulesLogged` and `.kilojoulesTarget` already exist for the
/// agents to bid on; this is what fills them.
public struct EnergyLedger: Sendable {
    public let dayStart: Date
    public let targetKilojoules: Double
    public private(set) var entries: [MealEntry] = []

    public init(dayStart: Date, targetKilojoules: Double = 8_700) {
        self.dayStart = dayStart
        self.targetKilojoules = targetKilojoules
    }

    public mutating func record(_ entry: MealEntry) { entries.append(entry) }

    public var loggedKilojoules: Double {
        entries.reduce(0) { $0 + $1.totalKilojoules }
    }

    public var remainingKilojoules: Double {
        max(0, targetKilojoules - loggedKilojoules)
    }

    public var fractionOfTarget: Double {
        targetKilojoules <= 0 ? 0 : min(1, loggedKilojoules / targetKilojoules)
    }

    /// NFR14: kilojoules are what is stored. Calories are a display unit only.
    public var loggedCalories: Double { loggedKilojoules / 4.184 }

    /// The weakest portion behind today's total. A day built from four eyeballed
    /// portions is not a day that can carry a bare number, and this is what the
    /// evidence gate needs in order to say so.
    public var weakestPortionConfidence: Double? {
        entries.flatMap(\.items).map(\.confidence).min()
    }
}
