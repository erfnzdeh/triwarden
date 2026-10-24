import Darwin
import Foundation

/// A literal-only migration reader. This type never evaluates input or writes a file.
public struct EnvImportFile: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public struct Entry: Sendable, Identifiable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        public let variable: String
        public let value: String?
        public let line: Int
        public let problem: String?
        public let suggested: Bool
        public var id: String { variable }
        public var description: String { "EnvImportEntry(\(variable), value: <masked>)" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: ["variable": variable, "value": "<masked>"]) }
    }

    public let entries: [Entry]
    public var description: String { "EnvImportFile(\(entries.count) masked entries)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["entryCount": entries.count]) }
    private static let maximumSize = 256 * 1024

    public init(data: Data) throws {
        guard !data.isEmpty, data.count <= Self.maximumSize, let text = String(data: data, encoding: .utf8),
              !text.utf8.contains(0) else { throw Self.invalidFile }
        var parsed: [Entry] = [], names = Set<String>()
        for (offset, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = offset + 1
            var input = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            guard !input.contains("\r"), !input.contains("\u{2028}"), !input.contains("\u{2029}") else { throw Self.invalidLine(line) }
            input = input.trimmingCharacters(in: .whitespaces)
            if input.isEmpty || input.hasPrefix("#") { continue }
            if input.hasPrefix("export ") || input.hasPrefix("export\t") {
                input = String(input.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            }
            guard parsed.count < 256, let equals = input.firstIndex(of: "=") else { throw Self.invalidLine(line) }
            let variable = String(input[..<equals]).trimmingCharacters(in: .whitespaces)
            guard variable.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,127}$", options: .regularExpression) != nil else {
                throw Self.invalidLine(line)
            }
            guard names.insert(variable).inserted else {
                throw SecretsFailure("The .env file repeats a variable on line \(line). Keep one assignment for each variable and open the file again.")
            }
            let source = String(input[input.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            let value = try Self.literal(source, line: line)
            let problem: String?
            if (try? LaunchPolicy.validateVariable(variable)) == nil {
                problem = "Program-control variables cannot supply API keys."
            } else if value == nil {
                problem = "This value uses unsupported syntax. Use a single-line literal value."
            } else if value?.isEmpty == true {
                problem = "This value is empty."
            } else if value?.hasPrefix("triwarden://vault/") == true {
                problem = "This value is already a vault reference."
            } else if (value?.utf8.count ?? 0) > 32_768 {
                problem = "This value exceeds 32 KiB."
            } else { problem = nil }
            parsed.append(.init(variable: variable, value: problem == nil ? value : nil, line: line,
                                problem: problem, suggested: problem == nil && Self.suggest(variable, value: value ?? "")))
        }
        guard !parsed.isEmpty else { throw Self.invalidFile }
        entries = parsed
    }

    /// Preserve file order. Every selected name must identify an eligible entry.
    public func selected(_ names: Set<String>) throws -> [Entry] {
        let selected = entries.filter { names.contains($0.variable) }
        guard !names.isEmpty, names.count <= 16, selected.count == names.count,
              selected.allSatisfy({ $0.problem == nil && $0.value != nil }),
              selected.reduce(0, { $0 + ($1.value?.utf8.count ?? 0) }) <= 32_768 else {
            throw SecretsFailure("Select 1 to 16 available keys with at most 32 KiB of values in total.")
        }
        return selected
    }

    public static func read(_ url: URL) throws -> Self {
        guard url.isFileURL else { throw invalidFile }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw SecretsFailure("Cannot open the .env file. Select a regular file that you can read.") }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0, before.st_size <= maximumSize else { throw invalidFile }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var data = Data()
        do {
            while data.count <= maximumSize {
                let chunk = try handle.read(upToCount: min(16_384, maximumSize + 1 - data.count)) ?? Data()
                if chunk.isEmpty { break }
                data.append(chunk)
            }
        } catch { throw invalidFile }
        var after = stat()
        guard fstat(fd, &after) == 0, data.count == before.st_size,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw SecretsFailure("The .env file changed during the read. Open it again to review the current values.")
        }
        return try Self(data: data)
    }

    private static func literal(_ input: String, line: Int) throws -> String? {
        guard let first = input.first else { return "" }
        if first == "'" || first == "\"" {
            var value = "", index = input.index(after: input.startIndex), unsupported = false
            while index < input.endIndex {
                let character = input[index]
                if character == first {
                    let remainder = input[input.index(after: index)...]
                    guard remainder.isEmpty || (remainder.first?.isWhitespace == true &&
                          (remainder.trimmingCharacters(in: .whitespaces).isEmpty || remainder.trimmingCharacters(in: .whitespaces).hasPrefix("#"))) else {
                        throw invalidLine(line)
                    }
                    return unsupported ? nil : value
                }
                if first == "\"", character == "\\" {
                    index = input.index(after: index)
                    guard index < input.endIndex else { throw invalidLine(line) }
                    switch input[index] {
                    case "n": value.append("\n")
                    case "r": value.append("\r")
                    case "t": value.append("\t")
                    case "\\": value.append("\\")
                    case "\"": value.append("\"")
                    default: unsupported = true
                    }
                } else {
                    if first == "\"", character == "$" || character == "`" { unsupported = true }
                    value.append(character)
                }
                index = input.index(after: index)
            }
            throw invalidLine(line)
        }
        var value = input
        if let comment = input.indices.first(where: { input[$0] == "#" && $0 > input.startIndex && input[input.index(before: $0)].isWhitespace }) {
            value = String(input[..<comment]).trimmingCharacters(in: .whitespaces)
        }
        guard !value.contains(where: { "$`\\;|&<>()\"'".contains($0) || $0.isWhitespace }) else { return nil }
        return value
    }

    private static func suggest(_ variable: String, value: String) -> Bool {
        let name = variable.uppercased()
        let publicPrefixes = ["PUBLIC_", "NEXT_PUBLIC_", "VITE_", "EXPO_PUBLIC_", "REACT_APP_", "NUXT_PUBLIC_"]
        guard !publicPrefixes.contains(where: name.hasPrefix),
              !["PUBLISHABLE", "ANON_KEY", "PUBLIC_KEY"].contains(where: name.contains) else { return false }
        let words = Set(name.split(separator: "_").map(String.init))
        if !words.isDisjoint(with: ["KEY", "SECRET", "TOKEN", "PASSWORD", "PASSWD", "CREDENTIAL", "PRIVATE", "AUTH", "DSN"]) { return true }
        return URLComponents(string: value)?.password?.isEmpty == false
    }

    private static var invalidFile: SecretsFailure {
        SecretsFailure("Select a UTF-8 .env file with 1 to 256 assignments and at most 256 KiB.")
    }
    private static func invalidLine(_ line: Int) -> SecretsFailure {
        SecretsFailure("Cannot read line \(line) of the .env file. Use one literal NAME=value assignment per line and open the file again.")
    }
}
