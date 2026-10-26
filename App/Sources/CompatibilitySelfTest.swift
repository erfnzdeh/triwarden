#if DEBUG
import AppKit
import Foundation
import TriCrypto
import VaultwardenAPI

/// Synthetic, offline checks of the shared decoder, the app's mutation boundaries and the menu bar's phase.
@MainActor
enum CompatibilitySelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--selftest-compatibility") else { return }
        AccountStore.namespace = "CompatibilitySelfTest"
        AutoFillIdentities.isEnabled = false
        Task {
            var failures = 0
            func check(_ ok: Bool, _ label: String) {
                print(ok ? "PASS" : "FAIL", label)
                if !ok { failures += 1 }
            }
            do {
                let key = try SymmetricKeyPair(combined: Data((0..<64).map(UInt8.init)))
                func enc(_ value: String) throws -> String {
                    try EncString.encrypt(Data(value.utf8), with: key).description
                }
                let future: [String: Any] = [
                    "id": "future", "type": 99, "name": try enc("Future item"), "folderId": "folder",
                    "revisionDate": "2026-10-12T00:00:00Z", "favorite": true,
                    // A future type may reuse known keys. None of these may become usable credentials.
                    "notes": try enc("synthetic private note"),
                    "login": ["username": try enc("synthetic user"), "password": try enc("synthetic password"),
                              "totp": try enc("JBSWY3DPEHPK3PXP"), "uris": [["uri": try enc("https://example.com")]]],
                    "fields": [["name": try enc("token"), "value": try enc("synthetic token"), "type": 0]],
                    "future": ["UpperCaseKey": [NSNull(), false, 0, "", "測試"]]
                ]
                let known: [[String: Any]] = try (1...5).map { type in
                    ["id": "known-\(type)", "type": type, "name": try enc("Known \(type)")]
                }
                let data = try JSONSerialization.data(withJSONObject: [
                    "profile": ["id": "synthetic", "email": "synthetic@example.com", "key": ""],
                    "folders": [["id": "folder", "name": try enc("Work")]], "ciphers": known + [future]
                ])
                let decoded = try VaultDecoder.decode(data, userKey: key, accountId: "compatibility")
                let item = decoded.items.first { $0.id == "future" }!
                check(decoded.items.count == 6 && decoded.hiddenCount == 0, "unknown item remains discoverable")
                check(item.kind == .unsupported && item.unsupportedType == 99 && !item.isSupported,
                      "server type is retained without login fallback")
                check(item.name == "Future item" && item.folderName == "Work" && item.favorite && item.revised != nil,
                      "shared metadata remains readable")
                check(item.username == nil && item.password == nil && item.totp == nil && item.notes == nil &&
                      item.websites.isEmpty && item.fields.isEmpty && item.passkeys.isEmpty && item.attachments.isEmpty,
                      "unknown payload never becomes credentials or visible fields")
                check(decoded.items.filter(\.isSupported).count == 5, "all existing item types remain supported")
                let raw = try JSONSerialization.jsonObject(with: decoded.rawCiphers["future"]!) as! NSDictionary
                check(raw == future as NSDictionary, "raw unknown payload is retained losslessly")

                let account = SavedAccount(id: "compatibility", email: "synthetic@example.com", serverKind: "selfHosted",
                                           serverURL: "https://example.invalid", kdf: .pbkdf2(iterations: 600_000), protectedUserKey: "")
                AccountStore.saveCache(data, account.id)
                defer { AccountStore.erase(account.id) }
                let session = AccountSession(account: account, userKey: key,
                    makeClient: { VaultClient(environment: $0, deviceIdentifier: "synthetic") }, makeSession: { .shared })
                check(session.items.first { $0.id == "future" }?.unsupportedType == 99,
                      "unknown item survives an offline cache reopen")
                try session.requireWritableItems(["known-1", "known-5"])
                let writes: [(String, () async throws -> Void)] = [
                    ("edit", { try await session.update("future", edit: CipherEdit(name: "changed")) }),
                    ("move", { try await session.update("future", edit: CipherEdit(folderId: .some(nil))) }),
                    ("trash", { try await session.trash("future") }),
                    ("restore", { try await session.restore("future") }),
                    ("delete", { try await session.deleteForever("future") }),
                    ("archive", { try await session.archive("future") }),
                    ("unarchive", { try await session.unarchive("future") }),
                    ("share", { try await session.share("future", organizationId: "org", collectionIds: []) }),
                    ("collections", { try await session.setCollections("future", collectionIds: []) }),
                    ("add attachment", { try await session.addAttachment("future", name: "synthetic", contents: Data()) }),
                    ("delete attachment", { try await session.deleteAttachment("future", "attachment") }),
                    ("mixed batch", { try await session.bulk(.trash, ids: ["known-1", "future"]) })
                ]
                for (label, write) in writes {
                    do { try await write(); check(false, "reject \(label)") }
                    catch CipherEditor.CompatibilityError.unsupportedType(99) { check(true, "reject \(label) before a request") }
                    catch { check(false, "reject \(label) with compatibility error") }
                }
                check(AccountStore.loadCache(account.id) == data, "rejected operations leave encrypted cache unchanged")

                let model = AppModel()
                model.items = decoded.items
                model.previewUnlocked = true
                model.beginEditing(EditRequest(mode: .edit(item)))
                check(model.editing == nil, "edit form cannot open")
                model.beginEditing(EditRequest(mode: .clone(item)))
                check(model.editing == nil, "clone form cannot open")
                await model.bulk(.trash, ["known-1", "future"])
                await model.toggleFavorite(item)
                await model.setArchived(item, true)
                check(model.items == decoded.items, "mixed batch and single actions cannot optimistically mutate unsupported items")
                check(model.itemContextActions(item).allSatisfy { !$0.enabled }, "context menu offers no unsafe actions")

                // The menu bar follows the window's phase: with nothing signed in there is no vault to unlock.
                model.previewUnlocked = false
                for (label, phase) in [("login", AppModel.Phase.login), ("two-step", .twoFactor(providers: [])),
                                       ("device verification", .deviceVerification), ("SSO password", .ssoPassword)] {
                    model.phase = phase
                    check(model.isSignedOut && !model.isUnlocked && !model.hasOpenVault, "menu bar offers a sign-in while \(label)")
                }
                model.phase = .locked
                check(!model.isSignedOut && !model.isUnlocked && !model.hasOpenVault, "menu bar offers an unlock for a locked vault")
                model.previewUnlocked = true
                model.phase = .login
                check(!model.isSignedOut && model.hasOpenVault, "an open vault is not signed out, even on the login screen")
            } catch {
                check(false, "synthetic compatibility fixture: \(error)")
            }
            print("Compatibility self-test: \(failures) failure(s)")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
