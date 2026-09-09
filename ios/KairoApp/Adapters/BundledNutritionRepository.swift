import Foundation
import KairoKit

/// The offline half of `NutritionRepository`: the same port, served out of
/// `Resources/nutrition-seed.json` instead of over the network.
///
/// This is what `.preview` binds, so the demo and the recorded video work on a
/// simulator in flight mode — the property the README promises. It is not a set
/// of fixtures somebody typed: every row was fetched from Open Food Facts by
/// `scripts/fetch-nutrition.swift` and still carries the barcode it came from,
/// so a figure on screen in the demo is as traceable as one from a live scan.
/// That is also why `attribution` credits Open Food Facts rather than us: the
/// data is theirs, under the ODbL, wherever it is being read from.
public struct BundledNutritionRepository: NutritionRepository {
    public let attribution: String
    /// Keyed by barcode for lookup; `ordered` keeps the file's order for search
    /// so preview results are the same on every run.
    private let byCode: [String: FoodReference]
    private let ordered: [FoodReference]

    public init(bundle: Bundle = .main, resource: String = "nutrition-seed") {
        let document = Self.load(bundle: bundle, resource: resource)
        attribution = document.attribution
        ordered = document.foods
        byCode = Dictionary(document.foods.map { ($0.sourceID, $0) },
                            uniquingKeysWith: { first, _ in first })
    }

    /// Rows already in memory, so this cannot fail for a reason worth reporting —
    /// a barcode is either in the seed file or it is not.
    public func byBarcode(_ code: String) async throws -> FoodReference {
        let barcode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = byCode[barcode] else {
            throw NutritionLookupError.notFound(barcode)
        }
        return match
    }

    /// Case-insensitive substring match over name and brand.
    ///
    /// Deliberately dumb: no fuzzy matching, no synonyms, no "did you mean". A
    /// near-miss dressed up as a hit is how the wrong product's kilojoules end up
    /// in somebody's day, and the ungrounded branch exists for exactly the case
    /// where this returns nothing.
    public func search(_ text: String, limit: Int) async throws -> [FoodReference] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty, limit > 0 else { return [] }

        var prefixed: [FoodReference] = []
        var contained: [FoodReference] = []
        for food in ordered {
            let name = food.name.lowercased()
            if name.hasPrefix(needle) {
                prefixed.append(food)
            } else if name.contains(needle) || food.brand?.lowercased().contains(needle) == true {
                contained.append(food)
            }
        }
        // Name-prefix matches first, then the rest, each in file order — which is
        // barcode order, so the preview is reproducible.
        return Array((prefixed + contained).prefix(limit))
    }

    // MARK: - Loading

    private struct Document {
        let attribution: String
        let foods: [FoodReference]
    }

    private struct Seed: Decodable {
        struct Food: Decodable {
            let barcode: String
            let name: String
            let brand: String?
            let kilojoulesPer100g: Double
            let proteinGramsPer100g: Double
            let carbGramsPer100g: Double
            let fatGramsPer100g: Double
            let declaredServingGrams: Double?
        }
        let source: String
        let attribution: String
        let foods: [Food]
    }

    /// Loaded once, eagerly, in `init`. Decoding a few kilobytes on the main
    /// thread at startup is cheaper than the machinery it would take to make it
    /// lazy, and it keeps the type `Sendable` without a lock.
    private static func load(bundle: Bundle, resource: String) -> Document {
        let fallbackAttribution = "Nutrition data from Open Food Facts (openfoodfacts.org), "
            + "made available under the Open Database Licence (ODbL)."
        guard let url = bundle.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let seed = try? JSONDecoder().decode(Seed.self, from: data) else {
            // No seed file means an empty larder: every lookup misses and every
            // search comes back empty. That is the right failure — the app then
            // says it cannot ground the meal, which is true, instead of falling
            // back to numbers from nowhere. Deliberately not an assertion: a
            // missing resource should not take the app down mid-demo, and the
            // behaviour it degrades to is behaviour the app already handles.
            FileHandle.standardError.write(Data(
                "[nutrition] \(resource).json missing or unreadable — no offline food data. "
                    .appending("Run: swift scripts/fetch-nutrition.swift\n").utf8))
            return Document(attribution: fallbackAttribution, foods: [])
        }
        return Document(
            attribution: seed.attribution.isEmpty ? fallbackAttribution : seed.attribution,
            foods: seed.foods.map { food in
                FoodReference(
                    id: "seed:\(food.barcode)",
                    name: food.name,
                    brand: food.brand,
                    per100g: NutritionFacts(
                        kilojoules: food.kilojoulesPer100g,
                        proteinGrams: food.proteinGramsPer100g,
                        carbGrams: food.carbGramsPer100g,
                        fatGrams: food.fatGramsPer100g),
                    declaredServingGrams: food.declaredServingGrams,
                    // The source is Open Food Facts even though the transport was
                    // a file in the bundle, and the sourceID is still the barcode,
                    // so the citation reads the same either way.
                    source: seed.source,
                    sourceID: food.barcode)
            })
    }
}
