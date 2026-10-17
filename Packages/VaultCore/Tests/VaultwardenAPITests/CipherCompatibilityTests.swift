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
