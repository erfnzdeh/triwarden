import Foundation
import Testing
import TriCrypto
@testable import VaultwardenAPI

@Suite struct CipherCompatibilityTests {
    let key = try! SymmetricKeyPair(combined: Data((0..<64).map(UInt8.init)))

    @Test(arguments: [0, -1, 6, 99])
    func unknownTypesCannotBePatchedOrReencrypted(_ type: Int) throws {
        let raw = try JSONSerialization.data(withJSONObject: [
            "id": "future", "type": type, "name": "opaque", "futurePayload": ["token": "opaque"]
        ] as [String: Any])
        #expect(throws: CipherEditor.CompatibilityError.unsupportedType(type)) {
            try CipherEditor.updatedCipher(raw: raw, edit: CipherEdit(favorite: true), key: key)
        }
        #expect(throws: CipherEditor.CompatibilityError.unsupportedType(type)) {
            try CipherEditor.sharedCipher(raw: raw, key: key, organizationKey: key, organizationId: "org")
        }
    }

    @Test(arguments: [1, 2, 3, 4, 5])
    func knownTypesRetainFutureFieldsWhenPatched(_ type: Int) throws {
        let raw = Data("""
        {"id":"known","type":\(type),"revisionDate":"2026-10-12T00:00:00Z",
         "future":{"nested":[null,false,0,"",{"token":"opaque"}],"unicode":"測試"},
         "login":{"future":{"enabled":false}},"favorite":false}
        """.utf8)
        let original = try #require(JSONSerialization.jsonObject(with: raw) as? NSDictionary)
        let updated = try CipherEditor.updatedCipher(raw: raw, edit: CipherEdit(favorite: true), key: key)
        let patched = try #require(JSONSerialization.jsonObject(with: updated) as? NSDictionary)
        #expect(patched["future"] as? NSDictionary == original["future"] as? NSDictionary)
        #expect(patched["login"] as? NSDictionary == original["login"] as? NSDictionary)
        #expect(patched["type"] as? Int == type)
        #expect(patched["favorite"] as? Bool == true)
        #expect(patched["lastKnownRevisionDate"] as? String == original["revisionDate"] as? String)
    }

    @Test func unknownTypeCannotBecomeAPartialExport() throws {
        let name = try EncString.encrypt(Data("Future item".utf8), with: key).description
        let sync = try JSONSerialization.data(withJSONObject: [
            "profile": ["id": "user", "email": "synthetic@example.com", "key": ""],
            "ciphers": [["id": "future", "type": 99, "name": name, "futurePayload": ["token": "opaque"]]]
        ] as [String: Any])
        #expect(throws: CipherEditor.CompatibilityError.unsupportedType(99)) {
            try VaultExport.plainVault(syncData: sync, userKey: key)
        }
    }

    @Test func opaqueCipherKeysSurviveRawExtraction() throws {
        let future: [String: Any] = ["Id": "future", "Type": 99, "Name": "opaque",
                                  "FuturePayload": ["UPPER": "opaque", "NestedKey": [false, NSNull(), ""]]]
        let sync = try JSONSerialization.data(withJSONObject: ["Ciphers": [future]])
        let extracted = try #require(CipherEditor.rawCiphers(fromSync: sync)["future"])
        #expect(try JSONSerialization.jsonObject(with: extracted) as? NSDictionary == future as NSDictionary)
    }

    @Test func unknownPayloadShapesDoNotBreakTheVault() throws {
        let sync = Data("""
        {"profile":{"id":"user","email":"synthetic@example.com","key":""},
         "ciphers":[{"id":"future","type":99,"name":"opaque","notes":{"new":"shape"},
                     "login":"opaque","fields":false,"attachments":42,"passwordHistory":{}},
                    {"id":"known","type":1,"name":"opaque","login":{"username":"opaque"}}]}
        """.utf8)
        let decoded = try SyncResponse.decode(sync)
        #expect(decoded.ciphers.count == 2)
        #expect(decoded.ciphers[0].type == 99 && decoded.ciphers[0].login == nil && decoded.ciphers[0].fields == nil)
        #expect(decoded.ciphers[1].login?.username == "opaque")
        let raw = try #require(CipherEditor.rawCiphers(fromSync: sync)["future"])
        let future = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        #expect(future["login"] as? String == "opaque" && future["attachments"] as? Int == 42)
    }
}

/// Every cipher write body names the account it belongs to. Bitwarden's web-v2025.6.0 added `encryptedFor` to the
/// cipher request, and Vaultwarden 1.37 deserializes it as a required user id: a body without it is refused with
/// 422 before the request is handled, on create, edit, share and import alike.
@Suite struct CipherWriteBodyTests {
    let owner = "bbf61681-e775-4807-8ae7-48f860b6986a"

    @Test func theOwnerIsTheAccessTokensSubject() throws {
        let claims = try JSONSerialization.data(withJSONObject: ["email": "usagi@chiikawarden.test", "sub": owner])
        let segment = claims.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(VaultClient.jwtClaim("sub", "header.\(segment).signature") == owner)
    }

    @Test func aNewItemNamesItsOwnerAndKeepsItsShape() throws {
        let body = Data(#"{"type":2,"name":"2.x|y|z","folderId":null,"favorite":false,"secureNote":{"type":0}}"#.utf8)
        let object = try #require(JSONSerialization.jsonObject(with: VaultClient.cipherBody(body, owner: owner)) as? [String: Any])
        #expect(object["encryptedFor"] as? String == owner)
        #expect(object["type"] as? Int == 2)
        #expect((object["secureNote"] as? [String: Any])?["type"] as? Int == 0)
        #expect(object["folderId"] as? NSNull != nil)
    }

    @Test func anEditedItemNamesItsOwner() throws {
        // The PUT body is the server's own JSON with the edit patched in, and the server never sends this back.
        let body = Data(#"{"id":"c1","type":1,"name":"2.x|y|z","login":{"username":"2.a|b|c"},"revisionDate":"2026-10-12T00:00:00Z"}"#.utf8)
        let object = try #require(JSONSerialization.jsonObject(with: VaultClient.cipherBody(body, owner: owner)) as? [String: Any])
        #expect(object["encryptedFor"] as? String == owner)
        #expect(object["id"] as? String == "c1")
        #expect((object["login"] as? [String: Any])?["username"] as? String == "2.a|b|c")
    }

    @Test func everyImportedItemNamesItsOwner() throws {
        let body = Data(#"{"ciphers":[{"type":1,"name":"a"},{"type":2,"name":"b"}],"folders":[{"name":"c"}],"folderRelationships":[{"key":0,"value":0}]}"#.utf8)
        let root = try #require(JSONSerialization.jsonObject(with: VaultClient.importBody(body, owner: owner)) as? [String: Any])
        let ciphers = try #require(root["ciphers"] as? [[String: Any]])
        #expect(ciphers.count == 2)
        #expect(ciphers.allSatisfy { $0["encryptedFor"] as? String == owner })
        #expect((root["folders"] as? [[String: Any]])?.count == 1)
        #expect((root["folderRelationships"] as? [[String: Any]])?.count == 1)
    }

    @Test func bodiesWithoutAnOwnerAreLeftAlone() {
        // An older server sees exactly what it saw before, and so does a token that carries no subject.
        let body = Data(#"{"type":2,"name":"x"}"#.utf8)
        #expect(VaultClient.cipherBody(body, owner: nil) == body)
        #expect(VaultClient.importBody(body, owner: nil) == body)
    }
}
