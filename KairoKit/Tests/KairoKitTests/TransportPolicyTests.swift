import Testing
import Foundation
@testable import KairoKit

/// NFR6 in transit — what may carry a day of health summaries off this phone.
@Suite("NFR6 — transport")
struct TransportPolicyTests {

    @Test("https to anywhere is fine", arguments: [
        "https://kairo.fly.dev", "https://192.168.1.10:8080", "https://example.com/v1",
    ])
    func httpsIsAccepted(address: String) {
        #expect(TransportPolicy.objection(to: address) == nil)
    }

    @Test("cleartext to a remote host is refused", arguments: [
        "http://192.168.1.10:8080",     // the exact thing the settings placeholder suggests
        "http://kairo.fly.dev",
        "http://10.0.0.5:8080",
    ])
    func cleartextToRemoteIsRefused(address: String) {
        let objection = TransportPolicy.objection(to: address)
        #expect(objection != nil)
        // The sentence has to say what to do, not just that something is wrong.
        #expect(objection?.contains("https") == true)
    }

    @Test("loopback stays exempt", arguments: [
        "http://127.0.0.1:8080", "http://localhost:8080", "http://[::1]:8080",
        "http://my-mac.local:8080", "http://my-mac.local.:8080",
    ])
    func loopbackIsExempt(address: String) {
        // The zero-key local path is a backend on this machine. There is no
        // network segment to intercept and no certificate anybody could issue,
        // and refusing it would mean the one configuration that sends nothing
        // anywhere is the one the app will not talk to.
        #expect(TransportPolicy.objection(to: address) == nil)
    }

    @Test("an empty address is not an objection")
    func emptyIsOnDevice() {
        // Clearing the field is the deliberate way to run entirely on-device.
        #expect(TransportPolicy.objection(to: "") == nil)
        #expect(TransportPolicy.objection(to: "   ") == nil)
    }

    @Test("something that is not an address says so in its own words")
    func unparseableIsItsOwnMessage() {
        let objection = TransportPolicy.objection(to: "not an address")
        #expect(objection != nil)
        // Distinct from the https message: "type a real address" and "use TLS"
        // send somebody to two different places.
        #expect(objection?.contains("https") == false)
    }

    @Test("a hostname that merely contains the word local is not loopback")
    func lookalikeHostsAreNotExempt() {
        // `localhost.attacker.example` and `notlocal` both end up remote. The
        // check is a suffix on a label, not a substring anywhere in the host.
        #expect(!TransportPolicy.isLoopback("localhost.attacker.example"))
        #expect(!TransportPolicy.isLoopback("notlocalhost"))
        #expect(!TransportPolicy.isLoopback("local.example.com"))
    }
}
