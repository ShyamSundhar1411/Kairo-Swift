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
    }

    private func question(for items: [FoodItem]) -> String {
        guard let weakest = items.min(by: { $0.confidence < $1.confidence }) else {
            return "What was in this?"
        }
        return "How much \(weakest.name) was there — about \(Int(weakest.grams)) g?"
    }
}
