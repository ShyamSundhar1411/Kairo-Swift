import Testing
import Foundation
@testable import KairoKit

// Every nutrition figure in this file is synthetic and round on purpose: 1000 kJ
// and 10/20/5 g per 100 g, so a 250 g portion is 2500 kJ and 25/50/12.5 g and the
// arithmetic can be checked by eye. None of it is a real food. This project
// treats an unverified real-looking number as a defect, so the fixtures are
// obviously fake and their `source` says so.
private enum Fixture {
    static let per100g = NutritionFacts(kilojoules: 1000, proteinGrams: 10, carbGrams: 20, fatGrams: 5)

    static let unbranded = FoodReference(
        id: "fix-1", name: "synthetic grain", per100g: per100g,
        declaredServingGrams: 40,
        source: "synthetic fixture", sourceID: "fixture-grain-1")

    static let branded = FoodReference(
        id: "fix-2", name: "synthetic biscuit", brand: "Fixture Foods", per100g: per100g,
        source: "synthetic fixture", sourceID: "9300000000001")

    /// A meal whose items carry exactly the confidences given, at 1000 kJ each,
    /// so a meal's total is `1000 × items` and needs no working out.
    static func meal(_ id: String, at t: Date, confidences: [Double]) -> MealEntry {
        MealEntry(id: id, capturedAt: t, items: confidences.enumerated().map { i, c in
            FoodItem(name: "item-\(i)", grams: 100,
                     facts: NutritionFacts(kilojoules: 1000), confidence: c)
        })
    }
}

/// Member A — CF1 / CF2, NFR14. A day's total, and how much of one may be said
/// out loud.
@Suite("Member A — energy ledger")
struct EnergyLedgerTests {
    let day = DateHelp.at(2026, 8, 25)
    let t = DateHelp.at(2026, 8, 25, 12, 30)

    /// 10 000 kJ target so halves and fifths are readable.
    func ledger(target: Double = 10_000, meals: [[Double]] = []) -> EnergyLedger {
        var l = EnergyLedger(dayStart: day, targetKilojoules: target)
        for (i, confidences) in meals.enumerated() {
            l.record(Fixture.meal("meal-\(i)", at: t, confidences: confidences))
        }
        return l
    }

    // MARK: - Totals

    @Test("the day's total is the sum of its entries")
    func totals() {
        // Two meals of two 1000 kJ items each = 4000 kJ of a 10 000 kJ target.
        let l = ledger(meals: [[1.0, 1.0], [1.0, 1.0]])
        #expect(l.loggedKilojoules == 4000)
        #expect(l.remainingKilojoules == 6000)
        #expect(l.fractionOfTarget == 0.4)
    }

    @Test("going over target clamps at zero remaining rather than going negative")
    func overTargetClamps() {
        // 5000 kJ logged against a 4000 kJ target: 1000 kJ over.
        let l = ledger(target: 4000, meals: [[1.0, 1.0, 1.0], [1.0, 1.0]])
        #expect(l.loggedKilojoules == 5000)
        #expect(l.remainingKilojoules == 0, "a negative allowance is not a thing to show a user")
        #expect(l.fractionOfTarget == 1, "the fraction is clamped so a progress ring cannot overflow")
    }

    @Test("a target of zero yields a zero fraction rather than a division by zero")
    func noTarget() {
        let l = ledger(target: 0, meals: [[1.0]])
        #expect(l.fractionOfTarget == 0)
        #expect(l.remainingKilojoules == 0)
    }

    @Test("an empty ledger totals zero and is not over target")
    func emptyTotals() {
        let l = ledger()
        #expect(l.loggedKilojoules == 0)
        #expect(l.remainingKilojoules == 10_000)
        #expect(l.fractionOfTarget == 0)
    }

    @Test("kilojoules are stored and calories are derived at 4.184 (NFR14)")
    func caloriesAreDerived() {
        // 4184 kJ is exactly 1000 Cal at the documented ratio, which is the only
        // reason this figure was chosen.
        var l = ledger()
        l.record(MealEntry(id: "meal-0", capturedAt: t, items: [
            FoodItem(name: "item-0", grams: 100,
                     facts: NutritionFacts(kilojoules: 4184), confidence: 1.0),
        ]))
        #expect(l.loggedKilojoules == 4184)
        #expect(abs(l.loggedCalories - 1000) < 0.000_1)
    }

    // MARK: - Scaling a reference to a portion

    @Test("a per-100 g reference scales to the portion actually eaten")
    func scalesToPortion() {
        let item = Fixture.unbranded.item(grams: 250, portionConfidence: 1.0)
        #expect(item.grams == 250)
        #expect(item.facts.kilojoules == 2500)
        #expect(item.facts.proteinGrams == 25)
        #expect(item.facts.carbGrams == 50)
        #expect(item.facts.fatGrams == 12.5)
    }

