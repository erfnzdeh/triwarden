import TriCrypto
import CryptoKit
import Foundation
import LocalAuthentication
import Security
import VaultwardenAPI

/// What we keep on disk to unlock an account without the network. Nothing here decrypts the vault on its
/// own: `protectedUserKey` needs the master password (or the Secure Enclave, for Touch ID).
struct SavedAccount: Codable, Equatable, Identifiable {
    /// Stable per server + email, so logging in again replaces rather than duplicates.
    var id: String
    var email: String
    var serverKind: String
    var serverURL: String
    var kdf: KDFConfig
    var protectedUserKey: String
    var addedAt = Date()
    /// Self-hosted "Custom environment" overrides; nil when every service derives from `serverURL`.
    var customURLs: CustomURLs?

    static func makeID(serverKind: String, serverURL: String, email: String, customURLs: CustomURLs? = nil) -> String {
        let anchor = customURLs.flatMap { ($0.base ?? $0.webVault ?? $0.api)?.absoluteString } ?? serverURL
        let server = serverKind == "selfHosted" ? anchor.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) : serverKind
        let digest = SHA256.hash(data: Data("\(server)|\(KDF.normalizedEmail(email))".utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    var serverSummary: String {
        switch serverKind {
        case "bitwardenUS": "bitwarden.com"
        case "bitwardenEU": "bitwarden.eu"
        default: (customURLs.flatMap { $0.webVault ?? $0.base ?? $0.api }?.host()) ?? URL(string: serverURL)?.host() ?? serverURL
        }
    }

    var environment: ServerEnvironment? {
        switch serverKind {
        case "bitwardenUS": .bitwardenUS
        case "bitwardenEU": .bitwardenEU
        default:
            if let customURLs { .custom(customURLs) } else { URL(string: serverURL).map(ServerEnvironment.selfHosted) }
        }
    }
}

/// Per-account storage in the App Group (shared with the AutoFill extension):
/// `Accounts/<id>/{account,vault,biometric}.json`, refresh token in the Keychain.
enum AccountStore {
    /// Team-prefixed group: no provisioning needed on macOS.
    static let appGroup = "FX3VR69P5K.io.github.sinhong2011.triwarden"

    /// Storage namespace. Tests switch to their own so they can never touch real accounts.
    nonisolated(unsafe) static var namespace = "Accounts"

    private static var root: URL {
        let fm = FileManager.default
        let base = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appending(path: namespace, directoryHint: .isDirectory)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Non-secret metadata shared by the app and its extensions, kept beside this namespace's account folders.
    /// Tests use a separate namespace, so their indexes can never affect real AutoFill requests.
    static func metadataURL(_ name: String) -> URL { root.appending(path: name) }

    /// Files must be writable while the screen is locked (background sync). Their contents are already
    /// encrypted with vault keys, so "until first unlock" protection is the right class; "complete" protection
    /// makes atomic writes fail while the Mac is locked.
    private static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]

    private static func dir(_ id: String) -> URL {
        let d = root.appending(path: id, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // MARK: Accounts

    /// All saved accounts, oldest first.
    static func accounts() -> [SavedAccount] {
        if namespace == "Accounts" { migrateSingleAccountLayout() }
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return ids.compactMap(load).sorted { $0.addedAt < $1.addedAt }
    }

    static func load(_ id: String) -> SavedAccount? {
        let url = root.appending(path: id).appending(path: "account.json")
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(SavedAccount.self, from: $0) }
    }

    static func save(_ account: SavedAccount) {
        var account = account
        if let existing = load(account.id) { account.addedAt = existing.addedAt } // keep its place in the list
        try? JSONEncoder().encode(account).write(to: dir(account.id).appending(path: "account.json"), options: writeOptions)
    }

    static func erase(_ id: String) {
        sessionPINs[id] = nil
        try? FileManager.default.removeItem(at: root.appending(path: id))
        Keychain.delete(service: refreshService(id))
    }

    /// Offline unlock: re-derive the master key; the MAC on the protected user key proves the password.
    static func unlock(_ id: String, password: String) -> SymmetricKeyPair? {
        guard let saved = load(id),
              let mk = try? KDF.masterKey(password: password, email: saved.email, config: saved.kdf),
              let stretched = try? SymmetricKeyPair.stretched(masterKey: mk),
              let raw = try? EncString(saved.protectedUserKey).decrypt(with: stretched) else { return nil }
        return try? SymmetricKeyPair(combined: raw)
    }

    // MARK: Encrypted vault cache

    /// The sync payload exactly as the server sent it (every secret still encrypted).
    static func loadCache(_ id: String) -> Data? { try? Data(contentsOf: root.appending(path: id).appending(path: "vault.json")) }
    static func saveCache(_ data: Data, _ id: String) {
        try? data.write(to: dir(id).appending(path: "vault.json"), options: writeOptions)
    }

    // MARK: Refresh token (Keychain)

    private static func refreshService(_ id: String) -> String {
        namespace == "Accounts" ? "io.github.sinhong2011.triwarden.refresh.\(id)" : "io.github.sinhong2011.triwarden.\(namespace).refresh.\(id)"
    }
    static func refreshToken(_ id: String) -> String? {
        Keychain.read(service: refreshService(id)).flatMap { String(data: $0, encoding: .utf8) }
    }
    static func setRefreshToken(_ token: String?, _ id: String) {
        if let token { Keychain.write(Data(token.utf8), service: refreshService(id)) } else { Keychain.delete(service: refreshService(id)) }
    }

    // MARK: Touch ID (Secure Enclave)

    /// The user key, sealed with a key derived from a biometry-gated Secure Enclave key.
    private struct BiometricBlob: Codable {
        var enclaveKey: Data      // SecureEnclave key handle (useless off this Mac / without Touch ID)
        var ephemeralPublic: Data // peer for key agreement
        var sealed: Data          // AES-GCM(userKey)
    }

    private static func biometricURL(_ id: String) -> URL { root.appending(path: id).appending(path: "biometric.json") }

    static func isTouchIDEnabled(_ id: String) -> Bool { FileManager.default.fileExists(atPath: biometricURL(id).path) }

    static var isTouchIDAvailable: Bool {
        SecureEnclave.isAvailable && LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    static func enableTouchID(userKey: SymmetricKeyPair, _ id: String) throws {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           [.privateKeyUsage, .biometryCurrentSet], &error) else {
            throw error!.takeRetainedValue() as Error
        }
        let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        // Wrapping only needs the enclave *public* key, so no prompt here.
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: enclave.publicKey)
        let sealed = try AES.GCM.seal(userKey.encryptionKey + userKey.macKey, using: wrapKey(shared)).combined!
        let blob = BiometricBlob(enclaveKey: enclave.dataRepresentation,
                                 ephemeralPublic: ephemeral.publicKey.rawRepresentation, sealed: sealed)
        try JSONEncoder().encode(blob).write(to: dir(id).appending(path: "biometric.json"), options: writeOptions)
    }

    static func disableTouchID(_ id: String) { try? FileManager.default.removeItem(at: biometricURL(id)) }

    /// Unseals one account's user key. Pass an already-evaluated `LAContext` to avoid a second prompt.
    static func unlockWithTouchID(_ id: String, context: LAContext) throws -> SymmetricKeyPair {
        let blob = try JSONDecoder().decode(BiometricBlob.self, from: Data(contentsOf: biometricURL(id)))
        let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob.enclaveKey,
                                                                      authenticationContext: context)
        let peer = try P256.KeyAgreement.PublicKey(rawRepresentation: blob.ephemeralPublic)
        let raw = try AES.GCM.open(AES.GCM.SealedBox(combined: blob.sealed),
                                   using: wrapKey(try enclave.sharedSecretFromKeyAgreement(with: peer)))
        return try SymmetricKeyPair(combined: raw)
    }

    /// One Touch ID prompt, then every enrolled account in `ids` is unsealed with the same context.
    @MainActor
    static func unlockAllWithTouchID(_ ids: [String], reason: String, context: LAContext = LAContext()) async -> [String: SymmetricKeyPair] {
        await attemptUnlockAllWithTouchID(ids, reason: reason, context: context).keys
    }

    /// The keys opened by one Touch ID prompt, plus enough failure detail for an interactive caller to recover from
    /// a prompt that raced the app or its window becoming usable. Deliberate cancellation is not retryable.
    struct TouchIDUnlockAttempt {
        var keys: [String: SymmetricKeyPair]
        var failure: LAError.Code?

        var shouldRetryWhenInteractive: Bool {
            switch failure {
            case .notInteractive?, .appCancel?, .systemCancel?: true
            default: false
            }
        }
    }

    /// The result-bearing form used by the main unlock screen. Other callers only need the opened keys above.
    @MainActor
    static func attemptUnlockAllWithTouchID(_ ids: [String], reason: String,
                                            context: LAContext = LAContext()) async -> TouchIDUnlockAttempt {
        let enrolled = ids.filter(isTouchIDEnabled)
        guard !enrolled.isEmpty else { return TouchIDUnlockAttempt(keys: [:], failure: nil) }
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) else {
                return TouchIDUnlockAttempt(keys: [:], failure: nil)
            }
        } catch {
            return TouchIDUnlockAttempt(keys: [:], failure: (error as? LAError)?.code)
        }
        var keys: [String: SymmetricKeyPair] = [:]
        for id in enrolled { keys[id] = try? unlockWithTouchID(id, context: context) }
        return TouchIDUnlockAttempt(keys: keys, failure: nil)
    }

    private static func wrapKey(_ shared: SharedSecret) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("triwarden-touchid".utf8),
                                       sharedInfo: Data(), outputByteCount: 32)
    }

    // MARK: PIN

    /// The user key sealed with a key made from the PIN (stretched with the account's own KDF) and, where the Mac
    /// has one, a Secure Enclave key: the blob is useless anywhere but on this Mac. Five wrong PINs erase it.
    private struct PINBlob: Codable {
        var enclaveKey: Data?      // Secure Enclave key handle, no biometry needed
        var ephemeralPublic: Data?
        var sealed: Data           // AES-GCM(userKey)
        var failures = 0
    }

    static let pinAttempts = 5

    private static func pinURL(_ id: String) -> URL { root.appending(path: id).appending(path: "pin.json") }
    /// PINs that last only until the app quits (the default: after a restart, the master password).
    nonisolated(unsafe) private static var sessionPINs: [String: Data] = [:]

    static func isPINEnabled(_ id: String) -> Bool {
        sessionPINs[id] != nil || FileManager.default.fileExists(atPath: pinURL(id).path)
    }
    /// Whether the PIN survives a restart (kept on disk) rather than living only in this run.
    static func isPINPersistent(_ id: String) -> Bool { FileManager.default.fileExists(atPath: pinURL(id).path) }

    static func enablePIN(_ pin: String, userKey: SymmetricKeyPair, persistent: Bool, _ id: String) throws {
        guard let saved = load(id) else { throw CocoaError(.fileNoSuchFile) }
        let stretched = try pinSecret(pin, saved)
        var blob = PINBlob(sealed: Data())
        var secret = stretched
        if SecureEnclave.isAvailable {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                               [.privateKeyUsage], &error) else {
                throw error!.takeRetainedValue() as Error
            }
            let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
            let ephemeral = P256.KeyAgreement.PrivateKey()
            let shared = try ephemeral.sharedSecretFromKeyAgreement(with: enclave.publicKey)
            secret += shared.withUnsafeBytes { Data($0) }
            blob.enclaveKey = enclave.dataRepresentation
            blob.ephemeralPublic = ephemeral.publicKey.rawRepresentation
        }
        blob.sealed = try AES.GCM.seal(userKey.encryptionKey + userKey.macKey, using: pinWrapKey(secret)).combined!
        disablePIN(id)
        let data = try JSONEncoder().encode(blob)
        if persistent { try data.write(to: dir(id).appending(path: "pin.json"), options: writeOptions) } else { sessionPINs[id] = data }
    }

    /// Moves the PIN between this run only and disk (surviving restarts), without asking for it again.
    static func setPINPersistent(_ persistent: Bool, _ id: String) {
        guard isPINEnabled(id), persistent != isPINPersistent(id) else { return }
        if persistent, let data = sessionPINs[id] {
            try? data.write(to: dir(id).appending(path: "pin.json"), options: writeOptions)
            sessionPINs[id] = nil
        } else if !persistent, let data = try? Data(contentsOf: pinURL(id)) {
            sessionPINs[id] = data
            try? FileManager.default.removeItem(at: pinURL(id))
        }
    }

    static func disablePIN(_ id: String) {
        sessionPINs[id] = nil
        try? FileManager.default.removeItem(at: pinURL(id))
    }

    enum PINResult { case unlocked(SymmetricKeyPair), wrong(left: Int), erased }

    /// Opens the user key with the PIN. A wrong one counts; the fifth erases the PIN.
    static func unlockWithPIN(_ id: String, pin: String) -> PINResult? {
        let persistent = isPINPersistent(id)
        guard let saved = load(id), let data = persistent ? try? Data(contentsOf: pinURL(id)) : sessionPINs[id],
              var blob = try? JSONDecoder().decode(PINBlob.self, from: data),
              var secret = try? pinSecret(pin, saved) else { return nil }
        if let handle = blob.enclaveKey, let peerData = blob.ephemeralPublic,
           let enclave = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: handle),
           let peer = try? P256.KeyAgreement.PublicKey(rawRepresentation: peerData),
           let shared = try? enclave.sharedSecretFromKeyAgreement(with: peer) {
            secret += shared.withUnsafeBytes { Data($0) }
        }
        if let box = try? AES.GCM.SealedBox(combined: blob.sealed),
           let raw = try? AES.GCM.open(box, using: pinWrapKey(secret)), let key = try? SymmetricKeyPair(combined: raw) {
            if blob.failures > 0 { blob.failures = 0; store(blob, id, persistent: persistent) }
            return .unlocked(key)
        }
        blob.failures += 1
        if blob.failures >= pinAttempts {
            disablePIN(id)
            return .erased
        }
        store(blob, id, persistent: persistent)
        return .wrong(left: pinAttempts - blob.failures)
    }

    private static func store(_ blob: PINBlob, _ id: String, persistent: Bool) {
        guard let data = try? JSONEncoder().encode(blob) else { return }
        if persistent { try? data.write(to: dir(id).appending(path: "pin.json"), options: writeOptions) } else { sessionPINs[id] = data }
    }

    /// The PIN stretched with the account's KDF (salted apart from the master password's use of the email).
    private static func pinSecret(_ pin: String, _ saved: SavedAccount) throws -> Data {
        try KDF.masterKey(password: pin, email: saved.email + "|triwarden-pin", config: saved.kdf)
    }

    private static func pinWrapKey(_ secret: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Data("triwarden-pin".utf8),
                               info: Data(), outputByteCount: 32)
    }

    // MARK: Migration

    /// Moves the earlier single-account layout (`Account/` in the group or Application Support) into
    /// `Accounts/<id>/`, carrying the refresh token along.
    private static func migrateSingleAccountLayout() {
        let fm = FileManager.default
        var candidates = [fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Account")]
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            candidates.insert(group.appending(path: "Account"), at: 0)
        }
        struct Legacy: Codable { var email: String; var serverKind: String; var serverURL: String; var kdf: KDFConfig; var protectedUserKey: String }
        for old in candidates where fm.fileExists(atPath: old.path) {
            defer { try? fm.removeItem(at: old) }
            guard let data = try? Data(contentsOf: old.appending(path: "account.json")),
                  let legacy = try? JSONDecoder().decode(Legacy.self, from: data) else { continue }
            let id = SavedAccount.makeID(serverKind: legacy.serverKind, serverURL: legacy.serverURL, email: legacy.email)
            let target = root.appending(path: id)
            guard !fm.fileExists(atPath: target.path) else { continue }
            try? fm.moveItem(at: old, to: target)
            save(SavedAccount(id: id, email: legacy.email, serverKind: legacy.serverKind, serverURL: legacy.serverURL,
                              kdf: legacy.kdf, protectedUserKey: legacy.protectedUserKey))
            let oldService = "io.github.sinhong2011.triwarden.refresh"
            if let token = Keychain.read(service: oldService) {
                Keychain.write(token, service: refreshService(id))
                Keychain.delete(service: oldService)
            }
        }
    }
}

