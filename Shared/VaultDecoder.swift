import TriCrypto
import Foundation
import VaultwardenAPI

/// The decrypted, display-ready vault. Shared by the app and the AutoFill extension.
struct DecodedVault {
    var items: [VaultItem]
    var folders: [Grouping]
    var organizations: [Grouping]
    var hiddenCount: Int
    var keyring: Keyring
    var rawCiphers: [String: Data]
    var sends: [SendItem] = []
    /// The payload as parsed, still encrypted.
    var sync: SyncResponse
}

enum VaultDecoder {
    /// Server timestamps, with or without fractional seconds (Vaultwarden sends six digits).
    static func date(_ string: String?) -> Date? {
        guard var s = string else { return nil }
        if let dot = s.firstIndex(of: "."), let end = s[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            s.removeSubrange(dot..<end)
        }
        if !s.hasSuffix("Z") && !s.contains("+") && s.count == 19 { s += "Z" }
        return try? Date(s, strategy: .iso8601)
    }

    /// - Parameter unchanged: items known to be the same as in `data` (after a one-item update); they're kept as they
    ///   are instead of being decrypted again. Reuse counts and folder names are worked out afresh either way.
    static func decode(_ data: Data, userKey: SymmetricKeyPair, accountId: String = "",
                       unchanged: [String: VaultItem] = [:]) throws -> DecodedVault {
        let sync = try SyncResponse.decode(data)
        let keyring = Keyring(userKey: userKey, profile: sync.profile)
        var hidden = 0
        var items: [VaultItem] = sync.ciphers.compactMap { cipher in
            if let kept = unchanged[cipher.id] { return kept }
            guard let key = keyring.key(for: cipher) else { hidden += 1; return nil }
            func dec(_ s: String?) -> String? {
                s.flatMap { try? EncString($0).decryptString(with: key) }.flatMap { $0.isEmpty ? nil : $0 }
            }
            let kind = VaultItem.Kind(rawValue: cipher.type) ?? .login
            let uris = (cipher.login?.uris ?? []).compactMap { dec($0.uri) }
            let fullURI = uris.first
            let totpSecret = dec(cipher.login?.totp)
            var item = VaultItem(
                id: cipher.id,
                accountId: accountId,
                kind: kind,
                name: dec(cipher.name) ?? "—",
                username: dec(cipher.login?.username),
                host: fullURI.flatMap { URL(string: $0)?.host() },
                password: dec(cipher.login?.password),
                totp: totpSecret.flatMap(TOTP.init),
                notes: dec(cipher.notes),
                totpSecret: totpSecret,
                uri: fullURI,
                uris: uris,
                favorite: cipher.favorite ?? false,
                hasPasskey: !(cipher.login?.fido2Credentials ?? []).isEmpty,
                folderId: cipher.folderId,
                isDeleted: cipher.deletedDate != nil,
                organizationId: cipher.organizationId,
                collectionIds: cipher.collectionIds ?? []
            )
            item.revised = Self.date(cipher.revisionDate)
            item.deleted = Self.date(cipher.deletedDate)
            item.created = Self.date(cipher.creationDate)
            item.passwordRevised = Self.date(cipher.login?.passwordRevisionDate)
            item.archived = Self.date(cipher.archivedDate)
            item.reprompt = cipher.reprompt == 1
            item.passwordHistory = (cipher.passwordHistory ?? []).compactMap { entry in
                dec(entry.password).map { VaultItem.PastPassword(password: $0, date: Self.date(entry.lastUsedDate)) }
            }
            // Raw values for the editor, by API name.
            func raw(_ pairs: [(String, String?)]) -> [String: String] {
                Dictionary(pairs.compactMap { k, v in dec(v).map { (k, $0) } }, uniquingKeysWith: { a, _ in a })
            }
            switch kind {
            case .card:
                let c = cipher.card
                item.properties = raw([("cardholderName", c?.cardholderName), ("brand", c?.brand), ("number", c?.number),
                                       ("expMonth", c?.expMonth), ("expYear", c?.expYear), ("code", c?.code)])
                let number = dec(c?.number)
                let month = dec(c?.expMonth), year = dec(c?.expYear)
                item.username = number.map { "•••• " + $0.suffix(4) } ?? dec(c?.brand)
                item.fields = [
                    number.map { ItemField(label: String(localized: "Card number"), value: $0, secret: true, monospaced: true) },
                    dec(c?.cardholderName).map { ItemField(label: String(localized: "Cardholder"), value: $0) },
                    (month != nil || year != nil) ? ItemField(label: String(localized: "Expires"), value: "\(month ?? "--")/\(year ?? "----")") : nil,
                    dec(c?.code).map { ItemField(label: String(localized: "Security code"), value: $0, secret: true, monospaced: true) },
                ].compactMap { $0 }
            case .identity:
                let i = cipher.identity
                item.properties = raw([
                    ("title", i?.title), ("firstName", i?.firstName), ("middleName", i?.middleName), ("lastName", i?.lastName),
                    ("company", i?.company), ("email", i?.email), ("phone", i?.phone), ("username", i?.username),
                    ("address1", i?.address1), ("address2", i?.address2), ("city", i?.city), ("state", i?.state),
                    ("postalCode", i?.postalCode), ("country", i?.country), ("ssn", i?.ssn),
                    ("passportNumber", i?.passportNumber), ("licenseNumber", i?.licenseNumber),
                ])
                let name = [dec(i?.title), dec(i?.firstName), dec(i?.middleName), dec(i?.lastName)].compactMap { $0 }.joined(separator: " ")
                item.username = name.isEmpty ? dec(i?.email) : name
                item.fields = [
                    name.isEmpty ? nil : ItemField(label: String(localized: "Name"), value: name),
                    dec(i?.email).map { ItemField(label: String(localized: "Email"), value: $0) },
                    dec(i?.phone).map { ItemField(label: String(localized: "Phone"), value: $0) },
                    dec(i?.company).map { ItemField(label: String(localized: "Company"), value: $0) },
                    dec(i?.username).map { ItemField(label: String(localized: "Username"), value: $0) },
                    [dec(i?.address1), dec(i?.address2), dec(i?.city), dec(i?.state), dec(i?.postalCode), dec(i?.country)]
                        .compactMap { $0 }.joined(separator: ", ")
                        .nilIfEmpty.map { ItemField(label: String(localized: "Address"), value: $0) },
                    dec(i?.ssn).map { ItemField(label: String(localized: "National ID / SSN"), value: $0, secret: true) },
                    dec(i?.passportNumber).map { ItemField(label: String(localized: "Passport number"), value: $0, secret: true) },
                    dec(i?.licenseNumber).map { ItemField(label: String(localized: "Licence number"), value: $0, secret: true) },
                ].compactMap { $0 }
            case .sshKey:
                let k = cipher.sshKey
                item.properties = raw([("privateKey", k?.privateKey), ("publicKey", k?.publicKey), ("keyFingerprint", k?.keyFingerprint)])
                item.username = dec(k?.keyFingerprint)
                item.fields = [
                    dec(k?.publicKey).map { ItemField(label: String(localized: "Public key"), value: $0, monospaced: true) },
                    dec(k?.keyFingerprint).map { ItemField(label: String(localized: "Fingerprint"), value: $0, monospaced: true) },
                    dec(k?.privateKey).map { ItemField(label: String(localized: "Private key"), value: $0, secret: true, monospaced: true) },
                ].compactMap { $0 }
            case .note:
                item.username = item.notes.map { String($0.prefix(60)) }
            case .login:
                item.passkeys = (cipher.login?.fido2Credentials ?? []).compactMap { $0.decrypted(with: key) }
            }
            item.attachments = (cipher.attachments ?? []).compactMap { a in
                guard let fileKey = try? a.fileKey(itemKey: key) else { return nil }
                let size = a.size.flatMap(Int.init) ?? 0
                return VaultItem.Attachment(id: a.id, fileName: dec(a.fileName) ?? "attachment", size: size,
                                            sizeName: a.sizeName ?? ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file),
                                            url: a.url, fileKey: fileKey)
            }
            item.customFields = (cipher.fields ?? []).map { f in
                CustomField(name: dec(f.name) ?? "", value: dec(f.value) ?? "", kind: CustomField.Kind(rawValue: f.type) ?? .text)
            }
            item.fields += item.customFields.filter { $0.kind != .linked }.map { f in
                switch f.kind {
                case .boolean: ItemField(label: f.name, value: f.value == "true" ? String(localized: "Yes") : String(localized: "No"))
                case .hidden: ItemField(label: f.name, value: f.value, secret: true)
                default: ItemField(label: f.name, value: f.value)
                }
            }
            return item
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let counts = Dictionary(items.filter { !$0.isDeleted }.compactMap(\.password).map { ($0, 1) }, uniquingKeysWith: +)
        for i in items.indices {
            if let pw = items[i].password { items[i].reuseCount = (counts[pw] ?? 1) - 1 }
        }
        let folders = (sync.folders ?? []).compactMap { f in
            (try? EncString(f.name).decryptString(with: userKey)).map { Grouping(id: f.id, name: $0) }
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let organizations: [Grouping] = (sync.profile.organizations ?? []).compactMap { org -> Grouping? in
            guard let orgKey = keyring.orgKeys[org.id] else { return nil }
            let collections = (sync.collections ?? []).filter { $0.organizationId == org.id }.compactMap { c in
                (try? EncString(c.name).decryptString(with: orgKey)).map { Grouping(id: c.id, name: $0) }
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return Grouping(id: org.id, name: org.name ?? String(localized: "Shared vault"), children: collections)
        }
        let folderNames = Dictionary(folders.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        for i in items.indices { items[i].folderName = items[i].folderId.flatMap { folderNames[$0] } }
        return DecodedVault(items: items, folders: folders, organizations: organizations, hiddenCount: hidden,
                            keyring: keyring, rawCiphers: CipherEditor.rawCiphers(fromSync: data),
                            sends: decodeSends(data, userKey: userKey, accountId: accountId), sync: sync)
    }

    static func decodeSends(_ data: Data, userKey: SymmetricKeyPair, accountId: String) -> [SendItem] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ s: String?) -> Date? { s.flatMap { iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) } }
        return SyncResponse.sends(data).compactMap { send in
            guard let accessId = send.accessId, let material = send.key.flatMap({ try? EncString($0).decrypt(with: userKey) }),
                  let key = try? SendCrypto.key(from: material) else { return nil }
            func dec(_ s: String?) -> String? { s.flatMap { try? EncString($0).decryptString(with: key) } }
            var item = SendItem(id: send.id, accountId: accountId, accessId: accessId, kind: send.type == 1 ? .file : .text,
                            name: dec(send.name) ?? "—", notes: dec(send.notes), text: dec(send.text?.text),
                            hideText: send.text?.hidden ?? false, fileName: dec(send.file?.fileName), sizeName: send.file?.sizeName,
                            keyMaterial: material, accessCount: send.accessCount ?? 0, maxAccessCount: send.maxAccessCount,
                            hasPassword: send.password != nil, disabled: send.disabled ?? false,
                            deletionDate: date(send.deletionDate), expirationDate: date(send.expirationDate))
            item.hideEmail = send.hideEmail ?? false
            return item
        }
        .sorted { ($0.deletionDate ?? .distantFuture) < ($1.deletionDate ?? .distantFuture) }
    }
}
