
import Foundation
import Network

/// Discovers Kairo backends on the local network using Bonjour.
///
/// The backend advertises `_kairo._tcp`. Discovery never overrides a
/// manually configured address; it only supplies candidates for the UI.
///
/// Bonjour is link-local and will not reliably cross subnets, VPNs,
/// or networks with client isolation.
@Observable
final class BackendDiscovery {

    struct Found: Equatable, Identifiable {
        /// Bonjour service instance name.
        let name: String

        /// Resolved IP address or hostname.
        let host: String

        let port: Int

        /// Whether the backend advertises that authentication is required.
        let needsToken: Bool

        var id: String {
            "\(host):\(port)"
        }

        var url: String {
            "http://\(host):\(port)"
        }
    }

    private(set) var found: [Found] = []
    private(set) var searching = false
    private(set) var denied = false

    private var browser: NWBrowser?
    private var resolvers: [String: NWConnection] = [:]

    /// TXT-record authentication requirements, keyed by service identity.
    private var tokenRequirements: [String: Bool] = [:]

    func start() {
        guard browser == nil else { return }

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false

        let browser = NWBrowser(
            for: .bonjour(type: "_kairo._tcp", domain: nil),
            using: parameters
        )

        browser.stateUpdateHandler = { [weak self] state in
            print("[Bonjour] Browser state: \(state)")

            if case .failed(let error) = state {
                print("[Bonjour] Browser failed: \(error)")
            }

            if case .waiting(let error) = state {
                print("[Bonjour] Browser waiting: \(error)")
            }

            Task { @MainActor in
                guard let self else { return }

                switch state {
                case .ready:
                    self.searching = true
                    self.denied = false

                case .waiting:
                    self.searching = false

                case .failed:
                    self.searching = false
                    self.denied = true

                case .cancelled:
                    self.searching = false

                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            print("[Bonjour] Results: \(results.count)")

            for result in results {
                print("[Bonjour] Endpoint: \(result.endpoint)")
                print("[Bonjour] Metadata: \(result.metadata)")
            }

            Task { @MainActor in
                self?.resolve(results)
            }
        }

        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil

        for connection in resolvers.values {
            connection.cancel()
        }

        resolvers.removeAll()
        tokenRequirements.removeAll()
        found.removeAll()
        searching = false
        denied = false
    }

    @MainActor
    private func resolve(_ results: Set<NWBrowser.Result>) {
        var live: Set<String> = []

        for result in results {
            guard case let .service(name, type, domain, _) = result.endpoint
            else {
                continue
            }

            let key = "\(name).\(type).\(domain)"
            live.insert(key)

            // Read the Bonjour TXT record, if provided.
            if case let .bonjour(txtRecord) = result.metadata {
                let authValue = txtRecord["auth"]?.lowercased()
                tokenRequirements[key] = authValue == "required"

                print(
                    "[Bonjour] Service \(name), auth=\(authValue ?? "unspecified")"
                )
            }

            guard resolvers[key] == nil else {
                continue
            }

            print("[Bonjour] Starting resolver for \(name)")

            let connection = NWConnection(
                to: result.endpoint,
                using: .tcp
            )

            resolvers[key] = connection

            connection.stateUpdateHandler = { [weak self] state in
                print("[Bonjour] Resolver \(name): \(state)")

                switch state {
                case .ready:
                    guard
                        let endpoint = connection.currentPath?.remoteEndpoint,
                        case let .hostPort(host, port) = endpoint
                    else {
                        print(
                            "[Bonjour] Ready, but no host/port: " +
                            "\(String(describing: connection.currentPath?.remoteEndpoint))"
                        )
                        return
                    }

                    let resolvedHost = Self.plain(host)
                    let resolvedPort = Int(port.rawValue)

                    print(
                        "[Bonjour] Resolved \(name) -> " +
                        "\(resolvedHost):\(resolvedPort)"
                    )

                    Task { @MainActor in
                        guard let self else {
                            connection.cancel()
                            return
                        }

                        self.record(
                            name: name,
                            host: resolvedHost,
                            port: resolvedPort,
                            needsToken: self.tokenRequirements[key] ?? false
                        )

                        connection.cancel()
                        self.resolvers.removeValue(forKey: key)
                    }

                case .failed(let error):
                    print("[Bonjour] Resolver failed for \(name): \(error)")

                    Task { @MainActor in
                        self?.resolvers.removeValue(forKey: key)
                        connection.cancel()
                    }

                case .cancelled:
                    print("[Bonjour] Resolver cancelled for \(name)")

                default:
                    break
                }
            }

            connection.start(queue: .main)
        }

        // Cancel resolvers for services that disappeared.
        for (key, connection) in resolvers where !live.contains(key) {
            connection.cancel()
            resolvers.removeValue(forKey: key)
            tokenRequirements.removeValue(forKey: key)
        }

        // Remove discovered entries whose service instances disappeared.
        let liveNames = Set(
            results.compactMap { result -> String? in
                guard case let .service(name, _, _, _) = result.endpoint
                else {
                    return nil
                }

                return name
            }
        )

        found.removeAll { !liveNames.contains($0.name) }
    }

    @MainActor
    private func record(
        name: String,
        host: String,
        port: Int,
        needsToken: Bool
    ) {
        let entry = Found(
            name: name,
            host: host,
            port: port,
            needsToken: needsToken
        )

        guard !found.contains(where: { $0.id == entry.id }) else {
            return
        }

        found.append(entry)
        print("[Bonjour] Added backend: \(entry.url), needsToken=\(needsToken)")
    }

    /// Formats an NWEndpoint.Host for use in an HTTP URL.
    private static func plain(_ host: NWEndpoint.Host) -> String {
        switch host {
        case let .ipv4(address):
            return "\(address)" // No interface scope for IPv4.

        case let .ipv6(address):
            let value = "\(address)"
            let bare = value.split(separator: "%").first.map(String.init) ?? value
            return "[\(bare)]"

        case let .name(name, _):
            return name

        @unknown default:
            return "\(host)"
        }
    }
}

