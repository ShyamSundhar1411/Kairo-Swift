import SwiftUI
import KairoKit

/// Member C - CF9. A contract is proposed and accepted, never applied silently,
/// and it always carries an end date.
///
/// This is the only card in the app that asks the user for something, so it is
/// the only one allowed to look unlike the rest: a teal wash, a disc keyed to
/// the disruption that triggered it, the reduction drawn as a ring rather than
/// stated in a sentence, and every suspended class named on its own instead of
/// being flattened into a comma-joined list. Consent is easier to withhold when
/// what is being asked for is legible.
struct ContractProposalCard: View {
    @Environment(AppModel.self) private var model
    let contract: PlanContract

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            titleRow

            Text(bodyCopy)
                .font(.kairoBody)
                .foregroundStyle(Kairo.inkSoft)
                .fixedSize(horizontal: false, vertical: true)

            reductionRow
            suspendedRow
            expiryRow

            TrustNote(text: "This ends on its own - it will not quietly become your new normal.",
                      icon: "clock.arrow.circlepath")

            buttons
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kairoCard(tint: Kairo.teal)
        .shadow(color: Kairo.teal.opacity(0.18), radius: 20, y: 8)
    }

    // MARK: - Title

    private var titleRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Kairo.teal)
                .frame(width: 46, height: 46)
                .background(Circle().fill(Kairo.teal.opacity(0.16)))
                .overlay(Circle().strokeBorder(Kairo.teal.opacity(0.30), lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 3) {
                Text("ASKING, NOT APPLYING")
                    .font(.kairoLabel).tracking(1.1)
                    .foregroundStyle(Kairo.teal)
                Text(headline)
                    .font(.kairoSubject)
                    .foregroundStyle(Kairo.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - What it changes

    private var reductionPercent: Int { Int((contract.targetReduction * 100).rounded()) }

    private var reductionRow: some View {
        HStack(spacing: 14) {
            MetricRing(progress: contract.targetReduction,
                       tint: Kairo.teal,
                       centreText: "\(reductionPercent)%",
                       size: 58, lineWidth: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text("Targets drop \(reductionPercent)%")
                    .font(.kairoHeadline)
                    .foregroundStyle(Kairo.ink)
                Text("Applied to every daily target while the contract runs, then handed back.")
                    .font(.caption)
                    .foregroundStyle(Kairo.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: Kairo.Radius.inner, style: .continuous)
                .fill(Kairo.hairline.opacity(0.04))
        }
    }

    /// Each suspended class in its own colour. A user who does not want their
    /// sitting reminders paused has to be able to see that that is what is on
    /// the table.
    private var suspendedRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionHeader(title: "Reminders that pause", icon: "pause.circle")

            // PillWrap rather than a horizontal scroller: the point of naming
            // every suspended class is that the user can see what is on the
            // table, and a class parked off the right edge of a row nothing
            // advertises as scrollable is a class they will not see.
            if suspendedClasses.isEmpty {
                Pill(text: "nothing pauses", icon: "bell.fill", tint: Kairo.inkSoft)
            } else {
                PillWrap {
                    ForEach(suspendedClasses, id: \.self) { name in
                        Pill(text: Kairo.title(forNudgeClass: name),
                             icon: Kairo.icon(forNudgeClass: name),
                             tint: Kairo.colour(forNudgeClass: name))
                    }
                }
            }
        }
    }

    private var suspendedClasses: [String] {
        contract.suspended.map(\.name).sorted()
    }

    // MARK: - When it ends

    private var expiryRow: some View {
        PillWrap {
            if let expiry = contract.expiresAt {
                Pill(text: runLength, icon: "calendar.badge.clock", tint: Kairo.violet)
                Pill(text: "ends \(expiry.formatted(date: .abbreviated, time: .omitted))",
                     tint: Kairo.inkSoft)
            } else {
                Pill(text: "no end date recorded", icon: "calendar.badge.clock", tint: Kairo.coral)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Days rather than a bare date: the promise is about how long this lasts,
    /// so the length is what gets shown.
    private var runLength: String {
        guard let days = daysRunning else { return "no end date" }
        switch days {
        case 0:  return "ends today"
        case 1:  return "runs 1 day"
        default: return "runs \(days) days"
        }
    }

    private var daysRunning: Int? {
        guard let expiry = contract.expiresAt else { return nil }
        // The user's own calendar. A contract that "runs 3 days" counted in
        // Sydney is off by one for half the world.
        let cal = Calendar.current
        let from = cal.startOfDay(for: model.env.clock.now)
        let to = cal.startOfDay(for: expiry)
        return max(0, cal.dateComponents([.day], from: from, to: to).day ?? 0)
    }

    // MARK: - Consent

    /// Stacked rather than side by side. Two capsule buttons on one line at
    /// accessibility XXXL leave about forty points each for "Use the smaller
    /// plan", and the consent control is the last place in the app that should
    /// be shrinking its own label to fit.
    @ViewBuilder private var buttons: some View {
        let controls = Group {
            Button("Not now") { respond(accept: false) }
                .buttonStyle(.kairoSoft)
            Button("Use the smaller plan") { respond(accept: true) }
                .buttonStyle(.kairoProminent(Kairo.teal))
        }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { controls }
            VStack(spacing: 10) { controls }
        }
        .padding(.top, 2)
    }

    /// CF9 - recorded where the agents can see it, not only on the phone.
    private func respond(accept: Bool) {
        Task { await model.respondToContract(accept: accept) }
    }

    // MARK: - Copy

    private var headline: String {
        switch contract.kind {
        case .illness:  "Two signals say you may be unwell"
        case .travel:   "You have changed time zones"
        case .deadline: "Your calendar is unusually full"
        case .injury:   "You have not trained in a while"
        case .none:     "Something has changed"
        }
    }

    private var icon: String {
        switch contract.kind {
        case .illness:  "thermometer.medium"
        case .travel:   "airplane"
        case .deadline: "calendar.badge.exclamationmark"
        case .injury:   "bandage.fill"
        case .none:     "arrow.down.right.circle.fill"
        }
    }

    /// The substance of the original sentence, minus the two numbers that are
    /// now drawn instead of written.
    private var bodyCopy: String {
        "Kairo can run a smaller version of your plan for a few days: your daily "
        + "targets drop, and some reminders stop bidding for your attention altogether."
    }
}
