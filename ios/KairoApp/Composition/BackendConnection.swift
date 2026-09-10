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

        var isConnected: Bool { if case .connected = self { true } else { false } }

        var label: String {
            switch self {
            case .onDevice:      "On-device only"
            case .checking:      "Checking…"
            case .connected:     "Agents connected"
            case .unreachable:   "Backend unreachable"
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
            }
        }
    }

    private static let key = "kairo.backend.baseURL"
    private static let tokenKey = "kairo.backend.token"

    private(set) var state: State = .onDevice
    /// The last time the backend answered an arbitration, so the UI can say
    /// where what it is showing actually came from.
    private(set) var lastServedByBackend: Date?

    var address: String {
        didSet { UserDefaults.standard.set(address, forKey: Self.key) }
    }
    var token: String {
        didSet { UserDefaults.standard.set(token, forKey: Self.tokenKey) }
    }

    init(address: String? = nil) {
        let stored = UserDefaults.standard.string(forKey: Self.key)
        self.address = address ?? stored ?? ""
        self.token = UserDefaults.standard.string(forKey: Self.tokenKey) ?? ""
    }

    /// nil when nothing is configured, which is the on-device path.
    var client: RemoteAgentClient? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.host != nil else { return nil }
        return RemoteAgentClient(baseURL: url,
                                 token: token.isEmpty ? nil : token)
    }

    @MainActor
    func check() async {
        guard let client else {
            state = .onDevice
            return
        }
        state = .checking
        do {
            let health = try await client.health()
            state = .connected(mode: health.mode, promptVersion: health.promptVersion,
                               roles: health.roles.count)
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
