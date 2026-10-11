import TriCrypto
import Foundation
import Testing
@testable import VaultwardenAPI

/// Import / export beyond the basics: a file encrypted by an independent implementation, every item type and the
/// parts that are easy to lose (passkeys, password history, hidden and boolean fields, URI match rules, reprompt,
/// favorites, nested folders), Argon2id files, and damaged or foreign files.
@Suite struct ImportExportCoverageTests {
    let key = try! SymmetricKeyPair(combined: Data((0..<64).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }))

    /// A password-protected export written by DevServer/seed.py's crypto (Python, independent of the app), the way
    /// Bitwarden's clients write one. Password "fixture-pass", PBKDF2 100,000.
    static let independentFile = #"""
{"encrypted": true, "passwordProtected": true, "salt": "c2FsdHktc2FsdA==", "kdfType": 0, "kdfIterations": 100000, "kdfMemory": null, "kdfParallelism": null, "encKeyValidation_DO_NOT_EDIT": "2.rXegPOwSrCaFCetfOcul/Q==|y2JgIOkc5hzYCeQ0pZMOWlFKN3MLtTTb/pFSn0iZranNPHXE4hb78+3CoWlPdaJu|zDSLvWtEFrvx+cjn5/tg2C9nsXRP4H9hjwyy1G7M5vk=", "data": "2.WG9fx098OoGH5fLuU6AWTA==|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"}
"""#

    func fixture() throws -> ImportPreview {
        try VaultImport.preview(Data(Self.independentFile.utf8), password: "fixture-pass")
    }

    @Test func readsAFileFromAnIndependentImplementation() throws {
        #expect(throws: ImportError.passwordRequired) { try VaultImport.preview(Data(Self.independentFile.utf8)) }
        #expect(throws: ImportError.wrongPassword) { try VaultImport.preview(Data(Self.independentFile.utf8), password: "Fixture-pass") }
        let preview = try fixture()
        #expect(preview.format == .bitwardenPasswordProtected)
        #expect(preview.folders == ["Work/Dev"])
        #expect(preview.items.map(\.type) == [1, 3, 4, 2, 5])
        #expect(preview.problems.isEmpty)
    }

    @Test func keepsEverythingAnItemCarries() throws {
        let items = try fixture().items
        let login = items[0]
        #expect(login.folder == 0 && login.json["favorite"] as? Bool == true && login.json["reprompt"] as? Int == 0)
        let l = try #require(login.json["login"] as? [String: Any])
        #expect((l["uris"] as? [[String: Any]])?.map { $0["match"] as? Int } == [nil, 1])
        let passkey = try #require((l["fido2Credentials"] as? [[String: Any]])?.first)
        #expect(passkey["rpId"] as? String == "cloudflare.com" && passkey["keyValue"] as? String == "MIGHAgEA")
        #expect(passkey["counter"] as? String == "0" && passkey["creationDate"] as? String == "2026-01-02T03:04:05.000Z")
        #expect((login.json["fields"] as? [[String: Any]])?.map { $0["type"] as? Int } == [1, 0, 2])
        #expect((login.json["passwordHistory"] as? [[String: Any]])?.first?["password"] as? String == "old-pass")
        #expect(items[1].json["reprompt"] as? Int == 1)
        #expect((items[1].json["card"] as? [String: Any])?["number"] as? String == "4111111111116411")
        #expect((items[2].json["identity"] as? [String: Any])?["passportNumber"] as? String == "X1234")
        #expect(items[3].json["notes"] as? String == "hunter2")
        #expect((items[4].json["sshKey"] as? [String: Any])?["publicKey"] as? String == "ssh-ed25519 AAAAC3 homelab")
    }

    /// The request sent to the server: every secret encrypted, ids and dates plain, and decrypting it gives back
    /// exactly what the file held.
    @Test func importRequestEncryptsEverythingAndLosesNothing() throws {
        let preview = try fixture()
        let body = try VaultImport.requestBody(items: preview.items, folders: preview.folders, key: key)
        let text = String(decoding: body, as: UTF8.self)
        for secret in ["hunter2", "4111111111116411", "old-pass", "MIGHAgEA", "c!F-9x", "X1234", "ops@momonga.dev", "Work/Dev", "apac"] {
            #expect(!text.contains(secret), "\(secret) left in the clear")
        }
        #expect(text.contains("2026-01-02T03:04:05.000Z"), "dates stay plain, as Bitwarden sends them")
        let root = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let sent = try #require(root["ciphers"] as? [[String: Any]])
        #expect(sent.count == preview.items.count)
        for (original, cipher) in zip(preview.items, sent) {
            var back = try #require(CipherFields.decrypt(cipher, key: key) as? [String: Any])
            // The request places items itself (folderRelationships), so these two are always null in it.
            #expect(back.removeValue(forKey: "folderId") is NSNull && back.removeValue(forKey: "organizationId") is NSNull)
            #expect(NSDictionary(dictionary: back).isEqual(to: original.json), "\(original.name) changed on the way")
        }
        #expect((root["folderRelationships"] as? [[String: Int]]) == [["key": 0, "value": 0]])
    }

    /// Our own export of the same vault reads back the same, plain and password-protected (PBKDF2 and Argon2id).
    @Test(arguments: [KDFConfig.pbkdf2(iterations: 100_000), .argon2id(iterations: 3, memoryMiB: 64, parallelism: 4)])
    func exportReadsBackTheSame(kdf: KDFConfig) throws {
        let source = try fixture()
        let folders: [[String: Any]] = source.folders.enumerated().map { ["id": "f\($0.offset)", "name": $0.element] }
        let items: [[String: Any]] = source.items.map { item in
            var json = item.json
            json["folderId"] = item.folder.map { "f\($0)" } ?? NSNull()
            return json
        }
        let plain = try VaultExport.json(folders: folders, items: items)
        let protected = try VaultExport.passwordProtected(plain, password: "pw", kdf: kdf)
        #expect(throws: ImportError.wrongPassword) { try VaultImport.preview(protected, password: "nope") }
        for preview in [try VaultImport.preview(plain), try VaultImport.preview(protected, password: "pw")] {
            #expect(preview.folders == source.folders)
            #expect(preview.items.count == source.items.count)
            for (a, b) in zip(preview.items, source.items) {
                #expect(a.folder == b.folder && NSDictionary(dictionary: a.json).isEqual(to: b.json), "\(a.name) changed")
            }
        }
    }

    // MARK: Damaged and foreign files

    @Test func refusesWhatItCantRead() throws {
        #expect(throws: (any Error).self) { try VaultImport.preview(Data((0..<512).map { _ in UInt8.random(in: 0...255) })) }
        #expect(throws: (any Error).self) { try VaultImport.preview(Data()) }
        #expect(throws: ImportError.empty) { try VaultImport.preview(Data(#"{"encrypted":false,"folders":[],"items":[]}"#.utf8)) }
        #expect(throws: ImportError.empty) { try VaultImport.preview(Data("name,url,username,password,note\n".utf8)) }
        #expect(throws: ImportError.unsupported) {
            try VaultImport.preview(Data(#"{"encrypted":false,"folders":[],"items":[{"type":9,"name":"x"}]}"#.utf8))
        }
    }

    @Test func damagedProtectedFileIsRefusedNotMisread() throws {
        var doc = try #require(try JSONSerialization.jsonObject(with: Data(Self.independentFile.utf8)) as? [String: Any])
        let data = try #require(doc["data"] as? String)
        // Flip a character in the ciphertext: the MAC must catch it.
        var chars = Array(data)
        let i = chars.count / 2
        chars[i] = chars[i] == "A" ? "B" : "A"
        doc["data"] = String(chars)
        let tampered = try JSONSerialization.data(withJSONObject: doc)
        #expect(throws: (any Error).self) { try VaultImport.preview(tampered, password: "fixture-pass") }
        doc["data"] = String(data.prefix(40))
        #expect(throws: (any Error).self) { try VaultImport.preview(JSONSerialization.data(withJSONObject: doc), password: "fixture-pass") }
    }

    @Test func unknownItemsAreReportedAndTheRestImported() throws {
        let file = #"{"encrypted":false,"folders":[],"items":[{"type":9,"name":"future"},{"type":2,"name":"Note","notes":"n","secureNote":{"type":0}}]}"#
        let preview = try VaultImport.preview(Data(file.utf8))
        #expect(preview.items.map(\.name) == ["Note"])
        #expect(preview.problems == [.unknownType(item: 1)])
    }
}

@Suite struct ShareCipherTests {
    let userKey = try! SymmetricKeyPair(combined: Data((0..<64).map { UInt8($0) }))
    let orgKey = try! SymmetricKeyPair(combined: Data((0..<64).map { UInt8(200 - $0) }))

    @Test func sharedCipherIsReencryptedForTheOrganization() throws {
        var edit = CipherEdit(name: "GitHub", notes: "n", username: "usagi", password: "pw", totp: "JBSW", uri: "https://github.com")
        edit.customFields = [CustomField(name: "PIN", value: "0420", kind: .hidden)]
        var raw = try JSONSerialization.jsonObject(with: CipherEditor.newCipher(kind: .login, edit: edit, key: userKey)) as! [String: Any]
        raw["id"] = "c1"; raw["revisionDate"] = "2026-01-01T00:00:00Z"; raw["folderId"] = "f1"
        let shared = try CipherEditor.sharedCipher(raw: JSONSerialization.data(withJSONObject: raw), key: userKey,
                                                   organizationKey: orgKey, organizationId: "o1")
        #expect(shared["organizationId"] as? String == "o1" && shared["key"] is NSNull)
        #expect(shared["lastKnownRevisionDate"] as? String == "2026-01-01T00:00:00Z")
        // Readable with the organization key only.
        let back = try #require(CipherFields.decrypt(shared, key: orgKey) as? [String: Any])
        let login = back["login"] as? [String: Any]
        #expect(back["name"] as? String == "GitHub" && login?["password"] as? String == "pw" && login?["totp"] as? String == "JBSW")
        #expect((back["fields"] as? [[String: Any]])?.first?["value"] as? String == "0420")
        #expect((CipherFields.decrypt(shared, key: userKey) as? [String: Any])?["name"] as? String != "GitHub")
    }

    @Test func attachmentKeysAreRewrappedForTheOrganization() throws {
        let fileKey = Data((0..<64).map { UInt8(truncatingIfNeeded: $0 &* 3) })
        let raw: [String: Any] = ["id": "c1", "type": 2, "name": try EncString.encrypt(Data("x".utf8), with: userKey).description,
                                  "attachments": [["id": "a1", "fileName": try EncString.encrypt(Data("scan.pdf".utf8), with: userKey).description,
                                                   "key": try EncString.encrypt(fileKey, with: userKey).description]]]
        let shared = try CipherEditor.sharedCipher(raw: JSONSerialization.data(withJSONObject: raw), key: userKey,
                                                   organizationKey: orgKey, organizationId: "o1")
        let moved = try #require((shared["attachments2"] as? [String: Any])?["a1"] as? [String: String])
        #expect(try EncString(moved["key"]!).decrypt(with: orgKey) == fileKey, "the file's own key, now under the organization's")
        #expect(try EncString(moved["fileName"]!).decryptString(with: orgKey) == "scan.pdf")
    }

    @Test func severalWebsitesReplaceTheListAndKeepAnUnchangedMatch() throws {
        var created = CipherEdit(name: "Mail")
        created.uris = ["https://mail.google.com", "https://accounts.google.com"]
        var raw = try #require(JSONSerialization.jsonObject(with: CipherEditor.newCipher(kind: .login, edit: created, key: userKey)) as? [String: Any])
        var login = try #require(raw["login"] as? [String: Any])
        var rows = try #require(login["uris"] as? [[String: Any]])
        #expect(rows.count == 2)
        #expect(try EncString(rows[0]["uri"] as? String ?? "").decryptString(with: userKey) == "https://mail.google.com")
        rows[0]["match"] = 0
        login["uris"] = rows
        raw["login"] = login
        var change = CipherEdit()
        change.uris = ["https://mail.google.com", "https://gmail.com"]
        let updated = try #require(JSONSerialization.jsonObject(with: CipherEditor.updatedCipher(
            raw: JSONSerialization.data(withJSONObject: raw), edit: change, key: userKey)) as? [String: Any])
        let next = try #require((updated["login"] as? [String: Any])?["uris"] as? [[String: Any]])
        #expect(next.count == 2)
        #expect(next[0]["match"] as? Int == 0)
        #expect(try EncString(next[1]["uri"] as? String ?? "").decryptString(with: userKey) == "https://gmail.com")
        #expect(!(next[1]["match"] is Int))
    }

    @Test func legacyAttachmentsWithoutTheirOwnKeyAreRefused() throws {
        let raw: [String: Any] = ["id": "c1", "type": 2, "name": "x", "attachments": [["id": "a1", "fileName": "f"]]]
        #expect(throws: CipherEditor.ShareError.self) {
            try CipherEditor.sharedCipher(raw: JSONSerialization.data(withJSONObject: raw), key: userKey, organizationKey: orgKey, organizationId: "o1")
        }
    }
}
