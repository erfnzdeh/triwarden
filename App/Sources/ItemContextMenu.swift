import AppKit
import SwiftUI

extension AppModel {
    /// Shared actions for vault, code and menu-bar rows; existing guards and confirmations stay at execution.
    func itemContextActions(_ item: VaultItem) -> [ActionMenuEntry] {
        var rows: [ActionMenuEntry] = []
        if let username = item.username, !username.isEmpty {
            rows.append(ActionMenuEntry(title: String(localized: "Copy Username"), symbol: "person") { self.copy(username, label: String(localized: "Username")) })
        }
        if let password = item.password, !password.isEmpty {
            rows.append(ActionMenuEntry(title: String(localized: "Copy Password"), symbol: "key") { self.copyPassword(item) })
            rows.append(ActionMenuEntry(title: String(localized: "Show Password in Large Type"), symbol: "textformat.size") { self.showLargeType(item) })
        }
        if let totp = item.totp {
            rows.append(ActionMenuEntry(title: String(localized: "Copy One-Time Code"), symbol: "clock") { self.guarded(item) { self.copy(totp.code(at: .now), label: String(localized: "Code")) } })
        }
        if let notes = item.notes, !notes.isEmpty {
            rows.append(ActionMenuEntry(title: String(localized: "Copy Notes"), symbol: "note.text") { self.guarded(item) { self.copy(notes, label: String(localized: "Notes")) } })
        }
        if let address = item.uri ?? item.host, !address.isEmpty,
           let url = URL(string: address.contains("://") ? address : "https://" + address) {
            rows.append(ActionMenuEntry(title: String(localized: "Open Website"), symbol: "safari", separatorBefore: true) { NSWorkspace.shared.open(url) })
            rows.append(ActionMenuEntry(title: String(localized: "Copy Website"), symbol: "link") { self.copyPlain(url.absoluteString) })
        }
        if item.isDeleted {
            rows.append(ActionMenuEntry(title: String(localized: "Restore"), symbol: "arrow.uturn.backward", separatorBefore: true) { Task { await self.restore(item) } })
            rows.append(ActionMenuEntry(title: String(localized: "Delete Forever…"), symbol: "trash.slash", destructive: true) { self.confirmDeleteForever(item) })
        } else {
            rows.append(ActionMenuEntry(title: String(localized: "Edit"), symbol: "pencil", separatorBefore: true) { self.guarded(item) { self.beginEditing(EditRequest(mode: .edit(item))) } })
            rows.append(ActionMenuEntry(title: String(localized: "Clone"), symbol: "plus.square.on.square") { self.guarded(item) { self.beginEditing(EditRequest(mode: .clone(item))) } })
            rows.append(ActionMenuEntry(title: item.favorite ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites"), symbol: item.favorite ? "star.slash" : "star") { Task { await self.toggleFavorite(item) } })
            rows.append(ActionMenuEntry(title: item.isArchived ? String(localized: "Unarchive") : String(localized: "Archive"), symbol: "archivebox") { Task { await self.setArchived(item, !item.isArchived) } })
            if item.organizationId != nil {
                rows.append(ActionMenuEntry(title: String(localized: "Shared Folders…"), symbol: "rectangle.stack") { self.organizationSheet = .collections(item.id) })
            } else if session(for: item.accountId)?.organizations.isEmpty == false {
                rows.append(ActionMenuEntry(title: String(localized: "Move to Shared Vault…"), symbol: "building.2") { self.organizationSheet = .share([item.id]) })
            }
            rows.append(ActionMenuEntry(title: String(localized: "Move to Trash…"), symbol: "trash", destructive: true, separatorBefore: true) { self.confirmTrash(item) })
        }
        return rows
    }
}
