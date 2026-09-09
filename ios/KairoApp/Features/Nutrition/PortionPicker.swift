import SwiftUI
import KairoKit

/// Member A — CF1. The step between a published row and a logged portion.
///
/// Once a barcode or a search has produced a `FoodReference`, the composition is
/// settled: somebody measured it, published it, and Kairo cites the row. What is
/// still unknown is how much of it was eaten, and that is the only place error
/// can enter — so this screen is entirely about the portion, and about being
/// straight regarding how the portion was arrived at.
///
/// Which is why every path out of here carries a `PortionBasis` as well as a
/// number. `PortionBasis.confidence` becomes the `confidence` on the resulting
/// `FoodItem`, which the evidence gate reads later; a weighed portion is worth
/// more than an eyeballed one, and this screen shows that trade rather than
/// burying it.
///
/// The one rule the copy keeps repeating: no invented conversions. A cup of
/// rolled oats and a cup of rice weigh nothing like each other. Kairo holds no
/// densities, so it does not offer a cup of a food — it offers what it can
/// define, and says plainly why the rest is missing.
struct PortionPicker: View {
    let reference: FoodReference
    /// Called with the portion and how it was arrived at — two values, not one.
    /// The grams decide the number; the basis decides what the number is worth.
    /// A caller that took only the grams would be dropping the half of this
    /// screen that matters.
    let onChoose: (Double, PortionBasis) -> Void

    @State private var basis: PortionBasis
    /// Nothing is pre-selected for the measures or the estimate. A portion that
    /// arrived by default is not a portion anybody chose, and it would go into
    /// the day under the user's name.
    @State private var measureID: String?
    @State private var typedGrams = ""
    @State private var estimatedGrams: Double?

    init(reference: FoodReference,
         onChoose: @escaping (Double, PortionBasis) -> Void) {
        self.reference = reference
        self.onChoose = onChoose
        // Open on the strongest option this row can actually support. A packaged
        // food arrives with its serving already measured, so there is nothing to
        // ask; anything else has to be weighed or estimated.
        _basis = State(initialValue: reference.declaredServingGrams != nil
                       ? .declaredServing : .weighed)
    }

    var body: some View {
        VStack(spacing: Kairo.Space.stack) {
            identityCard
            methodCard
            energyCard
            confirmButton
            TrustNote(text: "The composition figures here are published — somebody else "
                      + "measured them, and Kairo cites the row it read. The portion is the "
                      + "only part in doubt, which is why this screen exists and why what "
                      + "it records is how you arrived at it.")
        }
    }

    // MARK: - What this is, and who says so

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(reference.name)
                    .font(.kairoHeadline)
                    .foregroundStyle(Kairo.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let brand = reference.brand {
                    Text(brand)
                        .font(.kairoCaption)
                        .foregroundStyle(Kairo.inkSoft)
                }
            }

