import Foundation
import Observation
import UIKit
import KairoKit

/// Member A — CF1 / OF1. Drives the `MealEntry` lifecycle. The view never moves
/// the state machine itself; every transition goes through here so an illegal
/// one surfaces as an error instead of a wrong screen.
@Observable
final class MealLogModel {
    private let clock: Clock
    private let threshold: Double

    private(set) var entry: MealEntry
    private(set) var clarifyingQuestion: String?
    private(set) var error: String?
    /// The photo the user actually took. It lives here rather than on
    /// `MealEntry` because `KairoKit` imports Foundation and nothing else —
    /// putting a `UIImage` in the domain would break that in one line.
    ///
    /// Nothing is done with it yet beyond showing it back to the user. The
    /// classifier is phase 2; until then the photo is real and the estimate
    /// beside it is scripted, and the screen has to say so.
    private(set) var photo: UIImage?

    /// FR8.2 — drinks the analyst could see in the photograph.
    ///
    /// **Offered, never logged.** The hydration total is the number the user
    /// taps to correct; a volume read off a picture written into it without
    /// asking would put a guess where somebody believes they measured. The user
    /// accepts each one, or none.
    private(set) var drinks: [RemoteAgentClient.InferredDrink] = []
    /// Drinks the user has accepted this session, so the offer does not come
    /// back after it has been answered.
    private(set) var acceptedDrinkIDs: Set<String> = []
    private(set) var analysing = false
    /// Set when the backend was asked and could not answer — distinct from the
    /// analyst having looked and declined to quantify, which is `.ungrounded`
    /// and is a feature (OF1).
    private(set) var analysisFailure: String?

    var pendingDrinks: [RemoteAgentClient.InferredDrink] {
        drinks.filter { !acceptedDrinkIDs.contains($0.id) }
    }

    init(clock: Clock, confidenceThreshold: Double = 0.6) {
        self.clock = clock
        self.threshold = confidenceThreshold
        self.entry = MealEntry(id: UUID().uuidString, capturedAt: clock.now)
    }

    var state: MealEntryState { entry.state }

    func attach(_ photo: UIImage) {
        self.photo = photo
    }

    func discardPhoto() {
        photo = nil
    }

    /// Simulates the on-device Core ML pass. The real classifier is injected in
    /// phase 2; the state machine around it does not change.
    func recognise(candidates: [FoodItem], grounded: Bool) {
        do {
            try entry.lifecycle.transition(on: "beginRecognition", to: .classifying, at: clock.now)
            guard grounded else {
                try entry.lifecycle.transition(on: "noGroundingFound", to: .ungrounded, at: clock.now)
                return
            }
            entry.items = candidates
            if entry.confidence >= threshold {
                try entry.lifecycle.transition(on: "confidenceAccepted", to: .estimated, at: clock.now)
            } else {
                clarifyingQuestion = question(for: candidates)
                try entry.lifecycle.transition(on: "confidenceBelowThreshold",
                                               to: .awaitingClarification, at: clock.now)
            }
        } catch { self.error = String(describing: error) }
    }

    // MARK: - CF1 over the network (FR8.2)

    /// Drive the machine from a real analysis.
    ///
    /// Separate from `recognise` because the backend has already decided which
    /// branch this is — `state` on the response is the analyst's own answer —
    /// and re-deriving it here from the confidence would give two sources for
    /// one decision. The scripted paths still call `recognise`; this is the
    /// same machine reached with real evidence.
    func apply(_ analysis: RemoteAgentClient.MealAnalysis) {
        drinks = analysis.drinks
        analysisFailure = analysis.failure
        guard analysis.failure == nil else {
            // The analysis did not happen. Saying "ungrounded" here would dress
            // a broken call up as the product working as designed.
            return
        }
        do {
            try entry.lifecycle.transition(on: "beginRecognition", to: .classifying, at: clock.now)
            guard analysis.grounded, !analysis.items.isEmpty else {
                try entry.lifecycle.transition(on: "noGroundingFound", to: .ungrounded, at: clock.now)
                return
            }
            entry.items = analysis.items
            if let question = analysis.clarifyingQuestion {
                clarifyingQuestion = question
                try entry.lifecycle.transition(on: "confidenceBelowThreshold",
                                               to: .awaitingClarification, at: clock.now)
            } else {
                try entry.lifecycle.transition(on: "confidenceAccepted", to: .estimated, at: clock.now)
            }
        } catch { self.error = String(describing: error) }
    }

