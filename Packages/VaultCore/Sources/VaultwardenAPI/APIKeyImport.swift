import Foundation

/// An in-memory import plan. The normal vault import path encrypts its items before sending them.
public struct APIKeyImport: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public struct Key: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        public let variable: String
        public let value: String
        public init(variable: String, value: String) { self.variable = variable; self.value = value }
        public var description: String { "APIKeyImportKey(\(variable), value: <masked>)" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: ["variable": variable, "value": "<masked>"]) }
    }
    public struct Record: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        public let itemID: String
        public let importID: String
        public let variable: String
        public let value: String
        public init(itemID: String, importID: String, variable: String, value: String) {
            self.itemID = itemID; self.importID = importID; self.variable = variable; self.value = value
        }
        public var description: String { "APIKeyImportRecord(value: <masked>)" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: ["value": "<masked>"]) }
    }
    public static let receiptField = "triwarden-import-id"
    public let id: String
    public let keys: [Key]
    public let project: String
    public var description: String { "APIKeyImport(\(keys.count) masked keys)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["keyCount": keys.count]) }

    public init(keys: [Key], project: String) throws {
        guard (1...16).contains(keys.count), Set(keys.map(\.variable)).count == keys.count,
              keys.allSatisfy({ $0.variable.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,127}$", options: .regularExpression) != nil &&
                  !$0.value.isEmpty && !$0.value.utf8.contains(0) }),
              keys.reduce(0, { $0 + $1.value.utf8.count }) <= 32_768 else { throw Failure.invalidSelection }
        let name = project.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 256,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.invalidSelection }
        self.keys = keys; self.project = name; id = UUID().uuidString
    }

    public func items() throws -> [ImportedItem] {
        keys.map { key in
            ImportedItem(json: ["type": 2, "name": project + " · " + key.variable, "reprompt": 0,
                "secureNote": ["type": 0], "fields": [
                    ["name": "api-key", "value": key.value, "type": 1],
                    ["name": "environment-variable", "value": key.variable, "type": 0],
                    ["name": Self.receiptField, "value": id, "type": 0]
                ]], folder: nil)
        }
    }

    /// Return IDs in selection order. Duplicate or partial receipts cannot complete migration.
    public func verifiedIDs(in records: [Record]) throws -> [String] {
        let matches = records.filter { $0.importID == id }
        guard matches.count == keys.count, Set(matches.map(\.itemID)).count == matches.count,
              matches.allSatisfy({ !$0.itemID.isEmpty }) else { throw Failure.incompleteReceipt }
        return try keys.map { key in
            let found = matches.filter { $0.variable == key.variable }
            guard found.count == 1, Data(found[0].value.utf8) == Data(key.value.utf8) else { throw Failure.incompleteReceipt }
            return found[0].itemID
        }
    }

    private enum Failure: Error, LocalizedError {
        case invalidSelection, incompleteReceipt
        var errorDescription: String? {
            switch self {
            case .invalidSelection: "Select 1 to 16 keys and enter a project name. Use at most 32 KiB of key values."
            case .incompleteReceipt: "Cannot confirm all imported keys. Sync the destination account and check the saved items before you import again."
            }
        }
    }
}
