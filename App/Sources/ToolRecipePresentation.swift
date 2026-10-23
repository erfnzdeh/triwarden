import Foundation
import SecretsAgent

extension ToolLaunchRecipe {
    var localizedTitle: String {
        switch self {
        case .claudeCode: String(localized: "Claude Code")
        case .npm: String(localized: "npm development project")
        case .node: String(localized: "Node.js script")
        case .python: String(localized: "Python script")
        case .custom: String(localized: "Other program")
        }
    }
}
