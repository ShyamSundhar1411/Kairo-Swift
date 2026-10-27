import SwiftUI
import UIKit
import KairoKit

/// Member A — CF1 / OF1. One screen, four states, and the one branch no
/// competitor has: admitting it does not know the dish.
///
/// The state machine is the visual here. `MealProgressTrack` draws the path this
/// entry is actually on, including the branch it took, so the machine is
/// legible without a debug label.
struct MealCaptureView: View {
    @Environment(AppModel.self) private var app
    @State private var model: MealLogModel?
    @State private var showingCamera = false
    /// The barcode path, which is the only one that yields a measured figure.
    /// A scan resolves to a published row, the row plus a portion becomes a
    /// `FoodItem`, and the state machine takes it from there.
    @State private var lookingUp: String?
    @State private var reference: FoodReference?
    @State private var lookupFailure: String?
    /// NFR6 — per-session consent for a photo leaving the phone. `@State` and
    /// not persisted on purpose: "per session" is the requirement's word, and a
    /// remembered yes is a different promise from the one made.
    @State private var confirmingUpload = false

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    KairoLoadingScreen(label: "Getting the log ready")
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .fullScreenCover(isPresented: $showingCamera) {
            MealCameraSheet(onPhoto: { image in
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                    model?.attach(image)
                }
            }, onBarcode: { code in
                Task { await resolve(code) }
            })
        }
        .confirmationDialog("Send this photo to the backend?",
                            isPresented: $confirmingUpload, titleVisibility: .visible) {
            Button("Send it once") { Task { await analysePhoto() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The photo leaves your iPhone and goes to the bound backend, which "
                 + "passes it to the vision model. Nothing else about your day goes "
                 + "with it. Asked every session (NFR6).")
        }
        .sheet(item: $reference) { row in
            PortionPickerSheet(reference: row) { grams, basis in
                adopt(row, grams: grams, basis: basis)
            }
        }
        .task {
            if model == nil { model = MealLogModel(clock: app.env.clock) }
        }
    }

    @ViewBuilder
    private func content(_ model: MealLogModel) -> some View {
        ScrollView {
            VStack(spacing: Kairo.Space.stack) {
                header(model)
                MealProgressTrack(entry: model.entry)

                switch model.state {
                case .captured:
                    captureSection(model)
                case .ungrounded:
                    ungroundedSection(model)
                case .awaitingTeaching:
                    teachingSection(model)
                case .awaitingClarification:
                    clarificationSection(model)
                case .estimated:
                    estimateSection(model)
                case .logged, .archived:
                    loggedSection(model)
                default:
                    transitionalSection(model)
                }

                // FR8.2. Outside the state switch on purpose: a drink is
                // visible in the photograph whether or not the *food* could be
                // grounded, so the offer survives the ungrounded branch. A
                // bottle beside an unrecognised dish was still a bottle.
                drinksOffer(model)

                if let failure = model.analysisFailure { errorCard(failure) }
                if let e = model.error { errorCard(e) }

                TrustNote(text: "Kilojoules are what Kairo stores — that is the unit on an "
                          + "Australian label. Calories, where they appear at all, are a "
                          + "derived display. Nothing is written to your day until you confirm it.")
            }
            .padding(.horizontal, Kairo.Space.stack)
            .padding(.top, 4)
            .padding(.bottom, 28)
        }
        .background(KairoCanvas())
    }

    // MARK: - Header

    private func header(_ model: MealLogModel) -> some View {
        KairoHeader(eyebrow: "log a meal", title: title(for: model.state)) {
            if model.state != .captured {
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { model.reset() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .bold))
                        Text("Start over").font(.kairoLabel).tracking(0.5)
                    }
                    .foregroundStyle(Kairo.inkSoft)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Capsule().fill(Kairo.hairline.opacity(0.06)))
                    .overlay(Capsule().strokeBorder(Kairo.hairline.opacity(0.12), lineWidth: 0.5))
                }
                .buttonStyle(.kairoPress)
            }
        }
        .padding(.horizontal, 4)
    }

    /// The title says which state the entry is in, in words rather than in an
    /// enum case name.
    private func title(for state: MealEntryState) -> String {
        switch state {
        case .captured:              "What did you eat?"
        case .classifying:           "Looking at it"
        case .ungrounded:            "I don't know this one"
        case .awaitingTeaching:      "Teach me once"
        case .awaitingClarification: "One question"
        case .estimated:             "Here's the estimate"
        case .confirmed:             "Writing it down"
        case .logged, .corrected:    "Logged"
        case .archived:              "Filed for the day"
        case .failed:                "That didn't work"
        }
    }

    // MARK: - captured

    @ViewBuilder
    private func captureSection(_ model: MealLogModel) -> some View {
        if lookingUp != nil || lookupFailure != nil {
            barcodeStatus
        }

        visionWarning

        VStack(spacing: 8) {
            SectionHeader(title: "Photo", icon: "camera", tint: Kairo.leaf)
            if let photo = model.photo {
                photoTaken(photo, model)
            } else {
                photoPrompt
            }
        }

        VStack(spacing: 8) {
            SectionHeader(title: model.photo == nil ? "Scripted photos" : "Scripted estimate",
                          icon: "square.stack.3d.up",
                          trailing: "3 paths", tint: Kairo.inkFaint)
            if model.photo != nil {
                TrustNote(text: "The photo above is yours. The three estimates below are "
                          + "still scripted — the on-device classifier is phase 2 work, so "
                          + "Kairo will not pretend to have read your plate. Pick the "
                          + "branch you want to see.",
                          icon: "exclamationmark.triangle")
            }

            analyseRow

            // Same seeded items and the same `recognise` calls as before — these
            // are the branches the state machine can take without a backend.
            ChoiceCard(title: "Grilled salmon and rice",
                       subtitle: "the confident path: both items clear the threshold, "
                       + "so it goes straight to an estimate",
                       icon: "fork.knife",
                       tint: Kairo.leaf) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                    model.recognise(candidates: [
                        FoodItem(name: "grilled salmon", grams: 160,
                                 facts: NutritionFacts(kilojoules: 1180, proteinGrams: 34),
                                 confidence: 0.88),
                        FoodItem(name: "steamed rice", grams: 180,
                                 facts: NutritionFacts(kilojoules: 1000, carbGrams: 58),
                                 confidence: 0.79),
                    ], grounded: true)
                }
            }

            ChoiceCard(title: "Ambiguous portion (mixed plate)",
                       subtitle: "confidence lands under the threshold, so Kairo spends "
                       + "one question instead of guessing the portion",
                       icon: "questionmark.bubble",
                       tint: Kairo.amber) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                    model.recognise(candidates: [
                        FoodItem(name: "stir-fried noodles", grams: 300,
                                 facts: NutritionFacts(kilojoules: 2400, carbGrams: 82),
                                 confidence: 0.41),
                    ], grounded: true)
                }
            }

            // FR8.2 without a vision provider. It feeds a canned response
            // through `apply` — the *same* handler the network path uses — so
            // the drink offer being exercised here is evidence about the real
            // code and not about a second one written for the demo. The only
            // thing scripted is where the `MealAnalysis` came from.
            ChoiceCard(title: "A plate with a glass beside it",
                       subtitle: "scripted FR8.2: the analyst sees a drink it can "
                       + "measure, and Kairo offers it rather than logging it",
                       icon: "cup.and.saucer.fill",
                       tint: Kairo.sky) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                    model.apply(Self.plateWithAGlass)
                }
            }

            ChoiceCard(title: "A dish Kairo has never seen",
                       subtitle: "takes the ungrounded path: it refuses to publish a number",
                       icon: "questionmark.circle",
                       tint: Kairo.coral) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                    model.recognise(candidates: [], grounded: false)
                }
            }
        }
    }

    /// The scripted FR8.2 response.
    ///
    /// Two drinks on purpose, and only one of them survives: the water is in
    /// shot and measurable, the second is the inference the schema exists to
    /// stop — a model reasoning "they had curry, so probably a lassi" rather
    /// than seeing one. The backend zeroes it; this fixture arrives already
    /// filtered, which is what a real response looks like by the time it is here.
    private static let plateWithAGlass = RemoteAgentClient.MealAnalysis(
        state: "estimated", grounded: true, failure: nil, clarifyingQuestion: nil,
        items: [
            FoodItem(name: "dal and rice", grams: 320,
                     facts: NutritionFacts(kilojoules: 1850, proteinGrams: 18, carbGrams: 74),
                     confidence: 0.81),
        ],
        drinks: [
            RemoteAgentClient.InferredDrink(name: "water", millilitres: 250,
                                            kilojoules: 0, confidence: 0.72),
        ])

    /// FR8.2 / NFR6 — send the photo to the analyst, having asked first.
    ///
    /// Separate button rather than automatic on capture, because NFR6 says meal
    /// photographs are "uploaded only on explicit per-session consent" and an
    /// upload that happens because you took a picture is not consent to
    /// anything. The sheet states what leaves the phone before it leaves.
    @ViewBuilder private var analyseRow: some View {
        if let model, model.photo != nil {
            if model.analysing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Reading your plate…")
                        .font(.kairoCaption).foregroundStyle(Kairo.inkSoft)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .kairoCard()
            } else if app.backend.client != nil,
                      app.backend.provider?.visionIsUnavailable != true {
                ChoiceCard(title: "Analyse this photo",
                           subtitle: "sends it to the bound backend once. Real items, real "
                           + "confidence — and any drink it can actually see (FR8.2).",
                           icon: "sparkle.magnifyingglass",
                           tint: Kairo.sky) {
                    confirmingUpload = true
                }
            }
        }
    }

    /// FR8.2's offer. **Never written without an answer.**
    ///
    /// The hydration total is the number the user taps to correct; a volume read
    /// off a picture written into it silently would put a guess where somebody
    /// believes they measured. Declining is recorded the same way accepting is,
    /// because "no" is an answer and an offer that reappears has not heard it.
    @ViewBuilder private func drinksOffer(_ model: MealLogModel) -> some View {
        if !model.pendingDrinks.isEmpty {
            VStack(spacing: 8) {
                SectionHeader(title: "A drink in the photo", icon: "cup.and.saucer",
                              trailing: "\(model.pendingDrinks.count)", tint: Kairo.sky)
                TrustNote(text: "Kairo thinks it can see this. It has not been added to "
                          + "your water — a volume read off a picture is weaker than a "
                          + "tap, so it asks.",
                          icon: "hand.raised")
                ForEach(model.pendingDrinks) { drink in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "drop.fill")
                            .font(.kairoGlyph(15, weight: .semibold))
                            .foregroundStyle(Kairo.colour(for: .hydration))
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(Kairo.colour(for: .hydration).opacity(0.14)))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(drink.name), about \(Int(drink.millilitres)) ml")
                                .font(.kairoHeadline).foregroundStyle(Kairo.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("confidence \(Int(drink.confidence * 100))%")
                                .font(.kairoCaption).foregroundStyle(Kairo.inkSoft)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 10) {
                        Button("Add to my water") {
                            if let sip = model.acceptDrink(drink) { app.record(sip) }
                        }
                        .buttonStyle(.kairoProminent(Kairo.colour(for: .hydration)))
                        Button("Not mine") { model.declineDrink(drink) }
                            .buttonStyle(.kairoSoft)
                    }
                }
            }
            .kairoCard(tint: Kairo.sky)
        }
    }

    /// The one provider fact that belongs on a feature screen.
    ///
    /// Everything else about which model answered is a settings fact. This is
    /// not: it predicts a failure the user is about to walk into, and it has to
    /// be said *before* they photograph anything rather than after, when the
    /// answer comes back empty and looks like the app not recognising the dish.
    @ViewBuilder private var visionWarning: some View {
        if app.backend.provider?.visionIsUnavailable == true {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "eye.trianglebadge.exclamationmark")
                    .font(.kairoGlyph(15, weight: .semibold))
                    .foregroundStyle(Kairo.amber)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Kairo.amber.opacity(0.14)))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Photo analysis is unavailable on this deployment")
                        .font(.kairoHeadline).foregroundStyle(Kairo.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("The barcode path still works, and it is the one that yields a "
                         + "measured figure rather than an estimate.")
                        .font(.kairoCaption).foregroundStyle(Kairo.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .kairoCard(tint: Kairo.amber)
            .accessibilityElement(children: .combine)
        }
    }

    /// The camera is real. What it feeds is not yet, and the section below says
    /// so — a tappable tile that opens nothing would be the worse lie, but so
    /// would a photo followed by numbers presented as a measurement.
    private var photoPrompt: some View {
        Button { showingCamera = true } label: {
            VStack(spacing: 10) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Kairo.leaf)
                Text("Photograph your meal")
                    .font(.kairoHeadline)
                    .foregroundStyle(Kairo.ink)
                Text("One photo. It stays on your iPhone unless you ask for it to be "
                     + "analysed — and that asks you first, every session (NFR6).")
                    .font(.kairoCaption)
                    .foregroundStyle(Kairo.inkSoft)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .padding(.horizontal, 18)
            .background {
                let shape = RoundedRectangle(cornerRadius: Kairo.Radius.card, style: .continuous)
                shape
                    .fill(Kairo.hairline.opacity(0.03))
                    .overlay {
                        shape.strokeBorder(
                            LinearGradient(colors: [Kairo.leaf.opacity(0.75),
                                                    Kairo.teal.opacity(0.30)],
                                           startPoint: .topLeading,
                                           endPoint: .bottomTrailing),
                            style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                    }
            }
        }
        .buttonStyle(.kairoPress)
        .accessibilityLabel("Photograph your meal. Opens the camera.")
    }

    // MARK: - the barcode path

    @ViewBuilder private var barcodeStatus: some View {
        if let code = lookingUp {
            HStack(spacing: 12) {
                KairoInlineLoader()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Looking up \(code)").font(.kairoHeadline)
                        .foregroundStyle(Kairo.ink)
                    Text("in the food composition table")
                        .font(.caption).foregroundStyle(Kairo.inkSoft)
                }
                Spacer(minLength: 0)
            }
            .kairoCard(tint: Kairo.sky)
        } else if let why = lookupFailure {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "barcode.viewfinder")
                        .font(.system(size: 12, weight: .bold))
                    Text("NOT IN THE TABLE").font(.kairoLabel).tracking(1.1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Kairo.coral)
                Text(why)
                    .font(.subheadline).foregroundStyle(Kairo.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Fair enough") { lookupFailure = nil }
                    .buttonStyle(.kairoSoft(Kairo.coral))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .kairoCard(tint: Kairo.coral)
        }
    }

    /// A scan resolves to a published row or to nothing. There is no third
    /// branch where Kairo supplies a number of its own.
    @MainActor
    /// FR8.2. The user has said yes; send it once.
    private func analysePhoto() async {
        guard let model, let client = app.backend.client else { return }
        await model.analysePhoto(using: client, userID: app.userID,
                                 coverage: app.coverage)
    }

    private func resolve(_ code: String) async {
        lookingUp = code
        lookupFailure = nil
        do {
            let row = try await app.env.nutrition.byBarcode(code)
            lookingUp = nil
            reference = row
        } catch {
            lookingUp = nil
            lookupFailure = explain(error, code: code)
        }
    }

    private func explain(_ error: Error, code: String) -> String {
        switch error as? NutritionLookupError {
        case .notFound:
            "Nothing is published for \(code). Kairo will not invent a row — "
            + "photograph the meal and teach it the dish instead."
        case .noEnergyPublished:
            "\(code) is on file, but nobody has published an energy figure for it. "
            + "Kairo would have to write a zero, and a zero is not a measurement."
        case .offline:
            "Kairo could not reach the food table, so it has nothing to tell you. "
            + "Nothing was estimated in the meantime."
        case nil:
            "That barcode could not be resolved: \(error.localizedDescription)"
        }
    }

    /// The published row, times the portion the user chose. Every figure in the
    /// resulting item traces back to `row.sourceID`.
    private func adopt(_ row: FoodReference, grams: Double, basis: PortionBasis) {
        reference = nil
        guard let model else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            model.adoptFromLabel(row.item(grams: grams, portionConfidence: basis.confidence))
        }
    }

    /// The photo, reduced to a strip once it is no longer the subject.
    private func photoStrip(_ photo: UIImage) -> some View {
        HStack(spacing: 12) {
            Image(uiImage: photo)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 62, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("Your photo").font(.kairoLabel).tracking(0.6)
                    .foregroundStyle(Kairo.inkFaint)
                Text("The numbers beside it are scripted, not read from it.")
                    .font(.caption)
                    .foregroundStyle(Kairo.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Pill(text: "on this iPhone", icon: "iphone", tint: Kairo.teal)
        }
        .kairoCard(padding: 12, radius: Kairo.Radius.inner)
        .accessibilityElement(children: .combine)
    }

    private func photoTaken(_ photo: UIImage, _ model: MealLogModel) -> some View {
        VStack(spacing: 12) {
            Image(uiImage: photo)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: Kairo.Radius.inner,
                                            style: .continuous))
                .overlay(alignment: .topLeading) {
                    Pill(text: "on this iPhone", icon: "iphone", tint: Kairo.teal)
                        .padding(10)
                }
                .accessibilityLabel("The meal photo you took. It stays on this iPhone.")

            HStack(spacing: 10) {
                Button("Retake") {
                    model.discardPhoto()
                    showingCamera = true
                }
                .buttonStyle(.kairoSoft)
                Button("Remove") { model.discardPhoto() }
                    .buttonStyle(.kairoSoft(Kairo.coral))
            }
        }
        .kairoCard()
    }

    // MARK: - ungrounded (OF1)

    @ViewBuilder
    private func ungroundedSection(_ model: MealLogModel) -> some View {
        VStack(spacing: 8) {
            SectionHeader(title: "Ungrounded", icon: "questionmark.circle", tint: Kairo.coral)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Kairo.coral)
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(Kairo.coral.opacity(0.14)))
                    Text("I don't recognise this dish")
                        .font(.kairoSubject)
                        .foregroundStyle(Kairo.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }

                Text("I could publish a number, but it would be a guess dressed up as "
                     + "a measurement.")
                    .font(.kairoBody)
                    .foregroundStyle(Kairo.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Teach me once") {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                        model.requestTeaching()
                    }
                }
                .buttonStyle(.kairoProminent(Kairo.coral))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .kairoCard(tint: Kairo.coral)

            TrustNote(text: "No estimate exists for this entry, so none is shown. The "
                      + "machine holds at ungrounded until you teach it or abandon it.",
                      icon: "hand.raised")
        }
    }

    // MARK: - awaitingTeaching (OF1)

    @ViewBuilder
    private func teachingSection(_ model: MealLogModel) -> some View {
        VStack(spacing: 8) {
            SectionHeader(title: "Teach me", icon: "graduationcap", tint: Kairo.coral)

            ChoiceCard(title: "Scan the barcode or label",
                       subtitle: "reads the panel off the packet — the strongest evidence "
                       + "there is",
                       icon: "barcode.viewfinder",
                       tint: Kairo.leaf) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                    model.teach(FoodItem(name: "taught dish", grams: 250,
                                         facts: NutritionFacts(kilojoules: 1900, proteinGrams: 22),
                                         confidence: 0.95))
                }
            }

            ChoiceCard(title: "Describe it instead",
                       subtitle: "a guided description — usable, and recorded as the weaker "
                       + "source it is",
                       icon: "text.viewfinder",
                       tint: Kairo.amber) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                    model.teach(FoodItem(name: "described dish", grams: 250,
                                         facts: NutritionFacts(kilojoules: 2000),
                                         confidence: 0.7))
                }
            }

            TrustNote(text: "Taught once. The entry stays flagged as yours, so the estimate "
                      + "is never passed off later as something Kairo worked out on its own.",
                      icon: "graduationcap")
        }
    }

    // MARK: - awaitingClarification

    @ViewBuilder
    private func clarificationSection(_ model: MealLogModel) -> some View {
        VStack(spacing: 8) {
            SectionHeader(title: "One question", icon: "questionmark.bubble", tint: Kairo.amber)

            VStack(alignment: .leading, spacing: 10) {
                Pill(text: "costs one interruption", icon: "bell.badge", tint: Kairo.amber)
                Text(model.clarifyingQuestion ?? "What was in this?")
                    .font(.kairoSubject)
                    .foregroundStyle(Kairo.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .kairoCard(tint: Kairo.amber)

            ChoiceCard(title: "About one cup",
                       subtitle: "220 g of noodles",
                       icon: "circle.grid.2x1",
                       tint: Kairo.teal) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                    model.answerClarification(with: [
                        FoodItem(name: "stir-fried noodles", grams: 220,
                                 facts: NutritionFacts(kilojoules: 1760, carbGrams: 60),
                                 confidence: 0.82),
                    ])
                }
            }

            ChoiceCard(title: "About two cups",
                       subtitle: "440 g of noodles",
                       icon: "circle.grid.2x2",
                       tint: Kairo.teal) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                    model.answerClarification(with: [
                        FoodItem(name: "stir-fried noodles", grams: 440,
                                 facts: NutritionFacts(kilojoules: 3520, carbGrams: 120),
                                 confidence: 0.82),
                    ])
                }
            }

            TrustNote(text: "This question is charged to the same attention budget as a "
                      + "reminder.", icon: "gauge.with.dots.needle.bottom.50percent")
        }
    }

    // MARK: - estimated

    @ViewBuilder
    private func estimateSection(_ model: MealLogModel) -> some View {
        let entry = model.entry
        let macros = macroTotals(entry)

        VStack(spacing: 8) {
            // The photo stays with the estimate. Taking one and then hiding it
            // behind a set of numbers is how a screen stops being about a meal.
            if let photo = model.photo { photoStrip(photo) }
            SectionHeader(title: "Estimate", icon: "list.bullet.rectangle",
                          trailing: String(format: "%.0f%% confident", entry.confidence * 100),
                          tint: Kairo.leaf)

            VStack(alignment: .leading, spacing: 16) {
                ForEach(entry.items, id: \.name) { item in
                    itemRow(item)
                }

                Divider().overlay(Kairo.hairline.opacity(0.12))

                // NFR14: kilojoules first and largest — Australian labels are in kJ,
                // and kJ is the unit Kairo stores. Calories are derived, and look it.
                VStack(alignment: .leading, spacing: 2) {
                    Text("TOTAL")
                        .font(.kairoLabel).tracking(1.1)
                        .foregroundStyle(Kairo.inkFaint)
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text("\(Int(entry.totalKilojoules))")
                            .font(.kairoDisplay)
                            .monospacedDigit()
                            .foregroundStyle(Kairo.ink)
                            .contentTransition(.numericText())
                        Text("kJ")
                            .font(.kairoNumber)
                            .foregroundStyle(Kairo.inkSoft)
                        Spacer(minLength: 0)
                    }
                    Text("≈ \(Int(derivedCalories(entry))) Cal, derived from the kilojoules")
                        .font(.caption2)
                        .foregroundStyle(Kairo.inkFaint)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Total \(Int(entry.totalKilojoules)) kilojoules")

                macroRow(macros)

                if entry.taughtByUser {
                    Pill(text: "you taught me this one", icon: "graduationcap",
                         tint: Kairo.violet)
                }

                Button("Looks right — log it") {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                        model.confirmAndLog()
                    }
                }
                .buttonStyle(.kairoProminent(Kairo.leaf))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .kairoCard()
        }
    }

    private func itemRow(_ item: FoodItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.kairoHeadline)
                        .foregroundStyle(Kairo.ink)
                    Text("\(Int(item.grams)) g")
                        .font(.kairoCaption)
                        .foregroundStyle(Kairo.inkFaint)
                }
                Spacer(minLength: 8)
                HStack(alignment: .lastTextBaseline, spacing: 3) {
                    Text("\(Int(item.facts.kilojoules))")
                        .font(.kairoSubject)
                        .monospacedDigit()
                        .foregroundStyle(Kairo.ink)
                    Text("kJ")
                        .font(.kairoLabel)
                        .foregroundStyle(Kairo.inkFaint)
                }
            }

            ScoreMeter(value: item.confidence, tint: confidenceTint(item.confidence), height: 5)

            HStack {
                Text(String(format: "%.0f%% confident", item.confidence * 100))
                Spacer()
                Text(confidenceWord(item.confidence))
            }
            .font(.kairoMono)
            .foregroundStyle(confidenceTint(item.confidence).opacity(0.9))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), \(Int(item.grams)) grams, "
                            + "\(Int(item.facts.kilojoules)) kilojoules, "
                            + String(format: "%.0f percent confident", item.confidence * 100))
    }

    /// The macros were always on `NutritionFacts` and never shown. The meters are
    /// each macro's share of the grams on this plate, not a share of any target —
    /// Kairo does not hold a macro goal for you.
    private func macroRow(_ m: (protein: Double, carbs: Double, fat: Double)) -> some View {
        let total = m.protein + m.carbs + m.fat
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                macroCell("protein", m.protein, total, Kairo.sky)
                macroCell("carbs", m.carbs, total, Kairo.amber)
                macroCell("fat", m.fat, total, Kairo.violet)
            }
            if m.fat == 0 || m.protein == 0 || m.carbs == 0 {
                Text("A zero is a gap in the reference entry, not a claim that there "
                     + "is none of it.")
                    .font(.caption2)
                    .foregroundStyle(Kairo.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func macroCell(_ label: String, _ grams: Double,
                           _ total: Double, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.kairoLabel).tracking(0.8)
                .foregroundStyle(Kairo.inkFaint)
            Text("\(Int(grams.rounded())) g")
                .font(.kairoHeadline)
                .monospacedDigit()
                .foregroundStyle(grams > 0 ? Kairo.ink : Kairo.inkFaint)
            ScoreMeter(value: total > 0 ? grams / total : 0, tint: tint, height: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(Int(grams.rounded())) grams")
    }

    private func macroTotals(_ entry: MealEntry) -> (protein: Double, carbs: Double, fat: Double) {
        entry.items.reduce(into: (protein: 0.0, carbs: 0.0, fat: 0.0)) { acc, item in
            acc.protein += item.facts.proteinGrams
            acc.carbs += item.facts.carbGrams
            acc.fat += item.facts.fatGrams
        }
    }

    /// Through the domain's own conversion, so there is exactly one definition of
    /// what a calorie is in this app.
    private func derivedCalories(_ entry: MealEntry) -> Double {
        entry.items.reduce(0) { $0 + $1.facts.calories }
    }

    private func confidenceTint(_ c: Double) -> Color {
        if c >= 0.8 { return Kairo.leaf }
        if c >= 0.6 { return Kairo.amber }
        return Kairo.coral
    }

    private func confidenceWord(_ c: Double) -> String {
        if c >= 0.8 { return "grounded" }
        if c >= 0.6 { return "usable" }
        return "weak"
    }

    // MARK: - logged

    @ViewBuilder
    private func loggedSection(_ model: MealLogModel) -> some View {
        VStack(spacing: 8) {
            if let photo = model.photo { photoStrip(photo) }
            SectionHeader(title: "Logged", icon: "checkmark.seal", tint: Kairo.leaf)
            LoggedCard(kilojoules: model.entry.totalKilojoules,
                       taught: model.entry.taughtByUser) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { model.reset() }
            }
        }

        // CF3 used to be demonstrated here with a hard-coded disagreement about
        // "the meal you just logged" — two `Position`s written in this file,
        // identical for every meal anyone ever logged, carrying evidence
        // sentences about a plate the user had not photographed.
        //
        // It is gone, and `SecondOpinionView` went with it rather than being
        // left as an unreachable view. The backend's `/v1/dissent` returns
        // `dto.outcome` — the winning position, the policy and the reason — and
        // never the losing positions, so there is no way to draw a real
        // two-sided disagreement from what is on the wire. Drawing one anyway
        // would mean writing the loser's argument here, which is the thing this
        // change removed. When the route carries the whole `DisagreementCase`,
        // the card belongs here.
    }


    // MARK: - Transitional and error

    private func transitionalSection(_ model: MealLogModel) -> some View {
        HStack(spacing: 12) {
            KairoInlineLoader()
            // In words. This printed `model.state.name` — a camelCase machine
            // state — at the user, in monospace, on a feature screen.
            Text(title(for: model.state))
                .font(.kairoHeadline)
                .foregroundStyle(Kairo.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kairoCard()
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Kairo.coral)
                Text("The machine refused that move")
                    .font(.kairoHeadline)
                    .foregroundStyle(Kairo.ink)
                Spacer(minLength: 0)
            }
            Text(message)
                .font(.kairoMono)
                .foregroundStyle(Kairo.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kairoCard(tint: Kairo.coral)
    }
}

// MARK: - Logged

/// Split out so `symbolEffect` gets a fresh `@State` trigger each time the card
/// appears.
private struct LoggedCard: View {
    let kilojoules: Double
    let taught: Bool
    let logAnother: () -> Void

    @State private var landed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Kairo.leaf)
                    .symbolEffect(.bounce, value: landed)
                    .frame(width: 50, height: 50)
                    .background(Circle().fill(Kairo.leaf.opacity(0.14)))

                VStack(alignment: .leading, spacing: 3) {
                    Text("On your day")
                        .font(.kairoHeadline)
                        .foregroundStyle(Kairo.ink)
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text("\(Int(kilojoules))")
                            .font(.kairoNumber)
                            .monospacedDigit()
                            .foregroundStyle(Kairo.ink)
                            .contentTransition(.numericText())
                        Text("kJ logged")
                            .font(.kairoCaption)
                            .foregroundStyle(Kairo.inkSoft)
                    }
                }
                Spacer(minLength: 0)
            }

            if taught {
                Pill(text: "logged from what you taught me", icon: "graduationcap",
                     tint: Kairo.violet)
            }

            Button("Log another", action: logAnother)
                .buttonStyle(.kairoSoft(Kairo.leaf))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kairoCard(tint: Kairo.leaf)
        .onAppear { landed = true }
    }
}

