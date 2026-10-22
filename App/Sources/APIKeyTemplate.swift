import SwiftUI
import SecretsAgent
import VaultwardenAPI

/// A vault preset, not a new server cipher type. Other Bitwarden clients see a normal Secure Note.
enum APIKeyTemplate {
    static let keyField = "api-key"
    static let serviceField = "service"
    static let environmentField = "environment-variable"
    static var fields: [CustomField] {
        [CustomField(name: keyField, value: "", kind: .hidden),
         CustomField(name: serviceField, value: "", kind: .text),
         CustomField(name: environmentField, value: "API_KEY", kind: .text)]
    }

    /// Identify preset rows when the editor loads; names typed into extra rows never hide those rows.
    static func primaryFieldIDs(in fields: [CustomField]) -> Set<UUID> {
        Set([fields.first { $0.name == keyField && $0.kind == .hidden }?.id,
             fields.first { $0.name == serviceField && $0.kind == .text }?.id,
             fields.first { $0.name == environmentField && $0.kind == .text }?.id].compactMap { $0 })
    }

    static func suggestedVariable(service: String) -> String {
        switch service.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "anthropic": "ANTHROPIC_API_KEY"
        case "openai": "OPENAI_API_KEY"
        default: "API_KEY"
        }
    }

    static func variableProblem(_ name: String) -> String? {
        guard !name.isEmpty else { return String(localized: "Enter the variable name your tool expects, for example OPENAI_API_KEY.") }
        guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,127}$", options: .regularExpression) != nil else {
            return String(localized: "Use up to 128 letters, numbers or underscores. Start with a letter or underscore, for example OPENAI_API_KEY.")
        }
        do { try LaunchPolicy.validateVariable(name); return nil }
        catch { return String(localized: "Use a key variable such as API_KEY. Program-control variables such as PATH and NODE_OPTIONS aren't allowed.") }
    }

    #if DEBUG
    static var fixture: VaultItem {
        var item = VaultItem(id: "api-key-demo", accountId: "demo", kind: .note, name: "Anthropic development",
            username: nil, host: nil, password: nil, totp: nil, notes: nil, favorite: false)
        item.customFields = [CustomField(name: keyField, value: "triwarden-test-only", kind: .hidden),
                             CustomField(name: serviceField, value: "Anthropic", kind: .text),
                             CustomField(name: environmentField, value: "ANTHROPIC_API_KEY", kind: .text)]
        item.fields = [ItemField(label: keyField, value: "triwarden-test-only", secret: true),
                       ItemField(label: serviceField, value: "Anthropic"),
                       ItemField(label: environmentField, value: "ANTHROPIC_API_KEY", monospaced: true)]
        return item
    }
    #endif
}

extension VaultItem {
    var isAPIKey: Bool {
        kind == .note && customFields.filter { $0.name == APIKeyTemplate.keyField }.count == 1 &&
            customFields.contains { $0.name == APIKeyTemplate.keyField && $0.kind == .hidden }
    }
    var apiKeyService: String { customFields.first { $0.name == APIKeyTemplate.serviceField && $0.kind == .text }?.value ?? "" }
    var apiKeyVariable: String {
        let saved = customFields.filter { $0.name == APIKeyTemplate.environmentField && $0.kind == .text }
        return saved.count == 1 && !saved[0].value.isEmpty ? saved[0].value : APIKeyTemplate.suggestedVariable(service: apiKeyService)
    }
}

extension AppModel {
    func beginAPIKey(accountIDs: [String]? = nil) {
        var prefill = EditItemSheet.Prefill()
        prefill.apiKey = true
        prefill.accountIDs = accountIDs
        beginEditing(EditRequest(mode: .create(.secureNote), prefill: prefill))
    }

    func provideKeyToTool(_ item: VaultItem) {
        leaveNewItemForm {
            self.toolLaunchReference = ToolLaunchReference(accountID: item.accountId, itemID: item.id)
        }
    }

    func showToolsAndProjects() {
        leaveNewItemForm {
            self.requestedSection = .toolLaunches
            self.bringToFront()
        }
    }
}

struct ToolLaunchReference: Identifiable {
    let accountID: String
    let itemID: String
    var id: String { accountID + "|" + itemID }
}
