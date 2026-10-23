import CryptoKit
import Darwin
import Foundation

public struct SecretsFailure: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct SecretField: Sendable {
    public let name: String
    public let value: String
    public let hidden: Bool
    public init(name: String, value: String, hidden: Bool) {
        self.name = name; self.value = value; self.hidden = hidden
    }
}

public enum SecretSelector: Codable, Equatable, Sendable {
    case password
    case hidden(String)

    public var label: String {
        switch self { case .password: "Password"; case .hidden(let name): name }
    }

    public func resolve(password: String?, fields: [SecretField]) throws -> String {
        let value: String?
        switch self {
        case .password: value = password
        case .hidden(let name):
            let matches = fields.filter { $0.name == name }
            guard matches.count == 1, matches[0].hidden else {
                throw SecretsFailure("The hidden field is missing, renamed, or duplicated. Select the key again through Tools > Edit Setup.")
            }
            value = matches[0].value
        }
        guard let value, !value.isEmpty, !value.utf8.contains(0), value.utf8.count <= 32_768 else {
            throw SecretsFailure("The selected field is empty or cannot be used as an environment variable.")
        }
        return value
    }
}

public struct SecretsBinding: Codable, Equatable, Sendable {
    public var accountID: String
    public var itemID: String
    public var field: SecretSelector
    public var variable: String
    public init(accountID: String, itemID: String, field: SecretSelector, variable: String) {
        self.accountID = accountID; self.itemID = itemID; self.field = field; self.variable = variable
    }
}

/// Reference-only tool settings. No resolved credential values are stored here.
public struct SecretsProfile: Codable, Equatable, Sendable {
    public var name: String
    public var accountID: String
    public var itemID: String
    public var field: SecretSelector
    public var variable: String
    public var executable: String
    public var arguments: [String]
    public var directory: String
    public var enabled: Bool
    public var displayName: String?
    public var additionalBindings: [SecretsBinding]?
    public var bindings: [SecretsBinding] {
        [SecretsBinding(accountID: accountID, itemID: itemID, field: field, variable: variable)] + (additionalBindings ?? [])
    }
    public var title: String { displayName ?? name }

    public init(name: String, accountID: String, itemID: String, field: SecretSelector, variable: String,
                executable: String, arguments: [String], directory: String, enabled: Bool = true, displayName: String? = nil,
                additionalBindings: [SecretsBinding]? = nil) {
        self.name = name; self.accountID = accountID; self.itemID = itemID; self.field = field
        self.variable = variable; self.executable = executable; self.arguments = arguments
        self.directory = directory; self.enabled = enabled
        self.displayName = displayName
        self.additionalBindings = additionalBindings
    }

    public func validate() throws {
        guard name.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$", options: .regularExpression) != nil,
              !accountID.isEmpty, !itemID.isEmpty,
              executable.hasPrefix("/"), directory.hasPrefix("/"), arguments.count <= 128,
              ([accountID, itemID, executable, directory, field.label] + arguments).allSatisfy(Self.safeText),
              arguments.reduce(0, { $0 + $1.utf8.count }) <= 16_384 else {
            throw SecretsFailure("Use a short tool ID, an exact vault field, and absolute paths for the executable and working folder. Arguments must use single lines.")
        }
        if let displayName {
            guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  displayName.count <= 128, Self.safeText(displayName) else {
                throw SecretsFailure("Give this tool a name of up to 128 characters without control characters.")
            }
        }
        guard bindings.count <= 16, Set(bindings.map(\.variable)).count == bindings.count,
              bindings.allSatisfy({ !$0.accountID.isEmpty && !$0.itemID.isEmpty &&
                  [$0.accountID, $0.itemID, $0.field.label].allSatisfy(Self.safeText) }),
              try JSONEncoder().encode(self).count <= 48 * 1024 else {
            throw SecretsFailure("Use up to 16 valid key references with different environment variable names.")
        }
        for binding in bindings { try LaunchPolicy.validateVariable(binding.variable) }
    }

