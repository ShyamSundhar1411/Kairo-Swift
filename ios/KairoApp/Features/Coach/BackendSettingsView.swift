import SwiftUI
import KairoKit

/// Where the agents live, and proof of whether they are answering.
///
/// This screen exists because the app is usable either way. Without it, a phone
/// that has quietly lost the backend looks exactly like one that never had it -
/// and the whole claim of the project is that five roles reasoned about your day,
/// so "did they actually?" has to be answerable.
///
/// It is also the only place in the app that may render a provider name, a model
/// id, or a figure of money. A user does not need to know they are talking to a
/// particular model to drink water, and hundredths of a cent on a feature screen
/// is a backend detail wearing a health app's clothes. One exception lives on
/// Meals: an unusable vision tier is a provider fact that predicts a failure the
/// user is about to walk into, so it is said before the camera opens.
struct BackendSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var isChecking = false
    /// Presenting the tour over the app rather than clearing
    /// `kairo.tour.completed` and flipping the root: closing it should return
    /// here, not drop the reader on Today.
    @State private var replayingTour = false
    @State private var discovery = BackendDiscovery()
    /// The same key `KairoApp` reads to pick its root, so clearing it here
    /// returns the whole app to the first-launch tour, not a sheet over it.
    @AppStorage("kairo.tour.completed") private var tourCompleted = true

    var body: some View {
        @Bindable var backend = model.backend

        Form {
            Section {
                StatusRow(state: backend.state)
                if case let .refusing(diagnosis) = backend.state {
                    // Verbatim, and given a row of its own. The backend is up
                    // and has written a sentence for a person to act on; this is
                    // the single highest-value thing the app can do with it.
                    Text(diagnosis)
                        .font(.footnote)
                        .foregroundStyle(Kairo.coral)
                        .textSelection(.enabled)
                }
                // A request that failed while the backend stayed up. Said here
                // rather than by marking the whole connection down.
                if backend.state.isConnected, let problem = backend.lastRequestProblem {
                    Text("Last request failed: \(problem)")
                        .font(.footnote)
                        .foregroundStyle(Kairo.amber)
                }
            } header: {
                Text("Status")
            } footer: {
                if case .refusing = backend.state {
                    Text("The server answered. It is refusing every request until the "
                         + "configuration above is fixed - which is a different problem "
                         + "from an address that does not resolve.")
                } else {
                    Text(backend.state.detail)
                }
            }

            demoSection
            provenanceSection
            if let provider = backend.provider { providerSection(provider) }
            if let budget = backend.budget { budgetSection(budget) }
            if let provider = backend.provider, !provider.considered.isEmpty {
                consideredSection(provider)
            }
            discoverySection(backend)
            addressSection(backend)
            wristSection
            if !backend.ports.isEmpty { portsSection(backend.ports) }
            tourSection
        }
        .navigationTitle("Agents")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - What produced the screen behind this one

    private var provenance: ArbitrationProvenance {
        ArbitrationProvenance(source: model.arbitrationSource,
                              costing: model.arbitrationCosting,
                              connection: model.backend.state)
    }

    /// Split into a body and a footer, and the footer into a stored string,
    /// because Swift 6.1.2 gave up type-checking this as one expression:
    /// "unable to type-check this expression in reasonable time". Swift 6.4
    /// solves it, which is why it compiled here and failed in CI.
    ///
    /// The expensive half is the footer. A chain of `+` over six string literals
    /// is six overload resolutions the solver has to carry through the whole
    /// `ViewBuilder` closure; a single multi-line literal is one token. The
    /// house style uses `+ "…"` in a dozen other views and they are fine - this
    /// one sat beside five conditional rows, which is what tipped it over.
    private var provenanceSection: some View {
        Section {
            provenanceRows
        } header: {
            Text("This pass")
        } footer: {
            Text(Self.provenanceFooter(provenance.oneLine))
        }
    }

    @ViewBuilder
    private var provenanceRows: some View {
        LabeledContent("Decided the ledger") {
            Text(provenance.label).foregroundStyle(provenance.tint)
        }
        // S7 - read off the sealed record, so this says which backend
        // answered *that* pass rather than which one happens to be bound now.
        if let provider = model.servingProvider {
            LabeledContent("Answered by") { Text(provider).foregroundStyle(.secondary) }
        }
        if let modelID = model.servingModelID {
            LabeledContent("Bidding model") {
                Text(modelID).foregroundStyle(.secondary)
            }
        }
        if !model.contributingRoles.isEmpty {
            LabeledContent("Roles that contributed") {
                Text("\(Set(model.contributingRoles).count) of \(AgentID.allCases.count)")
                    .monospacedDigit()
            }
        }
        if let last = model.backend.lastServedByBackend {
            LabeledContent("Last answered") {
                Text(last, style: .relative).foregroundStyle(.secondary)
            }
        }
    }

    private static func provenanceFooter(_ oneLine: String) -> String {
        """
        \(oneLine)

        The bidding model is the fast tier - the one the roles bid with. A \
        sentence written at the deep tier came from a different model on the \
        same provider.

        Either way the readings are this phone's. Sleep and movement come from \
        Health, water from the watch - and where nothing was measured, nothing \
        is claimed.
        """
    }

    // MARK: - Which model, and whether its ids exist

    private func providerSection(_ provider: RemoteAgentClient.Provider) -> some View {
        Section {
            LabeledContent("Provider") { Text(provider.displayName).foregroundStyle(.secondary) }
            if let answered = provider.answeredAtBind {
                LabeledContent("Answered at bind") {
                    Label(answered ? "yes" : "no",
                          systemImage: answered ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(answered ? Kairo.leaf : Kairo.coral)
                        .labelStyle(.titleAndIcon)
                }
            }
            ForEach(provider.models) { m in
                LabeledContent(m.tier) {
                    HStack(spacing: 6) {
                        Text(m.id).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        validation(m.validated)
                    }
                }
            }
            LabeledContent("Costing") {
                Text(provider.isShadowCosted ? "shadow" : "metered")
                    .foregroundStyle(provider.isShadowCosted ? Kairo.amber : .secondary)
            }
        } header: {
            Text("Which model answered")
        } footer: {
            Text(provider.selectedBecause.isEmpty
                 ? "Tiers served: \(provider.supportsTiers.joined(separator: ", "))."
                 : provider.selectedBecause
                   + "\n\nTiers served: \(provider.supportsTiers.joined(separator: ", "))."
                   + "\n\nA tick means the backend asked the vendor and the model id exists. "
                   + "A cross means it does not, and every request at that tier will fail. "
                   + "A dash means the vendor would not list its catalogue, which is a "
                   + "permissions fact, not a health one.")
        }
    }

    @ViewBuilder
    private func validation(_ validated: Bool?) -> some View {
        switch validated {
        case .some(true):  Image(systemName: "checkmark.seal.fill").foregroundStyle(Kairo.leaf)
        case .some(false): Image(systemName: "xmark.octagon.fill").foregroundStyle(Kairo.coral)
        case nil:          Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    // MARK: - Section 7.1, the second budget

    /// The only screen in the app that renders money, and it renders the
    /// backend's own sentence about that money verbatim beneath it. A figure in
    /// hundredths of a cent is meaningless without the note that says whether it
    /// is a bill or a stand-in, so the two are never separated.
    private func budgetSection(_ budget: RemoteAgentClient.Budget) -> some View {
        Section {
            LabeledContent("Service tier") {
                Text(budget.tier).foregroundStyle(.secondary)
            }
            LabeledContent("Spent this month") {
                HStack(spacing: 6) {
                    Text("\(budget.spentHundredthsOfACent) of "
                         + "\(budget.ceilingHundredthsOfACent)")
                        .monospacedDigit().foregroundStyle(.secondary)
                    if budget.isNotional {
                        Text("notional")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Kairo.amber)
                    }
                }
            }
        } header: {
            Text("Cost ladder")
        } footer: {
            // Verbatim. Not reformatted, not re-worded - the backend is the only
            // thing that knows what its own figures stand for.
            Text(budget.note)
        }
    }

    private func consideredSection(_ provider: RemoteAgentClient.Provider) -> some View {
        Section {
            ForEach(provider.considered) { skipped in
                VStack(alignment: .leading, spacing: 2) {
                    Text(skipped.displayName)
                    Text(skipped.reason)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Looked at and passed over")
        } footer: {
            Text("The order is fixed and written down, so a deployment never binds a "
                 + "different model than the last one did because two keys happened to "
                 + "be present.")
        }
    }

    // MARK: - Where it is

    /// Backends found on this network.
    ///
    /// A LAN address is the one setting that is both required on a real device
    /// and guaranteed to go stale - a reboot, a new lease, a different network.
    /// Typing it in is the work this section deletes.
    ///
    /// Only ever offers; `adopt(chosen:)` refuses to overwrite an address
    /// somebody entered, including when that address is currently wrong.
    @ViewBuilder private func discoverySection(_ backend: BackendConnection) -> some View {
        Section {
            if discovery.denied {
                Label("Local network access is off. Settings → Kairo → Local Network.",
                      systemImage: "wifi.exclamationmark")
                    .font(.kairoCaption)
                    .foregroundStyle(Kairo.amber)
            } else if discovery.found.isEmpty {
                HStack(spacing: 10) {
                    if discovery.searching { ProgressView() }
                    Text(discovery.searching
                         ? "Looking for a backend on this network…"
                         : "Not looking.")
                        .font(.kairoCaption)
                        .foregroundStyle(Kairo.inkSoft)
                }
            } else {
                ForEach(discovery.found) { found in
                    Button {
                        backend.adopt(found.url, chosen: true)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(found.name).font(.kairoHeadline)
                                Text(found.url)
                                    .font(.kairoCaption)
                                    .foregroundStyle(Kairo.inkSoft)
                            }
                            Spacer()
                            if backend.address == found.url {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Kairo.teal)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("On this network")
        } footer: {
            Text("Bonjour does not cross subnets or most VPNs. On those, type the "
                 + "address below - it is what `serve-lan.sh` prints.")
        }
        .task {
            discovery.start()
        }
        .onDisappear { discovery.stop() }
        .onChange(of: discovery.found) { _, now in
            // Exactly one, and nobody has ever chosen: take it. Two is a
            // question only the person can answer, and asking beats guessing.
            guard now.count == 1, let only = now.first else { return }
            backend.adopt(only.url, chosen: false)
        }
    }

    /// The wrist, permanently - not only during onboarding.
    ///
    /// Somebody who pairs a watch a week after installing needs somewhere to see
    /// that it worked, and "is it connected?" should have an answer that is not
    /// inferred from whether a glass of water showed up.
    ///
    /// There is deliberately no sign-in here. The watch never contacts the
    /// backend; it talks to this phone, and the pairing iOS established is what
    /// says whose wrist it is (AS-15, `docs/TRUST-BOUNDARIES.md`).
    private var wristSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: WristLinkCopy.icon(model.wristLink))
                    .font(.kairoGlyph(15, weight: .semibold))
                    .foregroundStyle(WristLinkCopy.tint(model.wristLink))
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(WristLinkCopy.headline(model.wristLink))
                        .font(.kairoHeadline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(WristLinkCopy.detail(model.wristLink))
                        .font(.kairoCaption)
                        .foregroundStyle(Kairo.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
        } header: {
            Text("Your watch")
        } footer: {
            Text("No second sign-in. The watch is yours because iOS paired it to "
                 + "this iPhone, and the same account covers both.")
        }
        .task { model.observeWristLink() }
    }

    /// Demo mode, for presenting from a phone with no Health history.
    ///
    /// The toggle swaps the readings, not the agents: with it on, the next pass
    /// sends the demo day to the same backend and the same five roles, and the
    /// backend's `/live` page draws it like any other request.
    private var demoSection: some View {
        Section {
            Toggle(isOn: Binding(get: { model.demoMode },
                                 set: { on in Task { await model.setDemoMode(on) } })) {
                Label("Demo day", systemImage: "theatermasks")
            }
            if model.demoMode {
                Toggle(isOn: Binding(get: { model.phoneStreamOn },
                                     set: { on in Task { @MainActor in model.setPhoneStream(on) } })) {
                    Label("Simulated wrist on this phone", systemImage: "waveform.path.ecg")
                }
                Toggle(isOn: Binding(get: { model.useRecordedHealth },
                                     set: { on in Task { await model.setUseRecordedHealth(on) } })) {
                    Label("Prefer recorded Health", systemImage: "heart.text.square")
                }
                if KairoHealthSeeding.isAvailable {
                    Button {
                        Task { await model.seedSimulatorHealth() }
                    } label: {
                        Label("Seed this simulator's Health (a week)", systemImage: "tray.and.arrow.down")
                    }
                    Button(role: .destructive) {
                        Task { await model.removeSeededHealth() }
                    } label: {
                        Label("Remove seeded Health", systemImage: "trash")
                    }
                    if let report = model.seedReport {
                        Text(report)
                            .font(.caption2.monospaced())
                            .foregroundStyle(Kairo.inkSoft)
                            .textSelection(.enabled)
                    }
                }
                Text(Self.blendNote)
                    .font(.footnote)
                    .foregroundStyle(Kairo.inkSoft)
            }
            Button {
                tourCompleted = false
            } label: {
                Label("Start the demo from the welcome tour", systemImage: "play.rectangle")
            }
            Button {
                Task { await model.runArbitration() }
            } label: {
                Label("Ask the agents again now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(model.backend.client == nil)
            Button {
                Task { await model.teach(DemoScenario.aboutMe) }
            } label: {
                HStack {
                    Label("Tell Kairo about the demo user", systemImage: "text.bubble")
                    if model.teaching { Spacer(); ProgressView() }
                }
            }
            .disabled(model.backend.client == nil || model.teaching)
            if let said = model.lastExtraction {
                Text(said)
                    .font(.footnote)
                    .foregroundStyle(Kairo.inkSoft)
            }
        } header: {
            Text("Presenting")
        } footer: {
            Text(Self.demoFooter)
        }
    }

    /// How the three sources combine, in one literal for the type-checker.
    private static let blendNote = """
        Sleep and the week come from recorded Health when it has them (seed it \
        above in the simulator), otherwise from the scenario. Sitting, heart rate \
        and steps come from the watch's Demo page while it streams; the phone's \
        simulated wrist fills in when the watch is quiet, and holds still while it \
        talks. A pass is asked for only when something meaningful changes, at \
        most every 20 seconds.
        """

    /// One literal, for the type-checker reason on `provenanceSection`.
    private static let demoFooter = """
        Demo day replaces your Health readings with a scenario: 5.6 h sleep, 82 \
        minutes sitting, 800 ml of water and two meals. Nothing is written to \
        Health, and turning it off removes all of it. The agents, their prompts \
        and the safety screen are not simulated. "Tell Kairo" sends a short \
        paragraph to the memory curator, which decides what to remember.
        """

    /// The explanation, available again.
    ///
    /// It used to be reachable exactly once, on the first launch of a fresh
    /// install, and `kairo.tour.completed` had no writer that could clear it.
    /// Anybody who tapped Skip lost the only description of what the five roles
    /// are for.
    private var tourSection: some View {
        Section {
            Button {
                replayingTour = true
            } label: {
                Label("Show the welcome tour again", systemImage: "sparkles")
            }
        } footer: {
            Text("What the attention budget is, who the five roles are, and how "
                 + "to set the daily ceiling.")
        }
        .fullScreenCover(isPresented: $replayingTour) {
            // Presented over the app rather than by flipping the root, so
            // closing it returns here instead of dropping the reader on Today.
            WelcomeTour(app: model)
        }
    }

    private func addressSection(_ backend: BackendConnection) -> some View {
        @Bindable var backend = backend
        return Section {
            TextField("http://192.168.1.10:9080", text: $backend.address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                // Typing here is a choice, and a choice outranks anything
                // discovery finds from then on.
                .onSubmit { backend.addressWasEditedByHand() }
            // NFR6. The objection is shown here rather than left to surface as
            // a failed request: ATS refuses cleartext to a remote host with an
            // opaque URLError, which this screen would otherwise report as
            // "the backend did not answer" - sending somebody to debug a server
            // that is fine.
            if let objection = backend.addressObjection {
                Label(objection, systemImage: "lock.trianglebadge.exclamationmark.fill")
                    .font(.kairoCaption)
                    .foregroundStyle(Kairo.coral)
                    .labelStyle(.titleAndIcon)
            }
            SecureField("Bearer token (optional)", text: $backend.token)
            Button {
                Task {
                    isChecking = true
                    await model.backend.check(userID: model.userID)
                    if model.backend.state.isConnected {
                        await model.reloadContract()
                        await model.runArbitration()
                    }
                    isChecking = false
                }
            } label: {
                HStack {
                    Text("Connect")
                    if isChecking { Spacer(); ProgressView() }
                }
            }
            .disabled(isChecking)
        } header: {
            Text("Agent backend")
        } footer: {
            Text(Self.addressFooter)
        }
    }

    /// Stored rather than built inline, for the reason on `provenanceSection`:
    /// I grew this from three `+` terms to six in the same commit that put the
    /// keychain note here, and six is where the solver starts struggling.
    private static let addressFooter = """
        The address of the machine running `python -m kairo`. Leave it empty to \
        stay on the device. On a phone this must be the Mac's address on your \
        network, not localhost - localhost on a phone is the phone.

        Anything that is not on this machine must be https. The token is kept in \
        the keychain, not in preferences, and does not travel in a device backup.
        """

    // MARK: - Figure 14

    /// Architecture facts, at the bottom, where somebody looking for them will
    /// find them and nobody else will meet them.
    private func portsSection(_ ports: [RemoteAgentClient.Port]) -> some View {
        Section {
            ForEach(ports) { port in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(port.key).font(.kairoMono)
                        Spacer()
                        Text(port.adapter).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Text("\(port.interface) · \(port.direction)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Ports")
        } footer: {
            Text("What each seam in the architecture is bound to on the server. "
                 + "`pHealth` reads only what this phone chose to send.")
        }
    }
}

private struct StatusRow: View {
    let state: BackendConnection.State

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(tint).frame(width: 10, height: 10)
            Text(state.label)
            Spacer()
            if case .checking = state { ProgressView() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(state.label)
    }

    private var tint: Color {
        switch state {
        case .onDevice:    .secondary
        case .checking:    .orange
        case .connected:   Kairo.leaf
        case .unreachable: Kairo.amber
        // Up, and saying no. A different colour from unreachable because it is a
        // different instruction to the reader.
        case .refusing:    Kairo.coral
        // Up, correctly configured, and does not know you. Amber rather than
        // coral: nothing is broken, something is missing - and the field that
        // fixes it is on this very screen.
        case .unauthenticated: Kairo.amber
        }
    }
}
