import SwiftUI
import KairoKit

/// Where the agents live, and proof of whether they are answering.
///
/// This screen exists because the app is usable either way. Without it, a phone
/// that has quietly lost the backend looks exactly like one that never had it —
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
            } header: {
                Text("Status")
            } footer: {
                if case .refusing = backend.state {
                    Text("The server answered. It is refusing every request until the "
                         + "configuration above is fixed — which is a different problem "
                         + "from an address that does not resolve.")
                } else {
                    Text(backend.state.detail)
                }
            }

            provenanceSection
            if let provider = backend.provider { providerSection(provider) }
            if let budget = backend.budget { budgetSection(budget) }
            if let provider = backend.provider, !provider.considered.isEmpty {
                consideredSection(provider)
            }
            addressSection(backend)
            if !backend.ports.isEmpty { portsSection(backend.ports) }
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
    /// house style uses `+ "…"` in a dozen other views and they are fine — this
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
        // S7 — read off the sealed record, so this says which backend
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

        The bidding model is the fast tier — the one the roles bid with. A \
        sentence written at the deep tier came from a different model on the \
        same provider.

        Either way the readings are this phone's. Sleep and movement come from \
        Health, water from the watch — and where nothing was measured, nothing \
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
            // Verbatim. Not reformatted, not re-worded — the backend is the only
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

    private func addressSection(_ backend: BackendConnection) -> some View {
        @Bindable var backend = backend
        return Section {
            TextField("http://192.168.1.10:8080", text: $backend.address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            // NFR6. The objection is shown here rather than left to surface as
            // a failed request: ATS refuses cleartext to a remote host with an
            // opaque URLError, which this screen would otherwise report as
            // "the backend did not answer" — sending somebody to debug a server
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
        network, not localhost — localhost on a phone is the phone.

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
        // coral: nothing is broken, something is missing — and the field that
        // fixes it is on this very screen.
        case .unauthenticated: Kairo.amber
        }
    }
}
