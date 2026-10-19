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
                throw SecretsFailure("The hidden field is missing, renamed, or duplicated. Select the field again in Settings › Secrets.")
            }
            value = matches[0].value
        }
        guard let value, !value.isEmpty, !value.utf8.contains(0), value.utf8.count <= 32_768 else {
            throw SecretsFailure("The selected field is empty or cannot be used as an environment variable.")
        }
        return value
    }
}

/// One reference-only profile. No resolved credential values are stored here.
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

    public init(name: String, accountID: String, itemID: String, field: SecretSelector, variable: String,
                executable: String, arguments: [String], directory: String, enabled: Bool = true) {
        self.name = name; self.accountID = accountID; self.itemID = itemID; self.field = field
        self.variable = variable; self.executable = executable; self.arguments = arguments
        self.directory = directory; self.enabled = enabled
    }

    public func validate() throws {
        guard name.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$", options: .regularExpression) != nil,
              !accountID.isEmpty, !itemID.isEmpty,
              executable.hasPrefix("/"), directory.hasPrefix("/"), arguments.count <= 128,
              ([accountID, itemID, executable, directory, field.label] + arguments).allSatisfy(Self.safeText),
              arguments.reduce(0, { $0 + $1.utf8.count }) <= 16_384 else {
            throw SecretsFailure("Use a short profile name, an exact vault field, and absolute executable and working-directory paths. Arguments must be single lines.")
        }
        try LaunchPolicy.validateVariable(variable)
    }

    /// Exclude control and bidi-formatting characters from approval text as well as exec arguments.
    public static func safeText(_ value: String) -> Bool {
        value.utf8.count <= 4096 && !value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format
        }
    }

    public func revision() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct SecretsProfileStore: Sendable {
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

    public func load() throws -> SecretsProfile {
        let fd = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SecretsFailure("Create and save a profile in Triwarden Settings › Secrets first.") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= 65_536 else {
            throw SecretsFailure("The profile file has unsafe permissions or an invalid size. Save it again in Settings › Secrets.")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: 65_537) ?? Data()
        let profile = try JSONDecoder().decode(SecretsProfile.self, from: data)
        try profile.validate()
        return profile
    }

    public func save(_ profile: SecretsProfile) throws {
        try profile.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SecretsFailure("Couldn't create the private profile file.") }
        defer { close(fd); unlink(temporary.path) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: encoder.encode(profile))
        guard fsync(fd) == 0, rename(temporary.path, fileURL.path) == 0 else {
            throw SecretsFailure("Couldn't save the profile.")
        }
    }
}

public enum RunArguments {
    public static func parse(_ args: [String]) throws -> String {
        guard args.count == 2, args[0] == "--profile", !args[1].isEmpty else {
            throw SecretsFailure("usage: tw run --profile NAME\nThe saved command is configured in Settings › Secrets. Command overrides are disabled.")
        }
        return args[1]
    }
}
