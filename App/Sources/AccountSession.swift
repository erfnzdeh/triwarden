import TriCrypto
import Foundation
import Observation
import VaultwardenAPI

/// One unlocked account: its key, decrypted vault, server connection and live sync.
@MainActor @Observable
final class AccountSession {
    private(set) var account: SavedAccount
    private(set) var items: [VaultItem] = []
    private(set) var folders: [Grouping] = []
    private(set) var organizations: [Grouping] = []
    private(set) var sends: [SendItem] = []
    private(set) var hiddenCount = 0
    /// Sites that share sign-ins, from the server's domain rules.
    private(set) var equivalents = EquivalentDomains.none
    private(set) var lastSynced: Date?
    private(set) var isSyncing = false
    /// Set when a sync retry fails. Cleared on the next successful sync.
    private(set) var lastSyncError: String?

    private let userKey: SymmetricKeyPair
    private(set) var client: VaultClient?
    private var rawCiphers: [String: Data] = [:]
    /// The sync payload as last saved (every secret still encrypted), and the parts of it read often.
    private var payload = Data()
    private var cipherIndex: [String: SyncResponse.Cipher] = [:]
    private var profile: SyncResponse.Profile?
    /// The server's revision date at the last sync or one-item update: while it's the same, there's nothing new.
    private var knownRevision: String?
    /// Items live notifications named, waiting for the debounce; or a full sync, when one said something else.
    private var pendingIDs: Set<String> = []
    private var pendingFull = false
    private var keyring: Keyring?
    private var live: LiveSync?
    private var debounce: Task<Void, Never>?
    private var periodic: Timer?
    private let makeClient: (ServerEnvironment) -> VaultClient
    private let makeSession: () -> URLSession
    /// Called whenever items change, so the app can merge and republish.
    var onChange: () -> Void = {}

    var id: String { account.id }

    init(account: SavedAccount, userKey: SymmetricKeyPair, client: VaultClient? = nil,
         makeClient: @escaping (ServerEnvironment) -> VaultClient, makeSession: @escaping () -> URLSession) {
        self.account = account
        self.userKey = userKey
        self.client = client
        self.makeClient = makeClient
        self.makeSession = makeSession
        if let cache = AccountStore.loadCache(account.id) { try? load(cache) }
    }

    var environment: ServerEnvironment? { account.environment }

    // MARK: Sync

    /// Pulls the whole vault, caches the (still encrypted) payload, rebuilds, then listens for live changes.
    func refresh() async throws {
        guard let client else { return }
        isSyncing = true
        defer { isSyncing = false }
        // Asked first: a change landing during the sync then shows up as a newer revision next time.
        let revision = try? await client.revisionDate()
        let data = try await client.syncData()
        AccountStore.saveCache(data, account.id)
        try load(data)
        knownRevision = revision
        lastSynced = .now
        lastSyncError = nil
        await startLiveSync()
    }

    /// Brings just these items up to date: each is fetched on its own and put into the cached payload, and only they
    /// are decrypted again. `removed`: items deleted for good, dropped without asking. Falls back to a full sync for
    /// many items, or if anything goes wrong (an item gone or out of reach, say), so the vault never ends up stale.
    func reload(_ ids: Set<String>, removed: Set<String> = []) async throws {
        guard let client else { throw WriteError.offline }
        guard !ids.isEmpty || !removed.isEmpty else { return }
        guard ids.count <= 20, !payload.isEmpty else { try await refresh(); return }
        do {
            let revision = try await client.revisionDate()
            var changes: [String: Data?] = [:]
            for id in removed { changes.updateValue(nil, forKey: id) }
            for id in ids where !removed.contains(id) { changes[id] = try await client.cipherData(id: id) }
            guard let data = SyncPayload.replacingCiphers(in: payload, with: changes) else { throw WriteError.offline }
            try load(data, changed: ids.union(removed))
            AccountStore.saveCache(data, account.id)
            knownRevision = revision
            lastSynced = .now
            lastSyncError = nil
        } catch {
            try await refresh()
        }
    }

