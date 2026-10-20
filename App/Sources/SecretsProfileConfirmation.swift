import Foundation
import LocalAuthentication
import SecretsAgent
import Security

/// The native UI's profile approval, protected by the App's Data Protection Keychain entitlement.
/// Injectable service names let signed-app self-tests use their own disposable record.
@MainActor
struct SecretsProfileConfirmation {
    var service = "io.github.sinhong2011.triwarden.secrets-profile-revision.v1"
    var accessGroup = Keychain.accessGroup

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "local-profile",
         kSecAttrAccessGroup as String: accessGroup,
         kSecUseDataProtectionKeychain as String: true]
    }

    func read() -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ revision: String) throws {
        let data = Data(revision.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw writeFailure(update) }
        var query = query
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(query as CFDictionary, nil)
        guard added == errSecSuccess else { throw writeFailure(added) }
    }

    private func writeFailure(_ status: OSStatus) -> SecretsFailure {
        #if DEBUG
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--selftest-secrets") }) {
            // Report only the API status: never log the service, query, revision or credential.
            print("DIAGNOSTIC Keychain write status \(status)")
        }
        #endif
        return SecretsFailure("Couldn't confirm the profile in Keychain. No launch was enabled.")
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretsFailure("Couldn't remove the profile confirmation from Keychain.")
        }
    }
}
