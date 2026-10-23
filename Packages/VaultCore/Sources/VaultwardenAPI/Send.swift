import TriCrypto
import Foundation

/// A Send as the server returns it (sync and create). Name, notes, text and file name are EncStrings
/// under the Send key; `key` is the key material under the user key.
public struct SendResponse: Decodable, Sendable {
    public struct Text: Decodable, Sendable { public let text: String?; public let hidden: Bool? }
    public struct File: Decodable, Sendable {
        public let id: String?
        public let fileName: String?
        public let size: String?
        public let sizeName: String?

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id)
            fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
            if let n = try? c.decodeIfPresent(Int.self, forKey: .size) { size = String(n) } else {
                size = try c.decodeIfPresent(String.self, forKey: .size)
            }
            sizeName = try c.decodeIfPresent(String.self, forKey: .sizeName)
        }
        enum CodingKeys: String, CodingKey { case id, fileName, size, sizeName }
    }

    public let id: String
    public let accessId: String?
    public let type: Int
    public let name: String?
    public let notes: String?
    public let key: String?
    public let text: Text?
    public let file: File?
    public let maxAccessCount: Int?
    public let accessCount: Int?
    public let password: String?
    public let disabled: Bool?
    public let hideEmail: Bool?
    public let revisionDate: String?
    public let expirationDate: String?
    public let deletionDate: String?
}

public extension SyncResponse {
    /// Sends come with the sync payload; decoded separately so a malformed one never breaks the vault.
    static func sends(_ data: Data) -> [SendResponse] {
        struct Wrapper: Decodable { let sends: [SendResponse]? }
        return (try? JSONDecoder.vaultwarden.decode(Wrapper.self, from: data))?.sends ?? []
    }
}

/// What the user fills in for a new Send.
public struct SendDraft: Sendable {
    public enum Content: Sendable {
        case text(String, hidden: Bool)
        case file(name: String, contents: Data)
    }

    public var name: String
    public var notes: String = ""
    public var content: Content
    public var deletionDate: Date
    public var expirationDate: Date?
    public var maxAccessCount: Int?
    public var password: String?
    public var hideEmail = false

    public init(name: String, content: Content, deletionDate: Date) {
        self.name = name; self.content = content; self.deletionDate = deletionDate
    }

    /// The create body plus everything needed afterwards (link key, encrypted file).
    public struct Sealed: Sendable {
        public let body: Data
        public let keyMaterial: Data
        public let encryptedFile: Data?
    }

    /// `keyMaterial`: an existing Send's, when editing it (the link keeps working); nil makes a new one.
    public func seal(userKey: SymmetricKeyPair, keyMaterial: Data? = nil) throws -> Sealed {
        let material = try keyMaterial ?? SendCrypto.newKeyMaterial()
        let key = try SendCrypto.key(from: material)
        func enc(_ s: String) throws -> Any { s.isEmpty ? NSNull() : try EncString.encrypt(Data(s.utf8), with: key).description }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var body: [String: Any] = [
            "name": try enc(name), "notes": try enc(notes),
            "key": try EncString.encrypt(material, with: userKey).description,
            "deletionDate": iso.string(from: deletionDate),
            "expirationDate": expirationDate.map(iso.string(from:)) ?? NSNull(),
            "maxAccessCount": maxAccessCount ?? NSNull(),
            "hideEmail": hideEmail, "disabled": false,
        ]
        // The server holds only a one-way hash of the passphrase, so an edit can never show it again. Sending null
        // would wipe that hash and leave the link open to anyone holding it. So when editing (keyMaterial != nil) a
        // nil password means "leave it as it is" and the key is left out of the body; `remove-password` is how it
        // goes away. A new Send has no existing password, so null is the right value there.
        if let password, !password.isEmpty {
            body["password"] = try SendCrypto.passwordHash(password, keyMaterial: material)
        } else if keyMaterial == nil {
            body["password"] = NSNull()
        }
        var encryptedFile: Data?
        switch content {
        case .text(let text, let hidden):
            body["type"] = 0
            body["text"] = ["text": try enc(text), "hidden": hidden]
        case .file(let fileName, let contents):
            let sealed = try EncArrayBuffer.encrypt(contents, with: key)
            body["type"] = 1
            body["file"] = ["fileName": try enc(fileName)]
            body["fileLength"] = sealed.count
            encryptedFile = sealed
        }
        return Sealed(body: try JSONSerialization.data(withJSONObject: body), keyMaterial: material, encryptedFile: encryptedFile)
    }
}

public extension ServerEnvironment {
    /// The share link. The key material lives in the fragment, so the server never sees it.
    func sendLink(accessId: String, keyMaterial: Data) -> URL? {
        let tail = "\(accessId)/\(keyMaterial.base64URLEncoded)"
        switch self {
        case .bitwardenUS: return URL(string: "https://send.bitwarden.com/#\(tail)")
        case .bitwardenEU: return URL(string: "https://vault.bitwarden.eu/#/send/\(tail)")
        case .selfHosted(let base): return URL(string: base.appendingSlash.absoluteString + "#/send/\(tail)")
        case .custom(let urls):
            guard let root = urls.webVault ?? urls.base else { return nil }
            return URL(string: root.appendingSlash.absoluteString + "#/send/\(tail)")
        }
    }
}
