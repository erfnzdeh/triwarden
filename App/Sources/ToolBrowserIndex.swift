import Foundation
import SecretsAgent

/// Presentation only. Never resolves or caches credential values or grants authorization.
struct ToolBrowserIndex {
    enum Availability: String, CaseIterable {
        case ready, paused, locked, needsRepair
        var title: String {
            switch self {
            case .ready: String(localized: "Ready for approval")
            case .paused: String(localized: "Paused")
            case .locked: String(localized: "Account locked")
            case .needsRepair: String(localized: "Needs attention")
            }
        }
        var symbol: String {
            switch self { case .ready: "checkmark.shield"; case .paused: "pause.circle"; case .locked: "lock"; case .needsRepair: "exclamationmark.triangle" }
        }
    }
    enum Filter: String, CaseIterable {
        case all, ready, attention, paused
        var title: String {
            switch self { case .all: String(localized: "All tools"); case .ready: String(localized: "Ready"); case .attention: String(localized: "Needs attention"); case .paused: String(localized: "Paused") }
        }
        func includes(_ value: Availability) -> Bool {
            switch self { case .all: true; case .ready: value == .ready; case .attention: value == .locked || value == .needsRepair; case .paused: value == .paused }
        }
    }
    enum Order: String, CaseIterable {
        case ascending, descending
        var title: String { self == .ascending ? String(localized: "Name A–Z") : String(localized: "Name Z–A") }
    }
    struct Reference: Hashable { let account: String; let item: String }
    struct Item {
        let id: String
        let accountId: String
        let name: String
        let isAPIKey: Bool
    }
    struct Key: Identifiable {
        enum Repair { case unlockAccount, addAccount, selectKey }
        let binding: SecretsBinding
        let name: String
        let problem: String?
        let canView: Bool
        let repair: Repair?
        var id: String { binding.variable }
    }
    struct Entry: Identifiable {
        enum Action: Equatable { case copyLaunch, resume, repairKey(String), editSetup }
        let profile: SecretsProfile
        let keys: [Key]
        let availability: Availability
        var id: String { profile.name }
        var folder: String { URL(fileURLWithPath: profile.directory).lastPathComponent }
        /// Choose recovery before launch. This guides the UI; it does not authorize a launch.
        var nextAction: Action {
            if !profile.enabled { return .resume }
            if let key = keys.first(where: { $0.repair != nil }) { return .repairKey(key.id) }
            return availability == .ready ? .copyLaunch : .editSetup
        }
    }
    let entries: [Entry]
    private let items: [Reference: Item]

    init(profiles: [SecretsProfile], items: [VaultItem], unlocked: Set<String>, configurationError: Bool = false,
         configuredAccounts: Set<String>? = nil) {
        let grouped = Dictionary(grouping: items.filter { !$0.isDeleted && !$0.isArchived }, by: { Reference(account: $0.accountId, item: $0.id) })
        let lookup = grouped.compactMapValues { $0.count == 1 ? $0[0] : nil }
        self.items = lookup.mapValues { Item(id: $0.id, accountId: $0.accountId, name: $0.name, isAPIKey: $0.isAPIKey) }
        entries = profiles.map { profile in
            var lengths = 0
            let keys = profile.bindings.map { binding -> Key in
                let item = lookup[Reference(account: binding.accountID, item: binding.itemID)]
                let missingAccount = configuredAccounts.map { !$0.contains(binding.accountID) } ?? false
                let problem: String?
                if missingAccount { problem = String(localized: "Add this key's account to continue.") }
                else if !unlocked.contains(binding.accountID) { problem = String(localized: "Unlock this key's account to continue.") }
                else if let item {
                    if item.reprompt { problem = String(localized: "This key needs a master-password prompt that tool launches do not support.") }
                    else if !item.isSupported { problem = String(localized: "This item type cannot be supplied to a tool.") }
                    else {
                        // Inspect shape/length in the already unlocked model; do not copy resolved values into the index.
                        let length: Int?
                        switch binding.field {
                        case .password:
                            length = item.password.flatMap { $0.isEmpty || $0.utf8.contains(0) ? nil : $0.utf8.count }
                        case .hidden(let name):
                            let fields = item.customFields.filter { $0.name == name }
                            length = fields.count == 1 && fields[0].kind == .hidden && !fields[0].value.isEmpty && !fields[0].value.utf8.contains(0) ? fields[0].value.utf8.count : nil
                        }
                        if let length, length <= 32_768 { lengths += length; problem = nil }
                        else { problem = String(localized: "The saved field is missing, renamed, duplicated or empty. Edit the setup and select the key again.") }
                    }
                } else { problem = String(localized: "This key is not available. Select another saved key.") }
                return Key(binding: binding, name: item?.name ?? String(localized: "Unavailable key"), problem: problem,
                           canView: item != nil && !missingAccount && unlocked.contains(binding.accountID),
                           repair: missingAccount ? .addAccount : (problem == nil ? nil : (unlocked.contains(binding.accountID) ? .selectKey : .unlockAccount)))
            }
            let state: Availability
            if !profile.enabled { state = .paused }
            else if configurationError || (try? profile.validate()) == nil || lengths > 32_768 || keys.contains(where: { $0.repair == .addAccount }) { state = .needsRepair }
            else if profile.bindings.contains(where: { !unlocked.contains($0.accountID) }) { state = .locked }
            else if keys.contains(where: { $0.problem != nil }) { state = .needsRepair }
            else { state = .ready }
            return Entry(profile: profile, keys: keys, availability: state)
        }
    }

    func item(for binding: SecretsBinding) -> Item? { items[Reference(account: binding.accountID, item: binding.itemID)] }

    func results(query: String, filter: Filter, order: Order) -> [Entry] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return entries.filter { entry in
            guard filter.includes(entry.availability) else { return false }
            let text = ([entry.profile.title, entry.profile.name, entry.profile.directory, entry.profile.executable] + entry.keys.flatMap { [$0.name, $0.binding.variable] }).joined(separator: " ")
            return words.allSatisfy { text.localizedStandardContains($0) }
        }.sorted { lhs, rhs in
            let comparison = lhs.profile.title.localizedStandardCompare(rhs.profile.title)
            if comparison != .orderedSame { return order == .ascending ? comparison == .orderedAscending : comparison == .orderedDescending }
            if lhs.profile.directory != rhs.profile.directory { return lhs.profile.directory < rhs.profile.directory }
            return lhs.id < rhs.id
        }
    }

    static func selection(_ selected: String?, in results: [Entry], automatic: Bool) -> String? {
        if let selected, results.contains(where: { $0.id == selected }) { return selected }
        return automatic ? results.first?.id : nil
    }

    static func stepping(_ selected: String?, by delta: Int, in results: [Entry]) -> String? {
        guard !results.isEmpty else { return nil }
        let current = results.firstIndex { $0.id == selected } ?? (delta > 0 ? -1 : results.count)
        return results[min(max(current + delta, 0), results.count - 1)].id
    }
}
