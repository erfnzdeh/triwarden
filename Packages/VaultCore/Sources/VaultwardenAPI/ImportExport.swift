import TriCrypto
import Foundation

// Import and export in the formats of Bitwarden's official clients, so files move freely between them:
// Bitwarden JSON (plain, password-protected, account-encrypted), Bitwarden CSV, and the browsers' CSVs.
// Items travel as Bitwarden's own JSON shapes; encryption happens field by field with the right key.

// MARK: - Field encryption

/// Encrypts / decrypts every string field of a cipher's JSON, except ids and dates.
enum CipherFields {
    /// Plain in both the API and exports.
    static let plainKeys: Set<String> = [
        "id", "organizationId", "folderId", "collectionIds", "revisionDate", "creationDate", "deletedDate",
        "lastUsedDate", "passwordRevisionDate", "object", "uriChecksum",
    ]

    static func decrypt(_ any: Any, key: SymmetricKeyPair, field: String? = nil) -> Any {
        switch any {
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = decrypt(v, key: key, field: k) }
            return out
        case let array as [Any]:
            return array.map { decrypt($0, key: key, field: field) }
        case let string as String:
            guard let field, !plainKeys.contains(field), let enc = try? EncString(string),
                  let plain = try? enc.decryptString(with: key) else { return string }
            return plain
        default:
            return any
        }
    }

    static func encrypt(_ any: Any, key: SymmetricKeyPair, field: String? = nil) throws -> Any {
        switch any {
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = try encrypt(v, key: key, field: k) }
            return out
        case let array as [Any]:
            return try array.map { try encrypt($0, key: key, field: field) }
        case let string as String:
            guard let field, !plainKeys.contains(field) else { return string }
            return string.isEmpty ? NSNull() : try EncString.encrypt(Data(string.utf8), with: key).description
        default:
            return any
        }
    }
}

// MARK: - Export

public enum VaultExport {
    public enum Format: String, CaseIterable, Sendable {
        case json, encryptedJSON, csv
    }

    /// The personal vault (no organization items, nothing in Trash), decrypted into Bitwarden's export shapes.
    /// Attachments are left out, as in Bitwarden's own export.
    public static func plainVault(syncData: Data, userKey: SymmetricKeyPair) throws -> (folders: [[String: Any]], items: [[String: Any]]) {
        let sync = try SyncResponse.decode(syncData)
        let keyring = Keyring(userKey: userKey, profile: sync.profile)
        let raw = CipherEditor.rawCiphers(fromSync: syncData)

        let folders: [[String: Any]] = (sync.folders ?? []).map { folder in
            let name = (try? EncString(folder.name).decryptString(with: userKey)) ?? folder.name
            return ["id": folder.id, "name": name]
        }
        var items: [[String: Any]] = []
        for cipher in sync.ciphers where cipher.organizationId == nil && cipher.deletedDate == nil {
            try CipherEditor.requireSupportedType(cipher.type)
            guard let data = raw[cipher.id], let key = keyring.key(for: cipher),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let plain = CipherFields.decrypt(dict, key: key) as? [String: Any] else { continue }
            items.append(exportItem(plain))
        }
        return (folders, items)
    }

    /// One organization's vault (nothing in Trash), decrypted, with its collections — Bitwarden's organization export.
    public static func organizationVault(syncData: Data, userKey: SymmetricKeyPair, organizationId: String) throws
        -> (collections: [[String: Any]], items: [[String: Any]]) {
        let sync = try SyncResponse.decode(syncData)
        let keyring = Keyring(userKey: userKey, profile: sync.profile)
        guard let orgKey = keyring.orgKeys[organizationId] else { throw APIError.http(status: -1, message: "No key for this organization") }
        let raw = CipherEditor.rawCiphers(fromSync: syncData)
        let collections: [[String: Any]] = (sync.collections ?? []).filter { $0.organizationId == organizationId }.map { c in
            ["id": c.id, "organizationId": organizationId, "externalId": NSNull(),
             "name": (try? EncString(c.name).decryptString(with: orgKey)) ?? c.name]
        }
        var items: [[String: Any]] = []
        for cipher in sync.ciphers where cipher.organizationId == organizationId && cipher.deletedDate == nil {
            try CipherEditor.requireSupportedType(cipher.type)
            guard let data = raw[cipher.id], let key = keyring.key(for: cipher),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let plain = CipherFields.decrypt(dict, key: key) as? [String: Any] else { continue }
            var item = exportItem(plain)
            item["organizationId"] = organizationId
            item["folderId"] = NSNull()
            item["collectionIds"] = cipher.collectionIds ?? []
            items.append(item)
        }
        return (collections, items)
    }

