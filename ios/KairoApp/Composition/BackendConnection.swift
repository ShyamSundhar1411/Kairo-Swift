import Foundation
import Observation
import KairoKit

/// Where the agent backend is, and whether it is actually answering.
///
/// The address is per-device and changes constantly during development - the Mac
/// running the backend gets a new DHCP lease, the phone moves to a different
/// network - so it is a runtime setting rather than a build constant.
@Observable
final class BackendConnection {
    enum State: Equatable {
        /// No backend configured. Everything runs on the device.
        case onDevice
        case checking
        /// Reachable. Arbitration, meal analysis and explanations come from the
        /// five roles rather than from the on-device fallback.
        case connected(mode: String, promptVersion: String, roles: Int)
        /// Configured but not answering. The app keeps working on the device -
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
        /// The backend answered **401**. It is up, it is reachable, it is not
        /// misconfigured - it does not know who you are.
        ///
        /// Split out for exactly the reason `refusing` was split out of
        /// `unreachable`: these are three different instructions to the person
        /// holding the phone. *Unreachable* means check the address, *refusing*
        /// means read the sentence the server wrote, and this one means paste a
        /// token. Folding it into either of the others sends somebody to debug
        /// a network or a config that is already correct.
        ///
        /// Reachable at all because `/health` is exempt from the guard, so
        /// discovery succeeds and the first real request is where the token is
        /// missed.
        case unauthenticated

        var isConnected: Bool { if case .connected = self { true } else { false } }

        var label: String {
            switch self {
            case .onDevice:      "On-device only"
            case .checking:      "Checking…"
            case .connected:     "Agents connected"
            case .unreachable:   "Backend unreachable"
            case .refusing:      "Agents refusing"
            case .unauthenticated: "Backend needs a token"
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
                "\(why) Falling back to the on-device arbiter, so the app keeps working - "
                + "but what you see is not coming from the agents."
            case let .refusing(diagnosis):
                // Verbatim. The backend wrote this sentence for a person to
                // read, and reformatting it is how a precise instruction turns
                // into a vague one.
                diagnosis
            case .unauthenticated:
                "This backend is up and will not answer without a token. Paste the one "
                + "it printed when it started - `serve-lan.sh` shows it - into the field "
                + "above. Until then the on-device arbiter is deciding."
            }
        }
    }

    private static let key = "kairo.backend.baseURL"
    /// NFR6. A keychain account now, not a `UserDefaults` key. The old value is
    /// migrated once on first launch and then removed from the plist - leaving
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
    /// vendors that were passed over without a second request - and so the meal
    /// screen can warn about an unusable vision tier before the camera opens.
    private(set) var provider: RemoteAgentClient.Provider?
    /// Figure 14's ports, as bound on the server.
    private(set) var ports: [RemoteAgentClient.Port] = []
    /// Section 7.1's ladder, in the backend's own words. Fetched beside the
    /// health check because it is the only place the money may be rendered.
    private(set) var budget: RemoteAgentClient.Budget?

    /// Edits re-check on their own. Pressing a button to apply an address you
    /// have just finished typing is work the app can do for you, and the state
    /// it leaves behind otherwise - a new address with the old verdict still on
    /// screen - is actively misleading.
    var address: String {
        didSet {
            UserDefaults.standard.set(address, forKey: Self.key)
            guard address != oldValue else { return }
            scheduleRecheck()
        }
    }
    var token: String {
        didSet {
            KeychainStore.set(token, for: Self.tokenAccount)
            guard token != oldValue else { return }
            scheduleRecheck()
        }
    }

    /// Where a backend is, before anyone has told us otherwise.
    ///
    /// In the simulator this IS the Mac's loopback, so a developer who has the
    /// backend running gets the five agent roles on first launch with nothing
    /// typed. Demanding an address up front made the default experience the
    /// on-device fallback - the weakest version of the product - and left the
    /// person to discover a settings screen before they ever saw an agent.
    ///
    /// On a real device loopback is the phone itself and nothing answers; that
    /// resolves to `.unreachable` with the reason on screen, which is the state
    /// this class already exists to make visible. A wrong guess that announces
    /// itself beats a blank field that explains nothing.
    ///
    /// Which is still a poor first run on a phone, so the build can supply a
    /// better guess: set `KAIRO_BACKEND_URL` in `signing.env`, and
    /// `generate.sh` bakes it into Info.plist as `KairoDefaultBackendURL`. It
    /// is machine-specific and changes with the network, which is exactly why
    /// it belongs in a build setting rather than committed in this file.
    ///
    /// A stored address always wins - see `init`. This is only ever the value
    /// nobody has overridden yet.
    static let defaultAddress: String = {
        let configured = Bundle.main.object(forInfoDictionaryKey: "KairoDefaultBackendURL")
        guard let text = (configured as? String)?.trimmingCharacters(in: .whitespaces),
              !text.isEmpty else {
            return "http://127.0.0.1:9080"
        }
        return text
    }()

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
    /// through `KeychainStore` directly - and deletes the plist copy in the same
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
    ///
    /// 120 seconds per request. An arbitration is five model calls, and on a
    /// local model that can run well past the old 45 - at which point the app
    /// reported a backend that was busy working as unreachable.
    var client: RemoteAgentClient? { makeClient(timeout: 120) }

    /// `/health` answers instantly or not at all, so the check that decides
    /// whether the backend is *there* gets a short leash of its own.
    private var healthClient: RemoteAgentClient? { makeClient(timeout: 8) }