    /// A full sync only if the server's revision moved since the last one (switching back to the app, the timer).
    private func syncIfChanged() async throws {
        guard let client else { return }
        if let known = knownRevision, let now = try? await client.revisionDate(), now == known {
            lastSynced = .now
            lastSyncError = nil
            await startLiveSync()
            return
        }
        try await refresh()
    }

    /// Reconnects with the stored refresh token, then syncs. Failures keep the cached vault.
    func resume() async {
        guard let environment, let token = AccountStore.refreshToken(account.id) else { return }
        let client = self.client ?? makeClient(environment)
        self.client = client
        do {
            await client.restore(refreshToken: token)
            AccountStore.setRefreshToken(try await client.refreshAccessToken(), account.id)
            try await refresh()
        } catch {
            // Offline or session expired: keep the cache.
            lastSyncError = String(localized: "Couldn't sync. The vault on this Mac is unchanged.")
        }
    }

    /// Checks for changes soon (several calls in a row make one check).
    func scheduleSync() { runPending() }

    /// What live notifications said: one item each, or something that needs a full sync.
    private func received(_ changes: [LiveSync.Change]) {
        for change in changes {
            switch change {
            case .cipher(let id): pendingIDs.insert(id)
            case .other: pendingFull = true
            }
        }
        runPending()
    }

