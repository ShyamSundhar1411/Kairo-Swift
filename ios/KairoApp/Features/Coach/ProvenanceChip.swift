import SwiftUI
import KairoKit

/// Which system produced the ledger on screen — the third question a user has,
/// and the one the app never answered.
///
/// Bound to `AppModel.arbitrationSource`, not to the last health check. Those
/// two disagree, and the gap between them is exactly the failure
/// `RemoteAgentClient`'s docstring is about: the backend answers `/health`, the
/// arbitration request times out, the app falls back to the on-device arbiter,
/// and a chip wired to the health check goes on saying "connected" over a ledger
/// no agent ever saw.
///
/// The rule, in one line: if the ledger came from the on-device arbiter, the
/// chip is not teal.
enum ArbitrationProvenance: Equatable {
    /// The five roles produced this, and the service cost is a real one.
    case agents
    /// The five roles produced this on a deployment where the money is a
    /// stand-in — a free local model walking the same degradation ladder.
    case agentsShadowCosted
    /// Nothing is configured. Not an error, and not drawn as one.
    case thisPhone
    /// Configured, nothing listening. Check the address.
    case unreachable
    /// The backend answered 503. It is up and it has said what is wrong.
    case refusing

    init(source: AppModel.Source, costing: SuppressionCopy.Costing,
         connection: BackendConnection.State) {
        switch source {
        case .agents:
            self = costing == .notional ? .agentsShadowCosted : .agents
        case .onDevice:
            // Deliberately reading the connection only on this branch. What it
            // adds here is *why* the local arbiter answered, which is the next
            // thing a user needs; what it must never do is override a ledger
            // that genuinely came from the phone.
            switch connection {
            case .refusing:                      self = .refusing
            case .unreachable:                   self = .unreachable
            case .onDevice, .checking, .connected: self = .thisPhone
            }
        }
    }

    var label: String {
        switch self {
        case .agents:             "5 agents"
        case .agentsShadowCosted: "5 agents · local"
        case .thisPhone:          "this phone"
        case .unreachable:        "agents unreachable"
        case .refusing:           "agents refusing"
        }
    }

    var tint: Color {
        switch self {
        case .agents, .agentsShadowCosted: Kairo.teal
        case .thisPhone:                   Kairo.inkSoft
        case .unreachable:                 Kairo.amber
        case .refusing:                    Kairo.coral
        }
    }

    var icon: String {
        switch self {
        case .agents, .agentsShadowCosted: "point.3.connected.trianglepath.dotted"
        case .thisPhone:                   "iphone"
        case .unreachable:                 "antenna.radiowaves.left.and.right.slash"
        case .refusing:                    "exclamationmark.octagon"
        }
    }

    /// What the user is told if they never open the sheet.
    var oneLine: String {
        switch self {
        case .agents:
            "Five roles reasoned about this pass."
        case .agentsShadowCosted:
            "Five roles reasoned about this pass, on a model that costs nothing to run."
        case .thisPhone:
            "No agent backend is configured, so the copy of the arbiter on this phone "
            + "decided. It works offline; nothing here was reasoned about."
        case .unreachable:
            "The agent backend is configured but is not answering, so this phone decided."
        case .refusing:
            "The agent backend is up and refusing every request. It has said why — open "
            + "the agents sheet."
        }
    }
}

/// The chip itself. Occupies the slot the old "Attention" chip had in the Today
/// header, and leads to the agents sheet rather than to the contract — the
/// contract is one tap from the dial, which is the thing it is about.
struct ProvenanceChip: View {
    let provenance: ArbitrationProvenance

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: provenance.icon)
                .font(.kairoGlyph(11))
            // Wraps rather than truncating. "agents unreachable" abbreviated
            // to "agents unre…" is the one state where the user most needs the
            // whole word.
            Text(provenance.label)
                .font(.kairoLabel).tracking(0.5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(provenance.tint)
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(Capsule().fill(provenance.tint.opacity(0.14)))
        .overlay(Capsule().strokeBorder(provenance.tint.opacity(0.28), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Decided by \(provenance.label). \(provenance.oneLine)")
        .accessibilityAddTraits(.isButton)
    }
}