    /// Keeps the fields Bitwarden's export has; drops server bookkeeping (keys, attachments, permissions).
    static func exportItem(_ c: [String: Any]) -> [String: Any] {
        var item: [String: Any] = [:]
        for k in ["id", "organizationId", "folderId", "type", "reprompt", "name", "notes", "favorite", "fields",
                  "passwordHistory", "revisionDate", "creationDate", "deletedDate"] {
            item[k] = c[k] ?? NSNull()
        }
        item["collectionIds"] = NSNull()
        switch c["type"] as? Int {
        case 1:
            var login = c["login"] as? [String: Any] ?? [:]
            login.removeValue(forKey: "passwordRevisionDate")
            login["uris"] = (login["uris"] as? [[String: Any]])?.map { ["uri": $0["uri"] ?? NSNull(), "match": $0["match"] ?? NSNull()] }
            item["login"] = login
        case 2: item["secureNote"] = c["secureNote"] ?? ["type": 0]
        case 3: item["card"] = c["card"] ?? [String: Any]()
        case 4: item["identity"] = c["identity"] ?? [String: Any]()
        case 5: item["sshKey"] = c["sshKey"] ?? [String: Any]()
        default: break
        }
        return item
    }

    public static func json(folders: [[String: Any]], items: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["encrypted": false, "folders": folders, "items": items],
                                   options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// An organization export: collections instead of folders.
    public static func json(collections: [[String: Any]], items: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["encrypted": false, "collections": collections, "items": items],
                                   options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Bitwarden's password-protected export: the plain JSON, encrypted with a key from the file password.
    /// Any Bitwarden client can import it with that password.
    public static func passwordProtected(_ plainJSON: Data, password: String,
                                         kdf: KDFConfig = .pbkdf2(iterations: 600_000)) throws -> Data {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let saltString = salt.base64EncodedString()
        let key = try KDF.passwordKey(password: password, salt: saltString, config: kdf)
        var doc: [String: Any] = [
            "encrypted": true,
            "passwordProtected": true,
            "salt": saltString,
            "encKeyValidation_DO_NOT_EDIT": try EncString.encrypt(Data(UUID().uuidString.lowercased().utf8), with: key).description,
            "data": try EncString.encrypt(plainJSON, with: key).description,
        ]
        switch kdf {
        case .pbkdf2(let iterations):
            doc["kdfType"] = 0; doc["kdfIterations"] = iterations; doc["kdfMemory"] = NSNull(); doc["kdfParallelism"] = NSNull()
        case .argon2id(let iterations, let memory, let parallelism):
            doc["kdfType"] = 1; doc["kdfIterations"] = iterations; doc["kdfMemory"] = memory; doc["kdfParallelism"] = parallelism
        }
        return try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    public static let csvHeader = ["folder", "favorite", "type", "name", "notes", "fields", "reprompt",
                                   "login_uri", "login_username", "login_password", "login_totp"]

    /// Bitwarden CSV: logins and secure notes only (the format holds nothing else).
    public static func csv(folders: [[String: Any]], items: [[String: Any]]) -> (data: Data, skipped: Int) {
        csv(groups: folders, items: items, organization: false)
    }

    /// Bitwarden's organization CSV: a "collections" column (comma-separated names) instead of "folder".
    public static func csv(collections: [[String: Any]], items: [[String: Any]]) -> (data: Data, skipped: Int) {
        csv(groups: collections, items: items, organization: true)
    }

    static func csv(groups: [[String: Any]], items: [[String: Any]], organization: Bool) -> (data: Data, skipped: Int) {
        let folderNames = Dictionary(groups.compactMap { f in (f["id"] as? String).map { ($0, f["name"] as? String ?? "") } },
                                     uniquingKeysWith: { a, _ in a })
        var rows = [organization ? ["collections"] + csvHeader.filter { $0 != "folder" && $0 != "favorite" } : csvHeader]
        var skipped = 0
        for item in items {
            let type = item["type"] as? Int
            guard type == 1 || type == 2 else { skipped += 1; continue }
            let login = item["login"] as? [String: Any] ?? [:]
            let fields = (item["fields"] as? [[String: Any]] ?? []).map { "\($0["name"] as? String ?? ""): \($0["value"] as? String ?? "")" }
            let uris = (login["uris"] as? [[String: Any]] ?? []).compactMap { $0["uri"] as? String }
            let group = organization
                ? (item["collectionIds"] as? [String] ?? []).compactMap { folderNames[$0] }.joined(separator: ",")
                : (item["folderId"] as? String).flatMap { folderNames[$0] } ?? ""
            rows.append((organization ? [group] : [group, (item["favorite"] as? Bool) == true ? "1" : ""]) + [
                type == 1 ? "login" : "note",
                item["name"] as? String ?? "",
                item["notes"] as? String ?? "",
                fields.joined(separator: "\n"),
                String(item["reprompt"] as? Int ?? 0),
                uris.joined(separator: ","),
                login["username"] as? String ?? "",
                login["password"] as? String ?? "",
                login["totp"] as? String ?? "",
            ])
        }
        return (Data(CSV.write(rows).utf8), skipped)
    }
}

// MARK: - Import

public struct ImportedItem: @unchecked Sendable {
    /// A Bitwarden-format item with plain values (as in a plain JSON export).
    public var json: [String: Any]
    /// Index into `ImportPreview.folders`.
    public var folder: Int?

    public var type: Int { json["type"] as? Int ?? 0 }
    public var name: String { json["name"] as? String ?? "" }
    public var username: String? { (json["login"] as? [String: Any])?["username"] as? String }
    public var host: String? {
        ((json["login"] as? [String: Any])?["uris"] as? [[String: Any]])?.first.flatMap { $0["uri"] as? String }
            .flatMap(VaultImport.host)
    }
}

public struct ImportPreview: Sendable {
    public enum Format: String, Sendable {
        case bitwardenJSON, bitwardenPasswordProtected, bitwardenAccountEncrypted, bitwardenCSV
        case chromeCSV, safariCSV, firefoxCSV
        case onePassword1pux, onePasswordCSV, lastPassCSV, keePassXCCSV, keePassXML, protonPassCSV, dashlaneCSV
    }
    public var format: Format
    public var folders: [String]
    public var items: [ImportedItem]
    /// Rows or entries that couldn't be read, with why.
    public var problems: [ImportProblem]
}

public enum ImportProblem: Sendable, Equatable {
    /// A JSON item (1-based) of a type this app doesn't know.
    case unknownType(item: Int)
    /// A CSV row (1-based, header is row 1) whose type CSV can't carry.
    case unsupportedRow(row: Int, type: String)
}

public enum ImportError: Error, Equatable, Sendable {
    /// A password-protected Bitwarden export: ask for its file password.
    case passwordRequired
    case wrongPassword
    /// Encrypted with another account's key: export it from that account (or as password-protected).
    case otherAccount
    case unsupported
    case empty
}

public enum VaultImport {
    /// Reads any supported file. `password` is for password-protected exports; `accountKey` decrypts
    /// account-encrypted exports made from the same account.
    public static func preview(_ data: Data, password: String? = nil, accountKey: SymmetricKeyPair? = nil) throws(ImportError) -> ImportPreview {
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return try onePux(data) } // a ZIP: 1Password's .1pux
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}").union(.whitespacesAndNewlines))
        guard !text.isEmpty else { throw .empty }
        if text.hasPrefix("<") { return try keePassXML(Data(text.utf8)) }
        if text.hasPrefix("{"), let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            return try bitwardenJSON(root, password: password, accountKey: accountKey)
        }
        return try csv(text)
    }

