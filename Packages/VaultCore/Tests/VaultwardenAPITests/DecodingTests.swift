import Foundation
import Testing
import TriCrypto
@testable import VaultwardenAPI

@Suite struct DecodingTests {
    @Test func decodesPascalCaseSync() throws {
        let json = #"""
        {"Profile":{"Id":"u1","Email":"usagi@example.com","Key":"2.a|b|c"},
         "Ciphers":[{"Id":"c1","Type":1,"OrganizationId":null,"Name":"2.x|y|z",
                     "Login":{"Username":"2.u|u|u","Password":null,"Totp":null,"Uris":[{"Uri":"2.q|q|q"}]},
                     "Favorite":true,"DeletedDate":null}]}
        """#
        let sync = try JSONDecoder.vaultwarden.decode(SyncResponse.self, from: Data(json.utf8))
        #expect(sync.profile.email == "usagi@example.com")
        #expect(sync.ciphers.first?.login?.uris?.first?.uri == "2.q|q|q")
    }

    @Test func decodesTokenAndTwoFactorChallenge() throws {
        let token = try JSONDecoder.vaultwarden.decode(TokenResponse.self, from: Data(
            #"{"access_token":"a","refresh_token":"r","expires_in":7200,"Key":"2.k|k|k"}"#.utf8))
        #expect(token.key == "2.k|k|k")
        let err = try JSONDecoder.vaultwarden.decode(TokenErrorResponse.self, from: Data(
            #"{"error":"invalid_grant","error_description":"Two factor required.","TwoFactorProviders":[0]}"#.utf8))
        #expect(err.twoFactorProviders == ["0"])
    }

    @Test func kdfMapping() throws {
        let p = try JSONDecoder.vaultwarden.decode(PreloginResponse.self, from: Data(
            #"{"Kdf":1,"KdfIterations":3,"KdfMemory":64,"KdfParallelism":4}"#.utf8))
        #expect(try p.config() == .argon2id(iterations: 3, memoryMiB: 64, parallelism: 4))
    }
}

@Suite struct SendSealTests {
    let key = try! SymmetricKeyPair(combined: Data((0..<64).map(UInt8.init)))

    private func body(_ draft: SendDraft, keyMaterial: Data?) throws -> [String: Any] {
        let sealed = try draft.seal(userKey: key, keyMaterial: keyMaterial)
        return try #require(JSONSerialization.jsonObject(with: sealed.body) as? [String: Any])
    }

    /// Editing with the field left blank must not touch the server's hash: sending null would wipe the password and
    /// leave the link open to anyone holding it.
    @Test func editingWithoutTypingAPasswordLeavesTheHashAlone() throws {
        let draft = SendDraft(name: "Wi-Fi", content: .text("pochi-net", hidden: true),
                              deletionDate: .now.addingTimeInterval(86_400))
        let json = try body(draft, keyMaterial: Data(repeating: 7, count: 16))
        #expect(json["password"] == nil)
    }

    /// A new Send has no hash to keep, so it states plainly that there is none.
    @Test func aNewSendWithNoPasswordSaysSo() throws {
        let draft = SendDraft(name: "Wi-Fi", content: .text("pochi-net", hidden: true),
                              deletionDate: .now.addingTimeInterval(86_400))
        let json = try body(draft, keyMaterial: nil)
        #expect(json["password"] is NSNull)
    }

    /// Typing a new one replaces it, on a new Send and on an edit alike — and what travels is a hash, not the text.
    @Test func typingAPasswordHashesIt() throws {
        let editing = Data(repeating: 7, count: 16)
        for material in [nil, editing] as [Data?] {
            var draft = SendDraft(name: "Wi-Fi", content: .text("pochi-net", hidden: true),
                                  deletionDate: .now.addingTimeInterval(86_400))
            draft.password = "open sesame"
            let stored = try #require(body(draft, keyMaterial: material)["password"] as? String)
            #expect(stored != "open sesame")
            // Editing hashes against the Send's own key material, so the hash the server already holds still matches.
            if let material {
                #expect(stored == (try SendCrypto.passwordHash("open sesame", keyMaterial: material)))
            }
        }
    }
}
