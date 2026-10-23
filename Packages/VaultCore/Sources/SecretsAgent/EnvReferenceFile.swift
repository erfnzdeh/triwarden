import Darwin
import Foundation

/// Reference metadata only. The saved tool and normal app approval remain the authority for delivery.
public struct EnvReferenceFile: Sendable {
    public static let defaultName = ".env.triwarden"
    private static let maximumSize = 256 * 1024
    private static let prefix = "triwarden://vault/"
    private static let componentCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    public let toolID: String
    public let bindings: [SecretsBinding]

    public init(profile: SecretsProfile) throws {
        try profile.validate()
        toolID = profile.name; bindings = profile.bindings
        guard text.utf8.count <= Self.maximumSize else { throw Self.invalidFile }
    }

    public var text: String {
        (["# triwarden-env: 1", "# tool: " + toolID] + bindings.map { binding in
            let base = Self.prefix + Self.encode(binding.accountID) + "/" + Self.encode(binding.itemID)
            let field: String
            switch binding.field {
            case .password: field = "/password"
            case .hidden(let name): field = "/hidden/" + Self.encode(name)
            }
            return binding.variable + "=" + base + field
        }).joined(separator: "\n") + "\n"
    }

    public init(data: Data) throws {
        guard !data.isEmpty, data.count <= Self.maximumSize, let text = String(data: data, encoding: .utf8),
              !text.utf8.contains(0) else { throw Self.invalidFile }
        var tool: String?, version = false, variables = Set<String>(), references: [SecretsBinding] = []
        for (offset, raw) in text.components(separatedBy: "\n").enumerated() {
            let number = offset + 1, line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("# triwarden-env:") {
                guard !version, line == "# triwarden-env: 1" else { throw Self.invalidLine(number) }
                version = true
            } else if line.hasPrefix("# tool:") {
                let value = String(line.dropFirst("# tool:".count)).trimmingCharacters(in: .whitespaces)
                guard tool == nil, Self.validToolID(value) else { throw Self.invalidLine(number) }
                tool = value
            } else if line.hasPrefix("#") { continue }
            else {
                guard references.count < 16, let equals = line.firstIndex(of: "=") else { throw Self.invalidLine(number) }
                let variable = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
                guard (try? LaunchPolicy.validateVariable(variable)) != nil, variables.insert(variable).inserted else {
                    throw Self.invalidLine(number)
                }
                var value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
                if let quote = value.first, quote == "\"" || quote == "'" {
                    guard value.count >= 2, value.last == quote else { throw Self.invalidLine(number) }
                    value = String(value.dropFirst().dropLast())
                }
                guard let binding = Self.reference(value, variable: variable) else { throw Self.invalidLine(number) }
                references.append(binding)
            }
        }
        guard version, let tool, !references.isEmpty else { throw Self.invalidFile }
        toolID = tool; bindings = references
    }

    /// Compare the complete binding set. File edits cannot add keys, rename variables, or supply literal values.
    public func validate(against profile: SecretsProfile) throws {
        try profile.validate()
        guard toolID == profile.name,
              bindings.sorted(by: { $0.variable < $1.variable }) == profile.bindings.sorted(by: { $0.variable < $1.variable }) else {
            throw SecretsFailure("The references do not match this tool. Open its options in Tools and select Save .env References to create a new file.")
        }
    }

    public static func read(_ url: URL) throws -> Self {
        guard url.isFileURL else { throw invalidFile }
        // NONBLOCK prevents a pipe from hanging before fstat can reject it. The open descriptor pins the file.
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw SecretsFailure("Cannot open the reference file. Select a regular .env.triwarden file that you can read.") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= maximumSize else { throw invalidFile }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var data = Data()
        do {
            while data.count <= maximumSize {
                let chunk = try handle.read(upToCount: min(16_384, maximumSize + 1 - data.count)) ?? Data()
                if chunk.isEmpty { break }
                data.append(chunk)
            }
        }
        catch { throw invalidFile }
        return try Self(data: data)
    }

    public static func launchCommand(for url: URL) throws -> String {
        guard url.isFileURL, SecretsProfile.safeText(url.path), url.path.hasPrefix("/") else { throw invalidFile }
        return "tw run --env-file " + SavedToolCommands.shellQuote(url.path)
    }

    private static var invalidFile: SecretsFailure {
        SecretsFailure("Use a UTF-8 reference file with 1 to 16 keys. Keep it at 256 KiB or less. Save it from the tool options in Tools.")
    }
    private static func invalidLine(_ number: Int) -> SecretsFailure {
        // Never echo rejected input. It can contain a key that the user pasted by mistake.
        SecretsFailure("The reference file is not valid on line \(number). Open the tool options in Tools and select Save .env References.")
    }
    private static func validToolID(_ value: String) -> Bool {
        value.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$", options: .regularExpression) != nil
    }
    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: componentCharacters)!
    }
    private static func decode(_ value: String) -> String? {
        guard value.unicodeScalars.allSatisfy({ componentCharacters.contains($0) || $0 == "%" }),
              let decoded = value.removingPercentEncoding, SecretsProfile.safeText(decoded) else { return nil }
        return decoded
    }
    private static func reference(_ value: String, variable: String) -> SecretsBinding? {
        guard value.hasPrefix(prefix) else { return nil }
        let parts = String(value.dropFirst(prefix.count)).components(separatedBy: "/")
        guard parts.count == 3 || parts.count == 4,
              let account = decode(parts[0]), !account.isEmpty,
              let item = decode(parts[1]), !item.isEmpty else { return nil }
        let field: SecretSelector
        if parts.count == 3, parts[2] == "password" { field = .password }
        else if parts.count == 4, parts[2] == "hidden", let name = decode(parts[3]) { field = .hidden(name) }
        else { return nil }
        return .init(accountID: account, itemID: item, field: field, variable: variable)
    }
}