    // MARK: Bitwarden JSON

    static func bitwardenJSON(_ root: [String: Any], password: String?, accountKey: SymmetricKeyPair?) throws(ImportError) -> ImportPreview {
        if root["encrypted"] as? Bool == true, root["passwordProtected"] as? Bool == true {
            guard let password, !password.isEmpty else { throw .passwordRequired }
            guard let salt = root["salt"] as? String, let data = root["data"] as? String,
                  let check = root["encKeyValidation_DO_NOT_EDIT"] as? String else { throw .unsupported }
            let kdf: KDFConfig = (root["kdfType"] as? Int) == 1
                ? .argon2id(iterations: root["kdfIterations"] as? Int ?? 3, memoryMiB: root["kdfMemory"] as? Int ?? 64,
                            parallelism: root["kdfParallelism"] as? Int ?? 4)
                : .pbkdf2(iterations: root["kdfIterations"] as? Int ?? 600_000)
            guard let key = try? KDF.passwordKey(password: password, salt: salt, config: kdf) else { throw .unsupported }
            guard (try? EncString(check).decrypt(with: key)) != nil else { throw .wrongPassword }
            guard let plain = try? EncString(data).decrypt(with: key),
                  let inner = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else { throw .wrongPassword }
            var preview = try bitwardenJSON(inner, password: nil, accountKey: nil)
            preview.format = .bitwardenPasswordProtected
            return preview
        }

        var root = root
        var format = ImportPreview.Format.bitwardenJSON
        if root["encrypted"] as? Bool == true {
            guard let accountKey else { throw .otherAccount }
            if let check = root["encKeyValidation_DO_NOT_EDIT"] as? String, (try? EncString(check).decrypt(with: accountKey)) == nil {
                throw .otherAccount
            }
            root["folders"] = (root["folders"] as? [[String: Any]] ?? []).map { CipherFields.decrypt($0, key: accountKey) }
            root["items"] = (root["items"] as? [[String: Any]] ?? []).map { item -> Any in
                // Items with their own key: unwrap it with the account key first.
                var key = accountKey
                if let wrapped = item["key"] as? String, let raw = try? EncString(wrapped).decrypt(with: accountKey),
                   let itemKey = try? SymmetricKeyPair(combined: raw) { key = itemKey }
                return CipherFields.decrypt(item, key: key)
            }
            format = .bitwardenAccountEncrypted
        }

        // Organization exports group by collection; they import as folders (or collections, into an organization).
        let byCollection = (root["folders"] as? [[String: Any]] ?? []).isEmpty && root["collections"] != nil
        let folderList = (byCollection ? root["collections"] : root["folders"]) as? [[String: Any]] ?? []
        let folders = folderList.map { $0["name"] as? String ?? "" }
        let folderIndex = Dictionary(folderList.enumerated().compactMap { i, f in (f["id"] as? String).map { ($0, i) } },
                                     uniquingKeysWith: { a, _ in a })
        var items: [ImportedItem] = []
        var problems: [ImportProblem] = []
        for (i, raw) in (root["items"] as? [[String: Any]] ?? []).enumerated() {
            guard let item = importable(raw) else {
                problems.append(.unknownType(item: i + 1))
                continue
            }
            let group = byCollection ? (raw["collectionIds"] as? [String])?.first : raw["folderId"] as? String
            items.append(ImportedItem(json: item, folder: group.flatMap { folderIndex[$0] }))
        }
        guard !items.isEmpty || !folders.isEmpty else { throw problems.isEmpty ? .empty : .unsupported }
        return ImportPreview(format: format, folders: folders, items: items, problems: problems)
    }