// MARK: - Progress track

/// The state machine, drawn. Capture → recognise → estimate → logged, with the
/// branch step spliced in when this entry took one. The current step is tinted
/// and larger, steps already passed are filled and ticked, and the rest are
/// faint.
private struct MealProgressTrack: View {
    let entry: MealEntry
    /// Four labels under four dots across 375 points is 9 points of room each
    /// at an accessibility size, which rendered "capture" as "ca…" and
    /// "recognise" as "re…". The per-dot labels come off and the step is named
    /// in full underneath instead — the same words, legible, once.
    @Environment(\.dynamicTypeSize) private var typeSize

    private struct Step {
        let id: String
        let label: String
        let icon: String
        let tint: Color
    }

    var body: some View {
        let track = steps
        let current = currentIndex(in: track)

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(track.indices, id: \.self) { i in
                    if i > 0 {
                        connector(filled: i <= current, tint: track[i].tint)
                    }
                    dot(track[i], isCurrent: i == current, isPast: i < current,
                        showsLabel: !typeSize.isAccessibilitySize)
                }
            }
            .frame(maxWidth: .infinity)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: entry.state)

            // The step, in words, at every text size. This replaces the
            // `state · camelCaseName` line that used to sit here: the same
            // position, the same job, said in the vocabulary the dots use.
            Text(spokenStep(track, current: current))
                .font(.kairoCaption)
                .foregroundStyle(track.indices.contains(current)
                                 ? track[current].tint : Kairo.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .kairoCard(padding: 16)
        // The track was `accessibilityHidden` on every dot and carried a
        // camelCase enum name as its only label. One element, and its value is
        // the step in the same words the dots are labelled with.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue(spokenStep(track, current: current))
    }

    /// The current step, in the same words the track draws.
    private func spokenStep(_ track: [Step], current: Int) -> String {
        guard track.indices.contains(current) else { return "not started" }
        return "step \(current + 1) of \(track.count), \(track[current].label)"
    }

    // MARK: Steps

    private var steps: [Step] {
        var s: [Step] = [
            Step(id: "capture", label: "capture", icon: "camera.viewfinder", tint: Kairo.leaf),
            Step(id: "recognise", label: "recognise", icon: "magnifyingglass", tint: Kairo.sky),
        ]
        if let branch { s.append(branch) }
        s.append(Step(id: "estimate", label: "estimate", icon: "list.bullet.rectangle",
                      tint: Kairo.leaf))
        s.append(Step(id: "logged", label: "logged", icon: "checkmark.seal", tint: Kairo.leaf))
        return s
    }

    /// One slot, present only when this entry actually left the straight path.
    /// Its label follows how far down the branch the entry has gone, which is why
    /// the ungrounded and teach states share the slot.
    private var branch: Step? {
        let lifecycle = entry.lifecycle
        if lifecycle.visited(.ungrounded) || lifecycle.visited(.awaitingTeaching) {
            let onTheEdgeOfKnowing = entry.state == .ungrounded
            return Step(id: "branch",
                        label: onTheEdgeOfKnowing ? "unknown" : "teach",
                        icon: onTheEdgeOfKnowing ? "questionmark.circle" : "graduationcap",
                        tint: Kairo.coral)
        }
        if lifecycle.visited(.awaitingClarification) {
            return Step(id: "branch", label: "clarify", icon: "questionmark.bubble",
                        tint: Kairo.amber)
        }
        return nil
    }

    private func currentIndex(in steps: [Step]) -> Int {
        let id: String
        switch entry.state {
        case .captured:
            id = "capture"
        case .classifying, .failed:
            id = "recognise"
        case .ungrounded, .awaitingTeaching, .awaitingClarification:
            id = "branch"
        case .estimated, .confirmed:
            id = "estimate"
        case .logged, .corrected, .archived:
            id = "logged"
        }
        return steps.firstIndex { $0.id == id } ?? 0
    }

    // MARK: Drawing

    private func connector(filled: Bool, tint: Color) -> some View {
        Capsule()
            .fill(filled ? tint.opacity(0.45) : Kairo.hairline.opacity(0.10))
            .frame(height: 2)
            .frame(maxWidth: .infinity)
            .padding(.top, 19)
    }

    private func dot(_ step: Step, isCurrent: Bool, isPast: Bool,
                     showsLabel: Bool) -> some View {
        let diameter: CGFloat = isCurrent ? 34 : 24
        return VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(fill(step, isCurrent: isCurrent, isPast: isPast))
                    .frame(width: diameter, height: diameter)
                if isCurrent {
                    Circle()
                        .strokeBorder(step.tint.opacity(0.5), lineWidth: 1.5)
                        .frame(width: diameter + 8, height: diameter + 8)
                }
                Image(systemName: isPast ? "checkmark" : step.icon)
                    .font(.system(size: isCurrent ? 14 : 10, weight: .bold))
                    .foregroundStyle(isCurrent ? Color.black.opacity(0.85)
                                     : isPast ? step.tint : Kairo.inkFaint)
            }
            .frame(height: 42)

            // 9pt flat was unreadable before Dynamic Type was touched at all.
            // A scaling label needs room to grow, so the slot is a minimum
            // rather than a fixed width and the text may take two lines.
            if showsLabel {
                Text(step.label)
                    .font(.kairoLabel)
                    .fontWeight(isCurrent ? .bold : .medium)
                    .foregroundStyle(isCurrent ? step.tint
                                     : isPast ? Kairo.inkSoft : Kairo.inkFaint)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minWidth: 44)
        .accessibilityHidden(true)
    }

    private func fill(_ step: Step, isCurrent: Bool, isPast: Bool) -> AnyShapeStyle {
        if isCurrent { return AnyShapeStyle(Kairo.fade(step.tint)) }
        if isPast { return AnyShapeStyle(step.tint.opacity(0.24)) }
        return AnyShapeStyle(Kairo.hairline.opacity(0.07))
    }
}