    @Test("an awkward portion scales too, not just the round ones")
    func scalesAnAwkwardPortion() {
        // 37 g of the fixture: 370 kJ, 3.7 g protein, 7.4 g carb, 1.85 g fat.
        let item = Fixture.unbranded.item(grams: 37, portionConfidence: 0.9)
        #expect(abs(item.facts.kilojoules - 370) < 0.000_1)
        #expect(abs(item.facts.proteinGrams - 3.7) < 0.000_1)
        #expect(abs(item.facts.carbGrams - 7.4) < 0.000_1)
        #expect(abs(item.facts.fatGrams - 1.85) < 0.000_1)
    }

    @Test("portion confidence is clamped into 0...1")
    func portionConfidenceIsClamped() {
        #expect(Fixture.unbranded.item(grams: 100, portionConfidence: 1.4).confidence == 1)
        #expect(Fixture.unbranded.item(grams: 100, portionConfidence: -0.2).confidence == 0)
        #expect(Fixture.unbranded.item(grams: 100, portionConfidence: 0.7).confidence == 0.7)
    }

    @Test("the brand is shown in the item name when the reference has one")
    func brandAppearsInTheName() {
        let branded = Fixture.branded.item(grams: 100, portionConfidence: 1.0)
        #expect(branded.name == "synthetic biscuit (Fixture Foods)")

        let plain = Fixture.unbranded.item(grams: 100, portionConfidence: 1.0)
        #expect(plain.name == "synthetic grain")
        #expect(!plain.name.contains("("), "no brand means no empty brackets")
    }

    // MARK: - Portion basis

    @Test("portion bases are strictly ordered: weighed beats a label beats a cup beats a guess")
    func portionBasisOrdering() {
        // Asserting the ordering, not the numbers: the confidences are tuning
        // knobs and retuning them must not break this test.
        #expect(PortionBasis.weighed.confidence > PortionBasis.declaredServing.confidence)
        #expect(PortionBasis.declaredServing.confidence > PortionBasis.householdMeasure.confidence)
        #expect(PortionBasis.householdMeasure.confidence > PortionBasis.estimated.confidence)
    }