    /// The parts of an export item a new cipher takes (ids, dates and collections are the server's).
    static func importable(_ raw: [String: Any]) -> [String: Any]? {
        guard let type = raw["type"] as? Int, (1...5).contains(type) else { return nil }
        var item: [String: Any] = ["type": type, "favorite": raw["favorite"] as? Bool ?? false, "reprompt": raw["reprompt"] as? Int ?? 0]
        let name = (raw["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "--"
        item["name"] = name
        for k in ["notes", "fields", "passwordHistory"] where !(raw[k] is NSNull) { item[k] = raw[k] }
        switch type {
        case 1:
            var login = raw["login"] as? [String: Any] ?? [:]
            login.removeValue(forKey: "passwordRevisionDate")
            if let uris = login["uris"] as? [[String: Any]] {
                login["uris"] = uris.map { ["uri": $0["uri"] ?? NSNull(), "match": $0["match"] ?? NSNull()] }
            }
            item["login"] = login
        case 2: item["secureNote"] = raw["secureNote"] as? [String: Any] ?? ["type": 0]
        case 3: item["card"] = raw["card"] as? [String: Any] ?? [:]
        case 4: item["identity"] = raw["identity"] as? [String: Any] ?? [:]
        default: item["sshKey"] = raw["sshKey"] as? [String: Any] ?? [:]
        }
        return item
    }

    // MARK: CSV

    static func csv(_ text: String) throws(ImportError) -> ImportPreview {
        let rows = CSV.parse(text)
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }), rows.count > 1 else { throw .empty }
        func col(_ name: String) -> Int? { header.firstIndex(of: name) }
        let body = rows.dropFirst().filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }

        // Other password managers first: some of their headers also contain the browsers' columns.
        if col("login_uri") == nil, let other = otherCSV(header: header, rows: Array(body)) {
            guard !other.items.isEmpty else { throw .empty }
            return other
        }

        var folders: [String] = []
        var items: [ImportedItem] = []
        var problems: [ImportProblem] = []
        func value(_ row: [String], _ index: Int?) -> String {
            guard let index, index < row.count else { return "" }
            return row[index]
        }
        func login(name: String, uri: String, username: String, password: String, totp: String = "", notes: String = "") -> [String: Any] {
            var login: [String: Any] = ["username": username, "password": password]
            if !totp.isEmpty { login["totp"] = totp }
            let uris = uri.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !uris.isEmpty { login["uris"] = uris.map { ["uri": $0, "match": NSNull()] } }
            var item: [String: Any] = ["type": 1, "name": name.isEmpty ? (host(uri) ?? "--") : name, "login": login,
                                       "favorite": false, "reprompt": 0]
            if !notes.isEmpty { item["notes"] = notes }
            return item
        }

        let format: ImportPreview.Format
        if col("login_uri") != nil, col("type") != nil, col("name") != nil {
            format = .bitwardenCSV
            for (i, row) in body.enumerated() {
                let type = value(row, col("type")).lowercased()
                var item: [String: Any]
                switch type {
                case "login", "":
                    item = login(name: value(row, col("name")), uri: value(row, col("login_uri")),
                                 username: value(row, col("login_username")), password: value(row, col("login_password")),
                                 totp: value(row, col("login_totp")), notes: value(row, col("notes")))
                case "note":
                    item = ["type": 2, "name": value(row, col("name")).isEmpty ? "--" : value(row, col("name")),
                            "notes": value(row, col("notes")), "secureNote": ["type": 0], "favorite": false, "reprompt": 0]
                default:
                    problems.append(.unsupportedRow(row: i + 2, type: type))
                    continue
                }
                item["favorite"] = value(row, col("favorite")) == "1"
                item["reprompt"] = Int(value(row, col("reprompt"))) ?? 0
                let fields = value(row, col("fields")).split(separator: "\n").compactMap { line -> [String: Any]? in
                    guard let colon = line.firstIndex(of: ":") else { return nil }
                    return ["name": String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                            "value": String(line[colon...].dropFirst()).trimmingCharacters(in: .whitespaces),
                            "type": 0, "linkedId": NSNull()]
                }
                if !fields.isEmpty { item["fields"] = fields }
                // Organization CSVs have "collections" (comma-separated); the first one groups the item.
                let folderName = (col("folder") != nil ? value(row, col("folder"))
                                  : value(row, col("collections")).split(separator: ",").first.map(String.init) ?? "")
                    .trimmingCharacters(in: .whitespaces)
                var folder: Int?
                if !folderName.isEmpty {
                    if let existing = folders.firstIndex(of: folderName) { folder = existing } else { folders.append(folderName); folder = folders.count - 1 }
                }
                items.append(ImportedItem(json: item, folder: folder))
            }
        } else if col("title") != nil, col("url") != nil, col("username") != nil, col("password") != nil {
            format = .safariCSV // Apple Passwords / Safari: Title,URL,Username,Password,Notes,OTPAuth
            for row in body {
                items.append(ImportedItem(json: login(name: value(row, col("title")), uri: value(row, col("url")),
                                                      username: value(row, col("username")), password: value(row, col("password")),
                                                      totp: value(row, col("otpauth")), notes: value(row, col("notes")))))
            }
        } else if col("httprealm") != nil || col("formactionorigin") != nil, col("url") != nil {
            format = .firefoxCSV // url,username,password,httpRealm,formActionOrigin,guid,…
            for row in body {
                let url = value(row, col("url"))
                guard !url.hasPrefix("chrome://") else { continue } // Firefox's own internal entries
                items.append(ImportedItem(json: login(name: host(url) ?? url, uri: url,
                                                      username: value(row, col("username")), password: value(row, col("password")))))
            }
        } else if col("name") != nil, col("url") != nil, col("username") != nil, col("password") != nil {
            format = .chromeCSV // Chrome, Edge, Brave, Arc, Opera, Vivaldi: name,url,username,password,note
            for row in body {
                items.append(ImportedItem(json: login(name: value(row, col("name")), uri: value(row, col("url")),
                                                      username: value(row, col("username")), password: value(row, col("password")),
                                                      notes: value(row, col("note")).isEmpty ? value(row, col("notes")) : value(row, col("note")))))
            }
        } else {
            throw .unsupported
        }
        guard !items.isEmpty else { throw problems.isEmpty ? .empty : .unsupported }
        return ImportPreview(format: format, folders: folders, items: items, problems: problems)
    }

    static func host(_ uri: String) -> String? {
        let withScheme = uri.contains("://") ? uri : "https://" + uri
        return URL(string: withScheme)?.host()?.replacingOccurrences(of: "www.", with: "")
    }

    // MARK: Request

    /// The `POST /api/ciphers/import` body: every item and folder encrypted with the user key.
    public static func requestBody(items: [ImportedItem], folders: [String], key: SymmetricKeyPair) throws -> Data {
        // Only the folders that are used, re-indexed.
        let used = Array(Set(items.compactMap(\.folder))).sorted()
        let remap = Dictionary(uniqueKeysWithValues: used.enumerated().map { ($1, $0) })
        let ciphers = try items.map { item -> Any in
            var json = item.json
            json["folderId"] = NSNull()
            json["organizationId"] = NSNull()
            return try CipherFields.encrypt(json, key: key)
        }
        let encryptedFolders = try used.map { ["name": try EncString.encrypt(Data(folders[$0].utf8), with: key).description] }
        let relationships = items.enumerated().compactMap { i, item in item.folder.flatMap { remap[$0] }.map { ["key": i, "value": $0] } }
        return try JSONSerialization.data(withJSONObject: ["ciphers": ciphers, "folders": encryptedFolders,
                                                           "folderRelationships": relationships])
    }
}

