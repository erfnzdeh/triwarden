import AppKit
import SwiftUI
import VaultwardenAPI

/// Captured when the menu opens. Later navigation cannot widen a pending action.
struct SidebarScope {
    let accountIDs: [String]
    let vaultFilter: AppModel.VaultFilter
    let destination: SidebarSelection

    func contains(_ item: VaultItem) -> Bool {
        guard accountIDs.contains(item.accountId), destination.includes(item) else { return false }
        switch destination {
        case .myVault, .organization, .collection, .folder, .folders: return true
        default:
            switch vaultFilter {
            case .all: return true
            case .personal: return item.organizationId == nil
            case .organization(let id): return item.organizationId == id
            case .several(let keys): return keys.contains(item.organizationId ?? AppModel.VaultFilter.personalKey)
            }
        }
    }
}

extension AppModel {
    func sidebarActions(for destination: SidebarSelection, name: String? = nil,
                        organization: Grouping? = nil, collection: Grouping? = nil) -> [SidebarContextAction] {
        var ids = organization?.accountId.map { [$0] } ?? focusedAccountID.map { [$0] } ?? sessions.map(\.id)
        if case .folder(let path) = destination {
            ids = ids.filter { id in self.session(for: id)?.folders.contains { $0.name == path || $0.name.hasPrefix(path + "/") } == true }
        }
        if case .account(let id) = destination { ids = [id] }
        let scope = SidebarScope(accountIDs: ids, vaultFilter: vaultFilter, destination: destination)
        func action(_ title: String, _ symbol: String, enabled: Bool = true, run: @escaping () -> Void) -> SidebarContextAction {
            SidebarContextAction(title: title, symbol: symbol, enabled: enabled, run: run)
        }
        func search() -> SidebarContextAction {
            action(String(localized: "Search Here"), "magnifyingglass") {
                self.leaveNewItemForm {
                    if let key = destination.vaultKey {
                        self.vaultFilter = key == VaultFilter.personalKey ? .personal : .organization(key)
                    }
                    self.sidebarSearchScope = scope
                    self.sidebarSearchRequest = UUID()
                    self.searchFilters = destination.searchFilters
                    self.requestedSection = destination
                    self.wantsCodesSearchFocus = destination == .codes
                    self.wantsSearchFocus = destination != .codes
                }
            }
        }
        func sync() -> SidebarContextAction {
            action(String(localized: "Sync Accounts in This Scope"), "arrow.triangle.2.circlepath", enabled: !ids.isEmpty) {
                Task {
                    var errors: [String] = []
                    for id in ids {
                        guard let session = self.session(for: id) else { errors.append(String(localized: "Account is locked")); continue }
                        do { try await session.refresh() } catch { errors.append("\(session.account.email): \(error.localizedDescription)") }
                    }
                    if errors.isEmpty { self.flash(String(localized: "Sync complete")) }
                    else { self.sidebarActionError = errors.joined(separator: "\n") }
                }
            }
        }
        func create(_ kind: NewItemKind, title: String, sshImport: Bool = false, totp: Bool = false) -> SidebarContextAction {
            let symbol = switch kind { case .login: "key"; case .secureNote: "note.text"; case .card: "creditcard"; case .identity: "person.crop.rectangle"; case .sshKey: "terminal" }
            return action(title, symbol, enabled: !ids.isEmpty && (collection == nil || collection?.canWrite == true)) {
                self.leaveNewItemForm {
                    var prefill = EditItemSheet.Prefill()
                    prefill.accountIDs = ids
                    if case .folder(let path) = destination { prefill.folderPath = path }
                    prefill.favorite = destination == .section(.favorites)
                    prefill.organizationId = collection == nil ? nil : organization?.id
                    switch destination {
                    case .section:
                        prefill.vaultKeys = scope.vaultFilter.keys.map(Array.init)
                    default: break
                    }
                    prefill.collectionIds = collection.map { [$0.id] } ?? []
                    prefill.importSSH = sshImport
                    prefill.focusTOTP = totp
                    self.sidebarSearchScope = scope
                    self.requestedSection = destination == .codes ? .section(.logins) : destination
                    // Tool navigation settles before opening the detail form.
                    Task { @MainActor in
                        await Task.yield()
                        self.beginEditing(EditRequest(mode: .create(kind), prefill: prefill))
                    }
                }
            }
        }
        func newMenu() -> SidebarContextAction {
            SidebarContextAction(title: destination == .section(.favorites) ? String(localized: "New Favorite") : String(localized: "New Item Here"), symbol: "plus", enabled: !ids.isEmpty,
                children: [create(.login, title: String(localized: "New Login")),
                           create(.secureNote, title: String(localized: "New Secure Note")),
                           create(.card, title: String(localized: "New Card")),
                           create(.identity, title: String(localized: "New Identity")),
                           create(.sshKey, title: String(localized: "New SSH Key"))])
        }
        func web(_ title: String) -> SidebarContextAction? {
            guard let organization, let id = organization.accountId,
                  let base = session(for: id)?.webVault,
                  var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
            components.fragment = "/organizations/\(organization.id)/vault"
            guard let url = components.url else { return nil }
            return action(title, "safari") { NSWorkspace.shared.open(url) }
        }
        switch destination {
        case .section(.all): return [newMenu(), search(), sync()]
        case .section(.favorites): return [newMenu(), search()]
        case .section(.logins): return [create(.login, title: String(localized: "New Login")), search()]
        case .section(.cards): return [create(.card, title: String(localized: "New Card")), search()]
        case .section(.identities): return [create(.identity, title: String(localized: "New Identity")), search()]
        case .section(.notes): return [create(.secureNote, title: String(localized: "New Secure Note")), search()]
        case .section(.sshKeys): return [create(.sshKey, title: String(localized: "New SSH Key")),
            create(.sshKey, title: String(localized: "Import SSH Key…"), sshImport: true), search(),
            action(String(localized: "SSH Agent Settings…"), "gear") { self.showSettings(.security) }]
        case .section(.passkeys): return [search(),
            action(String(localized: "AutoFill Settings…"), "gear") { self.showSettings(.general) },
            action(String(localized: "Create passkeys on their website or app"), "info.circle", enabled: false) {}]
        case .myVault, .account:
            return [newMenu(), action(String(localized: "Import Here…"), "square.and.arrow.down", enabled: !ids.isEmpty) {
                self.beginImport(accountIDs: ids)
            }, search(), sync()]
        case .organization:
            var result = [search(), sync(), action(String(localized: "Copy Name"), "doc.on.doc") { self.copyPlain(name ?? "") }]
            if let link = web(String(localized: "Open Organization Web Vault")) { result.append(link) }
            if let organization {
                if organization.canManage { result.append(action(String(localized: "Event Log…"), "list.bullet.rectangle") { self.eventLogFor = organization.id }) }
                result.append(SidebarContextAction(title: String(localized: "Leave Shared Vault…"), symbol: "rectangle.portrait.and.arrow.right",
                    destructive: true, separatorBefore: true) { self.leaveOrganization(organization.id) })
            }
            return result
        case .collection:
            var result = collection?.canWrite == true ? [newMenu()] : [action(String(localized: "This collection is read-only"), "lock", enabled: false) {}]
            result += [search(), action(String(localized: "Copy Name"), "doc.on.doc") { self.copyPlain(name ?? "") }]
            if collection?.canManage == true, let link = web(String(localized: "Manage in Web Vault…")) { result.append(link) }
            return result
        case .sends:
            func send(_ kind: SendComposer.Kind, _ title: String) -> SidebarContextAction {
                action(title, "paperplane", enabled: !ids.isEmpty && !composingSend && editingSend == nil) {
                    self.leaveNewItemForm { self.composeNewSend(kind: kind, accountIDs: ids) }
                }
            }
            return [send(.text, String(localized: "New Text Send")), send(.file, String(localized: "New File Send")),
                action(expiredSendsOnly ? String(localized: "Show All Sends") : String(localized: "Show Expired Sends"), "clock") { self.expiredSendsOnly.toggle(); self.requestedSection = .sends }]
        case .codes: return [create(.login, title: String(localized: "New Login with TOTP"), totp: true), search()]
        case .generator:
            func generate(_ mode: GeneratorView.Mode, _ title: String) -> SidebarContextAction {
                action(title, "dice") { UserDefaults.standard.set(mode.rawValue, forKey: "generatorMode"); self.generatorRequest = UUID(); self.requestedSection = .generator }
            }
            return [generate(.password, String(localized: "Generate Password")), generate(.passphrase, String(localized: "Generate Passphrase")),
                    action(String(localized: "Generator Settings…"), "slider.horizontal.3") { self.requestedSection = .generator }]
        case .watchtower:
            func issue(_ value: WatchtowerReport.Issue, _ title: String) -> SidebarContextAction {
                action(title, value.symbol) { self.watchtowerIssueFilter = value; self.requestedSection = .watchtower }
            }
            return [action(String(localized: "Run Checks"), "arrow.clockwise") { self.watchtowerIssueFilter = nil; self.requestedSection = .watchtower; Task { await self.checkBreaches() } },
                issue(.weak, String(localized: "View Weak Passwords")), issue(.reused, String(localized: "View Reused Passwords")), issue(.breached, String(localized: "View Breached Passwords"))]
        case .folders:
            return [action(String(localized: "New Folder…"), "folder.badge.plus", enabled: !ids.isEmpty) { self.promptNewFolder(accountIDs: ids) }, search()]
        case .folder(let path):
            let folderIDs = sessions.filter { ids.contains($0.id) }.flatMap(\.folders).filter { $0.name == path }.map(\.id)
            return [newMenu(), action(String(localized: "New Subfolder…"), "folder.badge.plus", enabled: !ids.isEmpty) { self.promptNewFolder(in: path, accountIDs: ids) }, search(),
                action(String(localized: "Rename…"), "pencil") { self.folderContextAccountIDs = ids; self.renamingFolder = path },
                SidebarContextAction(title: String(localized: "Delete Folder…"), symbol: "folder.badge.minus", destructive: true, separatorBefore: true, enabled: !folderIDs.isEmpty) {
                    self.confirmDeleteFolder(name: path, ids: folderIDs)
                }]
        case .section(.archive), .section(.trash):
            let chosen = items.filter(scope.contains).map { (id: $0.id, accountID: $0.accountId) }
            var result = [search(), action(String(localized: "Restore Scoped Items…"), "arrow.uturn.backward", enabled: !chosen.isEmpty) {
                self.confirmSidebarBulk(self.items.filter { item in chosen.contains { $0.id == item.id && $0.accountID == item.accountId } && scope.contains(item) }, scope: scope, delete: false)
            }]
            if destination == .section(.trash) {
                result.append(SidebarContextAction(title: String(localized: "Empty Scoped Trash…"), symbol: "trash", destructive: true,
                    separatorBefore: true, enabled: !chosen.isEmpty) { self.confirmSidebarBulk(self.items.filter { item in chosen.contains { $0.id == item.id && $0.accountID == item.accountId } && scope.contains(item) }, scope: scope, delete: true) })
            }
            return result
        }
    }

