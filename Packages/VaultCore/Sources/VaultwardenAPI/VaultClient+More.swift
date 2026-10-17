import TriCrypto
import Foundation

// Endpoints beyond the vault basics: organizations, bulk edits, account security, devices, two-step login,
// sign-in requests, emergency access, equivalent domains and event logs. Bodies and answers are plain JSON
// (already encrypted where they hold secrets); callers decode what they need.

extension VaultClient {
    /// An authorized call to the API with an optional JSON body; returns the answer's bytes.
    @discardableResult
    public func call(_ method: String, _ path: String, json body: Any? = nil) async throws(APIError) -> Data {
        var r = try request(environment.apiURL, path)
        r.httpMethod = method
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do { r.httpBody = try JSONSerialization.data(withJSONObject: body) } catch { throw .http(status: -1, message: "encode") }
        }
        return try await sendRaw(authorized(r))
    }

    /// The same, decoded as a JSON object (camelCase keys, whatever case the server used).
    public func callJSON(_ method: String, _ path: String, json body: Any? = nil) async throws(APIError) -> [String: Any] {
        let data = try await call(method, path, json: body)
        guard !data.isEmpty else { return [:] }
        return (CipherEditor.normalize(try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    // MARK: Organizations and bulk edits

    /// Moves a personal item into an organization (`cipher` re-encrypted with the organization key, see
    /// `CipherEditor.sharedCipher`), into the given collections.
    public func shareCipher(id: String, cipher: [String: Any], collectionIds: [String]) async throws(APIError) {
        var cipher = cipher
        if let owner = cipherOwner { cipher["encryptedFor"] = owner }
        try await call("PUT", "ciphers/\(id)/share", json: ["cipher": cipher, "collectionIds": collectionIds])
    }

    /// Sets which collections an organization item is in.
    public func setCollections(cipherId: String, collectionIds: [String]) async throws(APIError) {
        try await call("PUT", "ciphers/\(cipherId)/collections_v2", json: ["collectionIds": collectionIds])
    }

    /// Moves personal items into a folder (nil: out of any folder).
    public func moveCiphers(ids: [String], folderId: String?) async throws(APIError) {
        try await call("PUT", "ciphers/move", json: ["ids": ids, "folderId": folderId ?? NSNull()] as [String: Any])
    }

    public func trashCiphers(ids: [String]) async throws(APIError) { try await call("PUT", "ciphers/delete", json: ["ids": ids]) }
    public func restoreCiphers(ids: [String]) async throws(APIError) { try await call("PUT", "ciphers/restore", json: ["ids": ids]) }
    public func deleteCiphers(ids: [String]) async throws(APIError) { try await call("DELETE", "ciphers", json: ["ids": ids]) }
    public func archiveCiphers(ids: [String]) async throws(APIError) { try await call("PUT", "ciphers/archive", json: ["ids": ids]) }

    public func leaveOrganization(id: String) async throws(APIError) { try await call("POST", "organizations/\(id)/leave") }

    // MARK: Sends

    /// Changes a Send (body from `SendDraft.seal(userKey:keyMaterial:)` with its own key material; a file Send's file
    /// stays as it is). A nil password keeps the current one.
    public func updateSend(id: String, body: Data) async throws(APIError) {
        guard let object = try? JSONSerialization.jsonObject(with: body) else { throw .http(status: -1, message: "encode") }
        try await call("PUT", "sends/\(id)", json: object)
    }

    public func removeSendPassword(id: String) async throws(APIError) { try await call("PUT", "sends/\(id)/remove-password") }

    // MARK: Account security

    /// The account's public key (base64 SubjectPublicKeyInfo), as the server holds it.
    public func publicKey(userId: String) async throws(APIError) -> String? {
        try await callJSON("GET", "users/\(userId)/public-key")["publicKey"] as? String
    }

    /// Devices signed in to the account.
    public func devices() async throws(APIError) -> [DeviceInfo] {
        let list = try await callJSON("GET", "devices")
        let devices = ((list["data"] ?? list["Data"]) as? [[String: Any]] ?? []).compactMap { DeviceInfo($0, current: deviceIdentifier) }
        // This Mac first, then the most recently active.
        return devices.sorted { a, b in
            a.isCurrent != b.isCurrent ? a.isCurrent : (a.lastActive ?? a.created ?? "") > (b.lastActive ?? b.created ?? "")
        }
    }

    /// Signs out every session (this one too).
    public func deauthorizeSessions(masterPasswordHash: String) async throws(APIError) {
        try await call("POST", "accounts/security-stamp", json: ["masterPasswordHash": masterPasswordHash])
    }

    /// Changes the master password, or the KDF (`changeKDF`): the new login hash and the user key wrapped with the new
    /// master key. Sends both the current shape and the older one (`newMasterPasswordHash`, `key`).
    public func changeMasterPassword(currentHash: String, change: MasterPasswordChange, hint: String?) async throws(APIError) {
        var body = change.body(currentHash: currentHash)
        body["masterPasswordHint"] = hint ?? NSNull()
        try await call("POST", "accounts/password", json: body)
    }

    public func changeKDF(currentHash: String, change: MasterPasswordChange) async throws(APIError) {
        try await call("POST", "accounts/kdf", json: change.body(currentHash: currentHash))
    }

    // MARK: Sign-in requests (log in with device)

    /// Requests from devices waiting for this one to approve their sign-in.
    public func pendingSignIns() async throws(APIError) -> [SignInRequest] {
        (try await callJSON("GET", "auth-requests/pending")["data"] as? [[String: Any]] ?? []).compactMap(SignInRequest.init)
    }

    /// Approves (`key`: the user key wrapped with the request's public key) or denies a request.
    public func answerSignIn(id: String, key: String?, approve: Bool) async throws(APIError) {
        try await call("PUT", "auth-requests/\(id)", json: ["deviceIdentifier": deviceIdentifier, "key": key ?? "",
                                                             "masterPasswordHash": NSNull(), "requestApproved": approve] as [String: Any])
    }

    /// As the device asking: request a sign-in approved from another device. Returns the request id.
    public func requestSignIn(email: String, publicKeySPKI: Data, accessCode: String) async throws(APIError) -> String {
        let answer = try await callJSON("POST", "auth-requests", json: [
            "email": email, "publicKey": publicKeySPKI.base64EncodedString(), "deviceIdentifier": deviceIdentifier,
            "accessCode": accessCode, "type": 0,
        ] as [String: Any])
        guard let id = answer["id"] as? String else { throw .http(status: -1, message: "No request id") }
        return id
    }

    /// As the device asking: the answer so far — the wrapped user key once approved, nil while waiting.
    public func signInResponse(id: String, accessCode: String) async throws(APIError) -> (approved: Bool?, key: String?) {
        let answer = try await callJSON("GET", "auth-requests/\(id)/response?code=\(accessCode)")
        return (answer["requestApproved"] as? Bool, answer["key"] as? String)
    }

    // MARK: Emergency access

    /// People this account trusts (`trusted`), or accounts that trust this one (`granted`).
    public func emergencyContacts(granted: Bool) async throws(APIError) -> [EmergencyContact] {
        (try await callJSON("GET", "emergency-access/\(granted ? "granted" : "trusted")")["data"] as? [[String: Any]] ?? [])
            .compactMap(EmergencyContact.init)
    }

    /// As the invited contact: accepts with the token from the invitation email's link.
    public func acceptEmergencyInvite(id: String, token: String) async throws(APIError) {
        try await call("POST", "emergency-access/\(id)/accept", json: ["token": token])
    }

    public func inviteEmergencyContact(email: String, takeover: Bool, waitDays: Int) async throws(APIError) {
        try await call("POST", "emergency-access/invite", json: ["email": email, "type": takeover ? 1 : 0, "waitTimeDays": waitDays] as [String: Any])
    }

    /// `action`: confirm (with `key`), initiate, approve, reject, delete, reinvite.
    public func emergencyAccess(_ action: String, id: String, key: String? = nil) async throws(APIError) {
        if action == "delete" { try await call("DELETE", "emergency-access/\(id)"); return }
        try await call("POST", "emergency-access/\(id)/\(action)", json: key.map { ["key": $0] })
    }

    /// As the trusted contact, once approved: the other account's items and its user key wrapped for this account.
    public func emergencyView(id: String) async throws(APIError) -> (ciphers: Data, wrappedKey: String?) {
        let data = try await call("POST", "emergency-access/\(id)/view")
        let root = CipherEditor.normalize(try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let ciphers = (try? JSONSerialization.data(withJSONObject: root["ciphers"] ?? [])) ?? Data("[]".utf8)
        return (ciphers, root["keyEncrypted"] as? String)
    }

    /// As the trusted contact, takeover: the other account's KDF and wrapped user key, then its new password.
    public func emergencyTakeover(id: String) async throws(APIError) -> (kdf: KDFConfig, wrappedKey: String?) {
        let a = try await callJSON("POST", "emergency-access/\(id)/takeover")
        let kdf: KDFConfig = (a["kdf"] as? Int) == 1
            ? .argon2id(iterations: a["kdfIterations"] as? Int ?? 3, memoryMiB: a["kdfMemory"] as? Int ?? 64, parallelism: a["kdfParallelism"] as? Int ?? 4)
            : .pbkdf2(iterations: a["kdfIterations"] as? Int ?? 600_000)
        return (kdf, a["keyEncrypted"] as? String)
    }

    public func emergencySetPassword(id: String, change: MasterPasswordChange) async throws(APIError) {
        try await call("POST", "emergency-access/\(id)/password", json: ["newMasterPasswordHash": change.newHash, "key": change.protectedUserKey])
    }

    // MARK: Event logs

    /// An organization's events between two dates, newest first (owners and admins; empty when the server keeps none).
    public func organizationEvents(id: String, start: Date, end: Date) async throws(APIError) -> [OrgEvent] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func q(_ d: Date) -> String { iso.string(from: d).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
        return (try await callJSON("GET", "organizations/\(id)/events?start=\(q(start))&end=\(q(end))")["data"] as? [[String: Any]] ?? [])
            .compactMap(OrgEvent.init)
    }

    /// Member ids to names and emails, for the event log.
    public func organizationMembers(id: String) async throws(APIError) -> [String: String] {
        let list = try await callJSON("GET", "organizations/\(id)/users")["data"] as? [[String: Any]] ?? []
        var out: [String: String] = [:]
        for m in list {
            let label = (m["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? m["email"] as? String ?? ""
            if let user = m["userId"] as? String { out[user] = label }
            if let member = m["id"] as? String { out[member] = label }
        }
        return out
    }

    // MARK: Two-step login

    /// Each provider's type and whether it's on (0 authenticator, 1 email, 7 WebAuthn, 3 YubiKey, 2 Duo…).
    public func twoFactorProviders() async throws(APIError) -> [Int: Bool] {
        let list = try await callJSON("GET", "two-factor")["data"] as? [[String: Any]] ?? []
        return Dictionary(list.compactMap { p in (p["type"] as? Int).map { ($0, p["enabled"] as? Bool ?? false) } }, uniquingKeysWith: { a, _ in a })
    }

    /// A new authenticator secret to scan (or the current one), and whether it's on.
    public func authenticatorSecret(masterPasswordHash: String) async throws(APIError) -> (key: String, enabled: Bool) {
        let answer = try await callJSON("POST", "two-factor/get-authenticator", json: ["masterPasswordHash": masterPasswordHash])
        return (answer["key"] as? String ?? "", answer["enabled"] as? Bool ?? false)
    }

    public func enableAuthenticator(key: String, code: String, masterPasswordHash: String) async throws(APIError) {
        try await call("PUT", "two-factor/authenticator", json: ["key": key, "token": code, "masterPasswordHash": masterPasswordHash])
    }

    public func disableTwoFactor(type: Int, masterPasswordHash: String) async throws(APIError) {
        try await call("PUT", "two-factor/disable", json: ["type": type, "masterPasswordHash": masterPasswordHash] as [String: Any])
    }

    /// The one-time recovery code that turns two-step login off if every method is lost.
    public func twoFactorRecoveryCode(masterPasswordHash: String) async throws(APIError) -> String? {
        try await callJSON("POST", "two-factor/get-recover", json: ["masterPasswordHash": masterPasswordHash])["code"] as? String
    }

    public func emailTwoFactor(masterPasswordHash: String) async throws(APIError) -> (email: String?, enabled: Bool) {
        let answer = try await callJSON("POST", "two-factor/get-email", json: ["masterPasswordHash": masterPasswordHash])
        return (answer["email"] as? String, answer["enabled"] as? Bool ?? false)
    }

    public func sendTwoFactorEmail(to email: String, masterPasswordHash: String) async throws(APIError) {
        try await call("POST", "two-factor/send-email", json: ["email": email, "masterPasswordHash": masterPasswordHash])
    }

    public func enableEmailTwoFactor(email: String, code: String, masterPasswordHash: String) async throws(APIError) {
        try await call("PUT", "two-factor/email", json: ["email": email, "token": code, "masterPasswordHash": masterPasswordHash])
    }
}

/// A new master password or KDF: what the server stores (login hash, user key wrapped with the new master key).
public struct MasterPasswordChange: Sendable {
    public let email: String
    public let kdf: KDFConfig
    public let newHash: String
    public let protectedUserKey: String

    public init(email: String, newPassword: String, kdf: KDFConfig, userKey: SymmetricKeyPair) throws {
        let salt = KDF.normalizedEmail(email)
        let master = try KDF.masterKey(password: newPassword, email: salt, config: kdf)
        self.email = salt
        self.kdf = kdf
        newHash = try KDF.masterPasswordHash(masterKey: master, password: newPassword)
        protectedUserKey = try EncString.encrypt(userKey.encryptionKey + userKey.macKey,
                                                 with: SymmetricKeyPair.stretched(masterKey: master)).description
    }

    var kdfJSON: [String: Any] {
        switch kdf {
        case .pbkdf2(let iterations): ["kdf": 0, "kdfIterations": iterations, "kdfMemory": NSNull(), "kdfParallelism": NSNull()]
        case .argon2id(let iterations, let memory, let parallelism):
            ["kdf": 1, "kdfIterations": iterations, "kdfMemory": memory, "kdfParallelism": parallelism]
        }
    }

    func body(currentHash: String) -> [String: Any] {
        [
            "masterPasswordHash": currentHash,
            "authenticationData": ["salt": email, "kdf": kdfJSON, "masterPasswordAuthenticationHash": newHash] as [String: Any],
            "unlockData": ["salt": email, "kdf": kdfJSON, "masterKeyWrappedUserKey": protectedUserKey] as [String: Any],
            "newMasterPasswordHash": newHash,
            "key": protectedUserKey,
        ]
    }
}

/// A device signed in to the account.
public struct DeviceInfo: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    /// Bitwarden's device type: 7 macOS desktop, 9 Chrome, 14 web vault, 0 Android, 1 iOS…
    public let type: Int
    public let identifier: String
    public let created: String?
    public let lastActive: String?
    /// This app's own sign-in (the device identifier it logs in with).
    public let isCurrent: Bool

    init?(_ d: [String: Any], current: String = "") {
        guard let id = (d["id"] ?? d["Id"]).map({ "\($0)" }), !id.isEmpty else { return nil }
        self.id = id
        name = d["name"] as? String ?? ""
        type = d["type"] as? Int ?? -1
        identifier = d["identifier"] as? String ?? ""
        created = d["creationDate"] as? String
        lastActive = (d["lastActivityDate"] ?? d["revisionDate"]) as? String
        isCurrent = !current.isEmpty && identifier.caseInsensitiveCompare(current) == .orderedSame
    }

    /// What it is, the way Bitwarden's web vault says it: "Desktop - macOS", "Web app - Chrome", "Extension - Safari".
    public var title: String {
        switch type {
        case 0: "Mobile - Android"
        case 1: "Mobile - iOS"
        case 15: "Mobile - Android (Amazon)"
        case 2: "Extension - Chrome"
        case 3: "Extension - Firefox"
        case 4: "Extension - Opera"
        case 5: "Extension - Edge"
        case 19: "Extension - Vivaldi"
        case 20: "Extension - Safari"
        case 6: "Desktop - Windows"
        case 7: "Desktop - macOS"
        case 8: "Desktop - Linux"
        case 16: "Desktop - Windows (UWP)"
        case 9: "Web app - Chrome"
        case 10: "Web app - Firefox"
        case 11: "Web app - Opera"
        case 12: "Web app - Edge"
        case 13: "Web app - Internet Explorer"
        case 14: "Web app"
        case 17: "Web app - Safari"
        case 18: "Web app - Vivaldi"
        case 21: "SDK"
        case 22: "Server"
        case 23: "CLI - Windows"
        case 24: "CLI - macOS"
        case 25: "CLI - Linux"
        default: name.isEmpty ? "Unknown device" : name
        }
    }

    /// A short kind, for an icon and a label.
    public var kind: String {
        switch type {
        case 0, 15: "android"
        case 1: "ios"
        case 6, 7, 8, 16: "desktop"
        case 2, 3, 4, 5, 19, 20: "extension"
        case 9, 10, 11, 12, 13, 14, 17, 18: "browser"
        case 21...25: "cli"
        default: "other"
        }
    }
}

/// Another device asking to sign in without the master password.
public struct SignInRequest: Sendable, Identifiable, Hashable {
    public let id: String
    /// Base64 SubjectPublicKeyInfo of the asking device.
    public let publicKey: String
    public let deviceType: String
    public let ipAddress: String
    public let created: String?

    init?(_ d: [String: Any]) {
        guard let id = d["id"] as? String, let key = d["publicKey"] as? String else { return nil }
        self.id = id
        publicKey = key
        deviceType = d["requestDeviceType"] as? String ?? ""
        ipAddress = d["requestIpAddress"] as? String ?? ""
        created = d["creationDate"] as? String
    }
}

/// One emergency-access relationship, from either side.
public struct EmergencyContact: Sendable, Identifiable, Hashable {
    public enum Status: Int, Sendable { case invited = 0, accepted, confirmed, recoveryInitiated, recoveryApproved }
    public let id: String
    public let status: Status
    /// Takeover (a new master password) rather than view-only.
    public let takeover: Bool
    public let waitDays: Int
    /// The other person's user id (grantee on the trusted side, grantor on the granted side).
    public let userId: String?
    public let email: String
    public let name: String?

    init?(_ d: [String: Any]) {
        guard let id = (d["id"] ?? d["Id"]).map({ "\($0)" }), !id.isEmpty else { return nil }
        self.id = id
        status = Status(rawValue: d["status"] as? Int ?? 0) ?? .invited
        takeover = (d["type"] as? Int) == 1
        waitDays = d["waitTimeDays"] as? Int ?? 7
        userId = (d["granteeId"] ?? d["grantorId"]) as? String
        email = d["email"] as? String ?? ""
        name = d["name"] as? String
    }
}

/// One entry in an organization's event log.
public struct OrgEvent: Sendable, Identifiable, Hashable {
    public let id = UUID()
    public let type: Int
    public let actingUserId: String?
    public let memberId: String?
    public let cipherId: String?
    public let collectionId: String?
    public let date: String
    public let ipAddress: String?
    public let deviceType: Int?

    init?(_ d: [String: Any]) {
        guard let type = d["type"] as? Int, let date = d["date"] as? String else { return nil }
        self.type = type
        actingUserId = (d["actingUserId"] ?? d["userId"]) as? String
        memberId = d["organizationUserId"] as? String
        cipherId = d["cipherId"] as? String
        collectionId = d["collectionId"] as? String
        self.date = date
        ipAddress = d["ipAddress"] as? String
        deviceType = d["deviceType"] as? Int
    }
}