    /// Exclude control and bidi-formatting characters from approval text as well as exec arguments.
    public static func safeText(_ value: String) -> Bool {
        value.utf8.count <= 4096 && !value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format
        }
    }

    public func requireApprovedRevision(_ approved: String?) throws {
        guard let approved, try revision() == approved else {
            throw SecretsFailure("This tool needs confirmation on this Mac. Review and save its settings through Tools > Edit Setup.")
        }
    }

    public func revision() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct SecretsProfileStore: Sendable {
    private struct Catalog: Codable { var version = 1; var profiles: [SecretsProfile] }
    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("profile.json") }
    public init(directory: URL) { self.directory = directory }

    public static var shared: Self {
        let group = "FX3VR69P5K.io.github.sinhong2011.triwarden"
        let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/" + group)
        return Self(directory: root.appendingPathComponent("Secrets", isDirectory: true))
    }

    public var socketURL: URL { directory.deletingLastPathComponent().appendingPathComponent("run.sock") }

    public func loadAll() throws -> [SecretsProfile] {
        let fd = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return [] }
            throw SecretsFailure("Cannot read the saved tools. Open Tools in Triwarden to review the error.")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= 4 * 1024 * 1024 else {
            throw SecretsFailure("The tool file has unsafe permissions or an invalid size. Save the tool again through Tools > Edit Setup.")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let profiles: [SecretsProfile]
        if object?["profiles"] != nil || object?["version"] != nil {
            let catalog = try JSONDecoder().decode(Catalog.self, from: data)
            guard catalog.version == 1 else { throw SecretsFailure("This tool settings format is unsupported.") }
            profiles = catalog.profiles
        } else { profiles = [try JSONDecoder().decode(SecretsProfile.self, from: data)] }
        guard profiles.count <= 64, Set(profiles.map(\.name)).count == profiles.count else {
            throw SecretsFailure("The saved tools contain duplicate names or exceed the limit of 64.")
        }
        for profile in profiles { try profile.validate() }
        return profiles.sorted { $0.name < $1.name }
    }

    public func load() throws -> SecretsProfile {
        let profiles = try loadAll()
        guard profiles.count == 1 else { throw SecretsFailure("Copy the required launch command from Tools in Triwarden.") }
        return profiles[0]
    }

    public func load(named name: String) throws -> SecretsProfile {
        guard let profile = try loadAll().first(where: { $0.name == name }) else {
            throw SecretsFailure("The requested tool is missing. Use tw tools list to find its launch command.")
        }
        return profile
    }

    public func revision() throws -> String {
        try Self.revision(of: loadAll())
    }

    public static func revision(of profiles: [SecretsProfile]) throws -> String {
        if profiles.count == 1 { return try profiles[0].revision() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(Catalog(profiles: profiles.sorted { $0.name < $1.name }))).map { String(format: "%02x", $0) }.joined()
    }

    public func requireApprovedRevision(_ approved: String?, profiles: [SecretsProfile]? = nil) throws {
        guard let approved, try Self.revision(of: profiles ?? loadAll()) == approved else {
            throw SecretsFailure("These tools need confirmation on this Mac. Review and save their settings through Tools > Edit Setup.")
        }
    }

    @discardableResult
    public func save(_ profile: SecretsProfile, basedOn snapshot: [SecretsProfile]? = nil) throws -> String {
        try profile.validate()
        var profiles = try snapshot ?? loadAll()
        profiles.removeAll { $0.name == profile.name }
        profiles.append(profile)
        return try write(profiles)
    }

    @discardableResult
    public func remove(named name: String, basedOn snapshot: [SecretsProfile]? = nil) throws -> String {
        try write((snapshot ?? loadAll()).filter { $0.name != name })
    }

    /// Explicit recovery to a known empty catalog. Never imports unreviewed file contents.
    @discardableResult
    public func clear() throws -> String { try write([]) }

    private func write(_ profiles: [SecretsProfile]) throws -> String {
        guard profiles.count <= 64, Set(profiles.map(\.name)).count == profiles.count else {
            throw SecretsFailure("Use up to 64 tools with unique names. Remove an unused setup first.")
        }
        for profile in profiles { try profile.validate() }
        let intendedRevision = try Self.revision(of: profiles)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SecretsFailure("Cannot create the private tool file. Open Tools in Triwarden to review the error.") }
        defer { close(fd); unlink(temporary.path) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: encoder.encode(Catalog(profiles: profiles.sorted { $0.name < $1.name })))
        guard fsync(fd) == 0, rename(temporary.path, fileURL.path) == 0 else {
            throw SecretsFailure("Cannot save the tool settings. Open Tools in Triwarden to review the error.")
        }
        return intendedRevision
    }
}

public enum RunArguments {
    public enum Source: Equatable, Sendable { case profile(String), environmentFile(String) }
    public static func source(_ args: [String]) throws -> Source {
        if args.count == 2, args[0] == "--env-file", !args[1].isEmpty,
           !args[1].hasPrefix("-"), SecretsProfile.safeText(args[1]) {
            return .environmentFile(args[1])
        }
        return .profile(try parse(args))
    }

    public static func parse(_ args: [String]) throws -> String {
        guard args.count == 2, args[0] == "--profile", !args[1].isEmpty else {
            throw SecretsFailure("usage: tw run [--profile ID | --env-file FILE]\nUse tw run in a terminal to choose a saved tool. Command overrides are disabled.")
        }
        return args[1]
    }
}
