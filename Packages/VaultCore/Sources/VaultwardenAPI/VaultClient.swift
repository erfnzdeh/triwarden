import CryptoKit
import TriCrypto
import Foundation

/// Minimal Bitwarden-protocol client (Vaultwarden or the official cloud): prelogin, password login, sync.
public actor VaultClient {
    public nonisolated let environment: ServerEnvironment
    private let session: URLSession
    let deviceIdentifier: String
    private let extraHeaders: [String: String]
    private var accessToken: String?
    private var refreshToken: String?

    /// Identifies us to the server. The official cloud gates features on known client names.
    static let clientName = "desktop"
    static let clientVersion = "2026.9.0"

    /// - Parameter extraHeaders: sent on every request, e.g. Cloudflare Access service tokens.
    public init(environment: ServerEnvironment, deviceIdentifier: String, extraHeaders: [String: String] = [:],
                session: URLSession = .shared) {
        self.environment = environment
        self.deviceIdentifier = deviceIdentifier
        self.extraHeaders = extraHeaders
        self.session = session
    }

    // MARK: Login

    public func prelogin(email: String) async throws(APIError) -> PreloginResponse {
        let body = try json(["email": KDF.normalizedEmail(email)])
        // Newest servers: identity/accounts/prelogin/password. Cloud and recent Vaultwarden:
        // identity/accounts/prelogin. Older Vaultwarden only has api/accounts/prelogin.
        let candidates = [
            (environment.identityURL, "accounts/prelogin/password"),
            (environment.identityURL, "accounts/prelogin"),
            (environment.apiURL, "accounts/prelogin"),
        ]
        var lastError = APIError.invalidServerURL
        for (base, path) in candidates {
            do {
                return try await send(post(base, path, jsonBody: body))
            } catch .http(let status, let message) where status == 404 || status == 405 {
                lastError = .http(status: status, message: message)
            }
        }
        throw lastError
    }

    /// Everything needed to unlock later without the network (all of it is safe at rest except `refreshToken`,
    /// which belongs in the Keychain).
    public struct LoginResult: Sendable {
        public let userKey: SymmetricKeyPair
        public let protectedUserKey: String
        public let kdf: KDFConfig
        public let refreshToken: String?
    }

    /// Restores a session from a stored refresh token (no password needed).
    public func restore(refreshToken: String) { self.refreshToken = refreshToken }

    /// Exchanges the refresh token for a new access token. Returns the (possibly rotated) refresh token.
    @discardableResult
    public func refreshAccessToken() async throws(APIError) -> String {
        guard let refreshToken else { throw .http(status: 401, message: "No session") }
        let token: TokenResponse = try await send(post(environment.identityURL, "connect/token", formBody: [
            "grant_type": "refresh_token", "client_id": Self.clientName, "refresh_token": refreshToken,
        ]))
        accessToken = token.accessToken
        if let rotated = token.refreshToken { self.refreshToken = rotated }
        return self.refreshToken ?? refreshToken
    }

    /// Logs in and returns the decrypted user key.
    ///
    /// - Parameters:
    ///   - twoFactor: provider id ("0" = authenticator app) and code, after a `.twoFactorRequired` error.
    ///   - newDeviceOTP: emailed code, after a `.newDeviceVerificationRequired` error (official cloud).
    public func login(email: String, password: String,
                      twoFactor: (provider: String, token: String)? = nil,
                      newDeviceOTP: String? = nil) async throws(APIError) -> SymmetricKeyPair {
        try await loginDetailed(email: email, password: password, twoFactor: twoFactor, newDeviceOTP: newDeviceOTP).userKey
    }

    public func loginDetailed(email: String, password: String,
                              twoFactor: (provider: String, token: String)? = nil,
                              newDeviceOTP: String? = nil) async throws(APIError) -> LoginResult {
        let config = try await prelogin(email: email).config()
        do {
            let masterKey = try KDF.masterKey(password: password, email: email, config: config)
            var form = [
                "grant_type": "password",
                "username": KDF.normalizedEmail(email),
                "password": try KDF.masterPasswordHash(masterKey: masterKey, password: password),
                "scope": "api offline_access",
                "client_id": Self.clientName,
                "deviceType": "7", // macOS desktop
                "deviceIdentifier": deviceIdentifier,
                "deviceName": "triwarden",
            ]
            if let twoFactor {
                form["twoFactorProvider"] = twoFactor.provider
                form["twoFactorToken"] = twoFactor.token
                form["twoFactorRemember"] = "0"
            }
            if let newDeviceOTP { form["newDeviceOtp"] = newDeviceOTP }
            var request = try post(environment.identityURL, "connect/token", formBody: form)
            // The cloud requires the login email echoed as base64url.
            request.setValue(Data(KDF.normalizedEmail(email).utf8).base64URLEncoded, forHTTPHeaderField: "Auth-Email")
            let token: TokenResponse = try await send(request)
            accessToken = token.accessToken
            refreshToken = token.refreshToken
            guard let protected = token.key else { throw APIError.missingUserKey }
            let stretched = try SymmetricKeyPair.stretched(masterKey: masterKey)
            let userKey = try SymmetricKeyPair(combined: EncString(protected).decrypt(with: stretched))
            return LoginResult(userKey: userKey, protectedUserKey: protected, kdf: config, refreshToken: token.refreshToken)
        } catch let error as CryptoError {
            throw .crypto(error)
        } catch let error as APIError {
            throw error
        } catch {
            throw .http(status: -1, message: error.localizedDescription)
        }
    }

    /// Finishes "log in with device": once another device approved the request, sign in with its access code. The
    /// user key itself came wrapped in the approval; the answer carries the master-password-wrapped copy for later
    /// unlocks, and the tokens.
    public func loginWithApprovedRequest(email: String, requestId: String, accessCode: String) async throws(APIError)
        -> (protectedUserKey: String, kdf: KDFConfig, refreshToken: String?) {
        let config = try await prelogin(email: email).config()
        let form = [
            "grant_type": "password", "username": KDF.normalizedEmail(email), "password": accessCode,
            "authRequest": requestId, "scope": "api offline_access", "client_id": Self.clientName,
            "deviceType": "7", "deviceIdentifier": deviceIdentifier, "deviceName": "triwarden",
        ]
        var request = try post(environment.identityURL, "connect/token", formBody: form)
        request.setValue(Data(KDF.normalizedEmail(email).utf8).base64URLEncoded, forHTTPHeaderField: "Auth-Email")
        let token: TokenResponse = try await send(request)
        accessToken = token.accessToken
        refreshToken = token.refreshToken
        guard let protected = token.key else { throw .missingUserKey }
        return (protected, config, token.refreshToken)
    }

    // MARK: Single sign-on (OpenID Connect)

    /// The redirect the server accepts for `client_id=desktop`; ASWebAuthenticationSession catches the
    /// `bitwarden` scheme for this session only, so it never clashes with an installed Bitwarden app.
    public static let ssoRedirectURI = "bitwarden://sso-callback"

    public struct SSOStart: Sendable {
        public let authorizeURL: URL
        public let state: String
        let verifier: String
    }

    /// After SSO the vault still needs the master password (Vaultwarden has no trusted-device or
    /// Key Connector decryption): finish with `unlockSSO`.
    public struct SSOSession: Sendable {
        public let email: String
        public let kdf: KDFConfig
        public let protectedUserKey: String
        public let refreshToken: String?
    }

    /// Step 1: ask the server for an SSO token and build the browser URL (PKCE S256).
    public func beginSSO(identifier: String) async throws(APIError) -> SSOStart {
        struct Prevalidated: Decodable { let token: String }
        var components = URLComponents(url: environment.identityURL.appending(path: "sso/prevalidate"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "domainHint", value: identifier)]
        guard let prevalidateURL = components.url else { throw .invalidServerURL }
        var r = try request(environment.identityURL, "sso/prevalidate")
        r.url = prevalidateURL
        let prevalidated: Prevalidated = try await send(r)

        let verifier = Self.randomURLSafe(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = Self.randomURLSafe(32)
        var authorize = URLComponents(url: environment.identityURL.appending(path: "connect/authorize"), resolvingAgainstBaseURL: false)!
        authorize.queryItems = [
            .init(name: "client_id", value: Self.clientName), .init(name: "redirect_uri", value: Self.ssoRedirectURI),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: "api offline_access"),
            .init(name: "state", value: state), .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "response_mode", value: "query"),
            .init(name: "domain_hint", value: identifier), .init(name: "ssoToken", value: prevalidated.token),
        ]
        guard let url = authorize.url else { throw .invalidServerURL }
        return SSOStart(authorizeURL: url, state: state, verifier: verifier)
    }

    /// Step 2: exchange the callback's code for tokens.
    public func finishSSO(callback: URL, start: SSOStart) async throws(APIError) -> SSOSession {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == start.state else {
            throw .http(status: 400, message: "Single sign-on was interrupted (state mismatch). Try again.")
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            let reason = items.first { $0.name == "error_description" || $0.name == "error" }?.value
            throw .http(status: 400, message: reason ?? "Single sign-on was cancelled.")
        }
        struct Token: Decodable {
            let access_token: String
            let refresh_token: String?
            // PascalCase on the wire; the decoder lower-cases the first letter.
            let key: String?
            let kdf: Int?
            let kdfIterations: Int?
            let kdfMemory: Int?
            let kdfParallelism: Int?
        }
        let token: Token = try await send(post(environment.identityURL, "connect/token", formBody: [
            "grant_type": "authorization_code", "code": code, "code_verifier": start.verifier,
            "redirect_uri": Self.ssoRedirectURI, "client_id": Self.clientName, "scope": "api offline_access",
            "deviceType": "7", "deviceIdentifier": deviceIdentifier, "deviceName": "triwarden",
        ]))
        accessToken = token.access_token
        refreshToken = token.refresh_token
        guard let email = Self.jwtClaim("email", token.access_token) else {
            throw .http(status: -1, message: "The server's token has no email address.")
        }
        guard let key = token.key else {
            throw .http(status: 400, message: "This account has no master password yet. Set one in the web vault, then try again.")
        }
        let kdf: KDFConfig
        switch token.kdf {
        case 1?: kdf = .argon2id(iterations: token.kdfIterations ?? 3, memoryMiB: token.kdfMemory ?? 64, parallelism: token.kdfParallelism ?? 4)
        default: kdf = .pbkdf2(iterations: token.kdfIterations ?? 600_000)
        }
        do { try kdf.validate() } catch { throw .crypto(error) }
        return SSOSession(email: email, kdf: kdf, protectedUserKey: key, refreshToken: token.refresh_token)
    }

    /// Step 3: the master password decrypts the user key (offline; nothing is sent).
    public nonisolated func unlockSSO(_ session: SSOSession, password: String) throws(APIError) -> SymmetricKeyPair {
        do {
            let masterKey = try KDF.masterKey(password: password, email: session.email, config: session.kdf)
            let stretched = try SymmetricKeyPair.stretched(masterKey: masterKey)
            return try SymmetricKeyPair(combined: EncString(session.protectedUserKey).decrypt(with: stretched))
        } catch .macMismatch {
            throw .http(status: 400, message: "Wrong master password.")
        } catch {
            throw .crypto(error)
        }
    }

    static func randomURLSafe(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64URLEncoded
    }

    static func jwtClaim(_ name: String, _ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2, let payload = Data(base64URL: String(parts[1])),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        return object[name] as? String
    }

    /// Current bearer token (for the notifications hub).
    public var currentAccessToken: String? { accessToken }

    /// Creates a folder (name must already be encrypted) and returns its id. Used by tests to trigger
    /// a server-side change notification.
    public func createFolder(encryptedName: String) async throws(APIError) -> String {
        struct Folder: Decodable { let id: String }
        var r = try post(environment.apiURL, "folders", jsonBody: json(["name": encryptedName]))
        if let accessToken { r.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        let folder: Folder = try await send(r)
        return folder.id
    }

    /// Renames a folder (the name already encrypted).
    public func renameFolder(id: String, encryptedName: String) async throws(APIError) {
        var r = try post(environment.apiURL, "folders/\(id)", jsonBody: json(["name": encryptedName]))
        r.httpMethod = "PUT"
        _ = try await sendRaw(authorized(r))
    }

    public func deleteFolder(id: String) async throws(APIError) {
        var r = try request(environment.apiURL, "folders/\(id)")
        r.httpMethod = "DELETE"
        if let accessToken { r.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        _ = try await sendRaw(r)
    }

    // MARK: Item writes

    func authorized(_ r: URLRequest) -> URLRequest {
        var r = r
        if let accessToken { r.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        return r
    }

    /// Creates a personal item from `CipherEditor.newCipher`. Returns the new id.
    public func createCipher(_ body: Data) async throws(APIError) -> String {
        struct Created: Decodable { let id: String }
        let created: Created = try await send(authorized(post(environment.apiURL, "ciphers", jsonBody: body)))
        return created.id
    }

    /// Creates a collection-owned item directly, without first saving a personal copy.
    public func createOrganizationCipher(_ body: Data, collectionIds: [String]) async throws(APIError) -> String {
        struct Created: Decodable { let id: String }
        do {
            let cipher = try JSONSerialization.jsonObject(with: body)
            let wrapped = try JSONSerialization.data(withJSONObject: ["cipher": cipher, "collectionIds": collectionIds])
            let created: Created = try await send(authorized(post(environment.apiURL, "ciphers/create", jsonBody: wrapped)))
            return created.id
        } catch let error as APIError { throw error }
        catch { throw .http(status: -1, message: "Malformed organization cipher") }
    }

    /// Imports many personal items at once (body from `VaultImport.requestBody`): ciphers, folders,
    /// and which folder each cipher goes in. All fields are already encrypted.
    public func importCiphers(_ body: Data) async throws(APIError) {
        _ = try await sendRaw(authorized(post(environment.apiURL, "ciphers/import", jsonBody: body)))
    }

    /// Imports into an organization (body from `VaultImport.organizationRequestBody`): ciphers and collections,
    /// encrypted with the organization key.
    public func importOrganizationCiphers(_ body: Data, organizationId: String) async throws(APIError) {
        let id = organizationId.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(["-"])) ?? organizationId
        _ = try await sendRaw(authorized(post(environment.apiURL, "ciphers/import-organization?organizationId=\(id)", jsonBody: body)))
    }

    /// Replaces an item with a body from `CipherEditor.updatedCipher`.
    public func updateCipher(id: String, _ body: Data) async throws(APIError) {
        var r = try post(environment.apiURL, "ciphers/\(id)", jsonBody: body)
        r.httpMethod = "PUT"
        _ = try await sendRaw(authorized(r))
    }

    /// Archives an item: kept in the vault, left out of search and AutoFill (Bitwarden 2026.2+, Vaultwarden 1.36+;
    /// on Bitwarden's cloud a paid plan).
    public func archiveCipher(id: String) async throws(APIError) {
        var r = try request(environment.apiURL, "ciphers/\(id)/archive")
        r.httpMethod = "PUT"
        _ = try await sendRaw(authorized(r))
    }

    public func unarchiveCipher(id: String) async throws(APIError) {
        var r = try request(environment.apiURL, "ciphers/\(id)/unarchive")
        r.httpMethod = "PUT"
        _ = try await sendRaw(authorized(r))
    }

    /// Moves to Trash (restorable).
    public func trashCipher(id: String) async throws(APIError) {
        var r = try request(environment.apiURL, "ciphers/\(id)/delete")
        r.httpMethod = "PUT"
        _ = try await sendRaw(authorized(r))
    }

    public func restoreCipher(id: String) async throws(APIError) {
        var r = try request(environment.apiURL, "ciphers/\(id)/restore")
        r.httpMethod = "PUT"
        _ = try await sendRaw(authorized(r))
    }

    /// Permanently deletes.
    public func deleteCipher(id: String) async throws(APIError) {
        var r = try request(environment.apiURL, "ciphers/\(id)")
        r.httpMethod = "DELETE"
        _ = try await sendRaw(authorized(r))
    }

    // MARK: Attachments

    /// Downloads an attachment's encrypted bytes. Asks the server for a fresh URL (cloud URLs are
    /// short-lived signed links), falling back to the one from sync on servers without that endpoint.
    public func downloadAttachment(cipherId: String, attachmentId: String, syncedURL: String?) async throws(APIError) -> Data {
        struct Located: Decodable { let url: String? }
        var location = syncedURL
        if let fresh: Located = try? await send(authorized(request(environment.apiURL, "ciphers/\(cipherId)/attachment/\(attachmentId)"))),
           let url = fresh.url {
            location = url
        }
        guard let location else { throw .http(status: 404, message: "Attachment not found") }
        return try await fetchLink(location)
    }

    /// Downloads a server-issued file link (attachment, Send file). Our own server's access headers go only
    /// to our own host. Vaultwarden builds links from its DOMAIN setting, which can differ from the address
    /// we reach it by (LAN IP, VPN name), so a failing self-hosted link is retried on the server we use.
    func fetchLink(_ location: String) async throws(APIError) -> Data {
        guard let url = URL(string: location, relativeTo: environment.apiURL.appendingSlash) else { throw .invalidServerURL }
        func fetch(_ url: URL) async throws(APIError) -> Data {
            var r = URLRequest(url: url.absoluteURL)
            if url.host() == environment.apiURL.host() { for (k, v) in extraHeaders { r.setValue(v, forHTTPHeaderField: k) } }
            return try await sendRaw(r)
        }
        do {
            return try await fetch(url)
        } catch {
            guard !environment.isOfficialCloud, url.host() != environment.apiURL.host(),
                  var parts = URLComponents(url: environment.apiURL.deletingLastPathComponent(), resolvingAgainstBaseURL: true)
            else { throw error }
            let base = parts.path.hasSuffix("/") ? String(parts.path.dropLast()) : parts.path
            let linkPath = url.path()
            parts.percentEncodedPath = linkPath.hasPrefix(base) ? linkPath : base + linkPath
            parts.percentEncodedQuery = url.query(percentEncoded: true)
            guard let local = parts.url else { throw error }
            return try await fetch(local)
        }
    }

    /// Uploads an already-encrypted file. `fileName` and `key` are EncStrings under the item key.
    /// Returns the new attachment id.
    @discardableResult
    public func uploadAttachment(cipherId: String, fileName: String, key: String, encrypted: Data) async throws(APIError) -> String {
        struct Slot: Decodable { let attachmentId: String; let url: String?; let fileUploadType: Int? }
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: [
                "key": key, "fileName": fileName, "fileSize": encrypted.count, "adminRequest": false,
            ])
        } catch { throw .http(status: -1, message: "encode") }
        let slot: Slot
        do {
            slot = try await send(authorized(post(environment.apiURL, "ciphers/\(cipherId)/attachment/v2", jsonBody: body)))
        } catch .http(let status, _) where status == 404 || status == 405 {
            // Servers without v2: one multipart POST with the key alongside.
            struct Legacy: Decodable { let attachments: [SyncResponse.Attachment]? }
            let r = try multipart(environment.apiURL, "ciphers/\(cipherId)/attachment", fileName: fileName, key: key, data: encrypted)
            let cipher: Legacy = try await send(authorized(r))
            return cipher.attachments?.last?.id ?? ""
        }
        if slot.fileUploadType == 1, let url = slot.url.flatMap(URL.init(string:)) {
            // Azure blob storage (Bitwarden cloud).
            var r = URLRequest(url: url)
            r.httpMethod = "PUT"
            r.setValue("BlockBlob", forHTTPHeaderField: "x-ms-blob-type")
            r.setValue("2020-04-08", forHTTPHeaderField: "x-ms-version")
            r.httpBody = encrypted
            _ = try await sendRaw(r)
        } else {
            let r = try multipart(environment.apiURL, "ciphers/\(cipherId)/attachment/\(slot.attachmentId)",
                                  fileName: fileName, key: nil, data: encrypted)
            _ = try await sendRaw(authorized(r))
        }
        return slot.attachmentId
    }

    public func deleteAttachment(cipherId: String, attachmentId: String) async throws(APIError) {
        var r = try request(environment.apiURL, "ciphers/\(cipherId)/attachment/\(attachmentId)")
        r.httpMethod = "DELETE"
        _ = try await sendRaw(authorized(r))
    }

    private func multipart(_ base: URL, _ path: String, fileName: String, key: String?, data: Data) throws(APIError) -> URLRequest {
        var r = try request(base, path)
        r.httpMethod = "POST"
        let boundary = "triwarden-\(UUID().uuidString)"
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        if let key {
            body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"key\"\r\n\r\n\(key)\r\n".utf8)
        }
        body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"data\"; filename=\"\(fileName)\"\r\n".utf8)
        body += Data("Content-Type: application/octet-stream\r\n\r\n".utf8) + data + Data("\r\n--\(boundary)--\r\n".utf8)
        r.httpBody = body
        return r
    }

    // MARK: Send

    /// Creates a Send from `SendDraft.seal`. File Sends upload their encrypted contents too.
    public func createSend(_ sealed: SendDraft.Sealed) async throws(APIError) -> SendResponse {
        guard let file = sealed.encryptedFile else {
            return try await send(authorized(post(environment.apiURL, "sends", jsonBody: sealed.body)))
        }
        struct Slot: Decodable { let url: String?; let fileUploadType: Int?; let sendResponse: SendResponse }
        let slot: Slot = try await send(authorized(post(environment.apiURL, "sends/file/v2", jsonBody: sealed.body)))
        guard let fileId = slot.sendResponse.file?.id else { throw .http(status: -1, message: "Missing file id") }
        if slot.fileUploadType == 1, let url = slot.url.flatMap(URL.init(string:)) {
            var r = URLRequest(url: url)
            r.httpMethod = "PUT"
            r.setValue("BlockBlob", forHTTPHeaderField: "x-ms-blob-type")
            r.setValue("2020-04-08", forHTTPHeaderField: "x-ms-version")
            r.httpBody = file
            _ = try await sendRaw(r)
        } else {
            let fileName = (slot.sendResponse.file?.fileName) ?? "file"
            let r = try multipart(environment.apiURL, "sends/\(slot.sendResponse.id)/file/\(fileId)", fileName: fileName, key: nil, data: file)
            _ = try await sendRaw(authorized(r))
        }
        return slot.sendResponse
    }

    public func deleteSend(id: String) async throws(APIError) {
        var r = try request(environment.apiURL, "sends/\(id)")
        r.httpMethod = "DELETE"
        _ = try await sendRaw(authorized(r))
    }

    /// Opens a Send the way a recipient does (no account). `passwordHash` from `SendCrypto.passwordHash`.
    public func accessSend(accessId: String, passwordHash: String? = nil) async throws(APIError) -> SendResponse {
        let body: Data
        do { body = try JSONSerialization.data(withJSONObject: passwordHash.map { ["password": $0] } ?? [:]) } catch {
            throw .http(status: -1, message: "encode")
        }
        return try await send(post(environment.apiURL, "sends/access/\(accessId)", jsonBody: body))
    }

    /// Downloads a file Send's encrypted contents as a recipient.
    public func accessSendFile(sendId: String, fileId: String, passwordHash: String? = nil) async throws(APIError) -> Data {
        struct Located: Decodable { let url: String }
        let body: Data
        do { body = try JSONSerialization.data(withJSONObject: passwordHash.map { ["password": $0] } ?? [:]) } catch {
            throw .http(status: -1, message: "encode")
        }
        let located: Located = try await send(post(environment.apiURL, "sends/\(sendId)/access/file/\(fileId)", jsonBody: body))
        return try await fetchLink(located.url)
    }

    // MARK: Password hint

    /// Asks the server to email the master password hint. Vaultwarden without mail configured may
    /// return the hint directly; that hint is returned here, otherwise `nil` (sent by email).
    public func requestPasswordHint(email: String) async throws(APIError) -> String? {
        let body = try json(["email": KDF.normalizedEmail(email)])
        do {
            let _: EmptyResponse = try await send(post(environment.apiURL, "accounts/password-hint", jsonBody: body))
            return nil
        } catch .http(_, let message?) where message.hasPrefix("Your password hint is: ") {
            return String(message.dropFirst("Your password hint is: ".count))
        }
    }

    // MARK: Server

    public func config() async throws(APIError) -> ServerConfig {
        try await send(request(environment.apiURL, "config"))
    }

    // MARK: Sync

    /// One item as the sync payload lists it (with its folder, favorite and collections for this user).
    /// Throws 404 once it's gone, or no longer shared with this account.
    public func cipherData(id: String) async throws(APIError) -> Data {
        try await sendRaw(authorized(request(environment.apiURL, "ciphers/\(id)/details")))
    }

    /// When the account's vault last changed (milliseconds since 1970, as the server counts them). A cheap way to
    /// tell whether a full sync would bring anything new.
    public func revisionDate() async throws(APIError) -> String {
        let data = try await sendRaw(authorized(request(environment.apiURL, "accounts/revision-date")))
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func sync() async throws(APIError) -> SyncResponse {
        try SyncResponse.decode(await syncData())
    }

    /// Raw sync payload — every secret in it is already encrypted, so it can be cached as-is.
    public func syncData() async throws(APIError) -> Data {
        var request = try request(environment.apiURL, "sync?excludeDomains=false")
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        return try await sendRaw(request)
    }

    // MARK: Plumbing

    func request(_ base: URL, _ path: String) throws(APIError) -> URLRequest {
        guard let url = URL(string: path, relativeTo: base.appendingSlash) else { throw .invalidServerURL }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.clientName, forHTTPHeaderField: "Bitwarden-Client-Name")
        request.setValue(Self.clientVersion, forHTTPHeaderField: "Bitwarden-Client-Version")
        request.setValue("7", forHTTPHeaderField: "Device-Type")
        request.setValue("Triwarden/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
        for (k, v) in extraHeaders { request.setValue(v, forHTTPHeaderField: k) }
        return request
    }

    private func post(_ base: URL, _ path: String, jsonBody: Data) throws(APIError) -> URLRequest {
        var r = try request(base, path)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = jsonBody
        return r
    }

    private func post(_ base: URL, _ path: String, formBody: [String: String]) throws(APIError) -> URLRequest {
        var r = try request(base, path)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        // RFC 3986 unreserved set only — `.alphanumerics` would let non-ASCII letters through unencoded.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        r.httpBody = formBody
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        return r
    }

    private func json(_ object: [String: String]) throws(APIError) -> Data {
        do { return try JSONEncoder().encode(object) } catch { throw .http(status: -1, message: "encode") }
    }

    func sendRaw(_ request: URLRequest) async throws(APIError) -> Data {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            throw .http(status: -1, message: error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else { throw APIError.from(status: status, body: data, decoder: .vaultwarden) }
        return data
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws(APIError) -> T {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            throw .http(status: -1, message: error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let decoder = JSONDecoder.vaultwarden
        guard (200..<300).contains(status) else {
            throw APIError.from(status: status, body: data, decoder: decoder)
        }
        if T.self == EmptyResponse.self { return EmptyResponse() as! T }
        do { return try decoder.decode(T.self, from: data) } catch {
            throw .http(status: status, message: "Unexpected response: \(error)")
        }
    }
}

struct EmptyResponse: Decodable {}

extension APIError {
    /// Maps an error body to a typed error; login challenges arrive as 400s with distinctive fields.
    static func from(status: Int, body: Data, decoder: JSONDecoder) -> APIError {
        let err = try? decoder.decode(TokenErrorResponse.self, from: body)
        if let providers = err?.twoFactorProviders, !providers.isEmpty {
            return .twoFactorRequired(providers: providers)
        }
        let text = String(decoding: body, as: UTF8.self).lowercased()
        if text.contains("new device verification required") || text.contains("device_error") {
            return .newDeviceVerificationRequired
        }
        if text.contains("hcaptcha_sitekey") || text.contains("captcha required") {
            return .captchaRequired
        }
        let description = [err?.errorDescription, err?.message, err?.error].compactMap { $0 }.first { !$0.isEmpty }
        return .http(status: status, message: description)
    }
}

extension JSONDecoder {
    /// Vaultwarden returns camelCase on newer versions and PascalCase on older ones.
    static var vaultwarden: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .custom { keys in
            let key = keys.last!.stringValue
            guard let first = key.first, !key.contains("_") else { return keys.last! }
            return AnyKey(first.lowercased() + key.dropFirst())
        }
        return d
    }
}

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension URL {
    var appendingSlash: URL {
        absoluteString.hasSuffix("/") ? self : URL(string: absoluteString + "/") ?? self
    }
}

