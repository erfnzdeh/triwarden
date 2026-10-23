import Foundation

/// A menu of saved references. Selection neither resolves credentials nor grants permission.
public struct SavedToolSelection {
    public let profiles: [SecretsProfile]

    public init(profiles: [SecretsProfile]) throws {
        guard !profiles.isEmpty else { throw SecretsFailure("No saved tools. Open Tools in Triwarden to add a tool.") }
        guard profiles.count <= 64, Set(profiles.map(\.name)).count == profiles.count else {
            throw SecretsFailure("Open Tools in Triwarden to repair the saved tool list.")
        }
        for profile in profiles { try profile.validate() }
        self.profiles = profiles.sorted { lhs, rhs in
            let order = lhs.title.localizedStandardCompare(rhs.title)
            if order != .orderedSame { return order == .orderedAscending }
            if lhs.directory != rhs.directory { return lhs.directory < rhs.directory }
            return lhs.name < rhs.name
        }
    }

    public var text: String {
        profiles.enumerated().map { index, profile in
            let duplicates = profiles.filter { $0.title == profile.title && $0.directory == profile.directory }.count > 1
            return "\(index + 1)) " + profile.title + (profile.enabled ? "" : " (paused)") + "\n   " + profile.directory +
                (duplicates ? " · " + profile.name : "")
        }.joined(separator: "\n")
    }

    public func select(_ input: String) throws -> SecretsProfile? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value.lowercased() == "q" { return nil }
        guard value.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(value), profiles.indices.contains(number - 1) else {
            throw SecretsFailure("Enter a number from 1 to \(profiles.count), or q to cancel.")
        }
        let profile = profiles[number - 1]
        guard profile.enabled else { throw SecretsFailure("This tool is paused. Resume it in Tools or choose another tool.") }
        return profile
    }
}
