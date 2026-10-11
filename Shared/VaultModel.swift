import TriCrypto
import Foundation
import VaultwardenAPI

// Shared by the app and the AutoFill extension.

struct VaultItem: Identifiable, Hashable {
    enum Kind: Int { case login = 1, note = 2, card = 3, identity = 4, sshKey = 5 }

    let id: String
    /// Which saved account this item belongs to (several can be unlocked at once).
    var accountId = ""
    var kind: Kind = .login
    var name: String
    var username: String?
    let host: String?
    let password: String?
    let totp: TOTP?
    let notes: String?
    var totpSecret: String?
    /// The first website. The full list is `uris`.
    var uri: String?
    /// Every website on the login, in order.
    var uris: [String] = []
    var favorite: Bool
    var hasPasskey = false
    var folderId: String?
    /// Decrypted folder name, e.g. "Work/Servers" (nested by "/").
    var folderName: String?
    var isDeleted = false
    /// When it went to the Trash.
    var deleted: Date?
    /// When it was archived; archived items stay in the vault but out of the lists, search and AutoFill.
    var archived: Date?
    var isArchived: Bool { archived != nil }
    var organizationId: String?
    var collectionIds: [String] = []
    /// When the item was last changed and first created (from the server).
    var revised: Date?
    var created: Date?
    /// When the password was last changed, as the server recorded it.
    var passwordRevised: Date?
    /// Filled in after sync: how many other items share this password.
    var reuseCount = 0
    /// Ask for the master password before showing or using its secrets.
    var reprompt = false
    /// Earlier passwords, newest first.
    var passwordHistory: [PastPassword] = []

    struct PastPassword: Hashable, Sendable {
        var password: String
        var date: Date?
    }

    var hasTOTP: Bool { totp != nil }

    /// Websites to show and edit. Falls back to `uri` for an item decoded before the list was kept.
    var websites: [String] {
        let list = uris.filter { !$0.isEmpty }
        if !list.isEmpty { return list }
        if let uri, !uri.isEmpty { return [uri] }
        return []
    }

    /// Host of each website, for matching a page to this login.
    var hosts: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in websites {
            let address = raw.contains("://") ? raw : "https://\(raw)"
            guard let host = URL(string: address)?.host()?.lowercased(), seen.insert(host).inserted else { continue }
            out.append(host)
        }
        if out.isEmpty, let host = host?.lowercased(), seen.insert(host).inserted { out.append(host) }
        return out
    }

    /// Extra fields for non-login kinds (card, identity, SSH key), in display order.
    var fields: [ItemField] = []
    /// Raw card / identity / SSH-key properties by API name, for editing.
    var properties: [String: String] = [:]
    /// Custom fields (text, hidden, boolean, linked).
    var customFields: [CustomField] = []
    /// Decrypted passkeys (ES256) on this login.
    var passkeys: [PasskeyCredential] = []
    var attachments: [Attachment] = []

    /// File metadata; contents are fetched and decrypted on demand.
    struct Attachment: Identifiable, Hashable, Sendable {
        var id: String
        var fileName: String
        var size: Int
        var sizeName: String
        var url: String?
        /// Decrypts the file contents.
        var fileKey: SymmetricKeyPair
        static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.fileName == b.fileName && a.size == b.size }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    /// Equal when everything shown is the same — not just the id: SwiftUI compares views' inputs with this, and an
    /// id-only check made it skip redrawing after a favorite, archive or edit. (Hashing stays by id, for identity.)
    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.revised == b.revised && a.favorite == b.favorite && a.isDeleted == b.isDeleted
            && a.archived == b.archived && a.name == b.name && a.username == b.username && a.password == b.password
            && a.notes == b.notes && a.totpSecret == b.totpSecret && a.uri == b.uri && a.uris == b.uris && a.folderId == b.folderId
            && a.folderName == b.folderName && a.organizationId == b.organizationId && a.collectionIds == b.collectionIds
            && a.reprompt == b.reprompt && a.properties == b.properties && a.customFields == b.customFields
            && a.attachments == b.attachments && a.passwordHistory == b.passwordHistory && a.passwordRevised == b.passwordRevised && a.deleted == b.deleted && a.reuseCount == b.reuseCount
            && a.passkeys.map(\.credentialId) == b.passkeys.map(\.credentialId) && a.accountId == b.accountId
    }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// A folder, organization or collection shown in the sidebar.
struct Grouping: Identifiable, Hashable {
    let id: String
    let name: String
    var children: [Grouping] = []
}

struct ItemField: Hashable, Identifiable {
    var id: String { label }
    let label: String
    let value: String
    var secret = false
    var monospaced = false
}

extension TOTP: @retroactive Hashable {
    public func hash(into h: inout Hasher) { h.combine(secret) }

    /// "621 115" — grouped for reading aloud and typing.
    func displayCode(at date: Date = .now) -> String {
        let c = code(at: date)
        return c.prefix(c.count / 2) + " " + c.suffix(c.count - c.count / 2)
    }
}


extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }

    /// Groups a card number for reading: Visa-style 4-4-4-4, Amex 4-6-5. Non-digits are stripped first.
    var formattedAsCardNumber: String {
        let digits = filter(\.isNumber)
        guard !digits.isEmpty else { return self }
        let groups: [Int]
        if digits.count == 15 { groups = [4, 6, 5] } // Amex
        else if digits.count == 14 { groups = [4, 6, 4] } // Diners
        else { groups = Array(repeating: 4, count: (digits.count + 3) / 4) }
        var i = digits.startIndex
        var parts: [Substring] = []
        for n in groups where i < digits.endIndex {
            let end = digits.index(i, offsetBy: n, limitedBy: digits.endIndex) ?? digits.endIndex
            parts.append(digits[i..<end])
            i = end
        }
        if i < digits.endIndex { parts.append(digits[i...]) }
        return parts.joined(separator: " ")
    }
}

/// A decrypted Send owned by one of the accounts.
struct SendItem: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case text, file }
    var id: String
    var accountId: String
    var accessId: String
    var kind: Kind
    var name: String
    var notes: String?
    var text: String?
    var hideText: Bool
    var fileName: String?
    var sizeName: String?
    /// Goes in the link's fragment; derives the Send key.
    var keyMaterial: Data
    var accessCount: Int
    var maxAccessCount: Int?
    var hasPassword: Bool
    var hideEmail = false
    var disabled: Bool
    var deletionDate: Date?
    var expirationDate: Date?

    var isExpired: Bool { expirationDate.map { $0 < .now } ?? false }
    var isUsedUp: Bool { maxAccessCount.map { accessCount >= $0 } ?? false }
}
