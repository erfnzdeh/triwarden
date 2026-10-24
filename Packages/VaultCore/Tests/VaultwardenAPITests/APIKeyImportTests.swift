import Foundation
import Testing
import TriCrypto
@testable import VaultwardenAPI

struct APIKeyImportTests {
    private let keys = [APIKeyImport.Key(variable: "OPENAI_API_KEY", value: "test-only-one"),
                        APIKeyImport.Key(variable: "OTHER_TOKEN", value: "test-only-two")]

    @Test func createsCompatibleSecureNotesWithExactVariableAndReceipt() throws {
        let plan = try APIKeyImport(keys: keys, project: "My project")
        let items = try plan.items()
        #expect(items.count == 2)
        #expect(items[0].name == "My project · OPENAI_API_KEY")
        #expect(items.allSatisfy { $0.type == 2 && $0.json["reprompt"] as? Int == 0 })
        for (item, key) in zip(items, keys) {
            let fields = try #require(item.json["fields"] as? [[String: Any]])
            #expect(fields.first { $0["name"] as? String == "api-key" }?["value"] as? String == key.value)
            #expect(fields.first { $0["name"] as? String == "api-key" }?["type"] as? Int == 1)
            #expect(fields.first { $0["name"] as? String == "environment-variable" }?["value"] as? String == key.variable)
            #expect(fields.first { $0["name"] as? String == "triwarden-import-id" }?["value"] as? String == plan.id)
        }
        #expect(!String(reflecting: plan).contains("test-only-one"))
        #expect(!String(reflecting: keys[0]).contains("test-only-one"))
    }

    @Test func receiptNeedsTheWholeExactSetAndRejectsDuplicates() throws {
        let plan = try APIKeyImport(keys: keys, project: "Project")
        let records = keys.enumerated().map { index, key in
            APIKeyImport.Record(itemID: "item-\(index)", importID: plan.id, variable: key.variable, value: key.value)
        }
        #expect(try plan.verifiedIDs(in: records) == ["item-0", "item-1"])
        #expect(throws: (any Error).self) { try plan.verifiedIDs(in: Array(records.prefix(1))) }
        #expect(throws: (any Error).self) { try plan.verifiedIDs(in: records + [records[0]]) }
        var changed = records
        changed[0] = .init(itemID: "item-0", importID: plan.id, variable: keys[0].variable, value: "wrong")
        #expect(throws: (any Error).self) { try plan.verifiedIDs(in: changed) }
        let unrelated = APIKeyImport.Record(itemID: "unrelated", importID: "another-batch", variable: keys[0].variable, value: keys[0].value)
        #expect(try plan.verifiedIDs(in: records + [unrelated]) == ["item-0", "item-1"])
    }

    @Test func requestEncryptsValuesAndMetadataBeforeDelivery() throws {
        let plan = try APIKeyImport(keys: keys, project: "My project")
        let key = try SymmetricKeyPair(combined: Data((0..<64).map { UInt8($0) }))
        let body = try VaultImport.requestBody(items: plan.items(), folders: [], key: key)
        let text = String(decoding: body, as: UTF8.self)
        for plain in ["test-only-one", "test-only-two", "OPENAI_API_KEY", "My project", plan.id] { #expect(!text.contains(plain)) }
    }

    @Test func rejectsInvalidSelectionsBeforeAnyWrite() {
        for selection in [[], [.init(variable: "9BAD", value: "x")], [.init(variable: "KEY", value: "")],
                          [.init(variable: "KEY", value: "a\u{0}b")], [keys[0], keys[0]],
                          (0..<17).map { .init(variable: "KEY_\($0)", value: "v") },
                          [.init(variable: "KEY", value: String(repeating: "a", count: 32_769))]] as [[APIKeyImport.Key]] {
            #expect(throws: (any Error).self) { try APIKeyImport(keys: selection, project: "Project") }
        }
    }
}