    func confirmSidebarBulk(_ chosen: [VaultItem], scope: SidebarScope, delete: Bool) {
        guard !chosen.isEmpty else { return }
        let groupedItems = Dictionary(grouping: chosen, by: { $0.accountId })
        let groups = groupedItems.mapValues { $0.map(\.id) }
        let details = groups.keys.sorted().map { id in
            let email = accounts.first { $0.id == id }?.email ?? id
            let vaults = Set(groupedItems[id, default: []].map { item in
                item.organizationId.flatMap { oid in organizations.first { $0.id == oid }?.name } ?? String(localized: "My vault")
            }).sorted().joined(separator: ", ")
            return "\(email) — \(vaults): \(groups[id, default: []].count)"
        }.joined(separator: "\n")
        confirm(delete ? String(localized: "Delete \(chosen.count) item(s) forever?") : String(localized: "Restore \(chosen.count) item(s)?"),
            message: details + "\n\n" + (delete ? String(localized: "This can't be undone.") : String(localized: "Only the items counted above will be restored.")),
            action: delete ? String(localized: "Delete Forever") : String(localized: "Restore"), destructive: delete) {
                var completed = 0
                var errors: [String] = []
                for id in groups.keys.sorted() {
                    guard let session = self.session(for: id) else { errors.append("\(id): " + String(localized: "Account is locked")); continue }
                    let frozen = Set(groups[id, default: []])
                    // Account + item association and eligibility are checked again; no newly arrived items are added.
                    let eligible = session.items.filter { item in frozen.contains(item.id) && scope.contains(item) }
                    if eligible.count != frozen.count { errors.append("\(session.account.email): " + String(localized: "Some items changed; they were skipped.")) }
                    if scope.destination == .section(.archive) {
                        for item in eligible {
                            do { try await session.unarchive(item.id); completed += 1 }
                            catch { errors.append("\(session.account.email): \(error.localizedDescription)") }
                        }
                    } else if !eligible.isEmpty {
                        do { try await session.bulk(delete ? .delete : .restore, ids: eligible.map(\.id)); completed += eligible.count }
                        catch { errors.append("\(session.account.email): \(error.localizedDescription)") }
                    }
                }
                self.flash(String(localized: "Completed for \(completed) item(s)"))
                if !errors.isEmpty { self.sidebarActionError = String(localized: "Completed for \(completed) item(s)") + "\n\n" + errors.joined(separator: "\n") + "\n\n" + String(localized: "Sync and inspect your vault before trying failed actions again.") }
            }
    }
}

// Reflect the sidebar's scope in the existing filter menu and chips, too.
extension SidebarSelection {
    var searchFilters: SearchFilters {
        var filters = SearchFilters()
        switch self {
        case .section(.logins): filters.type = .login
        case .section(.cards): filters.type = .card
        case .section(.identities): filters.type = .identity
        case .section(.notes): filters.type = .note
        case .section(.sshKeys): filters.type = .sshKey
        case .section(.favorites): filters.favorites = true
        case .section(.passkeys): filters.hasPasskey = true
        case .folder(let path): filters.folder = path
        default: break
        }
        return filters
    }
}
