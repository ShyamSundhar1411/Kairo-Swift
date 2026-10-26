import Foundation
import Observation
import KairoKit

/// Where the agent backend is, and whether it is actually answering.
///
/// The address is per-device and changes constantly during development — the Mac
/// running the backend gets a new DHCP lease, the phone moves to a different
/// network — so it is a runtime setting rather than a build constant.
@Observable
final class BackendConnection {
    enum State: Equatable {
        /// No backend configured. Everything runs on the device.
        case onDevice
        case checking
        /// Reachable. Arbitration, meal analysis and explanations come from the
        /// five roles rather than from the on-device fallback.
        case connected(mode: String, promptVersion: String, roles: Int)
        /// Configured but not answering. The app keeps working on the device —
        /// this state exists so that fact is visible rather than silent.
        case unreachable(String)
        /// The backend answered **503**. It is up, it is reachable, and it has
        /// said in English what is misconfigured.
        ///
        /// This was folded into `unreachable`, and the two are opposite
        /// instructions to the person holding the phone: *unreachable* means
        /// check the address, *refusing* means read the sentence the server
        /// sent. Printing that sentence is the single highest-value thing this
        /// app can do with the backend's provider contract, and it was being
        /// thrown away one layer below here.
        case refusing(diagnosis: String)

        var isConnected: Bool { if case .connected = self { true } else { false } }

        var label: String {
            switch self {
            case .onDevice:      "On-device only"
            case .checking:      "Checking…"
            case .connected:     "Agents connected"
            case .unreachable:   "Backend unreachable"
            case .refusing:      "Agents refusing"
            }
        }

        var detail: String {
            switch self {
            case .onDevice:
                "Kairo is allocating attention with the copy of the arbiter that runs on "
                + "this phone. It works offline, but nothing is being reasoned about by "
                + "the five agent roles."
            case .checking:
                "Asking the backend who it is."
            case let .connected(mode, version, roles):
                "\(roles) roles, prompts \(version), \(mode)."
            case let .unreachable(why):
                "\(why) Falling back to the on-device arbiter, so the app keeps working — "
                + "but what you see is not coming from the agents."
            case let .refusing(diagnosis):
                // Verbatim. The backend wrote this sentence for a person to
                // read, and reformatting it is how a precise instruction turns
                // into a vague one.
                diagnosis
            }
        }
    }

    private static let key = "kairo.backend.baseURL"
    /// NFR6. A keychain account now, not a `UserDefaults` key. The old value is
    /// migrated once on first launch and then removed from the plist — leaving
    /// it there would mean the credential was in two places, one of them the
    /// place this change exists to get it out of.
    private static let tokenAccount = "backend.token"
    private static let legacyTokenKey = "kairo.backend.token"

    private(set) var state: State = .onDevice
    /// The last time the backend answered an arbitration, so the UI can say
    /// where what it is showing actually came from.
    private(set) var lastServedByBackend: Date?

    /// What the last successful `/health` said about the model behind the
    /// service. Held so the agents sheet can show provider, model ids and the
    /// vendors that were passed over without a second request — and so the meal
    /// screen can warn about an unusable vision tier before the camera opens.
    private(set) var provider: RemoteAgentClient.Provider?
    /// Figure 14's ports, as bound on the server.
    private(set) var ports: [RemoteAgentClient.Port] = []
    /// Section 7.1's ladder, in the backend's own words. Fetched beside the
    /// health check because it is the only place the money may be rendered.
    private(set) var budget: RemoteAgentClient.Budget?

    var address: String {
        didSet { UserDefaults.standard.set(address, forKey: Self.key) }
    }
    var token: String {
        didSet { KeychainStore.set(token, for: Self.tokenAccount) }
    }

    /// Where a backend is, before anyone has told us otherwise.
    ///
    /// In the simulator this IS the Mac's loopback, so a developer who has the
    /// backend running gets the five agent roles on first launch with nothing
    /// typed. Demanding an address up front made the default experience the
    /// on-device fallback — the weakest version of the product — and left the
    /// person to discover a settings screen before they ever saw an agent.
    ///
    /// On a real device loopback is the phone itself and nothing answers; that
    /// resolves to `.unreachable` with the reason on screen, which is the state
    /// this class already exists to make visible. A wrong guess that announces
    /// itself beats a blank field that explains nothing.
    static let defaultAddress = "http://127.0.0.1:8080"

    init(address: String? = nil) {
        let stored = UserDefaults.standard.string(forKey: Self.key)
        // `stored` is honoured even when empty: clearing the field is a
        // deliberate "run on-device", and re-defaulting over it would make the
        // setting impossible to turn off.
        self.address = address ?? stored ?? Self.defaultAddress
        self.token = Self.loadToken()
    }

    /// Keychain first, then the old plist key once.
    ///
    /// `didSet` does not fire from an initialiser, so the migration writes
    /// through `KeychainStore` directly — and deletes the plist copy in the same
    /// breath, because a credential that exists in both places has only been
    /// copied, not moved.
    private static func loadToken() -> String {
        if let secure = KeychainStore.string(for: tokenAccount) { return secure }
        guard let legacy = UserDefaults.standard.string(forKey: legacyTokenKey),
              !legacy.isEmpty else { return "" }
        KeychainStore.set(legacy, for: tokenAccount)
        UserDefaults.standard.removeObject(forKey: legacyTokenKey)
        return legacy
    }

    /// nil when nothing is configured, which is the on-device path.
    var client: RemoteAgentClient? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.host != nil,
              Self.transportIsAcceptable(url) else { return nil }
        return RemoteAgentClient(baseURL: url,
                                 token: token.isEmpty ? nil : token)
    }

    /// NFR6, the in-transit half (SCRUM-24). The rule itself lives in
    /// `KairoKit.TransportPolicy`, where it has tests — the app target has no
    /// unit test bundle, and a decision about whether health summaries may
    /// leave the phone in cleartext should not be untested code behind a guard.
    static func transportIsAcceptable(_ url: URL) -> Bool {
        TransportPolicy.isAcceptable(url)
    }

    /// Why the address field is refusing, in a sentence meant for the person
    /// typing it. `nil` when there is nothing wrong with it.
    var addressObjection: String? { TransportPolicy.objection(to: address) }

    @MainActor
    func check(userID: String) async {
        guard let client else {
            state = .onDevice
            provider = nil
            ports = []
            budget = nil
            return
        }
        state = .checking
        do {
            let health = try await client.health()
            provider = health.provider
            ports = health.ports
            state = .connected(mode: health.mode, promptVersion: health.promptVersion,
                               roles: health.roles.count)
            // Best effort, and only once the service is known to be answering:
            // a budget that cannot be read is a missing row on one settings
            // screen, not a reason to report the backend as down.
            budget = try? await client.budget(userID: userID)
        } catch let refusal as RemoteAgentClient.Refusal {
            provider = refusal.provider
            ports = []
            budget = nil
            state = .refusing(diagnosis: refusal.diagnosis)
        } catch {
            state = .unreachable(shortReason(error))
        }
    }

    @MainActor
    func noteServed() {
        lastServedByBackend = Date()
    }

    @MainActor
    func noteFailure(_ error: Error) {
        if let refusal = error as? RemoteAgentClient.Refusal {
            if let p = refusal.provider { provider = p }
            state = .refusing(diagnosis: refusal.diagnosis)
            return
        }
        state = .unreachable(shortReason(error))
    }

    private func shortReason(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost: return "Nothing is listening there."
            case .timedOut:                             return "The backend did not answer in time."
            case .notConnectedToInternet:               return "This device is offline."
            default:                                    return urlError.localizedDescription
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