    @Test("every portion basis is a usable confidence")
    func portionBasisConfidencesAreInRange() {
        for basis in PortionBasis.allCases {
            #expect(basis.confidence > 0 && basis.confidence <= 1,
                    "\(basis.rawValue) is outside the 0...1 a FoodItem accepts")
            #expect(!basis.describedInWords.isEmpty)
        }
    }

    // MARK: - The weakest portion

    @Test("an empty ledger has no weakest portion at all")
    func weakestOfNothingIsNil() {
        #expect(ledger().weakestPortionConfidence == nil)
        // An entry with no items yet — still ungrounded — is the same situation.
        var l = ledger()
        l.record(MealEntry(id: "ungrounded", capturedAt: t))
        #expect(l.weakestPortionConfidence == nil)
    }

    @Test("the weakest portion is the minimum across every item of every entry")
    func weakestSpansSeveralEntries() {
        // The low item is in the *second* entry, so a bug that only looks at the
        // first entry — or at entry-level confidence — fails here.
        let l = ledger(meals: [[0.9, 0.8], [0.95, 0.55], [1.0]])
        #expect(l.weakestPortionConfidence == 0.55)
    }

    // MARK: - Observations

    @Test("a logged day fills in the energy observations the agents bid on")
    func observationsAreFilled() {
        let obs = ledger(meals: [[1.0, 1.0], [1.0]]).observations
        #expect(obs.kilojoulesLogged == 3000)
        #expect(obs.kilojoulesTarget == 10_000)
        #expect(obs.lines.contains { $0.contains("energy logged: 3000 kJ") })
        #expect(obs.lines.contains { $0.contains("10000 kJ target") })
    }

    @Test("a day with nothing logged reports energy as not measured, not as zero")
    func emptyDayReportsAbsence() {
        let obs = ledger().observations
        #expect(obs.kilojoulesLogged == nil,
                "0 kJ logged would read to an agent as a day of fasting")
        #expect(!obs.lines.contains { $0.contains("energy logged") })
    }

    @Test("a non-positive target is reported as no target rather than as zero")
    func noTargetIsAbsent() {
        let obs = ledger(target: 0, meals: [[1.0]]).observations
        #expect(obs.kilojoulesLogged == 1000)
        #expect(obs.kilojoulesTarget == nil)
    }

    @Test("an entry that is still ungrounded adds no coverage")
    func ungroundedEntriesDoNotCount() {
        var l = ledger(meals: [[1.0]])
        l.record(MealEntry(id: "ungrounded", capturedAt: t))
        #expect(l.loggedMealCount == 1)
    }

    // MARK: - The assertion-form ladder

    @Test("a day with nothing logged forbids any claim about today's energy")
    func emptyLedgerForbidsEverything() {
        #expect(ledger().permittedForm() == .forbidden,
                "a confident zero is a claim about the user's eating, not the absence of one")
    }

    @Test("three weighed meals earn a bare number")
    func weighedDayPermitsAnAssertion() {
        #expect(ledger(meals: [[1.0], [1.0], [1.0]]).permittedForm() == .assertion)
    }

    @Test("a day measured in cups may state the number only with its caveat")
    func householdMeasureDayIsQualified() {
        let l = ledger(meals: [[1.0], [PortionBasis.householdMeasure.confidence], [0.95]])
        #expect(l.permittedForm() == .qualified)
    }

    @Test("a day built from eyeballed portions gets a range, never a bare number")
    func eyeballedDayIsARange() {
        let eye = PortionBasis.estimated.confidence
        // Four eyeballed portions across a fully covered day: coverage is perfect
        // and the claim is still only a band.
        let l = ledger(meals: [[eye, eye], [eye], [eye]])
        #expect(l.permittedForm() == .range)
        #expect(l.permittedForm() < .assertion)
    }

    @Test("one weighed portion laundering three guesses does not raise the form")
    func theWeakestItemGoverns() {
        let l = ledger(meals: [[1.0, PortionBasis.estimated.confidence], [1.0], [1.0]])
        #expect(l.permittedForm() == .range,
                "averaging would have made this look measured")
    }

    @Test("a barely identified portion reduces the day to a question")
    func barelyIdentifiedDayIsAQuestion() {
        #expect(ledger(meals: [[1.0], [1.0], [0.1]]).permittedForm() == .question)
    }

    @Test("a zero-confidence portion is not evidence and forbids the claim")
    func zeroConfidencePortionForbids() {
        #expect(ledger(meals: [[1.0], [1.0], [0.0]]).permittedForm() == .forbidden)
    }

    @Test("thin coverage caps the form however well the portions were measured")
    func coverageCapsTheForm() {
        // One weighed meal of three expected: 0.33 coverage, below the 0.6 floor
        // and above half of it, which DayCoverage already calls a range.
        #expect(ledger(meals: [[1.0]]).permittedForm() == .range)
        // Two of three clears the floor and earns a qualified claim.
        #expect(ledger(meals: [[1.0], [1.0]]).permittedForm() == .qualified)
    }

    @Test("a user who eats twice a day is not permanently short of coverage")
    func expectedMealsIsPerUser() {
        let l = ledger(meals: [[1.0], [1.0]])
        #expect(l.permittedForm(expectedMeals: 2) == .assertion)
        #expect(l.permittedForm(expectedMeals: 3) == .qualified)
    }

    @Test("the portion ladder sits between the bases, not on them")
    func portionLadderIsMonotonic() {
        let forms = [PortionBasis.weighed, .declaredServing, .householdMeasure, .estimated]
            .map { EnergySummary.portionForm(weakestConfidence: $0.confidence) }
        #expect(forms == [.assertion, .assertion, .qualified, .range])
        // Monotonic in confidence: a better-measured portion is never allowed to
        // say less than a worse-measured one.
        let ladder = stride(from: 0.0, through: 1.0, by: 0.05)
            .map { EnergySummary.portionForm(weakestConfidence: $0) }
        #expect(zip(ladder, ladder.dropFirst()).allSatisfy { $0 <= $1 })
    }
}

/// Member A — CF2. The lookup boundary, exercised on the fake so the whole thing
/// runs with no network and no key.
@Suite("Member A — nutrition lookup")
struct NutritionRepositoryTests {
    let repo = InMemoryNutritionRepository([Fixture.unbranded, Fixture.branded])

    @Test("a barcode that is in the table comes back with its citation")
    func barcodeHit() async throws {
        let hit = try await repo.byBarcode("9300000000001")
        #expect(hit.id == "fix-2")
        #expect(hit.sourceID == "9300000000001")
        #expect(hit.source == "synthetic fixture")
    }

    @Test("a barcode that is not in the table is a miss, not a guess")
    func barcodeMiss() async {
        await #expect(throws: NutritionLookupError.notFound("0000000000000")) {
            _ = try await repo.byBarcode("0000000000000")
        }
    }

    @Test("search matches a substring of the name whatever the case")
    func searchIsCaseInsensitive() async throws {
        let shouted = try await repo.search("BISCUIT")
        let lower = try await repo.search("synthetic")
        let byBrand = try await repo.search("fixture foods")
        #expect(shouted.map(\.id) == ["fix-2"])
        #expect(lower.count == 2)
        #expect(byBrand.map(\.id) == ["fix-2"], "the brand is searchable too")
    }

    @Test("search is allowed to find nothing, which is what routes an entry to teaching")
    func searchCanReturnNothing() async throws {
        let miss = try await repo.search("nothing like this")
        let blank = try await repo.search("   ")
        #expect(miss.isEmpty)
        #expect(blank.isEmpty, "an empty query is not a match for everything")
    }

    @Test("search honours its limit")
    func searchHonoursLimit() async throws {
        let capped = try await repo.search("synthetic", limit: 1)
        #expect(capped.count == 1)
    }

    @Test("the fake does not pretend to be a data source")
    func attributionIsHonest() {
        #expect(repo.attribution.lowercased().contains("fixture"))
    }
}
