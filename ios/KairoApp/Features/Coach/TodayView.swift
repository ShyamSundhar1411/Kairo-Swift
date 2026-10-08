import SwiftUI
import KairoKit

/// Member C — CF7. The attention ledger.
///
/// One question: what did Kairo decide about your attention, and who lost.
/// Everything on this screen answers it, and the things that did not — three
/// stat tiles restating their own neighbours, a movement card that belongs on
/// Body, four unrelated score gauges — are gone rather than rearranged.
///
/// Six sections, at most, in any state:
///   1. the header, with the provenance chip
///   2. the dial → the attention contract
///   3. the roster and the ledger, as one card
///   4. water, compact
///   5. the contract proposal, when the agents are holding one
///   6. the trust note
struct TodayView: View {
    @Environment(AppModel.self) private var model
    /// The two hero cards put a fixed-width graphic beside a block of prose. At
    /// an accessibility size the prose needs the whole 375 points, so the
    /// graphic goes above it rather than squeezing it into a column.
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Kairo.Space.stack) {
                    header
                    dial
                    BidLedgerCard(delivered: model.arbitration?.delivered ?? [],
                                  suppressed: model.arbitration?.suppressed ?? [],
                                  costing: model.arbitrationCosting,
                                  record: model.arbitration?.record)
                    waterStrip

                    if let c = model.contract, c.state == .proposed {
                        ContractProposalCard(contract: c)
                    }

                    TrustNote(text: "Every bid that lost is listed above, with why. "
                              + "Nothing here was hidden from you, and a suppression made to "
                              + "save money is labelled as one.")
                }
                .padding(.horizontal, Kairo.Space.stack)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .background(KairoCanvas())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: - Header

    private var provenance: ArbitrationProvenance {
        ArbitrationProvenance(source: model.arbitrationSource,
                              costing: model.arbitrationCosting,
                              connection: model.backend.state)
    }

    private var header: some View {
        KairoHeader(eyebrow: dateLine, title: greeting) {
            NavigationLink { BackendSettingsView() } label: {
                ProvenanceChip(provenance: provenance)
            }
            .buttonStyle(.kairoPress)
        }
        .padding(.horizontal, 4)
    }

    private var dateLine: String {
        model.env.clock.now.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// The user's own morning, not Sydney's.
    ///
    /// This read `TimeZone(identifier: "Australia/Sydney")`, which is where the
    /// project was written. A user in Europe opened the app at breakfast and was
    /// greeted with "Good evening" — the one line on the screen that claims to
    /// know something about the person holding the phone, and it was about
    /// somebody else's afternoon.
    private var greeting: String {
        switch Calendar.current.component(.hour, from: model.env.clock.now) {
        case 0..<12:  "Good morning"
        case 12..<17: "Good afternoon"
        default:      "Good evening"
        }
    }

    // MARK: - The dial
    //
    // Tappable, and the only way into the attention contract. The ring is
    // `SegmentedRing` from the brand mark with the day's real numbers in it —
    // the logo *is* the data — so it earns the hero slot.

    private var dial: some View {
        NavigationLink { AttentionReceiptView() } label: {
            AdaptiveHeroRow(stacked: typeSize.isAccessibilitySize,
                            spacing: Kairo.Space.gutter) {
                AttentionDial(spent: model.schedule.spent, total: model.schedule.dailyBudget)
            } detail: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ATTENTION BUDGET")
                        .font(.kairoLabel).tracking(1.1)
                        .foregroundStyle(Kairo.inkFaint)
                    Text("\(model.schedule.spent) of \(model.schedule.dailyBudget) spent")
                        .font(.kairoHeadline)
                        .foregroundStyle(Kairo.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Interruptions, not notifications. Tap to change the ceiling.")
                        .font(.kairoCaption)
                        .foregroundStyle(Kairo.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)

                    if let c = model.contract, c.state == .active {
                        Pill(text: "plan contract active", icon: "checkmark.seal.fill",
                             tint: Kairo.teal)
                            .padding(.top, 2)
                    }
                }
            } trailing: {
                Image(systemName: "chevron.right")
                    .font(.kairoGlyph(11))
                    .foregroundStyle(Kairo.inkFaint)
            }
            .kairoCard()
        }
        .buttonStyle(.kairoPress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(model.schedule.spent) of \(model.schedule.dailyBudget) "
                            + "interruptions spent today")
        .accessibilityHint("Opens your attention contract")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Water

    /// CF8, compact. The number the user came looking for, and one pill rather
    /// than three: the watch-link state and the coverage counts both belong to
    /// the reading, not to the headline, and at 375pt three pills in a row had
    /// nowhere to go.
    private var waterStrip: some View {
        let log = model.hydration
        let logged = !log.sips.isEmpty
        let tint = Kairo.colour(for: .hydration)

        return AdaptiveHeroRow(stacked: typeSize.isAccessibilitySize,
                               spacing: Kairo.Space.gutter) {
            MetricRing(progress: logged ? log.fractionOfTarget : 0,
                       tint: logged ? tint : Kairo.inkFaint,
                       icon: Kairo.icon(for: .hydration),
                       centreText: logged ? "\(Int(log.fractionOfTarget * 100))%" : nil,
                       size: 62)
        } detail: {
            VStack(alignment: .leading, spacing: 5) {
                Text("WATER")
                    .font(.kairoLabel).tracking(1.1)
                    .foregroundStyle(Kairo.inkFaint)

                if logged {
                    Text("\(log.totalMillilitres) of \(log.targetMillilitres) ml")
                        .font(.kairoHeadline)
                        .foregroundStyle(Kairo.ink)
                        .contentTransition(.numericText())
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Not measured is not zero. Drawing an untouched day as
                    // "0 ml" would present an absence of data as an achievement,
                    // which is the same claim the coverage gate would refuse in a
                    // sentence — so the card does not make it either.
                    Text("Nothing logged yet")
                        .font(.kairoHeadline)
                        .foregroundStyle(Kairo.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }

                PillWrap {
                    Pill(text: waterPill.text, icon: waterPill.icon, tint: waterPill.tint)
                }
                .padding(.top, 1)
            }
        }
        .kairoCard(tint: logged ? tint : Kairo.inkFaint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(logged
            ? "\(log.totalMillilitres) of \(log.targetMillilitres) millilitres of water, "
              + "logged \(log.sips.count) times"
            : "No water logged yet today. \(emptyWaterHint)")
    }

    /// One pill, and it says the most useful thing available: how far there is
    /// to go once something has been logged, and where the number is supposed to
    /// come from before anything has.
    private var waterPill: (text: String, icon: String, tint: Color) {
        let log = model.hydration
        guard !log.sips.isEmpty else {
            return (model.wristAvailable && model.wristLinked ? "tap water on your watch"
                                                              : "nothing from the wrist yet",
                    model.wristLinked ? "applewatch.radiowaves.left.and.right" : "applewatch.slash",
                    Kairo.inkFaint)
        }
        if log.remainingMillilitres == 0 {
            return ("target reached — no more water nudges today",
                    "checkmark.seal.fill", Kairo.leaf)
        }
        return ("\(log.remainingMillilitres) ml to go", "drop.fill",
                Kairo.colour(for: .hydration))
    }

    /// Says where the number is supposed to come from, and — when there is no
    /// session at all — says that too rather than blaming the user for not
    /// tapping. VoiceOver only; the pill carries the short form.
    private var emptyWaterHint: String {
        guard model.wristAvailable else {
            return "This build has no watch link, so nothing can arrive from the wrist."
        }
        return model.wristLinked
            ? "Tap water on your watch and it lands here."
            : "Tap water on your watch; it arrives when the two are back in range."
    }
}

/// The state the app is in most of the time, given its own name and its own card
/// rather than an empty list.
///
/// When nothing won this takes the headline position inside the ledger card and
/// the losing bids sit underneath it unchanged — silence with four visible
/// losers underneath is a far stronger statement than silence alone.
struct SilenceCard: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "moon.zzz.fill")
                .font(.kairoGlyph(20, weight: .semibold))
                .foregroundStyle(Kairo.teal)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Kairo.teal.opacity(0.14)))
            VStack(alignment: .leading, spacing: 3) {
                Text("Nothing worth interrupting you for")
                    .font(.kairoHeadline).foregroundStyle(Kairo.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Kairo spent none of today's budget on this pass.")
                    .font(.kairoCaption).foregroundStyle(Kairo.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: Kairo.Radius.inner, style: .continuous)
                .fill(Kairo.teal.opacity(0.10))
        }
        .accessibilityElement(children: .combine)
    }
}
