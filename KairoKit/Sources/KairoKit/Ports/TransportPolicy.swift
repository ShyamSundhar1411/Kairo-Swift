import Foundation

/// NFR6, the in-transit half - as a rule rather than as a condition inside a view.
///
/// It lives in KairoKit for the same reason the arbiter does: it is a policy the
/// product has, not a detail of one screen, and here it has tests. The app
/// target has no unit test bundle, so a decision about whether a day of health
/// summaries may leave the phone in cleartext would otherwise be unverified
/// code behind a `guard`.
///
/// App Transport Security already refuses cleartext to a remote host -
/// `NSAllowsLocalNetworking` is the only exception in the Info.plist and there
/// is deliberately no `NSAllowsArbitraryLoads`. Stating the rule here anyway is
/// not belt-and-braces for its own sake:
///
/// - ATS fails at the moment of the request, as an opaque `URLError`, which the
///   connection screen reports as "the backend did not answer" - the one
///   diagnosis guaranteed to send somebody to debug a server that is fine.
/// - A build that later gains an ATS exception for some unrelated reason should
///   not silently also gain the ability to post health summaries over HTTP.
public enum TransportPolicy {

    /// Loopback is exempt and stays exempt. Kairo's zero-key local path is a
    /// backend on 127.0.0.1, where there is no network segment to intercept and
    /// no certificate anybody could issue. Refusing it would mean the only
    /// configuration that costs nothing and sends nothing anywhere is also the
    /// only one the app will not talk to.
    public static func isLoopback(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" {
            return true
        }
        // Bonjour names on the local link. `.local.` with the trailing dot is
        // the fully-qualified form and resolves to the same host.
        return host.hasSuffix(".local") || host.hasSuffix(".local.")
    }

    public static func isAcceptable(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "https" { return true }
        return isLoopback(url.host)
    }

    /// Why an address is being refused, in a sentence meant for the person who
    /// typed it rather than for a log. `nil` when there is nothing wrong.
    ///
    /// An empty address is not an objection: clearing the field is the
    /// deliberate way to run entirely on the device.
    public static func objection(to address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed), url.host != nil else {
            return "That is not an address Kairo can parse."
        }
        guard isAcceptable(url) else {
            return "Use https for a backend that is not on this machine. "
                 + "A day of health summaries over plain HTTP is readable by "
                 + "anything on the same network."
        }
        return nil
    }
}
