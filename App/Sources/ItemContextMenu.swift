import AppKit
import SwiftUI

/// A text Send opened prefilled from one item, for "Share by Link…" (issue #85).
struct SendPrefill: Equatable {
    var name: String
    var text: String
    var accountId: String?
}

extension VaultItem {
    /// The item's fields as the body of a text Send. The one-time code is left out on purpose: a TOTP secret in a
    /// link is a standing second-factor bypass for whoever keeps it. Empty values are skipped.
    func shareText() -> String {
        var rows: [(String, String)] = []
        if let username, !username.isEmpty { rows.append((String(localized: "Username"), username)) }
        if let password, !password.isEmpty { rows.append((String(localized: "Password"), password)) }
        let sites = websites.filter { !$0.isEmpty }
        if !sites.isEmpty { rows.append((String(localized: "Website"), sites.joined(separator: "\n"))) }
        // Cards, identities and keys have no username: share their labelled fields instead.
        if kind != .login {
            rows += fields.filter { !$0.value.isEmpty }.map { ($0.label, $0.value) }
        }
        if let notes, !notes.isEmpty { rows.append((String(localized: "Notes"), notes)) }
        return rows.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
    }
}

extension AppModel {
    /// Opens the Send composer prefilled with this item's fields; the usual Send options stay editable.
    func shareItemByLink(_ item: VaultItem) {
        let text = item.shareText()
        guard !text.isEmpty else {
            flash(String(localized: "This item has nothing to share."))
            return
        }
        // The text carries real secrets, so a reprompt-protected item asks for the password again first.
        guarded(item) {
            self.leaveNewItemForm {
                // The item's own account wins over whatever the sidebar had selected, so no context IDs.
                self.composeNewSend(prefill: SendPrefill(name: item.name, text: text, accountId: item.accountId))
            }
        }
    }

    /// A Send's right-click menu, shared by its row in the list and by its detail panel — the vault gives an item the
    /// same menu in both places, so the two never drift apart.
    func sendContextActions(_ send: SendItem) -> [ActionMenuEntry] {
        var rows: [ActionMenuEntry] = []
        if let link = sendLink(send) {
            rows.append(ActionMenuEntry(title: String(localized: "Copy Link"), symbol: "link") { self.copyPlain(link.absoluteString) })
            rows.append(ActionMenuEntry(title: String(localized: "Open Link"), symbol: "safari") { NSWorkspace.shared.open(link) })
        }
        if let text = send.text, !text.isEmpty {
            // The text holds the password this Send exists to carry: conceal it from clipboard managers, like the
            // app's other secrets, rather than leaving it in plain view of them.
            rows.append(ActionMenuEntry(title: String(localized: "Copy Text"), symbol: "doc.on.doc") {
                self.copy(text, label: String(localized: "Text"))
            })
        }
        if let notes = send.notes, !notes.isEmpty {
            rows.append(ActionMenuEntry(title: String(localized: "Copy Private Notes"), symbol: "note.text") {
                self.copyPlain(notes)
            })
        }
        if let fileName = send.fileName, !fileName.isEmpty {
            rows.append(ActionMenuEntry(title: String(localized: "Copy File Name"), symbol: "doc") { self.copyPlain(fileName) })
        }
        rows.append(ActionMenuEntry(title: String(localized: "Edit…"), symbol: "pencil", separatorBefore: !rows.isEmpty) { self.editSend(send) })
        rows.append(ActionMenuEntry(title: String(localized: "Delete…"), symbol: "trash", destructive: true) { self.confirmDeleteSend(send) })
        return rows
    }

    /// Shared actions for vault, code and menu-bar rows; existing guards and confirmations stay at execution.
    func itemContextActions(_ item: VaultItem) -> [ActionMenuEntry] {
        guard item.isSupported else {
            return [ActionMenuEntry(title: String(localized: "Unsupported item"), symbol: "lock", enabled: false) {}]
        }
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
            rows.append(ActionMenuEntry(title: String(localized: "Share by Link…"), symbol: "paperplane", separatorBefore: true) { self.shareItemByLink(item) })
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