extension VaultImport {
    /// Splits a large import into requests of at most `limit` items. Items are grouped by folder and whole folders are
    /// kept together where they fit, so a folder is created once (a folder bigger than the limit is split across batches).
    public static func batches(_ items: [ImportedItem], limit: Int) -> [[ImportedItem]] {
        guard items.count > limit else { return [items] }
        let groups = Dictionary(grouping: items, by: { $0.folder ?? -1 }).sorted { $0.key < $1.key }.map(\.value)
        var batches: [[ImportedItem]] = [[]]
        for group in groups {
            for part in stride(from: 0, to: group.count, by: limit).map({ Array(group[$0..<min($0 + limit, group.count)]) }) {
                if batches[batches.count - 1].count + part.count > limit { batches.append([]) }
                batches[batches.count - 1] += part
            }
        }
        return batches.filter { !$0.isEmpty }
    }

    /// The `POST /api/ciphers/import-organization` body: items and collections encrypted with the organization key.
    /// Folders in the file become collections, as in Bitwarden.
    public static func organizationRequestBody(items: [ImportedItem], collections: [String], organizationId: String,
                                               key: SymmetricKeyPair) throws -> Data {
        let used = Array(Set(items.compactMap(\.folder))).sorted()
        let remap = Dictionary(uniqueKeysWithValues: used.enumerated().map { ($1, $0) })
        let ciphers = try items.map { item -> Any in
            var json = item.json
            json["folderId"] = NSNull()
            guard var encrypted = try CipherFields.encrypt(json, key: key) as? [String: Any] else { return [String: Any]() }
            encrypted["organizationId"] = organizationId
            return encrypted
        }
        let encryptedCollections = try used.map {
            ["name": try EncString.encrypt(Data(collections[$0].utf8), with: key).description, "organizationId": organizationId]
        }
        let relationships = items.enumerated().compactMap { i, item in item.folder.flatMap { remap[$0] }.map { ["key": i, "value": $0] } }
        return try JSONSerialization.data(withJSONObject: ["ciphers": ciphers, "collections": encryptedCollections,
                                                           "collectionRelationships": relationships])
    }
}

// MARK: - CSV

public enum CSV {
    /// RFC 4180: quoted fields, doubled quotes, newlines inside quotes, CRLF or LF.
    public static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        let chars = Array(text) // Characters: "\r\n" is one grapheme
        var i = 0
        while i < chars.count {
            let c = chars[i]
            i += 1
            if quoted {
                if c == "\"" {
                    if i < chars.count, chars[i] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"": quoted = true
                case ",": row.append(field); field = ""
                case "\r\n", "\n", "\r": row.append(field); rows.append(row); row = []; field = ""
                default: field.append(c)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    public static func write(_ rows: [[String]]) -> String {
        rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    static func escape(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