    private func makeClient(timeout: TimeInterval) -> RemoteAgentClient? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.host != nil,
              Self.transportIsAcceptable(url) else { return nil }
        return RemoteAgentClient(baseURL: url,
                                 token: token.isEmpty ? nil : token,
                                 timeout: timeout)
    }

    /// The last request that failed while the backend itself was fine - a
    /// slow model, a route-level error. Shown on the Agents screen, and kept
    /// apart from `state` on purpose: see `noteFailure`.
    private(set) var lastRequestProblem: String?

    private var retryTask: Task<Void, Never>?

    /// Keep trying while not connected, so a backend started after the app -
    /// or one that blipped - comes back without anybody pressing Connect.
    /// Ten seconds apart, and silent while connected.
    @MainActor
    func startAutoRetry() {
        guard retryTask == nil else { return }
        retryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled else { return }
                switch self.state {
                case .unreachable, .refusing:
                    if let whoami = self.userIDForRecheck { await self.check(userID: whoami()) }
                default:
                    break
                }
            }
        }
    }

    /// NFR6, the in-transit half (SCRUM-24). The rule itself lives in
    /// `KairoKit.TransportPolicy`, where it has tests - the app target has no
    /// unit test bundle, and a decision about whether health summaries may
    /// leave the phone in cleartext should not be untested code behind a guard.
    static func transportIsAcceptable(_ url: URL) -> Bool {
        TransportPolicy.isAcceptable(url)
    }

    /// Why the address field is refusing, in a sentence meant for the person
    /// typing it. `nil` when there is nothing wrong with it.
    var addressObjection: String? { TransportPolicy.objection(to: address) }

    @MainActor
    /// Who to re-check as, set once by the composition root. Held here so the
    /// connection can retry without a caller present to pass it.
    var userIDForRecheck: (() -> String)?

    private var recheckTask: Task<Void, Never>?

    /// Debounced, because `address` changes on every keystroke and a request
    /// per character would be both useless and rude to whatever is listening.
    private func scheduleRecheck(after seconds: Double = 0.8, quiet: Bool = false) {
        recheckTask?.cancel()
        // Read on the main actor, inside the task: `didSet` runs wherever the
        // write did, and reaching for an isolated property from there is the
        // compile error this shape avoids.
        recheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, let whoami = self.userIDForRecheck else { return }
            await self.check(userID: whoami(), quiet: quiet)
        }
    }

    /// Whether anybody has chosen an address, as opposed to inheriting one.
    ///
    /// Discovery may fill an untouched field; it must never overwrite a typed
    /// one. Somebody who entered an address meant it, including when it is
    /// currently wrong.
    private(set) var addressWasChosen = UserDefaults.standard.bool(
        forKey: "kairo.backend.addressChosen")

    /// Take a discovered backend.
    ///
    /// `chosen` is false when this is the app adopting the only thing on the
    /// network by itself, and true when a person tapped it in a list.
    @MainActor
    func adopt(_ url: String, chosen: Bool) {
        guard chosen || !addressWasChosen else { return }
        if chosen {
            addressWasChosen = true
            UserDefaults.standard.set(true, forKey: "kairo.backend.addressChosen")
        }
        guard url != address else { return }
        address = url          // the didSet re-checks on its own
    }

    /// Record that the address on screen was typed rather than inherited.
    @MainActor
    func addressWasEditedByHand() {
        addressWasChosen = true
        UserDefaults.standard.set(true, forKey: "kairo.backend.addressChosen")
    }

    /// Try again now, if there is anything to try.
    ///
    /// Called when the app comes back to the foreground, which is the moment
    /// that matters: the usual way to see "backend unreachable" is to launch
    /// before starting the server, and the usual fix is to start it - after
    /// which the app had no reason to look again and sat on a stale verdict
    /// until somebody found this screen.
    @MainActor
    func recheckIfNotConnected() async {
        guard !state.isConnected, let userIDForRecheck else { return }
        await check(userID: userIDForRecheck())
    }

    /// - Parameter quiet: re-verify without flashing "Checking…" over a
    ///   connection that is probably fine - used after a single request failed.
    func check(userID: String, quiet: Bool = false) async {
        guard let client, let healthClient else {
            state = .onDevice
            provider = nil
            ports = []
            budget = nil
            return
        }
        if !(quiet && state.isConnected) { state = .checking }
        do {
            let health = try await healthClient.health()
            lastRequestProblem = nil
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

    /// One request failed. That is evidence about the request, not a verdict on
    /// the backend.
    ///
    /// This used to set the connection state from any failure, which is why the
    /// app "disconnected itself" a few requests in: a request SwiftUI cancelled
    /// because a screen went away, an arbitration that outlived the timeout on
    /// a slow model, or one route's own 503 ("no recommendation") each flipped
    /// the whole app to unreachable or refusing - and with the state no longer
    /// connected, coming back to the foreground stopped re-running the pass, so
    /// it stayed that way until somebody pressed Connect.
    ///
    /// Now: cancellation is ignored, a 401 is still definitive, and everything
    /// else asks `/health` - quietly - and lets that answer decide.
    @MainActor
    func noteFailure(_ error: Error) {
        if error is CancellationError { return }
        if let urlError = error as? URLError, urlError.code == .cancelled { return }
        // A 401 is not a network fault and not a misconfiguration. Reporting it
        // as "unreachable" sends somebody to check an address that is right.
        if case let RemoteAgentClient.ClientError.http(status, _) = error, status == 401 {
            state = .unauthenticated
            return
        }
        lastRequestProblem = (error as? RemoteAgentClient.Refusal)?.diagnosis ?? shortReason(error)
        scheduleRecheck(after: 0.3, quiet: true)
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