/// Minimal generic-password Keychain helper. Items live in the data-protection keychain under the App
/// Group, so the AutoFill extension can use them too; items from the older per-app (file) keychain are
/// moved over on first read.
enum Keychain {
    /// Keychain Sharing group of the app and its AutoFill extension.
    static let accessGroup = "FX3VR69P5K.io.github.sinhong2011.triwarden.shared"

    private static func base(_ service: String, shared: Bool) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if shared {
            q[kSecUseDataProtectionKeychain as String] = true
            q[kSecAttrAccessGroup as String] = accessGroup
        }
        return q
    }

    private static func copy(_ service: String, shared: Bool) -> Data? {
        var q = base(service, shared: shared)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    @discardableResult
    private static func add(_ data: Data, _ service: String, shared: Bool) -> Bool {
        var q = base(service, shared: shared)
        q[kSecValueData as String] = data
        // Same as the vault files: readable while the screen is locked (background sync), never off this Mac.
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func read(service: String) -> Data? {
        if let data = copy(service, shared: true) { return data }
        guard let legacy = copy(service, shared: false) else { return nil }
        if add(legacy, service, shared: true) { SecItemDelete(base(service, shared: false) as CFDictionary) }
        return legacy
    }

    static func write(_ data: Data, service: String) {
        delete(service: service)
        if !add(data, service, shared: true) { add(data, service, shared: false) }
    }

    /// True when the item lives in the shared (App Group) keychain.
    static func isShared(service: String) -> Bool { copy(service, shared: true) != nil }

    static func delete(service: String) {
        SecItemDelete(base(service, shared: true) as CFDictionary)
        SecItemDelete(base(service, shared: false) as CFDictionary)
    }
}
