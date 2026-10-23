import Foundation

/// Suggestions only. The app saves explicit paths and arguments for the normal approval checks.
public enum ToolLaunchRecipe: String, CaseIterable, Sendable {
    case claudeCode, npm, node, python, custom

    public var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .npm: "npm development project"
        case .node: "Node.js script"
        case .python: "Python script"
        case .custom: "Other program"
        }
    }
    public var binary: String? {
        switch self { case .claudeCode: "claude"; case .npm: "npm"; case .node: "node"; case .python: "python3"; case .custom: nil }
    }
    public var variable: String? { self == .claudeCode ? "ANTHROPIC_API_KEY" : nil }

    public func suggestedName(current: String, previous: Self?) -> String {
        current.isEmpty || current == previous?.title ? title : current
    }

    public func suggestedVariable(current: String, previous: Self?, keyDefault: String) -> String {
        current.isEmpty || current == (previous?.variable ?? keyDefault) ? (variable ?? keyDefault) : current
    }

    public func arguments(script: String, extra: [String]) -> [String] {
        switch self {
        case .npm: ["run", "dev"] + extra
        case .node, .python: [script] + extra
        case .claudeCode, .custom: extra
        }
    }

    public func candidates(home: URL) -> [String] {
        guard let binary else { return [] }
        return [home.appendingPathComponent(".local/bin/" + binary).path] +
            LaunchPolicy.searchPath.split(separator: ":").map { "\($0)/\(binary)" }
    }

    public func findExecutable(home: URL) -> String? {
        candidates(home: home).first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
