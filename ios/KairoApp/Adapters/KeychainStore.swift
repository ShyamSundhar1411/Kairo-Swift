import Foundation
import Security

/// NFR6, the at-rest half — for the one value in this app that is a credential.
///
/// The backend token was in `UserDefaults`, which is a plist in the app
/// container: readable from a filesystem dump, included in an unencrypted
/// iTunes backup, and restored onto whatever device that backup is restored to.
/// None of that is exotic. It is the default behaviour of the API that was
/// being used.
///
/// Keychain instead, with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`:
///
/// - **WhenUnlocked**, not `AfterFirstUnlock`, because nothing in Kairo needs
///   to talk to the backend while the phone is locked. Arbitration is driven by
///   the app being open or by a scheduled local notification, and a credential
///   that is readable at every moment the device is powered on is readable
///   during every moment it is lost.
/// - **ThisDeviceOnly**, because this token is paired with one backend the
///   developer is running on one machine. A restore onto a second device should
///   produce an app that asks for the address again, not one that silently
///   carries a credential somewhere nobody meant it to go.
///
/// Deliberately not generic. A "KeychainWrapper" that stores `Codable` anything
/// invites the Memory Book into the keychain, which is the wrong store for it —
/// that belongs in a protected file, which is what `FileProtection` is for.
enum KeychainStore {

    /// Namespaced to the bundle so a second build of Kairo on the same phone —
    /// which `KAIRO_BUNDLE_SUFFIX` exists to allow — does not read the first
    /// one's token.
    private static var service: String {
        (Bundle.main.bundleIdentifier ?? "au.edu.sydney.elec5620.kairo") + ".credentials"
    }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func string(for account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Writing an empty string deletes the item rather than storing nothing.
    ///
    /// Clearing the field in settings is a deliberate "stop using a token", and
    /// leaving a zero-length credential behind would make the keychain disagree
    /// with the screen about whether one exists.
    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        guard !value.isEmpty else { return delete(account) }
        guard let data = value.data(using: .utf8) else { return false }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        // Update first: SecItemAdd on an existing account returns
        // errSecDuplicateItem, and the obvious delete-then-add leaves a window
        // where the credential is gone if the add fails.
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = query(account)
        add.merge(attributes) { _, new in new }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        let status = SecItemDelete(query(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// SCRUM-21 — the profile, kept on the device as well as on the server.
///
/// `UserDefaults` rather than the Keychain, deliberately: an interruption
/// ceiling and a quiet window are preferences, not credentials, and putting
/// non-secrets in the Keychain trains whoever reads this next that the Keychain
/// is just storage. The token stays where it belongs, next door.
///
/// It exists at all because AG-1's ceiling is a grant the user made, NFR9 says
/// the app keeps working with no network, and a preference that lives only on a
/// backend vanishes the moment the backend does — which is precisely when a
/// ceiling most needs to be respected.
enum ProfileStore {
    private static let key = "kairo.profile"

    static func load() -> RemoteAgentClient.UserProfile {
        guard let raw = UserDefaults.standard.dictionary(forKey: key) else {
            return RemoteAgentClient.UserProfile()
        }
        return RemoteAgentClient.UserProfile(json: raw)
    }

    static func save(_ p: RemoteAgentClient.UserProfile) {
        UserDefaults.standard.set([
            "displayName": p.displayName,
            "locale": p.locale,
            "timezone": p.timezone,
            "dailyInterruptionCeiling": p.dailyInterruptionCeiling,
            "quietHoursStart": p.quietHoursStart,
            "quietHoursEnd": p.quietHoursEnd,
        ], forKey: key)
    }
}