    private func runPending() {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            // From here on the work runs to the end; a newer change waits for its own turn.
            debounce = nil
            let (full, ids) = (pendingFull, pendingIDs)
            pendingFull = false
            pendingIDs = []
            let work: () async throws -> Void = { [weak self] in
                guard let self else { return }
                if full { try await refresh() } else if !ids.isEmpty { try await reload(ids) } else { try await syncIfChanged() }
            }
            do { try await work() } catch {
                // The AutoFill extension may have rotated the refresh token meanwhile; use the stored one.
                if let stored = AccountStore.refreshToken(account.id) { await client?.restore(refreshToken: stored) }
                if let token = try? await client?.refreshAccessToken() { AccountStore.setRefreshToken(token, account.id) }
                do { try await work() } catch {
                    lastSyncError = String(localized: "Couldn't sync. The vault on this Mac is unchanged.")
                }
            }
        }
    }

    /// - Parameter changed: after a one-item update, the items that changed; the rest are kept as decrypted already.
    private func load(_ data: Data, changed: Set<String>? = nil) throws {
        let unchanged = changed.map { ids in
            Dictionary(items.lazy.filter { !ids.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        } ?? [:]
        let vault = try VaultDecoder.decode(data, userKey: userKey, accountId: account.id, unchanged: unchanged)
        payload = data
        cipherIndex = Dictionary(vault.sync.ciphers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        profile = vault.sync.profile
        items = vault.items
        folders = vault.folders
        organizations = vault.organizations
        sends = vault.sends
        hiddenCount = vault.hiddenCount
        keyring = vault.keyring
        rawCiphers = vault.rawCiphers
        equivalents = EquivalentDomains(syncData: data)
        onChange()
    }

    private func startLiveSync() async {
        guard live == nil, let client, let token = await client.currentAccessToken else { return }
        let live = LiveSync(environment: client.environment, accessToken: token, session: makeSession()) { [weak self] changes in
            Task { @MainActor in self?.received(changes) }
        }
        self.live = live
        do { try await live.start() } catch { self.live = nil }
        if periodic == nil {
            periodic = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleSync() }
            }
        }
    }

    /// Stops background work; the session object is then discarded.
    func close() {
        debounce?.cancel()
        periodic?.invalidate()
        let live = self.live
        self.live = nil
        Task { await live?.stop() }
    }

    // MARK: Touch ID

    func setTouchID(_ enabled: Bool) throws {
        if enabled { try AccountStore.enableTouchID(userKey: userKey, account.id) } else { AccountStore.disableTouchID(account.id) }
    }

    /// Turns PIN unlock on with `pin` (nil turns it off). `persistent`: it survives a restart. Stretching the PIN with
    /// the account's KDF takes a moment, so it runs off the main actor.
    func setPIN(_ pin: String?, persistent: Bool) async -> Bool {
        let key = userKey, id = account.id
        return await Task.detached(priority: .userInitiated) { () -> Bool in
            do {
                if let pin { try AccountStore.enablePIN(pin, userKey: key, persistent: persistent, id) } else { AccountStore.disablePIN(id) }
                return true
            } catch {
                return false
            }
        }.value
    }

    // MARK: Editing

    enum WriteError: Error { case offline }

    func create(_ kind: CipherEditor.Kind, edit: CipherEdit) async throws -> String {
        guard let client else { throw WriteError.offline }
        let id = try await client.createCipher(CipherEditor.newCipher(kind: kind, edit: edit, key: userKey))
        try await reload([id])
        return id
    }

    func update(_ id: String, edit: CipherEdit) async throws {
        guard let client, let raw = rawCiphers[id], let key = itemKey(id) else { throw WriteError.offline }
        try await client.updateCipher(id: id, CipherEditor.updatedCipher(raw: raw, edit: edit, key: key))
        try await reload([id])
    }

    /// The key that encrypts this item's fields (its own key, the org key, or the user key).
    private func itemKey(_ id: String) -> SymmetricKeyPair? {
        cipherIndex[id].flatMap { keyring?.key(for: $0) }
    }

    // MARK: Import and export

    /// Vaults this account may import into and export: Personal (nil id), then each organization where the user is an
    /// owner or admin, or has the import/export permission.
    func transferVaults() -> [(id: String?, name: String)] {
        let allowed = Set((profile?.organizations ?? []).filter(\.canImportExport).map(\.id))
        return [(nil, String(localized: "Personal"))] + organizations.filter { allowed.contains($0.id) }.map { ($0.id, $0.name) }
    }

    /// The personal vault, or an organization's, as a file in one of Bitwarden's export formats.
    /// Uses the synced (still encrypted) payload, so the export matches the server exactly.
    func export(_ format: VaultExport.Format, filePassword: String? = nil, organizationId: String? = nil) throws -> (data: Data, skipped: Int, count: Int) {
        guard !payload.isEmpty else { throw WriteError.offline }
        let cache = payload
        if let organizationId {
            let vault = try VaultExport.organizationVault(syncData: cache, userKey: userKey, organizationId: organizationId)
            let json = { try VaultExport.json(collections: vault.collections, items: vault.items) }
            switch format {
            case .json: return (try json(), 0, vault.items.count)
            case .encryptedJSON: return (try VaultExport.passwordProtected(json(), password: filePassword ?? ""), 0, vault.items.count)
            case .csv:
                let csv = VaultExport.csv(collections: vault.collections, items: vault.items)
                return (csv.data, csv.skipped, vault.items.count - csv.skipped)
            }
        }
        let vault = try VaultExport.plainVault(syncData: cache, userKey: userKey)
        let json = { try VaultExport.json(folders: vault.folders, items: vault.items) }
        switch format {
        case .json: return (try json(), 0, vault.items.count)
        case .encryptedJSON: return (try VaultExport.passwordProtected(json(), password: filePassword ?? ""), 0, vault.items.count)
        case .csv:
            let csv = VaultExport.csv(folders: vault.folders, items: vault.items)
            return (csv.data, csv.skipped, vault.items.count - csv.skipped)
        }
    }

    /// Reads an import file; account-encrypted Bitwarden exports from this account decrypt with its key.
    func previewImport(_ data: Data, password: String?) throws(ImportError) -> ImportPreview {
        try VaultImport.preview(data, password: password, accountKey: userKey)
    }

    /// Encrypts the chosen items here (with the organization's key when importing into one), sends them in one batch,
    /// then syncs. Into an organization, the file's folders become collections.
    func importItems(_ items: [ImportedItem], folders: [String], organizationId: String? = nil) async throws {
        guard let client else { throw WriteError.offline }
        // Bitwarden's cloud caps one import at about 7,000 items: send batches, keeping each folder in one batch.
        for batch in VaultImport.batches(items, limit: 5_000) {
            if let organizationId {
                guard let key = keyring?.orgKeys[organizationId] else { throw WriteError.offline }
                try await client.importOrganizationCiphers(
                    VaultImport.organizationRequestBody(items: batch, collections: folders, organizationId: organizationId, key: key),
                    organizationId: organizationId)
            } else {
                try await client.importCiphers(VaultImport.requestBody(items: batch, folders: folders, key: userKey))
            }
        }
        try await refresh()
    }

    // MARK: Send

    /// Creates a Send and returns its share link.
    func createSend(_ draft: SendDraft) async throws -> URL? {
        guard let client else { throw WriteError.offline }
        let sealed = try draft.seal(userKey: userKey)
        let created = try await client.createSend(sealed)
        try await refresh()
        return created.accessId.flatMap { environment?.sendLink(accessId: $0, keyMaterial: sealed.keyMaterial) }
    }

    func deleteSend(_ id: String) async throws {
        guard let client else { throw WriteError.offline }
        try await client.deleteSend(id: id)
        try await refresh()
    }

    // MARK: Attachments

    func attachmentContents(_ itemId: String, _ attachment: VaultItem.Attachment) async throws -> Data {
        guard let client else { throw WriteError.offline }
        let encrypted = try await client.downloadAttachment(cipherId: itemId, attachmentId: attachment.id, syncedURL: attachment.url)
        return try EncArrayBuffer.decrypt(encrypted, with: attachment.fileKey)
    }

    func addAttachment(_ itemId: String, name: String, contents: Data) async throws {
        guard let client, let key = itemKey(itemId) else { throw WriteError.offline }
        let sealed = try SealedAttachment(name: name, contents: contents, itemKey: key)
        try await client.uploadAttachment(cipherId: itemId, fileName: sealed.fileName, key: sealed.key, encrypted: sealed.encrypted)
        try await reload([itemId])
    }

    func deleteAttachment(_ itemId: String, _ attachmentId: String) async throws {
        guard let client else { throw WriteError.offline }
        try await client.deleteAttachment(cipherId: itemId, attachmentId: attachmentId)
        try await reload([itemId])
    }

    func createFolder(name: String) async throws -> String {
        guard let client else { throw WriteError.offline }
        let id = try await client.createFolder(encryptedName: EncString.encrypt(Data(name.utf8), with: userKey).description)
        try await refresh()
        return id
    }

    /// Renames folders (id → new full name), then syncs once.
    func renameFolders(_ names: [String: String]) async throws {
        guard let client else { throw WriteError.offline }
        for (id, name) in names {
            try await client.renameFolder(id: id, encryptedName: EncString.encrypt(Data(name.utf8), with: userKey).description)
        }
        try await refresh()
    }

    func deleteFolder(_ id: String) async throws {
        guard let client else { throw WriteError.offline }
        try await client.deleteFolder(id: id)
        try await refresh()
    }

    func trash(_ id: String) async throws {
        guard let client else { throw WriteError.offline }
        try await client.trashCipher(id: id)
        try await reload([id])
    }

    func archive(_ id: String) async throws {
        guard let client else { throw WriteError.offline }
        try await client.archiveCipher(id: id)
        try await reload([id])
    }

    func unarchive(_ id: String) async throws {
        guard let client else { throw WriteError.offline }
        try await client.unarchiveCipher(id: id)
        try await reload([id])
    }

    func restore(_ id: String) async throws {
        guard let client else { throw WriteError.offline }
        try await client.restoreCipher(id: id)
        try await reload([id])
    }

    func deleteForever(_ id: String) async throws {
        guard let client else { throw WriteError.offline }
        try await client.deleteCipher(id: id)
        try await reload([], removed: [id])
    }

    // MARK: Organizations and bulk edits

    /// Moves a personal item into an organization and its collections.
    func share(_ id: String, organizationId: String, collectionIds: [String]) async throws {
        guard let client, let raw = rawCiphers[id], let key = itemKey(id), let orgKey = keyring?.orgKeys[organizationId] else {
            throw WriteError.offline
        }
        let cipher = try CipherEditor.sharedCipher(raw: raw, key: key, organizationKey: orgKey, organizationId: organizationId)
        try await client.shareCipher(id: id, cipher: cipher, collectionIds: collectionIds)
        try await reload([id])
    }

    func setCollections(_ id: String, collectionIds: [String]) async throws {
        guard let client else { throw WriteError.offline }
        try await client.setCollections(cipherId: id, collectionIds: collectionIds)
        try await reload([id])
    }

    /// One request for many items: trash, restore, delete forever, archive, or move to a folder.
    enum Bulk { case trash, restore, delete, archive, move(folderId: String?) }

    func bulk(_ action: Bulk, ids: [String]) async throws {
        guard let client else { throw WriteError.offline }
        guard !ids.isEmpty else { return }
        switch action {
        case .trash: try await client.trashCiphers(ids: ids)
        case .restore: try await client.restoreCiphers(ids: ids)
        case .delete: try await client.deleteCiphers(ids: ids)
        case .archive: try await client.archiveCiphers(ids: ids)
        case .move(let folderId): try await client.moveCiphers(ids: ids, folderId: folderId)
        }
        if case .delete = action { try await reload([], removed: Set(ids)) } else { try await reload(Set(ids)) }
    }

    func leaveOrganization(_ id: String) async throws {
        guard let client else { throw WriteError.offline }
        try await client.leaveOrganization(id: id)
        try await refresh()
    }

    /// Changes a Send, keeping its key so the link still works.
    func updateSend(_ send: SendItem, draft: SendDraft, removePassword: Bool) async throws {
        guard let client else { throw WriteError.offline }
        let sealed = try draft.seal(userKey: userKey, keyMaterial: send.keyMaterial)
        try await client.updateSend(id: send.id, body: sealed.body)
        if removePassword { try await client.removeSendPassword(id: send.id) }
        try await refresh()
    }

    // MARK: Account security

    enum SecurityError: Error { case wrongPassword, signInAgain }

    /// The server's login hash for `password`, after checking it unlocks this account.
    func passwordHash(_ password: String) throws -> String {
        guard AccountStore.unlock(account.id, password: password) != nil else { throw SecurityError.wrongPassword }
        let master = try KDF.masterKey(password: password, email: account.email, config: account.kdf)
        return try KDF.masterPasswordHash(masterKey: master, password: password)
    }

    /// The account's public key, from its private key (offline).
    func publicKeySPKI() -> Data? {
        guard let encrypted = profile?.privateKey, let der = try? EncString(encrypted).decrypt(with: userKey),
              let key = try? RSAPrivateKey(pkcs8: der) else { return nil }
        return try? key.publicKeySPKI()
    }

    /// The private key itself, for unwrapping keys others wrapped for this account.
    func privateKey() -> RSAPrivateKey? {
        guard let encrypted = profile?.privateKey, let der = try? EncString(encrypted).decrypt(with: userKey) else { return nil }
        return try? RSAPrivateKey(pkcs8: der)
    }

    var userId: String? { profile?.id }

    /// Five words to compare out loud: this account's fingerprint phrase.
    func fingerprint() -> [String] {
        guard let spki = publicKeySPKI(), let id = userId else { return [] }
        return Fingerprint.phrase(publicKeySPKI: spki, material: id)
    }

    func devices() async throws -> [DeviceInfo] {
        guard let client else { throw WriteError.offline }
        return try await client.devices()
    }

    /// Signs out every other session; this Mac signs straight back in.
    func deauthorizeSessions(password: String) async throws {
        guard let client else { throw WriteError.offline }
        try await client.deauthorizeSessions(masterPasswordHash: passwordHash(password))
        do {
            let login = try await client.loginDetailed(email: account.email, password: password)
            AccountStore.setRefreshToken(login.refreshToken, account.id)
        } catch {
            throw SecurityError.signInAgain
        }
    }

    /// The web vault, for what's managed there (security keys, Duo, organizations' admin).
    var webVault: URL? {
        switch environment {
        case .bitwardenUS: URL(string: "https://vault.bitwarden.com")
        case .bitwardenEU: URL(string: "https://vault.bitwarden.eu")
        case .selfHosted(let base): base
        case .custom(let urls): urls.webVault ?? urls.base
        case nil: nil
        }
    }

    /// New master password (and/or KDF): the server first, then the copy on this Mac, so unlocking keeps working.
    func changeMasterPassword(current: String, new: String, kdf: KDFConfig? = nil, hint: String?) async throws {
        guard let client else { throw WriteError.offline }
        let currentHash = try passwordHash(current)
        let change = try MasterPasswordChange(email: account.email, newPassword: new, kdf: kdf ?? account.kdf, userKey: userKey)
        if kdf != nil, new == current {
            try await client.changeKDF(currentHash: currentHash, change: change)
        } else {
            try await client.changeMasterPassword(currentHash: currentHash, change: change, hint: hint)
        }
        var saved = account
        saved.kdf = change.kdf
        saved.protectedUserKey = change.protectedUserKey
        AccountStore.save(saved)
        account = saved
        // The server signs every session out (refresh tokens rotate): sign this one back in with the new password.
        // With two-step login on, that needs a code, so the account asks to sign in again instead.
        do {
            let login = try await client.loginDetailed(email: account.email, password: new)
            AccountStore.setRefreshToken(login.refreshToken, account.id)
        } catch {
            throw SecurityError.signInAgain
        }
        try? await refresh()
    }

    // Two-step login

    func twoFactorProviders() async throws -> [Int: Bool] {
        guard let client else { throw WriteError.offline }
        return try await client.twoFactorProviders()
    }

    func authenticatorSecret(password: String) async throws -> (key: String, enabled: Bool) {
        guard let client else { throw WriteError.offline }
        return try await client.authenticatorSecret(masterPasswordHash: passwordHash(password))
    }

    func enableAuthenticator(key: String, code: String, password: String) async throws {
        guard let client else { throw WriteError.offline }
        try await client.enableAuthenticator(key: key, code: code, masterPasswordHash: passwordHash(password))
    }

    func disableTwoFactor(type: Int, password: String) async throws {
        guard let client else { throw WriteError.offline }
        try await client.disableTwoFactor(type: type, masterPasswordHash: passwordHash(password))
    }

    func recoveryCode(password: String) async throws -> String? {
        guard let client else { throw WriteError.offline }
        return try await client.twoFactorRecoveryCode(masterPasswordHash: passwordHash(password))
    }

    func sendTwoFactorEmail(to email: String, password: String) async throws {
        guard let client else { throw WriteError.offline }
        try await client.sendTwoFactorEmail(to: email, masterPasswordHash: passwordHash(password))
    }

    func enableEmailTwoFactor(email: String, code: String, password: String) async throws {
        guard let client else { throw WriteError.offline }
        try await client.enableEmailTwoFactor(email: email, code: code, masterPasswordHash: passwordHash(password))
    }

    // MARK: Sign-in requests

    func pendingSignIns() async throws -> [SignInRequest] {
        guard let client else { throw WriteError.offline }
        return try await client.pendingSignIns()
    }

    /// The asking device's fingerprint phrase (its public key, with this account's email), to compare on its screen.
    func fingerprint(of request: SignInRequest) -> [String] {
        guard let spki = Data(base64Encoded: request.publicKey) else { return [] }
        return Fingerprint.phrase(publicKeySPKI: spki, material: KDF.normalizedEmail(account.email))
    }

    func answer(_ request: SignInRequest, approve: Bool) async throws {
        guard let client else { throw WriteError.offline }
        var wrapped: String?
        if approve {
            guard let spki = Data(base64Encoded: request.publicKey) else { throw WriteError.offline }
            wrapped = try RSAPublicKey(spki: spki).encrypt(userKey.encryptionKey + userKey.macKey)
        }
        try await client.answerSignIn(id: request.id, key: wrapped, approve: approve)
    }

    // MARK: Emergency access

    func emergencyContacts(granted: Bool) async throws -> [EmergencyContact] {
        guard let client else { throw WriteError.offline }
        return try await client.emergencyContacts(granted: granted)
    }

    /// Accepts an invitation from the link in its email (`…#/accept-emergency/?id=…&token=…`).
    func acceptEmergencyInvite(link: String) async throws {
        guard let client else { throw WriteError.offline }
        let query = link.split(separator: "?", maxSplits: 1).last.map(String.init) ?? ""
        var fields: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { fields[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
        }
        guard let id = fields["id"], let token = fields["token"] else { throw SecurityError.wrongPassword }
        try await client.acceptEmergencyInvite(id: id, token: token)
    }

    func inviteEmergencyContact(email: String, takeover: Bool, waitDays: Int) async throws {
        guard let client else { throw WriteError.offline }
        try await client.inviteEmergencyContact(email: email, takeover: takeover, waitDays: waitDays)
    }

    /// The contact's public key and its fingerprint phrase (their user id), to compare before confirming.
    func contactKey(_ contact: EmergencyContact) async throws -> (key: RSAPublicKey, fingerprint: [String]) {
        guard let client, let userId = contact.userId, let base64 = try await client.publicKey(userId: userId),
              let spki = Data(base64Encoded: base64) else { throw WriteError.offline }
        return (try RSAPublicKey(spki: spki), Fingerprint.phrase(publicKeySPKI: spki, material: userId))
    }

    /// Confirms an accepted contact: this account's user key, wrapped with their public key.
    func confirmEmergencyContact(_ contact: EmergencyContact, key: RSAPublicKey) async throws {
        guard let client else { throw WriteError.offline }
        try await client.emergencyAccess("confirm", id: contact.id, key: key.encrypt(userKey.encryptionKey + userKey.macKey))
    }

    func emergencyAccess(_ action: String, _ contact: EmergencyContact) async throws {
        guard let client else { throw WriteError.offline }
        try await client.emergencyAccess(action, id: contact.id)
    }

    /// The other account's user key, unwrapped with this account's private key.
    private func grantorKey(_ wrapped: String?) throws -> SymmetricKeyPair {
        guard let wrapped, let mine = privateKey() else { throw WriteError.offline }
        return try SymmetricKeyPair(combined: mine.decrypt(wrapped))
    }

    /// As an approved view-only contact: the other account's items, read-only.
    func emergencyView(_ contact: EmergencyContact) async throws -> [VaultItem] {
        guard let client else { throw WriteError.offline }
        let (ciphers, wrapped) = try await client.emergencyView(id: contact.id)
        let key = try grantorKey(wrapped)
        // A minimal sync payload around their items, decoded like our own.
        let list = (try? JSONSerialization.jsonObject(with: ciphers)) ?? []
        let sync: [String: Any] = ["profile": ["id": contact.userId ?? "", "email": contact.email, "key": "", "organizations": []],
                                   "folders": [], "ciphers": list]
        return try VaultDecoder.decode(JSONSerialization.data(withJSONObject: sync), userKey: key).items.filter { !$0.isDeleted }
    }

    /// As an approved takeover contact: the other account's KDF and key (step one), for setting its new password.
    func emergencyTakeoverKey(_ contact: EmergencyContact) async throws -> (kdf: KDFConfig, key: SymmetricKeyPair) {
        guard let client else { throw WriteError.offline }
        let (kdf, wrapped) = try await client.emergencyTakeover(id: contact.id)
        return (kdf, try grantorKey(wrapped))
    }

    func emergencyTakeover(_ contact: EmergencyContact, newPassword: String) async throws {
        guard let client else { throw WriteError.offline }
        let (kdf, key) = try await emergencyTakeoverKey(contact)
        let change = try MasterPasswordChange(email: contact.email, newPassword: newPassword, kdf: kdf, userKey: key)
        try await client.emergencySetPassword(id: contact.id, change: change)
    }

    // MARK: Event logs

    func organizationEvents(_ organizationId: String, days: Int) async throws -> (events: [OrgEvent], names: [String: String]) {
        guard let client else { throw WriteError.offline }
        async let events = client.organizationEvents(id: organizationId, start: .now.addingTimeInterval(-Double(days) * 86_400), end: .now)
        async let names = client.organizationMembers(id: organizationId)
        return try await (events, (try? await names) ?? [:])
    }
}