    /// Send the captured photo to the analyst.
    ///
    /// Does nothing without a photo: there is no path here that analyses an
    /// image the user did not take.
    func analysePhoto(using client: RemoteAgentClient, userID: String,
                      coverage: DayCoverage) async {
        guard let photo, let data = photo.jpegData(compressionQuality: 0.8) else { return }
        analysing = true
        defer { analysing = false }
        do {
            let analysis = try await client.analyseMeal(
                userID: userID, imageData: data, mediaType: "image/jpeg",
                hint: nil, coverage: coverage)
            apply(analysis)
        } catch {
            analysisFailure = String(describing: error)
        }
    }

    /// The user accepted one inferred drink. Returns the sip to log, or nil if
    /// it was already answered — so a double tap cannot double-count a glass.
    func acceptDrink(_ drink: RemoteAgentClient.InferredDrink) -> HydrationLog.Sip? {
        guard !acceptedDrinkIDs.contains(drink.id) else { return nil }
        acceptedDrinkIDs.insert(drink.id)
        return HydrationLog.Sip(id: "photo-\(entry.id)-\(drink.id)",
                                at: clock.now,
                                millilitres: Int(drink.millilitres.rounded()),
                                source: .photo)
    }

    /// The user declined it. Recorded the same way as acceptance so the offer
    /// does not reappear — "no" is an answer, not an absence of one.
    func declineDrink(_ drink: RemoteAgentClient.InferredDrink) {
        acceptedDrinkIDs.insert(drink.id)
    }

    func requestTeaching() {
        do { try entry.lifecycle.transition(on: "teachRequested", to: .awaitingTeaching, at: clock.now) }
        catch { self.error = String(describing: error) }
    }

    /// OF1 — the teach-once path. Barcode, label OCR, or a short description.
    func teach(_ item: FoodItem) {
        do {
            entry.items = [item]
            entry.taughtByUser = true
            try entry.lifecycle.transition(on: "dishTaught", to: .estimated, at: clock.now)
        } catch { self.error = String(describing: error) }
    }

    func answerClarification(with items: [FoodItem]) {
        do {
            entry.items = items
            clarifyingQuestion = nil
            try entry.lifecycle.transition(on: "userAnswered", to: .estimated, at: clock.now)
        } catch { self.error = String(describing: error) }
    }

    func confirmAndLog() {
        do {
            try entry.lifecycle.transition(on: "userConfirmed", to: .confirmed, at: clock.now)
            try entry.lifecycle.transition(on: "written", to: .logged, at: clock.now)
        } catch { self.error = String(describing: error) }
    }

    /// CF1 + OF1 — the barcode path.
    ///
    /// The classifier never grounded this dish; the label did. That is precisely
    /// the route OF1 already models — the `dishTaught` guard in the transition
    /// table names "barcode | label OCR | guided description" — so the entry
    /// walks the ungrounded/teach edges instead of faking a confident
    /// classification it never made. It also means `taughtByUser` is true, which
    /// is the honest thing to show.
    ///
    /// The portion's weakness rides on `item.confidence` and still limits what
    /// the day is allowed to assert; it is not laundered by arriving here.
    func adoptFromLabel(_ item: FoodItem) {
        do {
            try entry.lifecycle.transition(on: "beginRecognition", to: .classifying, at: clock.now)
            try entry.lifecycle.transition(on: "noGroundingFound", to: .ungrounded, at: clock.now)
            try entry.lifecycle.transition(on: "teachRequested", to: .awaitingTeaching, at: clock.now)
            entry.items = [item]
            entry.taughtByUser = true
            try entry.lifecycle.transition(on: "dishTaught", to: .estimated, at: clock.now)
        } catch { self.error = String(describing: error) }
    }

    func reset() {
        entry = MealEntry(id: UUID().uuidString, capturedAt: clock.now)
        clarifyingQuestion = nil
        error = nil
        photo = nil
        drinks = []
        acceptedDrinkIDs = []
        analysisFailure = nil
    }

    private func question(for items: [FoodItem]) -> String {
        guard let weakest = items.min(by: { $0.confidence < $1.confidence }) else {
            return "What was in this?"
        }
        return "How much \(weakest.name) was there — about \(Int(weakest.grams)) g?"
    }
}