            // The published row, unscaled. Everything below is this line times a
            // portion, so it is worth being able to see the line itself.
            HStack(alignment: .lastTextBaseline, spacing: 5) {
                Text("\(Int(reference.per100g.kilojoules.rounded()))")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Kairo.ink)
                Text("kJ per 100 g")
                    .font(.kairoCaption)
                    .foregroundStyle(Kairo.inkSoft)
                Spacer(minLength: 0)
            }

            // The citation, on the same card as the number, always. Attribution
            // is a licence condition for some sources and the whole point for
            // all of them: any figure in this app traces back to a row somebody
            // else published, and this is the line that proves it.
            VStack(alignment: .leading, spacing: 5) {
                Pill(text: reference.source, icon: "text.book.closed", tint: Kairo.teal)
                Text(reference.sourceID)
                    .font(.kairoMono)
                    .foregroundStyle(Kairo.inkFaint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kairoCard()
        .accessibilityElement(children: .combine)
    }

    // MARK: - How much

    private var methodCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "How much", icon: "scalemass", tint: Kairo.leaf)

            // The order is deliberate, and it is *not* the confidence order. The
            // label's serving comes first because it is the one portion figure
            // that arrives already measured, and for a packaged food it is the
            // fastest honest answer. Weighing scores higher (1.00 against 0.90)
            // and sits directly below — the figure on each row says so, rather
            // than the ordering implying it.
            VStack(spacing: 8) {
                ForEach(offeredBases, id: \.rawValue) { option in
                    methodRow(option)
                }
            }

            Divider().overlay(Kairo.hairline.opacity(0.12))

            control
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kairoCard()
    }

    private func methodRow(_ option: PortionBasis) -> some View {
        let selected = basis == option
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { basis = option }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(selected ? Kairo.leaf : Kairo.inkFaint)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title(for: option))
                        .font(.kairoHeadline)
                        .foregroundStyle(Kairo.ink)
                    Text(blurb(for: option))
                        .font(.caption)
                        .foregroundStyle(Kairo.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Pill(text: percent(option.confidence), tint: tint(for: option.confidence))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background {
                let shape = RoundedRectangle(cornerRadius: Kairo.Radius.inner, style: .continuous)
                shape
                    .fill(selected ? Kairo.leaf.opacity(0.10) : Kairo.hairline.opacity(0.04))
                    .overlay {
                        shape.strokeBorder(selected ? Kairo.leaf.opacity(0.45) : Color.clear,
                                           lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.kairoPress)
        .accessibilityLabel("\(title(for: option)). \(blurb(for: option)). "
                            + "Worth \(percent(option.confidence)).")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func title(for option: PortionBasis) -> String {
        switch option {
        case .declaredServing:  "The label's serving"
        case .householdMeasure: "A household measure"
        case .weighed:          "Weighed"
        case .estimated:        "Your estimate"
        }
    }

    private func blurb(for option: PortionBasis) -> String {
        switch option {
        case .declaredServing:
            reference.declaredServingGrams.map {
                "\(gramsText($0)), as the pack declares it — measured by whoever printed it"
            } ?? "This row declares no serving size"
        case .householdMeasure:
            "Servings counted or split by hand, plus millilitres where they can be "
            + "converted honestly"
        case .weighed:
            "Type what the scales said. The only portion here with no guess in it at all"
        case .estimated:
            "A round number, chosen by eye. Kairo logs it, and logs that it was a guess"
        }
    }

    /// The control for whichever basis is selected. One at a time, because they
    /// are alternatives rather than a form to fill in.
    @ViewBuilder private var control: some View {
        switch basis {
        case .declaredServing:  declaredControl
        case .householdMeasure: householdControl
        case .weighed:          weighedControl
        case .estimated:        estimatedControl
        }
    }

    /// Nothing to choose: the label declares one serving, and that is the
    /// portion. A multiplier here would quietly turn a measured figure into an
    /// eyeballed one, so multiples of a serving live under household measures
    /// instead, at the lower confidence they have earned.
    @ViewBuilder private var declaredControl: some View {
        if let serving = reference.declaredServingGrams {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "tag")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Kairo.leaf)
                    .padding(.top, 1)
                Text("One serving of \(gramsText(serving)), read straight off the label. "
                     + "Nothing about this portion is Kairo's guess.")
                    .font(.kairoCaption)
                    .foregroundStyle(Kairo.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var householdControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                ForEach(householdMeasures) { measure in
                    chip(measure.label, selected: measureID == measure.id) {
                        measureID = measure.id
                    }
                }
            }

            if let measure = selectedMeasure {
                Text("\(gramsText(measure.grams)) — \(measure.detail).")
                    .font(.caption)
                    .foregroundStyle(Kairo.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Pick a measure.")
                    .font(.caption)
                    .foregroundStyle(Kairo.inkFaint)
            }

            TrustNote(text: householdRefusal, icon: "hand.raised")
        }
    }

    private var weighedControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                TextField("0", text: $typedGrams)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Kairo.ink)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background {
                        RoundedRectangle(cornerRadius: Kairo.Radius.chip, style: .continuous)
                            .fill(Kairo.hairline.opacity(0.06))
                    }
                    .accessibilityLabel("Weight in grams")
                Text("g")
                    .font(.kairoNumber)
                    .foregroundStyle(Kairo.inkSoft)
                Spacer(minLength: 0)
            }

            if !typedGrams.isEmpty, parsedGrams == nil {
                Text("Kairo needs a weight in grams, above zero and up to 5,000 — past that "
                     + "it is a typo rather than a meal.")
                    .font(.caption)
                    .foregroundStyle(Kairo.coral)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Scales first, then this field. This is the only portion on the list "
                     + "that carries no estimate at all, which is why it is worth "
                     + "\(percent(PortionBasis.weighed.confidence)).")
                    .font(.caption)
                    .foregroundStyle(Kairo.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Round grams, not small/medium/large.
    ///
    /// Small, medium and large need a gram weight per food before they mean
    /// anything, and Kairo holds none — so a "medium" would be Kairo's invention
    /// wearing the user's name. A round number the user picks is genuinely their
    /// estimate, and the confidence beside it says what that is worth.
    private var estimatedControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 8)], spacing: 8) {
                ForEach(Self.estimateSteps, id: \.self) { step in
                    chip(gramsText(step), selected: estimatedGrams == step) {
                        estimatedGrams = step
                    }
                }
            }

            Text(estimatedGrams == nil
                 ? "Pick the round number closest to what you had."
                 : "Recorded as your estimate, not as a measurement.")
                .font(.caption)
                .foregroundStyle(Kairo.inkSoft)

            TrustNote(text: "Kairo does not offer small, medium and large here. Those need a "
                      + "gram weight for this particular food, Kairo holds none, and a "
                      + "made-up medium would end up in your day looking like your answer.",
                      icon: "hand.raised")
        }
    }

    /// The coarse ladder for an eyeballed portion. Round numbers on purpose: a
    /// figure like 173 g would imply a precision that eyes do not have.
    private static let estimateSteps: [Double] = [25, 50, 100, 150, 200, 300, 500]

    private func chip(_ label: String, selected: Bool,
                      action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { action() }
        } label: {
            Text(label)
                .font(.kairoLabel).tracking(0.4)
                .foregroundStyle(selected ? Color.black.opacity(0.88) : Kairo.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .background {
                    Capsule().fill(selected ? AnyShapeStyle(Kairo.leaf)
                                            : AnyShapeStyle(Kairo.hairline.opacity(0.07)))
                }
                .overlay {
                    if !selected {
                        Capsule().strokeBorder(Kairo.hairline.opacity(0.14), lineWidth: 0.5)
                    }
                }
        }
        .buttonStyle(.kairoPress)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - What the choice means

    private var energyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // NFR14: kilojoules first and largest — that is the unit on an
            // Australian label and the unit Kairo stores. Calories are a derived
            // display line, and they are drawn to look like one.
            VStack(alignment: .leading, spacing: 3) {
                Text("THIS PORTION")
                    .font(.kairoLabel).tracking(1.1)
                    .foregroundStyle(Kairo.inkFaint)

                if let item {
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text("\(Int(item.facts.kilojoules.rounded()))")
                            .font(.kairoDisplay)
                            .monospacedDigit()
                            .foregroundStyle(Kairo.ink)
                            .contentTransition(.numericText())
                        Text("kJ")
                            .font(.kairoNumber)
                            .foregroundStyle(Kairo.inkSoft)
                        Spacer(minLength: 0)
                    }
                    Text("≈ \(Int(item.facts.calories.rounded())) Cal, derived from the "
                         + "kilojoules")
                        .font(.caption2)
                        .foregroundStyle(Kairo.inkFaint)
                    Text("\(gramsText(item.grams)) · \(basis.describedInWords)")
                        .font(.kairoCaption)
                        .foregroundStyle(Kairo.inkSoft)
                } else {
                    // Never a zero while the portion is unknown: a zero is a
                    // claim, and no portion has been chosen yet.
                    KairoSkeleton(width: 150, height: 46)
                        .padding(.vertical, 3)
                    Text(prompt)
                        .font(.caption)
                        .foregroundStyle(Kairo.inkFaint)
                }
            }
            .accessibilityElement(children: .combine)

            if let item, macroTotal(item) > 0 {
                Text("protein \(gramsText(item.facts.proteinGrams))   "
                     + "carbs \(gramsText(item.facts.carbGrams))   "
                     + "fat \(gramsText(item.facts.fatGrams))")
                    .font(.kairoMono)
                    .foregroundStyle(Kairo.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(Kairo.hairline.opacity(0.12))

            confidenceLadder
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kairoCard(tint: item == nil ? nil : tint(for: basis.confidence))
    }

    /// The consequence of the choice, all four at once.
    ///
    /// The kilojoules do not move when the basis does — it is the same published
    /// row either way — so the only thing that changes is what the figure is
    /// worth. Showing the whole ladder is the quickest way to make that legible:
    /// weighing is not better arithmetic, it is a stronger claim.
    private var confidenceLadder: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("WHAT THE PORTION IS WORTH")
                .font(.kairoLabel).tracking(1.1)
                .foregroundStyle(Kairo.inkFaint)

            ForEach(PortionBasis.allCases.sorted { $0.confidence > $1.confidence },
                    id: \.rawValue) { option in
                HStack(spacing: 8) {
                    Text(option.describedInWords)
                        .font(.caption)
                        .foregroundStyle(option == basis ? Kairo.ink : Kairo.inkFaint)
                    Spacer(minLength: 6)
                    ScoreMeter(value: option.confidence,
                               tint: tint(for: option.confidence), height: 4)
                        .frame(width: 74)
                    Text(percent(option.confidence))
                        .font(.kairoMono)
                        .foregroundStyle(option == basis ? tint(for: option.confidence)
                                                         : Kairo.inkFaint)
                    Text(word(for: option.confidence))
                        .font(.kairoLabel)
                        .foregroundStyle(option == basis ? tint(for: option.confidence)
                                                         : Kairo.inkFaint)
                        .frame(width: 58, alignment: .leading)
                }
                .fontWeight(option == basis ? .semibold : .regular)
                .accessibilityElement(children: .combine)
            }

            Text(ladderNote)
                .font(.caption2)
                .foregroundStyle(Kairo.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var ladderNote: String {
        basis == .weighed
            ? "Weighed sits at the top of this list because nothing about the portion is "
            + "being guessed."
            : "Weighing the same food would carry "
            + "\(percent(PortionBasis.weighed.confidence)) instead of "
            + "\(percent(basis.confidence)). The kilojoules would not change — the "
            + "strength of the claim would."
    }

    // MARK: - Committing

    private var confirmButton: some View {
        Button {
            guard let grams = grams, grams > 0 else { return }
            onChoose(grams, basis)
        } label: {
            Text(confirmTitle)
        }
        .buttonStyle(.kairoProminent(Kairo.leaf))
        .disabled(item == nil)
        .opacity(item == nil ? 0.55 : 1)
    }

    private var confirmTitle: String {
        guard let item else { return "Pick a portion first" }
        return "Log \(gramsText(item.grams)) — \(basis.describedInWords)"
    }

    // MARK: - The arithmetic

    /// The portion, scaled off the published row. Nil until there is a portion
    /// to scale by, which is what keeps an unanswered screen from showing a
    /// number.
    private var item: FoodItem? {
        guard let grams = grams, grams > 0 else { return nil }
        return reference.item(grams: grams, portionConfidence: basis.confidence)
    }

    private var grams: Double? {
        switch basis {
        case .declaredServing:  reference.declaredServingGrams
        case .householdMeasure: selectedMeasure?.grams
        case .weighed:          parsedGrams
        case .estimated:        estimatedGrams
        }
    }

    /// A comma is a decimal separator on plenty of keyboards, so both are taken.
    /// Five kilograms is the ceiling: past that it is a slipped finger, not a
    /// meal, and a silent 50,000 kJ entry would be worse than a refusal.
    private var parsedGrams: Double? {
        let cleaned = typedGrams
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(cleaned), value > 0, value <= 5_000 else { return nil }
        return value
    }

    private func macroTotal(_ item: FoodItem) -> Double {
        item.facts.proteinGrams + item.facts.carbGrams + item.facts.fatGrams
    }

    // MARK: - What is on offer

    private var offeredBases: [PortionBasis] {
        var out: [PortionBasis] = []
        if reference.declaredServingGrams != nil { out.append(.declaredServing) }
        // Only offered when there is at least one measure Kairo can define. An
        // empty picker would be a control that does nothing.
        if !householdMeasures.isEmpty { out.append(.householdMeasure) }
        out.append(.weighed)
        out.append(.estimated)
        return out
    }

    /// The household measures Kairo is prepared to define, and nothing else.
    ///
    /// Two sources, both honest:
    ///
    /// 1. Multiples of the label's own declared serving. The serving itself was
    ///    measured by the manufacturer; counting two of them, or halving one by
    ///    eye, is a real household action with real variance — which is exactly
    ///    what `.householdMeasure` is worth (0.70) rather than what
    ///    `.declaredServing` is (0.90).
    ///
    /// 2. Millilitres at 1 g/mL, and only for a row that is water. Water is
    ///    1 g/mL to within far better than portion error; every other food has
    ///    its own density, and Kairo holds no table of them. "One cup of pasta =
    ///    200 g" is precisely the unverified number this app refuses, so cups
    ///    and spoons are not offered for anything else and the copy says why.
    ///
    /// The vessels are the Australian standard ones: a metric cup is 250 mL and
    /// an Australian tablespoon is 20 mL, not the 15 mL used in most of the
    /// world.
    private var householdMeasures: [PortionMeasure] {
        var out: [PortionMeasure] = []

        if let serving = reference.declaredServingGrams {
            out.append(.init(id: "half-serving", label: "½ serving",
                             detail: "the label's \(gramsText(serving)) serving, "
                             + "split by eye",
                             grams: serving / 2))
            out.append(.init(id: "two-servings", label: "2 servings",
                             detail: "two of the label's \(gramsText(serving)) servings",
                             grams: serving * 2))
            out.append(.init(id: "three-servings", label: "3 servings",
                             detail: "three of the label's \(gramsText(serving)) servings",
                             grams: serving * 3))
        }

        if isWaterLike {
            out.append(.init(id: "tsp", label: "1 tsp",
                             detail: "5 mL of water at 1 g per mL", grams: 5))
            out.append(.init(id: "tbsp", label: "1 tbsp",
                             detail: "20 mL — the Australian tablespoon — at 1 g per mL",
                             grams: 20))
            out.append(.init(id: "half-cup", label: "½ cup",
                             detail: "125 mL of water at 1 g per mL", grams: 125))
            out.append(.init(id: "cup", label: "1 cup",
                             detail: "a 250 mL metric cup of water at 1 g per mL",
                             grams: 250))
            out.append(.init(id: "600ml", label: "600 mL",
                             detail: "a 600 mL bottle of water at 1 g per mL", grams: 600))
        }

        return out
    }

    private var selectedMeasure: PortionMeasure? {
        householdMeasures.first { $0.id == measureID }
    }

    /// The only row where a volume can be turned into a weight without a
    /// per-food density.
    ///
    /// The list is short on purpose and is matched against the whole name rather
    /// than as a substring, so "coconut water" and "tonic water" — which carry
    /// sugar and are not 1 g/mL — cannot slip through. The zero-energy check is
    /// the second gate: a row calling itself water that has kilojoules in it is
    /// not water, whatever it is called.
    private var isWaterLike: Bool {
        let names: Set<String> = ["water", "tap water", "plain water", "still water",
                                  "mineral water", "spring water", "sparkling water",
                                  "carbonated water", "soda water"]
        let name = reference.name
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return names.contains(name) && reference.per100g.kilojoules < 1
    }

    /// Why the household list is as short as it is, in the two cases it can be.
    private var householdRefusal: String {
        if isWaterLike {
            "Millilitres are converted at 1 g per mL, which is only safe here because "
            + "this row is water. Kairo will not offer a cup or a spoon of a food: a cup "
            + "of one food weighs nothing like a cup of another, and Kairo holds no "
            + "densities to convert with."
        } else {
            "Cups and spoons are not offered for this one. A cup of rolled oats and a cup "
            + "of rice weigh nothing like each other, and Kairo holds no density for this "
            + "row — so the conversion would be invented. Weigh it instead, or estimate "
            + "it and take the lower confidence."
        }
    }

    private var prompt: String {
        switch basis {
        case .declaredServing:
            "This row declares no serving size, so there is nothing to read off it."
        case .householdMeasure:
            "Pick a measure above."
        case .weighed:
            "Type what the scales said."
        case .estimated:
            "Pick roughly how many grams you had."
        }
    }

    // MARK: - Formatting

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    /// The same thresholds and the same words the estimate screen uses, so a
    /// colour and a label mean one thing across the app.
    private func tint(for confidence: Double) -> Color {
        if confidence >= 0.8 { return Kairo.leaf }
        if confidence >= 0.6 { return Kairo.amber }
        return Kairo.coral
    }

    private func word(for confidence: Double) -> String {
        if confidence >= 0.8 { return "grounded" }
        if confidence >= 0.6 { return "usable" }
        return "weak"
    }

    /// Whole grams above 10 g, one decimal below it: a teaspoon is 5 g, and
    /// rounding 0.4 g of fat to zero would read as a claim that there is none.
    private func gramsText(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f g", value) : "\(Int(value.rounded())) g"
    }
}

/// One measure the picker is willing to name, with the reason it is allowed to
/// exist carried alongside it. `detail` is shown, not just documented — the user
/// gets to see the conversion rather than trust it.
private struct PortionMeasure: Identifiable, Equatable {
    let id: String
    let label: String
    let detail: String
    let grams: Double
}

// MARK: - As a sheet

/// The picker on its own screen, for the flow that arrives here straight from a
/// barcode. The same view, so there is one portion picker rather than two.
struct PortionPickerSheet: View {
    let reference: FoodReference
    let onChoose: (Double, PortionBasis) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: Kairo.Space.stack) {
                KairoHeader(eyebrow: "portion", title: "How much of it?") {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Kairo.inkSoft)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Kairo.hairline.opacity(0.07)))
                    }
                    .accessibilityLabel("Close without logging anything")
                }
                .padding(.horizontal, 4)

                PortionPicker(reference: reference) { grams, basis in
                    onChoose(grams, basis)
                    dismiss()
                }
            }
            .padding(.horizontal, Kairo.Space.stack)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background(KairoCanvas())
        // The weighed field is at the bottom of a card, so the keyboard has to
        // be dismissible without a Done bar the design does not have.
        .scrollDismissesKeyboard(.interactively)
    }
}

// MARK: - Previews

#Preview("Packaged, serving declared") {
    // Ferrero's published label figures for Nutella, which are also the row Open
    // Food Facts carries for 3017620422003 — the barcode the simulated scanner
    // offers. The Australian jar declares a 20 g serving.
    PortionPickerSheet(
        reference: FoodReference(
            id: "3017620422003",
            name: "Hazelnut cocoa spread",
            brand: "Nutella",
            per100g: NutritionFacts(kilojoules: 2255, proteinGrams: 6.3,
                                    carbGrams: 57.5, fatGrams: 30.9),
            declaredServingGrams: 20,
            source: "Open Food Facts",
            sourceID: "3017620422003")) { grams, basis in
        print("chose \(grams) g via \(basis.rawValue)")
    }
}

#Preview("Water, no serving declared") {
    // The one row whose energy needs no source — water carries none — and the
    // only kind of row where a cup can be converted honestly.
    PortionPickerSheet(
        reference: FoodReference(
            id: "water",
            name: "Water",
            per100g: NutritionFacts(kilojoules: 0),
            source: "no source needed: water carries no energy",
            sourceID: "—")) { grams, basis in
        print("chose \(grams) g via \(basis.rawValue)")
    }
}
