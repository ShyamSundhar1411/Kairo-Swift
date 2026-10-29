import Foundation
import Network

/// Finds the agent backend on the local network, so nobody has to type an
/// address that changes with the network anyway.
///
/// A LAN address is the one piece of configuration that is both required on a
/// real device and guaranteed to go stale — a reboot, a new DHCP lease, a
/// different café. Bonjour removes it: the backend announces `_kairo._tcp`
/// (`backend/kairo/discovery.py`) and this browses for it.
///
/// **What it cannot do**, said here so nobody debugs it for an hour: Bonjour is
/// link-local. It does not cross subnets, most VPNs, or a guest network that
/// isolates clients. On any of those the address field is still the answer,
/// which is why that field stays.
///
/// It also never overrides a stored address. Discovery supplies a value when
/// there is nothing better; a person who typed one meant it.
@Observable
final class BackendDiscovery {

    struct Found: Equatable, Identifiable {
        /// "Kairo on shyams-mac"
        let name: String
        let host: String
        let port: Int
        /// From the TXT record, so the app can say "found one, it wants a key"
        /// rather than discovering that on its first 401.
        let needsToken: Bool

        var id: String { "\(host):\(port)" }
        var url: String { "http://\(host):\(port)" }
    }

    private(set) var found: [Found] = []
    /// True while the browser is up. Not an error state — on a network with no
    /// backend this is simply the answer.
    private(set) var searching = false
    /// Set when iOS refuses the local-network permission, which is the one
    /// failure a person can actually fix and which is otherwise silent.
    private(set) var denied = false

    private var browser: NWBrowser?
    private var resolvers: [String: NWConnection] = [:]

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let browser = NWBrowser(
            for: .bonjour(type: "_kairo._tcp", domain: nil), using: parameters)

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.searching = true
                    self.denied = false
                case .waiting, .failed:
                    // `NWBrowser` reports a refused local-network permission as
                    // a waiting/failed state rather than anything named, so the
                    // app says the actionable thing instead of "no results".
                    self.denied = true
                    self.searching = false
                case .cancelled:
                    self.searching = false
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.resolve(results) }
        }

        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        for connection in resolvers.values { connection.cancel() }
        resolvers.removeAll()
        searching = false
    }

    /// A browse result carries a *name*, not an address. Resolving is a second
    /// step, and doing it with a short-lived `NWConnection` is the supported
    /// way — `NetService` resolution is deprecated and was never reliable under
    /// the iOS 14 permission model.
    @MainActor
    private func resolve(_ results: Set<NWBrowser.Result>) {
        var live: Set<String> = []

        for result in results {
            guard case let .service(name, type, domain, _) = result.endpoint else { continue }
            let key = "\(name).\(type).\(domain)"
            live.insert(key)
            guard resolvers[key] == nil else { continue }

            let connection = NWConnection(to: result.endpoint, using: .tcp)
            resolvers[key] = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard case .ready = state,
                      let endpoint = connection.currentPath?.remoteEndpoint,
                      case let .hostPort(host, port) = endpoint else { return }
                let text = Self.plain(host)
                Task { @MainActor in
                    self?.record(name: name, host: text, port: Int(port.rawValue))
                    connection.cancel()
                }
            }
            connection.start(queue: .main)
        }

        // Anything that went away takes its entry with it. A list that only
        // grows would offer a backend that stopped ten minutes ago.
        for (key, connection) in resolvers where !live.contains(key) {
            connection.cancel()
            resolvers.removeValue(forKey: key)
        }
        let names = Set(results.compactMap { result -> String? in
            guard case let .service(name, _, _, _) = result.endpoint else { return nil }
            return name
        })
        found.removeAll { !names.contains($0.name) }
    }

    @MainActor
    private func record(name: String, host: String, port: Int) {
        let entry = Found(name: name, host: host, port: port, needsToken: false)
        guard !found.contains(where: { $0.id == entry.id }) else { return }
        found.append(entry)
    }

    /// `NWEndpoint.Host` prints an IPv6 scope id (`fe80::1%en0`) and wraps
    /// nothing in brackets, neither of which goes into a URL unedited.
    private static func plain(_ host: NWEndpoint.Host) -> String {
        switch host {
        case let .ipv4(address):
            return "\(address)".split(separator: "%").first.map(String.init) ?? "\(address)"
        case let .ipv6(address):
            let bare = "\(address)".split(separator: "%").first.map(String.init) ?? "\(address)"
            return "[\(bare)]"
        case let .name(name, _):
            return name
        @unknown default:
            return "\(host)"
        }
    }
}
