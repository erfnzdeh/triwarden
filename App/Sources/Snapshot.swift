import SSHAgent
import AppIntents
import AuthenticationServices
#if DEBUG
import AppKit
import TriCrypto
import SwiftUI
import TipKit
import VaultwardenAPI

/// Debug-only: `Triwarden --snapshot` renders key screens offscreen in light and dark
/// to PNGs, so UI can be reviewed without screen-recording permission. Exits when done.
@MainActor
enum Snapshot {
    /// `make snapshots ONLY=login,send`: render only screens whose file name contains one of these (all when empty).
    static let only: [String] = (ProcessInfo.processInfo.environment["TRIWARDEN_SNAPSHOT_ONLY"] ?? "")
        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

    static func wanted(_ url: URL) -> Bool {
        only.isEmpty || only.contains { url.lastPathComponent.contains($0) }
    }

    static func runIfRequested() {
        let args = CommandLine.arguments
        guard args.contains("--snapshot") else { return }
        // Sandboxed: write inside our container and print the path. `TRIWARDEN_SNAPSHOT_DIR` sends them elsewhere
        // (a folder the sandbox can already write, e.g. build/snapshots) so other tools can read them.
        let dir = ProcessInfo.processInfo.environment["TRIWARDEN_SNAPSHOT_DIR"].map { URL(filePath: $0) }
            ?? FileManager.default.temporaryDirectory.appending(path: "snapshots", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let model = AppModel()
        model.serverKind = .selfHosted
        model.serverURL = "https://vault.home.arpa"
        model.email = "alex@example.com"
        model.serverStatus = .reachable(product: "Vaultwarden", version: "2026.6.0")
        model.touchIDEnabled = true

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            render(desktop(LoginView().environment(model).tint(.brand), dark: name == "dark"),
                   size: CGSize(width: 900, height: 600), appearance: appearance,
                   to: dir.appending(path: "login-\(name).png"))
        }
        // The emailed-code step, and the code cells part-typed, full and refused.
        let verifying = AppModel()
        verifying.email = "alex@example.com"
        verifying.phase = .deviceVerification
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            render(desktop(LoginView().environment(verifying).tint(.brand), dark: name == "dark"),
                   size: CGSize(width: 900, height: 600), appearance: appearance,
                   to: dir.appending(path: "login-code-\(name).png"))
            render(VStack(alignment: .leading, spacing: 24) {
                CodeEntry(code: .constant("24"))
                CodeEntry(code: .constant("240719"))
                CodeEntry(code: .constant("240718"), rejected: true)
                ResendCodeButton {}
            }.padding(30).background(Color(nsColor: .windowBackgroundColor)),
                   size: CGSize(width: 420, height: 330), appearance: appearance,
                   to: dir.appending(path: "login-code-cells-\(name).png"))
        }
        let custom = AppModel()
        custom.serverKind = .selfHosted
        custom.serverURL = "https://vault.example.com"
        custom.customIdentity = "https://login.example.com"
        custom.customNotifications = "http://push.example.com"
        render(desktop(LoginView().environment(custom).tint(.brand), dark: false),
               size: CGSize(width: 900, height: 760), appearance: .aqua, to: dir.appending(path: "login-custom-light.png"))
        render(desktop(CustomEnvironmentSheet().environment(custom).tint(.brand), dark: false),
               size: CGSize(width: 480, height: 520), appearance: .aqua, to: dir.appending(path: "custom-env-light.png"))
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            render(desktop(UnlockView().environment(model).tint(.brand), dark: name == "dark"),
                   size: CGSize(width: 900, height: 600), appearance: appearance,
                   to: dir.appending(path: "unlock-\(name).png"))
        }

        // The vault door at rest, typing, deriving the key, a wrong password, and the unlock sequence's key moments.
        let doorFrames: [(String, VaultDoorFrozen)] = [
            ("0-rest", .init(time: 12, opened: nil)),
            ("1-typing", .init(time: 12, opened: nil, typed: 5)),
            ("2-busy", .init(time: 12.2, opened: nil, typed: 9, busy: true)),
            ("3-wrong", .init(time: 12, opened: nil, alert: 0.9)),
            ("o1-power", .init(time: 12.1, opened: 0.12, typed: 9)),
            ("o2-heaven", .init(time: 12.2, opened: 0.2, typed: 9)),
            ("o3-person", .init(time: 12.3, opened: 0.27, typed: 9)),
            ("o4-keyway", .init(time: 12.4, opened: 0.4, typed: 9)),
            ("o5-unlatch", .init(time: 12.5, opened: 0.46, typed: 9)),
            ("o6-hub", .init(time: 12.6, opened: 0.58, typed: 9)),
            ("o7-pins", .init(time: 12.7, opened: 0.7, typed: 9)),
            ("o8-louvres", .init(time: 12.8, opened: 0.8, typed: 9)),
            ("o9-core", .init(time: 13, opened: 0.92, typed: 9)),
            ("c1-runes-in", .init(time: 12.2, opened: nil, closed: 0.2)),
            ("c2-hub-in", .init(time: 12.5, opened: nil, closed: 0.6)),
            ("c3-keyway", .init(time: 12.9, opened: nil, closed: 0.78)),
            ("c4-scramble", .init(time: 13.1, opened: nil, closed: 0.98)),
            ("c5-sealed", .init(time: 13.4, opened: nil, closed: 1.3)),
        ]
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for (frame, moment) in doorFrames {
                render(desktop(UnlockView().environment(model).environment(\.vaultDoorFrozen, moment).tint(.brand), dark: name == "dark"),
                       size: CGSize(width: 900, height: 600), appearance: appearance,
                       to: dir.appending(path: "door-\(frame)-\(name).png"))
            }
        }
        render(desktop(UnlockView().environment(model).tint(.brand), dark: false),
               size: CGSize(width: 380, height: 520), appearance: .aqua, to: dir.appending(path: "unlock-small-light.png"))

        // The unlock animation's open moment, and Settings at its default size.
        let opening = AppModel()
        opening.setPreviewAccounts([SavedAccount(id: "a", email: "alex@example.com", serverKind: "selfHosted",
                                                 serverURL: "https://vault.home.arpa", kdf: .pbkdf2(iterations: 600_000), protectedUserKey: "")])
        opening.unlockOpening = true
        render(desktop(UnlockView().environment(opening).tint(.brand), dark: false),
               size: CGSize(width: 900, height: 600), appearance: .aqua, to: dir.appending(path: "unlock-opening-light.png"))
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            render(SettingsView().environment(model).tint(.brand), size: CGSize(width: 820, height: 640),
                   appearance: appearance, to: dir.appending(path: "settings-\(name).png"))
        }

        let multi = AppModel()
        multi.setPreviewAccounts([
            SavedAccount(id: "a", email: "alex@example.com", serverKind: "selfHosted", serverURL: "https://vault.home.arpa",
                         kdf: .pbkdf2(iterations: 600_000), protectedUserKey: ""),
            SavedAccount(id: "b", email: "alex@work.example", serverKind: "bitwardenUS", serverURL: "",
                         kdf: .pbkdf2(iterations: 600_000), protectedUserKey: ""),
        ])
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            render(desktop(UnlockView().environment(multi).tint(.brand), dark: name == "dark"),
                   size: CGSize(width: 900, height: 640), appearance: appearance,
                   to: dir.appending(path: "unlock-multi-\(name).png"))
        }

        let unsupportedModel = AppModel()
        unsupportedModel.phase = .vault
        unsupportedModel.previewUnlocked = true
        unsupportedModel.setPreviewAccounts([SavedAccount(id: "demo", email: "alex@example.com", serverKind: "selfHosted",
                                                         serverURL: "https://vault.example.com", kdf: .pbkdf2(iterations: 600_000),
                                                         protectedUserKey: "")])
        let unsupported = VaultItem(id: "future", accountId: "demo", kind: .unsupported, unsupportedType: 99,
                                    name: "Future item", username: nil, host: nil, password: nil, totp: nil, notes: nil,
                                    favorite: false)
        unsupportedModel.items = [unsupported]
        unsupportedModel.selectedID = unsupported.id
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            render(desktop(VaultView().environment(unsupportedModel).tint(.brand), dark: name == "dark"),
                   size: CGSize(width: 1180, height: 760), appearance: appearance,
                   to: dir.appending(path: "unsupported-\(name).png"))
        }

        let vault = AppModel()
        vault.phase = .vault
        vault.items = demoItems.map { item in
            var item = item
            item.revised = Date(timeIntervalSince1970: 1_791_123_456) // a fixed moment, so renders don't change
            item.created = Date(timeIntervalSince1970: 1_748_500_000)
            return item
        }
        vault.previewUnlocked = true
        // The demo account only: never the accounts saved on this Mac (renders end up in the README).
        vault.setPreviewAccounts([SavedAccount(id: "demo", email: "alex@example.com", serverKind: "selfHosted",
                                               serverURL: "https://vault.home.arpa", kdf: .pbkdf2(iterations: 600_000),
                                               protectedUserKey: "")])
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            render(desktop(VaultView().environment(vault).tint(.brand), dark: name == "dark"),
                   size: CGSize(width: 1180, height: 760), appearance: appearance,
                   to: dir.appending(path: "vault-\(name).png"))
            render(desktop(CodesPane().environment(vault).tint(.brand), dark: name == "dark"),
                   size: CGSize(width: 900, height: 560), appearance: appearance, to: dir.appending(path: "codes-\(name).png"))
            renderWindow(VaultView().environment(vault).tint(.brand), size: CGSize(width: 1180, height: 760),
                         appearance: appearance, to: dir.appending(path: "window-\(name).png"))
            // A page (left edge under the search field) with the clipboard countdown in the header.
            vault.clipboardClearsAt = .now.addingTimeInterval(22)
            vault.clipboardHoldSeconds = 30
            renderWindow(VaultView().environment(vault).tint(.brand), size: CGSize(width: 1180, height: 760),
                         appearance: appearance, to: dir.appending(path: "window-page-item-\(name).png"))
            vault.clipboardClearsAt = nil // the pages as they usually look (they end up in the README)
            // The header bell with something waiting: its count badge sits over the circle's bright edge, not under it.
            vault.updates.noteAvailableVersion("0.6.0")
            renderWindow(VaultView().environment(vault).tint(.brand), size: CGSize(width: 1180, height: 760),
                         appearance: appearance, to: dir.appending(path: "window-bell-badge-\(name).png"))
            vault.updates.noteAvailableVersion(nil)
            let selected = vault.selectedID
            vault.beginEditing(EditRequest(mode: .create(.sshKey)))
            renderWindow(VaultView().environment(vault).tint(.brand), size: CGSize(width: 1180, height: 760),
                         appearance: appearance, to: dir.appending(path: "window-new-item-\(name).png"))
            vault.closeNewItemForm()
            vault.selectedID = selected
            for (page, slug) in [(SidebarSelection.codes, "codes"), (.generator, "generator"), (.watchtower, "watchtower")] {
                renderWindow(VaultView(initialSection: page).environment(vault).tint(.brand), size: CGSize(width: 1180, height: 760),
                             appearance: appearance, to: dir.appending(path: "window-page-\(slug)-\(name).png"))
            }
            // Renaming items (the selected one and another) updates their rows in place, under their new letters.
            let beforeRename = vault.items
            renderWindow(VaultView().environment(vault).tint(.brand), size: CGSize(width: 1180, height: 760), appearance: appearance,
                         to: dir.appending(path: "window-rename-before-\(name).png"), thenChange: {
                for i in vault.items.indices where ["GitHub", "Proton Mail"].contains(vault.items[i].name) {
                    vault.items[i].name = "Zed " + vault.items[i].name
                    vault.items[i].revised = .now
                }
            }, to: dir.appending(path: "window-rename-after-\(name).png"))
            vault.items = beforeRename
            vault.clipboardClearsAt = nil
            renderWindow(VaultView().environment(vault).tint(.brand), size: CGSize(width: 430, height: 760),
                         resizeFrom: CGSize(width: 1180, height: 760),
                         appearance: appearance, to: dir.appending(path: "window-resized-\(name).png"))
            for (w, d) in [(400, 0), (760, 0), (400, 2)] {
                renderWindow(VaultView(initialDepth: d).environment(vault).tint(.brand), size: CGSize(width: CGFloat(w), height: 760),
                             appearance: appearance, to: dir.appending(path: "window-\(w)-depth\(d)-\(name).png"))
            }
            for w in [760, 400] {
                renderWindow(VaultView().environment(vault).tint(.brand), size: CGSize(width: CGFloat(w), height: 760),
                             appearance: appearance, to: dir.appending(path: "window-\(w)-\(name).png"))
            }
            // The gate over the vault, frozen part-way, and the lock screen it hands over to.
            let gateModel = AppModel()
            gateModel.setPreviewAccounts(multi.accounts.prefix(1).map { $0 })
            gateModel.gate = .opening
            gateModel.unlockOpenedAt = .now.addingTimeInterval(-1.05)
            for p in [0.0, 0.3, 0.7] {
                render(ZStack {
                    desktop(VaultView().environment(vault).tint(.brand), dark: name == "dark")
                    GatePlates(progress: p).environment(gateModel)
                }, size: CGSize(width: 1100, height: 700), appearance: appearance,
                   to: dir.appending(path: "gate-\(Int(p * 100))-\(name).png"))
            }
            render(ZStack {
                desktop(VaultView().environment(vault).tint(.brand), dark: name == "dark")
                UnlockView().environment(gateModel)
            }, size: CGSize(width: 1100, height: 700), appearance: appearance, to: dir.appending(path: "gate-lockscreen-\(name).png"))
            // The default (calm) gate: the door holds still in the plates, opening and closing alike, and the lock
            // screen they hand over to.
            let calmModel = AppModel()
            calmModel.setPreviewAccounts(multi.accounts.prefix(1).map { $0 })
            for (motion, slug) in [(AppModel.GateMotion.opening, "open"), (.closing, "close")] {
                calmModel.gate = motion
                for p in [0.0, 0.5] {
                    render(ZStack {
                        desktop(VaultView().environment(vault).tint(.brand), dark: name == "dark")
                        GatePlates(progress: p).environment(calmModel)
                    }, size: CGSize(width: 1100, height: 700), appearance: appearance,
                       to: dir.appending(path: "gate-calm-\(slug)-\(Int(p * 100))-\(name).png"))
                }
            }
            calmModel.gate = nil
            render(ZStack {
                desktop(VaultView().environment(vault).tint(.brand), dark: name == "dark")
                UnlockView().environment(calmModel)
            }, size: CGSize(width: 1100, height: 700), appearance: appearance, to: dir.appending(path: "gate-calm-lockscreen-\(name).png"))
            renderWindow(UnlockView().environment(vault).tint(.brand), size: CGSize(width: 400, height: 640),
                         appearance: appearance, to: dir.appending(path: "unlock-400-\(name).png"))
        }
        // Shared vaults and folders, under their plain names: My Folders in the sidebar, a shared vault's section with
        // its shared folders, an item's Shared vault row, and the move and shared-folder sheets.
        let plainItems = vault.items
        vault.folders = [Grouping(id: "f-personal", name: "Personal"), Grouping(id: "f-work", name: "Work")]
        vault.organizations = [Grouping(id: "org-nw", name: "Northwind", children: [
            Grouping(id: "col-eng", name: "Engineering", canWrite: true),
            Grouping(id: "col-eng-be", name: "Engineering/Backend", canWrite: true),
            Grouping(id: "col-eng-fe", name: "Engineering/Frontend", canWrite: true),
            Grouping(id: "col-ops", name: "Operations", canWrite: true)])]
        vault.items = vault.items.map { item in
            var item = item
            if item.id == "1" { item.organizationId = "org-nw"; item.collectionIds = ["col-eng-fe"] }
            if item.id == "5" { item.organizationId = "org-nw"; item.collectionIds = ["col-eng-be", "col-ops"] }
            if item.id == "2" { item.folderId = "f-work"; item.folderName = "Work" }
            if item.id == "3" { item.folderId = "f-personal"; item.folderName = "Personal" }
            return item
        }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            renderWindow(VaultView(initialSelection: "1").environment(vault).tint(.brand), size: CGSize(width: 1180, height: 860),
                         appearance: appearance, to: dir.appending(path: "vault-shared-\(name).png"))
            render(desktop(CodesPane().environment(vault).tint(.brand), dark: name == "dark"),
                   size: CGSize(width: 900, height: 620), appearance: appearance, to: dir.appending(path: "vault-shared-codes-\(name).png"))
            vault.selectedID = "5" // in two shared folders: each a pill
            renderWindow(VaultView(initialSelection: "5").environment(vault).tint(.brand), size: CGSize(width: 1180, height: 860),
                         appearance: appearance, to: dir.appending(path: "vault-shared-two-\(name).png"))
            vault.selectedID = "1"
            // The vault picker: every vault shown, then My vault and Northwind checked.
            render(VaultSwitcherPicker().environment(vault).tint(.brand).background(Color.windowBase), size: CGSize(width: 300, height: 220),
                   appearance: appearance, to: dir.appending(path: "vault-shared-picker-all-\(name).png"))
            vault.vaultFilter = .organization("org-nw")
            render(VaultSwitcherPicker().environment(vault).tint(.brand).background(Color.windowBase), size: CGSize(width: 300, height: 220),
                   appearance: appearance, to: dir.appending(path: "vault-shared-picker-one-\(name).png"))
            vault.vaultFilter = .all
            // My vault and Northwind together: the switcher and the chip name both.
            vault.vaultFilter = .several([AppModel.VaultFilter.personalKey, "org-nw"])
            renderWindow(VaultView(initialSelection: "1").environment(vault).tint(.brand), size: CGSize(width: 1180, height: 860),
                         appearance: appearance, to: dir.appending(path: "vault-shared-several-\(name).png"))
            vault.vaultFilter = .all
            render(MoveToOrganizationSheet(itemIDs: ["2"]).environment(vault).tint(.brand), size: CGSize(width: 520, height: 600),
                   appearance: appearance, to: dir.appending(path: "vault-shared-move-\(name).png"))
            render(CollectionsSheet(itemID: "1").environment(vault).tint(.brand), size: CGSize(width: 480, height: 420),
                   appearance: appearance, to: dir.appending(path: "vault-shared-folders-\(name).png"))
            // The edit form's own Vault and Shared Folders: a personal item that can move, and a shared item whose
            // vault is read-only and whose shared folders are checked.
            if let personal = vault.items.first(where: { $0.id == "2" }),
               let shared = vault.items.first(where: { $0.id == "5" }) {
                render(EditItemSheet(mode: .edit(personal)).environment(vault).tint(.brand), size: CGSize(width: 580, height: 700),
                       appearance: appearance, to: dir.appending(path: "edit-vault-personal-\(name).png"))
                render(EditItemSheet(mode: .edit(shared)).environment(vault).tint(.brand), size: CGSize(width: 580, height: 760),
                       appearance: appearance, to: dir.appending(path: "edit-vault-shared-\(name).png"))
            }
        }
        // A shared vault with one writable folder: the only choice there is, so it starts checked and Move is ready.
        let manyCollections = vault.organizations
        vault.organizations = [Grouping(id: "org-nw", name: "Northwind", children: [
            Grouping(id: "col-only", name: "Family", canWrite: true),
            Grouping(id: "col-locked", name: "Payroll", canWrite: false)])]
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            render(MoveToOrganizationSheet(itemIDs: ["2"]).environment(vault).tint(.brand), size: CGSize(width: 520, height: 600),
                   appearance: appearance, to: dir.appending(path: "vault-shared-move-single-\(name).png"))
        }
        vault.organizations = manyCollections
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            render(NewFolderSheet(parent: "Work").environment(vault).tint(.brand), size: CGSize(width: 440, height: 300),
                   appearance: appearance, to: dir.appending(path: "vault-subfolder-\(name).png"))
            render(RenameFolderSheet(path: "Work").environment(vault).tint(.brand), size: CGSize(width: 440, height: 300),
                   appearance: appearance, to: dir.appending(path: "vault-rename-folder-\(name).png"))
        }
        vault.items = plainItems
        vault.folders = []
        vault.organizations = []

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            render(KeyboardShortcutsView().environment(vault).tint(.brand), size: CGSize(width: 1040, height: 760),
                   appearance: appearance, to: dir.appending(path: "shortcuts-\(name).png"))
        }

        // The one-time search tip, as the list shows it (TipKit forced on, in a throwaway store).
        try? Tips.configure([.datastoreLocation(.url(dir.appending(path: "tips", directoryHint: .isDirectory)))])
        Tips.showAllTipsForTesting()
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            render(desktop(TipView(SearchFiltersTip()).tipImageStyle(.secondary).frame(width: 318).padding(20), dark: name == "dark"),
                   size: CGSize(width: 360, height: 200), appearance: appearance,
                   to: dir.appending(path: "vault-search-tip-\(name).png"))
        }

        // Suggestions while a token is typed: types, then folders.
        vault.folders = [Grouping(id: "f-personal", name: "Personal"), Grouping(id: "f-work", name: "Work")]
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for (slug, typed) in [("type", "type:"), ("folder", "#w"), ("is", "has:")] {
                render(desktop(SearchSuggestionList(suggestions: vault.searchSuggestions(for: typed), pick: 0, accept: { _ in })
                    .padding(20), dark: name == "dark"),
                       size: CGSize(width: 320, height: 300), appearance: appearance,
                       to: dir.appending(path: "vault-search-suggest-\(slug)-\(name).png"))
            }
        }
        vault.folders = []

        // An empty vault: Import… right in the list.
        let full = vault.items
        vault.items = []
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            renderWindow(VaultView().environment(vault).tint(.brand), size: CGSize(width: 1180, height: 760),
                         appearance: appearance, to: dir.appending(path: "vault-empty-\(name).png"))
        }
        vault.items = full

        // An item with a Watchtower issue: its row leads to Watchtower (chevron).
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            renderWindow(VaultView(initialSelection: "4").environment(vault).tint(.brand), size: CGSize(width: 1180, height: 760),
                         appearance: appearance, to: dir.appending(path: "vault-watchtower-row-\(name).png"))
        }

        // The list's search with filters on: chips under the field, the filter menu filled; and filters that leave nothing.
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            vault.searchFilters = SearchFilters(type: .login, hasCode: true)
            renderWindow(VaultView(initialQuery: "git").environment(vault).tint(.brand), size: CGSize(width: 1180, height: 760),
                         appearance: appearance, to: dir.appending(path: "vault-search-\(name).png"))
            vault.searchFilters = SearchFilters(type: .card, favorites: true, hasPasskey: true)
            renderWindow(VaultView().environment(vault).tint(.brand), size: CGSize(width: 1180, height: 760),
                         appearance: appearance, to: dir.appending(path: "vault-search-empty-\(name).png"))
            vault.searchFilters = SearchFilters()
        }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            render(desktop(CommandPalette(close: {}).environment(vault).tint(.brand), dark: name == "dark"),
                   size: CGSize(width: 760, height: 620), appearance: appearance,
                   to: dir.appending(path: "palette-\(name).png"))
            render(MenuBarContent().environment(vault).tint(.brand).background(.regularMaterial),
                   size: CGSize(width: 380, height: 760), appearance: appearance,
                   to: dir.appending(path: "menubar-\(name).png"))
        }
        // The panel with no vault open: nothing signed in on this Mac, then a real locked vault beside it.
        let signedOutPanel = AppModel()
        signedOutPanel.setPreviewAccounts([])
        signedOutPanel.phase = .login
        let lockedPanel = AppModel()
        lockedPanel.setPreviewAccounts(vault.accounts)
        lockedPanel.phase = .locked
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            render(MenuBarContent().environment(signedOutPanel).tint(.brand).background(.regularMaterial),
                   size: CGSize(width: 380, height: 270), appearance: appearance,
                   to: dir.appending(path: "menubar-signed-out-\(name).png"))
            render(MenuBarContent().environment(lockedPanel).tint(.brand).background(.regularMaterial),
                   size: CGSize(width: 380, height: 240), appearance: appearance,
                   to: dir.appending(path: "menubar-locked-\(name).png"))
        }
        // The palette's states: ranked and loose matches, an item's actions, the generator, a new login from the query,
        // a type scope, commands only, and a locked vault.
        for (slug, query, actions) in [("query", "git", false), ("fuzzy", "gthb", false), ("actions", "git", true),
                                       ("gen", "gen 24", false), ("create", "acme.com", false), ("scope", "card: ", false),
                                       ("commands", ">account", false)] {
            render(desktop(CommandPalette(close: {}, initialQuery: query, initialActions: actions).environment(vault).tint(.brand), dark: true),
                   size: CGSize(width: 760, height: 720), appearance: .darkAqua,
                   to: dir.appending(path: "palette-\(slug)-dark.png"))
        }
        let lockedPalette = AppModel()
        lockedPalette.setPreviewAccounts(vault.accounts)
        lockedPalette.phase = .locked
        render(desktop(CommandPalette(close: {}).environment(lockedPalette).tint(.brand), dark: true),
               size: CGSize(width: 760, height: 420), appearance: .darkAqua, to: dir.appending(path: "palette-locked-dark.png"))
        // Called over a browser on github.com: that site's login first, in the palette and the menu bar panel.
        let browser = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }
        vault.foreground = ForegroundContext(app: "Safari", bundleID: "com.apple.Safari", pid: browser?.processIdentifier ?? 0,
                                             host: "github.com")
        vault.foregroundPinned = true
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            render(desktop(CommandPalette(close: {}).environment(vault).tint(.brand), dark: name == "dark"),
                   size: CGSize(width: 760, height: 620), appearance: appearance,
                   to: dir.appending(path: "palette-site-\(name).png"))
            render(MenuBarContent().environment(vault).tint(.brand).background(.regularMaterial),
                   size: CGSize(width: 380, height: 860), appearance: appearance,
                   to: dir.appending(path: "menubar-site-\(name).png"))
        }
        vault.foreground = nil
        vault.foregroundPinned = false
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            render(EditItemSheet(mode: .edit(demoItems[1])).environment(vault).tint(.brand),
                   size: CGSize(width: 580, height: 700), appearance: appearance,
                   to: dir.appending(path: "edit-\(name).png"))
            var card = demoItems.first { $0.kind == .card }!
            card.properties = ["cardholderName": "Alex Chen", "brand": "Visa", "number": "4111111111116411", "expMonth": "10", "expYear": "2026", "code": "123"]
            card.customFields = [CustomField(name: "PIN", value: "0420", kind: .hidden), CustomField(name: "Virtual", value: "true", kind: .boolean)]
            render(EditItemSheet(mode: .edit(card)).environment(vault).tint(.brand),
                   size: CGSize(width: 580, height: 700), appearance: appearance,
                   to: dir.appending(path: "edit-card-\(name).png"))
            render(EditItemSheet(mode: .create(.identity)).environment(vault).tint(.brand),
                   size: CGSize(width: 580, height: 700), appearance: appearance,
                   to: dir.appending(path: "edit-identity-\(name).png"))
            render(EditItemSheet(mode: .create(.sshKey)).environment(vault).tint(.brand),
                   size: CGSize(width: 580, height: 700), appearance: appearance,
                   to: dir.appending(path: "edit-ssh-\(name).png"))
            render(VStack(spacing: 14) {
                       FolderCascader(folders: vault.folders, selection: .constant(nil), create: { _ in nil }, newFolderIn: .constant(""))
                       FolderCascader(folders: vault.folders, selection: .constant(nil), create: { _ in nil }, newFolderIn: .constant("Work/Dev"))
                   }.padding(20).frame(width: 540).background(Color.windowBase).environment(vault).tint(.brand),
                   size: CGSize(width: 540, height: 200), appearance: appearance,
                   to: dir.appending(path: "edit-new-folder-\(name).png"))
            if vault.generatorHistory.isEmpty {
                vault.rememberGenerated("correct-Horse-battery-staple4", kind: "passphrase")
                vault.rememberGenerated("k#9vR!2mWq$7zLp", kind: "password")
                vault.rememberGenerated("alex+k3x9q2ma@proton.me", kind: "username")
            }
            // Each format, so the sheet's height can be checked to stay the same.
            let savedFormat = UserDefaults.standard.string(forKey: "exportFormat")
            for format in ["encryptedJSON", "json", "csv"] {
                UserDefaults.standard.set(format, forKey: "exportFormat")
                render(ExportSheet().environment(vault).tint(.brand).background(Color(nsColor: .windowBackgroundColor)),
                       size: CGSize(width: 500, height: 600), appearance: appearance, to: dir.appending(path: "export-\(format)-\(name).png"))
            }
            UserDefaults.standard.set(savedFormat, forKey: "exportFormat")
            render(desktop(ImportSheet().environment(vault).tint(.brand), dark: name == "dark"),
                   size: CGSize(width: 520, height: 420), appearance: appearance, to: dir.appending(path: "import-\(name).png"))
            for (label, size) in [("", CGSize(width: 1120, height: 760)), ("-narrow", CGSize(width: 680, height: 900))] {
                render(desktop(GeometryReader { geo in
                    ScrollView { GeneratorView().padding(28).frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .top) }
                }.environment(vault).tint(.brand), dark: name == "dark"),
                       size: size, appearance: appearance,
                       to: dir.appending(path: "generator\(label)-\(name).png"))
            }
        }
        vault.sends = [
            SendItem(id: "s1", accountId: "", accessId: "a1", kind: .text, name: "Wi-Fi for guests", notes: nil,
                     text: "maple-guest / sunny-4821", hideText: true, fileName: nil, sizeName: nil, keyMaterial: Data(count: 16),
                     accessCount: 1, maxAccessCount: 3, hasPassword: true, disabled: false,
                     deletionDate: .now.addingTimeInterval(5 * 86_400), expirationDate: nil),
            SendItem(id: "s2", accountId: "", accessId: "a2", kind: .file, name: "Lease scan", notes: "for the agent",
                     text: nil, hideText: false, fileName: "lease-2026.pdf", sizeName: "1.2 MB", keyMaterial: Data(count: 16),
                     accessCount: 0, maxAccessCount: nil, hasPassword: false, disabled: false,
                     deletionDate: .now.addingTimeInterval(86_400), expirationDate: nil),
        ]
        vault.selectedSendID = "s1"
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            render(desktop(SendsPane().environment(vault).tint(.brand).padding(14), dark: name == "dark"),
                   size: CGSize(width: 960, height: 640), appearance: appearance,
                   to: dir.appending(path: "send-\(name).png"))
            vault.composingSend = true
            render(desktop(SendsPane().environment(vault).tint(.brand).padding(14), dark: name == "dark"),
                   size: CGSize(width: 1100, height: 860), appearance: appearance,
                   to: dir.appending(path: "send-compose-\(name).png"))
            vault.composingSend = false
            // The dates the Send form can carry (issues #96, #97): the expiry unfolded in a new Send, and the
            // deletion date in Edit Send. Both are the app's own soft date field.
            render(desktop(SendComposer(opensExpiry: true).environment(vault).tint(.brand).padding(14), dark: name == "dark"),
                   size: CGSize(width: 720, height: 1120), appearance: appearance,
                   to: dir.appending(path: "send-compose-expiry-\(name).png"))
            render(desktop(SendComposer(editing: vault.sends[0]).environment(vault).tint(.brand).padding(14), dark: name == "dark"),
                   size: CGSize(width: 720, height: 1000), appearance: appearance,
                   to: dir.appending(path: "send-edit-\(name).png"))
            // The calendar the date field opens, on its own: a popover can't be captured offscreen.
            render(VStack {
                DateCalendar(label: "Expires",
                             date: .constant(.now.addingTimeInterval(3 * 86_400)),
                             range: Date.now...Date.now.addingTimeInterval(7 * 86_400))
                    .background(Color.panelStrong, in: .rect(cornerRadius: 12, style: .continuous))
                    .padding(20)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.windowBase),
                   size: CGSize(width: 320, height: 380), appearance: appearance,
                   to: dir.appending(path: "send-date-calendar-\(name).png"))
            // The folded "Advanced" row: it says what is set without being opened.
            let expiry = Date.now.addingTimeInterval(3 * 86_400)
            render(VStack {
                FormDisclosure(title: "Advanced",
                               summary: String(localized: "Expires \(expiry.formatted(date: .abbreviated, time: .shortened))"),
                               isExpanded: .constant(false)) {
                    EmptyView()
                }
                .padding(18)
                .background(Color.panelStrong, in: .rect(cornerRadius: 18, style: .continuous))
            }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(Color.windowBase),
                   size: CGSize(width: 560, height: 130), appearance: appearance,
                   to: dir.appending(path: "send-expiry-summary-\(name).png"))
            // Edit Send with an expiry set: the same disclosure, open, over the deletion date.
            var expiring = vault.sends[0]
            expiring.expirationDate = expiry
            render(desktop(SendComposer(editing: expiring).environment(vault).tint(.brand).padding(14), dark: name == "dark"),
                   size: CGSize(width: 720, height: 1060), appearance: appearance,
                   to: dir.appending(path: "send-edit-expiry-\(name).png"))
        }
        // "Share by Link…" (issue #85): the composer as it opens from an item, name and fields filled in.
        vault.composeNewSend(prefill: SendPrefill(
            name: "GitHub",
            text: "Username: octocat\nPassword: correct-horse-battery\nWebsite: https://github.com\nNotes: work account",
            accountId: nil))
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            render(desktop(SendsPane().environment(vault).tint(.brand).padding(14), dark: name == "dark"),
                   size: CGSize(width: 1100, height: 1180), appearance: appearance,
                   to: dir.appending(path: "send-share-by-link-\(name).png"))
        }
        vault.closeSendComposer()
        // The one-time sheet a Send opens after it's made: its link and the passphrase that opens it.
        let created = AppModel.CreatedSend(
            link: "https://vault.home.arpa/#/send/aBcD3fGh1JkL9mNoP2qR7sT/XrPVubZezJMect7W6bhvjA",
            passphrase: "mule-frost-jumbo-quiet-vex-razor", name: "GitHub")
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            render(desktop(SendCreatedSheet(created: created).environment(vault).tint(.brand), dark: name == "dark"),
                   size: CGSize(width: 520, height: 380), appearance: appearance,
                   to: dir.appending(path: "send-created-\(name).png"))
        }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let locked = AutoFillState()
            locked.domains = ["github.com"]
            locked.email = "alex@example.com"
            locked.touchIDEnabled = true
            locked.hasAccount = true
            render(AutoFillView(state: locked).background(Color.windowBase), size: CGSize(width: 440, height: 520),
                   appearance: appearance, to: dir.appending(path: "autofill-locked-\(name).png"))
            let open = AutoFillState()
            open.domains = ["github.com"]
            open.items = demoItems.filter { $0.kind == .login }
            open.unlocked = true
            open.hasAccount = true
            render(AutoFillView(state: open).background(Color.windowBase), size: CGSize(width: 440, height: 520),
                   appearance: appearance, to: dir.appending(path: "autofill-list-\(name).png"))
            let register = AutoFillState()
            register.begin(passkey: .init(rpId: "github.com", clientDataHash: Data(), userName: "alexchen"), registering: true)
            register.items = demoItems.filter { $0.kind == .login }
            register.unlocked = true
            register.hasAccount = true
            render(AutoFillView(state: register).background(Color.windowBase), size: CGSize(width: 440, height: 520),
                   appearance: appearance, to: dir.appending(path: "autofill-passkey-\(name).png"))
        }
        vault.breachCounts = ["4": 1203]
        // The reminders too: a card about to expire, a login saved twice, a password from years ago.
        let demoVault = vault.items
        var expiring = demoItems.first { $0.kind == .card }!
        let soon = Calendar.current.dateComponents([.month, .year], from: .now.addingTimeInterval(30 * 86_400))
        expiring.properties = ["expMonth": "\(soon.month!)", "expYear": "\(soon.year!)"]
        var twice = demoItems[2]
        twice = VaultItem(id: "dup", accountId: twice.accountId, name: twice.name, username: twice.username, host: twice.host,
                          password: twice.password, totp: nil, notes: nil, favorite: false)
        var old = demoItems[0]
        old.created = Calendar.current.date(byAdding: .year, value: -4, to: .now)
        vault.items = vault.items.map { $0.id == expiring.id ? expiring : $0.id == old.id ? old : $0 } + [twice]
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            render(desktop(WatchtowerView(onOpen: { _ in }).environment(vault).tint(.brand), dark: name == "dark"),
                   size: CGSize(width: 820, height: 1400), appearance: appearance,
                   to: dir.appending(path: "watchtower-\(name).png"))
        }
        vault.items = demoVault
        vault.breachCounts = nil
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            render(LargeTypeView(text: "m7Kq#vR2!tLp 0O1lI|"), size: CGSize(width: 1000, height: 420), appearance: appearance,
                   to: dir.appending(path: "largetype-\(name).png"))
        }
        // The Trash on a Bitwarden cloud account: the 30-day note, and when each item goes for good.
        let trash = AppModel()
        trash.setPreviewAccounts([SavedAccount(id: "cloud", email: "alex@example.com", serverKind: "bitwardenUS", serverURL: "",
                                               kdf: .pbkdf2(iterations: 600_000), protectedUserKey: "")])
        trash.previewUnlocked = true
        trash.phase = .vault
        trash.items = demoItems.prefix(4).enumerated().map { i, item in
            var gone = item
            gone.accountId = "cloud"
            gone.isDeleted = true
            gone.deleted = Calendar.current.date(byAdding: .day, value: -[28, 12, 3, 0][i], to: .now)
            return gone
        }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            render(desktop(VaultView(initialSelection: trash.items.first?.id, initialSection: .section(.trash)).environment(trash).tint(.brand),
                           dark: name == "dark"),
                   size: CGSize(width: 1180, height: 760), appearance: appearance, to: dir.appending(path: "trash-\(name).png"))
        }
        render(desktop(VaultView(initialSelection: "7").environment(vault).tint(.brand), dark: false),
               size: CGSize(width: 1180, height: 760), appearance: .aqua, to: dir.appending(path: "vault-card-light.png"))
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            render(SettingsView().environment(model).tint(.brand),
                   size: CGSize(width: 600, height: 520), appearance: appearance,
                   to: dir.appending(path: "settings-\(name).png"))
            // Each pane, so its controls can be checked. Demo accounts only: never the Mac's real ones.
            let people = AppModel()
            people.setPreviewAccounts([
                SavedAccount(id: "a", email: "alex@example.com", serverKind: "selfHosted", serverURL: "https://vault.home.arpa",
                             kdf: .pbkdf2(iterations: 600_000), protectedUserKey: ""),
                SavedAccount(id: "b", email: "sam@work.example", serverKind: "bitwardenEU", serverURL: "",
                             kdf: .argon2id(iterations: 3, memoryMiB: 64, parallelism: 4), protectedUserKey: ""),
            ])
            var historic = demoItems[1]
            historic.passwordRevised = Calendar.current.date(byAdding: .day, value: -12, to: .now)
            historic.passwordHistory = [
                .init(password: "7m4Gv%Y6A56NAMPBz#aoTX", date: Calendar.current.date(byAdding: .day, value: -12, to: .now)),
                .init(password: "hunter2-old", date: Calendar.current.date(byAdding: .year, value: -1, to: .now)),
            ]
            render(ItemHistoryCard(item: historic).environment(vault).padding(20).frame(width: 460)
                .background(Color(nsColor: .windowBackgroundColor)),
                   size: CGSize(width: 460, height: 260), appearance: appearance, to: dir.appending(path: "item-history-\(name).png"))
            render(PasswordHistorySheet(item: historic).environment(vault).background(Color(nsColor: .windowBackgroundColor)),
                   size: CGSize(width: 460, height: 330), appearance: appearance, to: dir.appending(path: "item-history-sheet-\(name).png"))
            render(AccountSwitcher(close: {}).environment(people).background(.regularMaterial),
                   size: CGSize(width: 300, height: 420), appearance: appearance,
                   to: dir.appending(path: "account-switcher-\(name).png"))
            if let first = people.accounts.first {
                render(AccountUnlockPane(account: first).environment(people).padding(.vertical, 6)
                    .background(Color(nsColor: .windowBackgroundColor)),
                       size: CGSize(width: 270, height: 520), appearance: appearance,
                       to: dir.appending(path: "account-unlock-\(name).png"))
            }
            let saved = UserDefaults.standard.string(forKey: "settingsPane")
            for pane in ["accounts", "general", "shortcuts", "server", "security", "developer", "license", "about"] {
                UserDefaults.standard.set(pane, forKey: "settingsPane")
                render(SettingsView().environment(people).tint(.controlTint),
                       size: CGSize(width: 820, height: 640), appearance: appearance,
                       to: dir.appending(path: "settings-\(pane.replacingOccurrences(of: ":", with: "-"))-\(name).png"))
            }
            UserDefaults.standard.set(saved, forKey: "settingsPane")
            render(desktop(LicenseReminderView().environment(model).tint(.brand), dark: name == "dark"),
                   size: CGSize(width: 460, height: 450), appearance: appearance,
                   to: dir.appending(path: "license-reminder-\(name).png"))
            // Registered: the thank-you page.
            model.license.preview(License.Registration(name: "Alex Chen", email: "alex@example.com", order: "1840221",
                                                       date: "2026-10-07"), key: "3C30C6C1-6296-4FC0-B465-BD762ACED135")
            UserDefaults.standard.set("license", forKey: "settingsPane")
            render(SettingsView().environment(model).tint(.controlTint), size: CGSize(width: 820, height: 640),
                   appearance: appearance, to: dir.appending(path: "settings-license-registered-\(name).png"))
            // The celebration, caught mid-burst and as the confetti falls.
            for moment in [0.35, 0.8] {
                render(desktop(LicenseSettings(celebrationFrozenAt: moment).environment(model).tint(.controlTint)
                    .frame(width: 600, height: 420), dark: name == "dark"),
                       size: CGSize(width: 600, height: 420), appearance: appearance,
                       to: dir.appending(path: "license-celebrate-\(Int(moment * 100))-\(name).png"))
            }
            model.license.preview(nil)
            UserDefaults.standard.set(saved, forKey: "settingsPane")
            // The menu bar panel with two accounts: the account button beside search and lock.
            render(MenuBarContent().environment(people).tint(.brand).background(.regularMaterial),
                   size: CGSize(width: 380, height: 360), appearance: appearance,
                   to: dir.appending(path: "menubar-accounts-\(name).png"))
            // An account's details, as the sheet over Settings › Accounts shows them.
            for account in people.accounts {
                render(AccountDetailsSheet(accountId: account.id).environment(people).tint(.controlTint)
                    .background(Color(nsColor: .windowBackgroundColor)),
                       size: CGSize(width: 620, height: 620), appearance: appearance,
                       to: dir.appending(path: "settings-account-\(account.id)-\(name).png"))
            }
        }
        print(dir.path)
        exit(0)
    }

    /// Paints the window base, which `containerBackground` provides in the real window.
    static func desktop(_ view: some View, dark: Bool) -> some View {
        ZStack {
            WindowBackdrop()
            view
        }
    }

    /// Runs a command-line tool for the self-test.
    /// Runs off the main actor: the SSH agent being tested needs the main actor to answer.
    nonisolated static func tool(_ name: String, _ args: [String], env: [String: String] = [:], stdin: Data? = nil) async -> (status: Int32, output: String) {
        await Task.detached { runTool(name, args, env: env, stdin: stdin) }.value
    }

    nonisolated static func runTool(_ name: String, _ args: [String], env: [String: String], stdin: Data?) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(filePath: name.hasPrefix("/") ? name : "/usr/bin/\(name)")
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        let out = Pipe(), input = Pipe()
        p.standardOutput = out; p.standardError = out; p.standardInput = input
        do { try p.run() } catch { return (-1, "\(error)") }
        if let stdin { input.fileHandleForWriting.write(stdin) }
        try? input.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static let demoItems: [VaultItem] = [
        VaultItem(id: "1", name: "Cloudflare", username: "ops@northwind.example", host: "dash.cloudflare.com",
                  password: "cf-9xQ!m2Lp#Vt7", totp: TOTP("JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP"), notes: nil, favorite: false),
        VaultItem(id: "2", name: "GitHub", username: "alexchen", host: "github.com", password: "m7Kq#vR2!tLp9wZe$Hu",
                  totp: TOTP("JBSWY3DPEHPK3PXP"), notes: "Recovery codes are in the “GitHub recovery” note.",
                  uri: "https://github.com/login?return_to=%2Fsettings%2Fsecurity", favorite: true,
                  hasPasskey: true,
                  passkeys: [PasskeyCredential(credentialId: "demo", keyValue: "", rpId: "github.com", userName: "alexchen",
                                               creationDate: Date(timeIntervalSince1970: 1_780_000_000))],
                  attachments: [VaultItem.Attachment(id: "a1", fileName: "github-recovery-codes.txt", size: 912, sizeName: "912 bytes",
                                                     fileKey: try! SymmetricKeyPair(combined: Data(count: 64))),
                                VaultItem.Attachment(id: "a2", fileName: "2fa-backup.pdf", size: 48_000, sizeName: "48 KB",
                                                     fileKey: try! SymmetricKeyPair(combined: Data(count: 64)))]),
        VaultItem(id: "3", name: "Proton Mail", username: "alex.chen@proton.me", host: "account.proton.me",
                  password: "pm-4Rt$w8Nq!zK", totp: nil, notes: nil, favorite: false, hasPasskey: true),
        VaultItem(id: "4", name: "Synology NAS", username: "admin", host: "nas.home.arpa", password: "reused-password",
                  totp: nil, notes: nil, favorite: false, reuseCount: 1),
        VaultItem(id: "6", kind: .sshKey, name: "homelab-ed25519", username: nil, host: nil, password: nil,
                  totp: nil, notes: nil, favorite: false),
        {
            var card = VaultItem(id: "7", kind: .card, name: "Travel Visa", username: "•••• 6411", host: nil, password: nil,
                                 totp: nil, notes: nil, favorite: false,
                                 fields: [ItemField(label: "Card number", value: "4111111111116411", secret: true, monospaced: true),
                                          ItemField(label: "Cardholder", value: "Alex Chen"), ItemField(label: "Expires", value: "10/2026"),
                                          ItemField(label: "Security code", value: "123", secret: true, monospaced: true)])
            card.properties = ["brand": "Visa", "number": "4111111111116411", "cardholderName": "Alex Chen",
                               "expMonth": "10", "expYear": "2026", "code": "123"]
            return card
        }(),
        VaultItem(id: "5", name: "Tailscale", username: "alexchen", host: "login.tailscale.com", password: "ts-Lw8!r2Kq$7m",
                  totp: TOTP("JBSWY3DPEHPK3PXQ"), notes: nil, favorite: true),
    ]

    /// A real window with SwiftUI's toolbar bridged in, so toolbar items render as in the app.
    /// `resizeFrom`: open at that size first, then shrink to `size` — like dragging the window edge.
    private static func renderWindow(_ view: some View, size: CGSize, resizeFrom: CGSize? = nil, appearance: NSAppearance.Name, to url: URL,
                                     thenChange change: (() -> Void)? = nil, to changedURL: URL? = nil) {
        guard wanted(url) else { return }
        let controller = NSHostingController(rootView: view.frame(minWidth: 380, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity))
        controller.sceneBridgingOptions = [.toolbars, .title]
        // Laid out at its size from the start: built at its minimum first, the split view keeps a cramped sidebar.
        controller.view.frame = CGRect(origin: .zero, size: resizeFrom ?? size)
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .fullSizeContentView, .closable, .miniaturizable, .resizable]
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: appearance)
        window.setContentSize(resizeFrom ?? size)
        window.orderFrontRegardless()
        window.makeKey()
        RunLoop.main.run(until: .now + 0.5)
        // Outside a WindowGroup the split view ignores the sidebar's column width; put the divider where the app has it.
        if size.width >= 900, let split = Self.firstSplitView(in: window.contentView) {
            split.setPosition(220, ofDividerAt: 0)
        }
        RunLoop.main.run(until: .now + 1)
        if resizeFrom != nil {
            window.setContentSize(size)
            RunLoop.main.run(until: .now + 1.5)
        }
        // The window as the screen shows it (glass and all), when the window server lets the app capture its own
        // window; otherwise its views drawn offscreen (glass comes out black).
        if let image = Self.capture(window) {
            Self.write(image, to: url)
        } else if let frame = window.contentView?.superview,
                  let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: rep)
            Self.write(rep, to: url)
        }
        // The same live window after a change to the model: what a sync or an edit does to views already on screen.
        if let change, let changedURL {
            change()
            RunLoop.main.run(until: .now + 1)
            if let image = Self.capture(window) {
                Self.write(image, to: changedURL)
            }
        }
        window.orderOut(nil)
    }

    /// Streams the render when a test runner asked for it, else writes it into the app's container.
    private static func write(_ image: CGImage, to url: URL) {
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        write(png, to: url)
    }

    private static func write(_ rep: NSBitmapImageRep, to url: URL) {
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        write(png, to: url)
    }

    private static func write(_ png: Data, to url: URL) {
        // Synthetic renders can be streamed directly to a test runner without reading the app container.
        if ProcessInfo.processInfo.environment["TRIWARDEN_SNAPSHOT_STDOUT"] == "1" {
            print("SNAPSHOT \(url.lastPathComponent) \(png.base64EncodedString())")
        } else {
            try? png.write(to: url)
        }
    }

    private static func firstSplitView(in view: NSView?) -> NSSplitView? {
        guard let view else { return nil }
        if let split = view as? NSSplitView { return split }
        for child in view.subviews { if let found = firstSplitView(in: child) { return found } }
        return nil
    }

    /// CGWindowListCreateImage of one of our own windows (no screen-recording permission needed for those). Hidden from
    /// Swift in the current SDK, so it's looked up at run time; debug snapshots only.
    private static func capture(_ window: NSWindow) -> CGImage? {
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: Create.self)
        // .null rect = the window's bounds; 1<<3 = including this window only; 1<<0 | 1<<3 = ignore framing, best resolution.
        return create(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue()
    }

    private static func render(_ view: some View, size: CGSize, appearance: NSAppearance.Name, to url: URL) {
        guard wanted(url) else { return }
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: appearance)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        window.makeKey()
        host.layoutSubtreeIfNeeded()
        // Let one run-loop turn pass so async layout and images settle.
        RunLoop.main.run(until: .now + 1.0)
        // Capture the frame view so the window background is included (sidebar vibrancy still isn't).
        let frame = host.superview ?? host
        guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        Self.write(rep, to: url)
        window.orderOut(nil)
    }
}
#endif

#if DEBUG
/// Debug-only: `Triwarden --selftest <server> <email> <password>` runs the account lifecycle inside the
/// real (signed, sandboxed) app: log in → lock → offline unlock from cache → resume session → wrong password → log out.
@MainActor
enum SelfTest {
    /// `--selftest <server> <email> <password> [<second email> <second password>]`
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--selftest"), i + 3 < args.count else { return }
        let (server, email, password) = (args[i + 1], args[i + 2], args[i + 3])
        let second = i + 5 < args.count ? (args[i + 4], args[i + 5]) : nil
        // Isolated storage: the self-test must never see or erase the user's real accounts.
        AccountStore.namespace = "SelfTestAccounts"
        AutoFillIdentities.isEnabled = false
        Task {
            var failures = 0
            func check(_ ok: Bool, _ what: String) { print(ok ? "PASS" : "FAIL", what); if !ok { failures += 1 } }

            let savedFocus = UserDefaults.standard.object(forKey: "accountFocus")
            let savedVaultFilter = UserDefaults.standard.object(forKey: "vaultFilter")
            defer {
                UserDefaults.standard.set(savedFocus, forKey: "accountFocus")
                UserDefaults.standard.set(savedVaultFilter, forKey: "vaultFilter")
            }
            let model = AppModel()
            for account in model.accounts { model.logOut(account.id) }
            model.serverKind = .selfHosted
            model.serverURL = server
            model.email = email
            await model.login(password: password)
            let firstID = SavedAccount.makeID(serverKind: "selfHosted", serverURL: server, email: email)
            check(model.isUnlocked && !model.items.isEmpty, "login + sync (\(model.items.count) items) \(model.errorMessage ?? "")")
            check(AccountStore.load(firstID) != nil && AccountStore.loadCache(firstID) != nil && AccountStore.refreshToken(firstID) != nil,
                  "account, encrypted cache and refresh token persisted")
            check(Keychain.isShared(service: "io.github.sinhong2011.triwarden.SelfTestAccounts.refresh.\(firstID)"),
                  "refresh token in the App Group keychain (AutoFill can save passkeys)")
            for stale in model.items.filter({ ["Sidebar bulk A", "Sidebar bulk late arrival"].contains($0.name) }) { await model.deleteForever(stale) }
            let count = model.items.count
            let org = model.organizations.first
            let collection = org?.children.first
            check(org != nil && collection != nil, "organization “\(org?.name ?? "-")” with collection “\(collection?.name ?? "-")”")
            if let org, let collection {
                check(model.items.contains { SidebarSelection.organization(org.id).includes($0) }
                      && model.items.contains { SidebarSelection.collection(collection.id).includes($0) },
                      "org and collection filters match their items")
            }

            // Every selectable sidebar destination has purpose-specific actions, scoped to its owner.
            let sidebarDestinations: [SidebarSelection] = VaultSection.allCases.map { .section($0) }
                + [.myVault, .folders, .folder("Selftest"), .sends, .codes, .generator, .watchtower]
            check(sidebarDestinations.allSatisfy { !model.sidebarActions(for: $0).isEmpty }, "context actions cover every sidebar destination")
            if let org, let collection {
                var readOnly = collection
                readOnly.canWrite = false
                let actions = model.sidebarActions(for: .collection(collection.id), organization: org, collection: readOnly)
                check(actions.first?.enabled == false && actions.first?.children.isEmpty == true,
                      "read-only collection cannot offer creation")
                let created = await model.createItem(.secureNote, edit: CipherEdit(name: "Selftest collection creation", notes: "scoped"),
                    accountId: firstID, organizationId: org.id, collectionIds: [collection.id])
                let shared = model.items.first { $0.name == "Selftest collection creation" }
                check(created && shared?.organizationId == org.id && shared?.collectionIds.contains(collection.id) == true && shared?.notes == "scoped",
                      "create directly in writable collection using organization key")
                if let shared { await model.deleteForever(shared) }
            }

            // Watchtower on the seeded vault.
            let report = WatchtowerReport(items: model.items, breaches: nil)
            let names = { (issue: WatchtowerReport.Issue) in Set(report.issues[issue, default: []].map(\.name)) }
            check(names(.weak).contains("Weak example") && names(.reused).isSuperset(of: ["Synology NAS", "Router"])
                  && !names(.insecure).contains("Router"),
                  "watchtower: weak, reused, private-IP http not flagged")
            await model.checkBreaches()
            let breached = Set(WatchtowerReport(items: model.items, breaches: model.breachCounts).issues[.breached, default: []].map(\.name))
            check(breached.contains("Weak example") && !breached.contains("GitHub"), "breach check (k-anonymity) flags 123456 only among known")

            // Folders: nested names, moving items, parent selection includes children, highlighting.
            let parentID = await model.createFolder(name: "Selftest")
            let childID = await model.createFolder(name: "Selftest/Nested")
            _ = await model.createItem(.login, edit: CipherEdit(name: "Folder Test Item", username: "f", password: "x"))
            if let item = model.items.first(where: { $0.name == "Folder Test Item" }), let childID {
                await model.move(itemIDs: [item.id], toFolderIn: [childID])
                let movedItem = model.items.first { $0.id == item.id }
                let tree = FolderNode.tree(model.folders)
                let parentNode = tree.first { $0.path == "Selftest" }
                check(movedItem?.folderId == childID && parentNode?.children.first?.path == "Selftest/Nested",
                      "move item into nested folder; tree nests Selftest › Nested")
                check(movedItem.map { SidebarSelection.folder("Selftest").includes($0) && SidebarSelection.folder("Selftest/Nested").includes($0) } == true,
                      "selecting the parent folder includes items in subfolders")
                let marked = Highlight.marked("Folder Test Item", "test")
                check(marked.runs.contains { $0.backgroundColor != nil }, "search match highlighting")
                if let movedItem { await model.deleteForever(movedItem) }
            } else {
                check(false, "folder setup")
            }
            if let childID { await model.deleteFolder(childID) }
            if let parentID { await model.deleteFolder(parentID) }

            // Editing lifecycle through the app model.
            let created = await model.createItem(.login, edit: CipherEdit(name: "Selftest Item", username: "u", password: "p-old", uri: "https://example.org"))
            let new = model.items.first { $0.name == "Selftest Item" }
            check(created && new != nil && model.selectedID == new?.id, "create login (selected after save)")
            if let new {
                await model.updateItem(new.id, edit: CipherEdit(name: "Selftest Edited", password: "p-new"))
                let edited = model.items.first { $0.id == new.id }
                check(edited?.name == "Selftest Edited" && edited?.password == "p-new" && edited?.username == "u", "edit keeps untouched fields")
                if let edited { await model.toggleFavorite(edited) }
                check(model.items.first { $0.id == new.id }?.favorite == true, "toggle favorite")
                if let starred = model.items.first(where: { $0.id == new.id }) { await model.toggleFavorite(starred) }
                check(model.items.first { $0.id == new.id }?.favorite == false, "toggle favorite off again")
                if let item = model.items.first(where: { $0.id == new.id }) { await model.setArchived(item, true) }
                let archivedItem = model.items.first { $0.id == new.id }
                check(archivedItem?.isArchived == true && archivedItem.map { VaultSection.archive.includes($0) && !VaultSection.all.includes($0) } == true,
                      "archive: in Archive, out of All Items")
                if let archivedItem { await model.setArchived(archivedItem, false) }
                check(model.items.first { $0.id == new.id }?.isArchived == false, "unarchive")
                if let item = model.items.first(where: { $0.id == new.id }) { await model.trash(item) }
                check(model.items.first { $0.id == new.id }?.isDeleted == true, "move to Trash")
                if let item = model.items.first(where: { $0.id == new.id }) { await model.restore(item) }
                check(model.items.first { $0.id == new.id }?.isDeleted == false, "restore from Trash")
                if let item = model.items.first(where: { $0.id == new.id }) { await model.deleteForever(item) }
                check(!model.items.contains { $0.id == new.id }, "delete forever")
            }

            // Watchtower's two-step login list (2fa.directory).
            let directory = await TwoFactorDirectory.load()
            check(directory.count > 500 && WatchtowerReport.guide(for: "gist.github.com", in: directory) != nil
                  && WatchtowerReport.guide(for: "example.invalid", in: directory) == nil,
                  "two-step login directory (\(directory.count) sites)")

                // Change password links: a site with /.well-known/change-password gets it, one without falls back to itself.
                let github = await ChangePasswordLink.url(for: "github.com")
                let example = await ChangePasswordLink.url(for: "example.com")
                let netflix = await ChangePasswordLink.url(for: "www.netflix.com")
                check(github?.path() == "/.well-known/change-password" && example?.absoluteString == "https://example.com"
                      && netflix?.path() == "/.well-known/change-password",
                      "change password links: github.com and netflix (HEAD refused) have one, example.com falls back to the site [\(github?.absoluteString ?? "nil") | \(netflix?.absoluteString ?? "nil") | \(example?.absoluteString ?? "nil")]")

            // Item extras: password history, the master-password re-prompt flag, clone.
            _ = await model.createItem(.login, edit: CipherEdit(name: "Selftest extras", username: "u", password: "first-pass"))
            if let extra = model.items.first(where: { $0.name == "Selftest extras" }) {
                var change = CipherEdit(password: "second-pass")
                change.reprompt = true
                _ = await model.updateItem(extra.id, edit: change)
                let updated = model.items.first { $0.id == extra.id }
                check(updated?.passwordHistory.first?.password == "first-pass" && updated?.reprompt == true,
                      "password history and master-password re-prompt saved")
                var clone = CipherEdit(name: "Selftest extras - Clone", username: "u", password: "second-pass")
                clone.reprompt = true
                _ = await model.createItem(.login, edit: clone)
                let copy = model.items.first { $0.name == "Selftest extras - Clone" }
                check(copy?.password == "second-pass" && copy?.reprompt == true && copy?.id != extra.id, "clone an item")
                for item in model.items where item.name.hasPrefix("Selftest extras") { await model.deleteForever(item) }
            }

            // Equivalent domains come down with sync: a google.com login belongs on youtube.com too.
            let eq = model.equivalentDomains
            check(eq.groups.count > 50 && eq.matches(itemHost: "accounts.google.com", site: "youtube.com")
                  && !eq.matches(itemHost: "github.com", site: "gitlab.com"),
                  "equivalent domains from the server (\(eq.groups.count) groups)")

            // Organizations: move a personal item in (re-encrypted with the organization key), change its collections.
            if let org = model.organizations.first, let collection = org.children.first {
                _ = await model.createItem(.login, edit: CipherEdit(name: "Selftest share", username: "kurimanju", password: "s3cret-share",
                                                                uri: "https://share.example"))
                if let mine = model.items.first(where: { $0.name == "Selftest share" }) {
                    // With an attachment: it must move along, readable with the organization's key.
                    let fileBytes = Data("attached to usagi's login \(UUID().uuidString)".utf8)
                    if let session = model.session(for: mine.accountId) {
                        try? await session.addAttachment(mine.id, name: "share-note.txt", contents: fileBytes)
                    }
                    let ok = await model.share([mine.id], organizationId: org.id, collectionIds: [collection.id])
                    if let moved = model.items.first(where: { $0.id == mine.id }), let attachment = moved.attachments.first,
                       let session = model.session(for: moved.accountId) {
                        let contents = try? await session.attachmentContents(moved.id, attachment)
                        check(contents == fileBytes && attachment.fileName == "share-note.txt",
                              "move to organization keeps an attachment (key re-wrapped, file unchanged)")
                    } else {
                        check(false, "move to organization keeps an attachment: not found after the move")
                    }
                    let moved = model.items.first { $0.id == mine.id }
                    check(ok && moved?.organizationId == org.id && moved?.password == "s3cret-share" && moved?.username == "kurimanju"
                          && moved?.uri == "https://share.example" && moved?.collectionIds == [collection.id],
                          "move to organization: re-encrypted with its key, in \(collection.name)")
                    let collectionsOK = await model.setCollections(moved ?? mine, collectionIds: [collection.id])
                    check(collectionsOK, "set an organization item's collections")
                    if let moved { await model.deleteForever(moved) }
                }
                // Editing and moving in one go (the edit form's Vault field): the fields are written first, then the
                // item is shared. Sharing re-encrypts the server's copy, so the reverse order would lose the edit.
                _ = await model.createItem(.login, edit: CipherEdit(name: "Selftest edit and share", username: "before", password: "before-pass"))
                if let mine = model.items.first(where: { $0.name == "Selftest edit and share" }) {
                    var edit = CipherEdit()
                    edit.name = "Selftest edit and share (edited)"
                    edit.username = "after"
                    edit.password = "after-pass"
                    let edited = await model.updateItem(mine.id, edit: edit)
                    let shared = await model.share([mine.id], organizationId: org.id, collectionIds: [collection.id])
                    let now = model.items.first { $0.id == mine.id }
                    check(edited && shared && now?.organizationId == org.id
                          && now?.name == "Selftest edit and share (edited)" && now?.username == "after" && now?.password == "after-pass"
                          && now?.collectionIds == [collection.id],
                          "edit then move to an organization keeps the edit")
                    if let now { await model.deleteForever(now) }
                }
            } else {
                check(false, "move to organization: no organization with a collection")
            }

            // A shared vault with one writable folder: the form picks it, so Move needs no click that decides nothing.
            let folders = [Grouping(id: "a", name: "Family", canWrite: true), Grouping(id: "b", name: "Payroll", canWrite: false)]
            check(folders.soleWritableCollection == "a", "one writable shared folder is picked automatically")
            check([Grouping(id: "a", name: "Family", canWrite: true), Grouping(id: "c", name: "Team", canWrite: true)]
                    .soleWritableCollection == nil, "two writable shared folders leave the choice to the user")
            check([Grouping(id: "b", name: "Payroll", canWrite: false)].soleWritableCollection == nil,
                  "a read-only shared folder is never picked")

            // Many at once: trash, restore, move to a folder, delete forever — one request each.
            for n in 1...3 { _ = await model.createItem(.secureNote, edit: CipherEdit(name: "Selftest bulk \(n)", notes: "b")) }
            let bulkIDs = model.items.filter { $0.name.hasPrefix("Selftest bulk") }.map(\.id)
            await model.bulk(.trash, bulkIDs)
            check(bulkIDs.count == 3 && bulkIDs.allSatisfy { id in model.items.first { $0.id == id }?.isDeleted == true }, "bulk move to Trash")
            await model.bulk(.restore, bulkIDs)
            check(bulkIDs.allSatisfy { id in model.items.first { $0.id == id }?.isDeleted == false }, "bulk restore")
            if let folderID = await model.createFolder(name: "Selftest bulk folder") {
                await model.bulk(.move(folderId: folderID), bulkIDs)
                check(bulkIDs.allSatisfy { id in model.items.first { $0.id == id }?.folderId == folderID }, "bulk move to a folder")
                await model.bulk(.delete, bulkIDs)
                check(!model.items.contains { bulkIDs.contains($0.id) }, "bulk delete forever")
                await model.deleteFolder(folderID)
            }

            // Cards, identities, SSH keys and custom fields.
            do {
                var cardEdit = CipherEdit(name: "Selftest card")
                cardEdit.properties = ["cardholderName": "Usagi", "number": "4111111111111111", "expMonth": "4", "expYear": "2031"]
                cardEdit.customFields = [CustomField(name: "PIN", value: "0420", kind: .hidden), CustomField(name: "Virtual", value: "true", kind: .boolean)]
                let ok = await model.createItem(.card, edit: cardEdit)
                let card = model.items.first { $0.name == "Selftest card" }
                check(ok && card?.kind == .card && card?.properties["number"] == "4111111111111111"
                      && card?.customFields.count == 2 && card?.fields.contains { $0.label == "PIN" && $0.secret } == true,
                      "create card with custom fields")
                if let card {
                    var edit = CipherEdit()
                    edit.properties = ["code": "123"]
                    edit.customFields = [CustomField(name: "PIN", value: "9999", kind: .hidden)]
                    _ = await model.updateItem(card.id, edit: edit)
                    let after = model.items.first { $0.id == card.id }
                    check(after?.properties["code"] == "123" && after?.properties["cardholderName"] == "Usagi"
                          && after?.customFields == [CustomField(name: "PIN", value: "9999", kind: .hidden)], "edit card keeps other fields")
                    await model.deleteForever(after ?? card)
                }
                var idEdit = CipherEdit(name: "Selftest identity")
                idEdit.properties = ["firstName": "Hachiware", "postalCode": "100-0001", "passportNumber": "X1234567"]
                _ = await model.createItem(.identity, edit: idEdit)
                let identity = model.items.first { $0.name == "Selftest identity" }
                check(identity?.properties["passportNumber"] == "X1234567" && identity?.username == "Hachiware", "create identity")
                if let identity { await model.deleteForever(identity) }
                let pair = SSHKeyPair.generateEd25519(comment: "selftest")
                var sshEdit = CipherEdit(name: "Selftest SSH")
                sshEdit.properties = ["privateKey": pair.privateKey, "publicKey": pair.publicKey, "keyFingerprint": pair.fingerprint]
                _ = await model.createItem(.sshKey, edit: sshEdit)
                let ssh = model.items.first { $0.name == "Selftest SSH" }
                check(ssh?.properties["publicKey"] == pair.publicKey && ssh?.username == pair.fingerprint, "create SSH key")

                // SSH agent: real ssh-add / ssh-keygen talk to it; approvals go through our hook.
                let socket = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AccountStore.appGroup)!
                    .appending(path: "t.sock")
                var asked: [String] = []
                model.sshAgent.approveOverride = { key, program in asked.append("\(program)→\(key)"); return true }
                model.sshAgent.start(at: socket)
                let env = ["SSH_AUTH_SOCK": socket.path]
                let listed = await Snapshot.tool("ssh-add", ["-L"], env: env)
                check(listed.status == 0 && listed.output.contains(pair.publicKey.split(separator: " ")[1]), "ssh-add lists the vault's SSH key")
                let pubFile = FileManager.default.temporaryDirectory.appending(path: "selftest-key.pub")
                try? Data((pair.publicKey + "\n").utf8).write(to: pubFile)
                let message = Data("signed commit\n".utf8)
                let agentSigned = await Snapshot.tool("ssh-keygen", ["-Y", "sign", "-n", "git", "-f", pubFile.path, "-q"], env: env, stdin: message)
                let signers = FileManager.default.temporaryDirectory.appending(path: "selftest-signers")
                let sigFile = FileManager.default.temporaryDirectory.appending(path: "selftest.sig")
                try? Data("usagi \(pair.publicKey)\n".utf8).write(to: signers)
                try? Data(agentSigned.output.utf8).write(to: sigFile)
                let verified = await Snapshot.tool("ssh-keygen", ["-Y", "verify", "-n", "git", "-I", "usagi", "-f", signers.path, "-s", sigFile.path],
                                         stdin: message)
                check(agentSigned.status == 0 && verified.status == 0 && asked == ["ssh-keygen→Selftest SSH"],
                      "git-style signing through the agent asks once and verifies")
                model.sshAgent.approveOverride = { _, _ in false }
                let denied = await Snapshot.tool("ssh-keygen", ["-Y", "sign", "-n", "git", "-f", pubFile.path, "-q"], env: env, stdin: message)
                check(denied.status != 0, "denied approval fails the signature")
                model.sshAgent.stop()
                model.sshAgent.approveOverride = nil
                if let ssh { await model.deleteForever(ssh) }

                // Passkey stored on a login: decoded, signable, published, preserved by edits.
                let hash = Data(repeating: 9, count: 32)
                let reg = try? Passkey.register(rpId: "webauthn.io", userName: "usagi", userHandle: Data("u-1".utf8), clientDataHash: hash)
                var pkEdit = CipherEdit(name: "Selftest passkey", username: "usagi", uri: "https://webauthn.io")
                pkEdit.passkey = reg?.credential
                _ = await model.createItem(.login, edit: pkEdit)
                var login = model.items.first { $0.name == "Selftest passkey" }
                let signed = login?.passkeys.first.flatMap { try? Passkey.assert($0, clientDataHash: hash) }
                check(login?.hasPasskey == true && signed?.credentialID == reg?.credentialID, "passkey saved, synced and signs")
                if let id = login?.id { _ = await model.updateItem(id, edit: CipherEdit(password: "changed")) }
                login = model.items.first { $0.name == "Selftest passkey" }
                check(login?.passkeys.first?.keyValue == reg?.credential.keyValue, "editing a login keeps its passkey")
                if let login { await model.deleteForever(login) }

                // Attachments: add from a file, preview a decrypted copy, delete.
                _ = await model.createItem(.secureNote, edit: CipherEdit(name: "Selftest files", notes: "x"))
                if let note = model.items.first(where: { $0.name == "Selftest files" }) {
                    let source = FileManager.default.temporaryDirectory.appending(path: "selftest 附件.txt")
                    let contents = Data("chiikawa attachment ✓\n".utf8) + Data(repeating: 7, count: 200_000)
                    try? contents.write(to: source)
                    let added = await model.addAttachments([source], to: note)
                    try? FileManager.default.removeItem(at: source)
                    let withFile = model.items.first { $0.id == note.id }
                    let file = withFile?.attachments.first
                    check(added && file?.fileName == "selftest 附件.txt" && (file?.size ?? 0) >= contents.count, "attach a file")
                    if let withFile, let file {
                        await model.previewAttachment(file, of: withFile)
                        let previewed = model.previewURL.flatMap { try? Data(contentsOf: $0) }
                        check(previewed == contents && model.previewURL?.lastPathComponent == file.fileName,
                              "download and decrypt for Quick Look")
                        await model.deleteAttachment(file, of: withFile)
                        check(model.items.first { $0.id == note.id }?.attachments.isEmpty == true, "delete attachment")
                    }
                    if let n = model.items.first(where: { $0.id == note.id }) { await model.deleteForever(n) }
                }

                // tw command line and App Intents.
                var cliEdit = CipherEdit(name: "Selftest cli", username: "cli-user", password: "cli-secret-42", totp: "JBSWY3DPEHPK3PXP")
                cliEdit.customFields = [CustomField(name: "PIN", value: "2468", kind: .hidden)]
                _ = await model.createItem(.login, edit: cliEdit)
                let cliSocket = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AccountStore.appGroup)!
                    .appending(path: "c.sock")
                var approvals: [String] = []
                model.cli.approveOverride = { approvals.append($0); return true }
                model.cli.start(at: cliSocket)
                let tw = CLIBridge.toolPath, cwEnv = ["TW_SOCKET": cliSocket.path]
                let status = await Snapshot.tool(tw, ["status"], env: cwEnv)
                let cwPassword = await Snapshot.tool(tw, ["get", "selftest cli"], env: cwEnv)
                let pin = await Snapshot.tool(tw, ["get", "Selftest cli", "--field", "PIN"], env: cwEnv)
                let cwCode = await Snapshot.tool(tw, ["code", "Selftest cli"], env: cwEnv)
                let generated = await Snapshot.tool(tw, ["generate", "--length", "32"], env: cwEnv)
                let missing = await Snapshot.tool(tw, ["get", "no-such-item-xyz"], env: cwEnv)
                check(status.output.hasPrefix("unlocked") && cwPassword.output == "cli-secret-42" && pin.output == "2468"
                      && cwCode.output.count == 6 && generated.output.count == 32 && missing.status != 0
                      && approvals.count == 3, "tw: status, get, custom field, code, generate, not found")
                model.cli.approveOverride = { _ in false }
                let refused = await Snapshot.tool(tw, ["get", "Selftest cli"], env: cwEnv)
                check(refused.status != 0 && refused.output.contains("Not approved"), "tw: refused approval reveals nothing")

                // Browser extension commands over the same socket (as Safari's handler / Chrome's host send them).
                model.cli.approveOverride = { approvals.append($0); return true }
                var confirmations: [String] = []
                var confirmAnswer = true
                model.cli.confirmOverride = { confirmations.append($0); return confirmAnswer }
                _ = await model.createItem(.login, edit: CipherEdit(name: "Selftest web", username: "web-user", password: "web-pass-1",
                                                                    uri: "https://login.chiikawa.test/signin"))
                func bridge(_ r: CLIRequest) async -> CLIResponse {
                    let path = cliSocket.path
                    return await Task.detached { BridgeClient.send(r, socket: path) }.value
                }
                let page = "https://login.chiikawa.test/signin?next=/"
                let matched = await bridge(CLIRequest(command: .match, url: page))
                let elsewhere = await bridge(CLIRequest(command: .match, url: "https://evil.example/login"))
                let webID = matched.rows?.first { $0.name == "Selftest web" }?.id ?? ""
                let filled = await bridge(CLIRequest(command: .fill, query: webID, url: page))
                let wrongSite = await bridge(CLIRequest(command: .fill, query: webID, url: "https://evil.example/login"))
                check(matched.rows?.count == 1 && matched.rows?.first?.detail == "web-user" && elsewhere.rows?.isEmpty == true
                      && filled.username == "web-user" && filled.password == "web-pass-1" && !wrongSite.ok,
                      "browser: suggestions only for the page's site, fill after approval, never on another site")
                let same = await bridge(CLIRequest(command: .save, url: page, username: "web-user", password: "web-pass-1"))
                let updated = await bridge(CLIRequest(command: .save, url: page, username: "web-user", password: "web-pass-2"))
                let added = await bridge(CLIRequest(command: .save, url: "https://new.chiikawa.test/login", username: "newbie", password: "n-1"))
                confirmAnswer = false
                let declined = await bridge(CLIRequest(command: .save, url: "https://other.chiikawa.test/", username: "x", password: "y"))
                let newItem = model.items.first { $0.host == "new.chiikawa.test" }
                check(same.value == "unchanged" && updated.value == "updated" && added.value == "saved" && declined.value == "skipped"
                      && confirmations.count == 3 && model.items.first { $0.id == webID }?.password == "web-pass-2"
                      && newItem?.username == "newbie" && !model.items.contains { $0.host == "other.chiikawa.test" },
                      "browser: save new, update changed, skip unchanged, respect Not Now")
                for item in model.items where item.name == "Selftest web" || item.host == "new.chiikawa.test" { await model.deleteForever(item) }
                model.cli.confirmOverride = nil

                model.cli.stop()
                model.cli.approveOverride = nil

                var gen = GeneratePasswordIntent()
                gen.length = 24
                let intentPassword = (try? await gen.perform())?.value
                let found = try? await VaultItemQuery().entities(matching: "selftest cli")
                var intentCode: String?
                if let entity = found?.first {
                    var codeIntent = GetOneTimeCodeIntent()
                    codeIntent.item = entity
                    intentCode = (try? await codeIntent.perform())?.value
                }
                check(intentPassword?.count == 24 && found?.count == 1 && intentCode?.count == 6,
                      "App Intents: generate, find item, get code (\(found?.count ?? -1) found)")
                if let cliItem = model.items.first(where: { $0.name == "Selftest cli" }) { await model.deleteForever(cliItem) }

                // Send: create, open it as a stranger from the copied link, delete.
                var sendDraft = SendDraft(name: "Selftest send", content: .text("hello from usagi", hidden: false),
                                          deletionDate: .now.addingTimeInterval(3_600))
                sendDraft.password = "pw"
                let sendCreated = await model.createSend(sendDraft, accountId: firstID)
                let copiedLink = NSPasteboard.general.string(forType: .string) ?? ""
                let mySend = model.sends.first { $0.name == "Selftest send" }
                var opened = ""
                if let mySend, let fragment = copiedLink.split(separator: "/").last, let material = Data(base64URL: String(fragment)),
                   let key = try? SendCrypto.key(from: material), let hash = try? SendCrypto.passwordHash("pw", keyMaterial: material) {
                    let stranger = VaultClient(environment: .selfHosted(URL(string: server)!), deviceIdentifier: UUID().uuidString)
                    let response = try? await stranger.accessSend(accessId: mySend.accessId, passwordHash: hash)
                    opened = response?.text?.text.flatMap { try? EncString($0).decryptString(with: key) } ?? ""
                }
                check(sendCreated && mySend?.hasPassword == true && copiedLink.contains("#/send/") && opened == "hello from usagi",
                      "Send: create, copy link, open as recipient")
                // Edit it: new text, password removed; the same link opens the new text without one.
                if let mySend, let fragment = copiedLink.split(separator: "/").last, let material = Data(base64URL: String(fragment)),
                   let key = try? SendCrypto.key(from: material) {
                    var change = SendDraft(name: "Selftest send", content: .text("edited by usagi", hidden: false),
                                           deletionDate: .now.addingTimeInterval(7_200))
                    change.maxAccessCount = 5
                    let edited = await model.updateSend(mySend, draft: change, removePassword: true)
                    let stranger = VaultClient(environment: .selfHosted(URL(string: server)!), deviceIdentifier: UUID().uuidString)
                    let response = try? await stranger.accessSend(accessId: mySend.accessId)
                    let reread = response?.text?.text.flatMap { try? EncString($0).decryptString(with: key) }
                    let after = model.sends.first { $0.id == mySend.id }
                    check(edited && reread == "edited by usagi" && after?.hasPassword == false && after?.maxAccessCount == 5,
                          "Send: edit keeps the link, new text, password removed")
                }
                if let mySend { await model.deleteSend(mySend) }
                check(!model.sends.contains { $0.name == "Selftest send" }, "Send: delete")

                // A file Send: upload, then download and decrypt it as a recipient with no password.
                let fileBytes = Data("file from hachiware \(UUID().uuidString)".utf8)
                let fileDraft = SendDraft(name: "Selftest file send", content: .file(name: "note.txt", contents: fileBytes),
                                          deletionDate: .now.addingTimeInterval(3_600))
                let fileCreated = await model.createSend(fileDraft, accountId: firstID)
                let fileLink = NSPasteboard.general.string(forType: .string) ?? ""
                let fileSend = model.sends.first { $0.name == "Selftest file send" }
                var downloaded: Data?
                var downloadedName = ""
                if let fileSend, let fragment = fileLink.split(separator: "/").last, let material = Data(base64URL: String(fragment)),
                   let key = try? SendCrypto.key(from: material) {
                    let stranger = VaultClient(environment: .selfHosted(URL(string: server)!), deviceIdentifier: UUID().uuidString)
                    if let response = try? await stranger.accessSend(accessId: fileSend.accessId), let fileId = response.file?.id,
                       let blob = try? await stranger.accessSendFile(sendId: response.id, fileId: fileId) {
                        downloaded = try? EncArrayBuffer.decrypt(blob, with: key)
                        downloadedName = response.file?.fileName.flatMap { try? EncString($0).decryptString(with: key) } ?? ""
                    }
                }
                check(fileCreated && downloaded == fileBytes && downloadedName == "note.txt",
                      "Send: file upload, download and decrypt as recipient")
                if let fileSend { await model.deleteSend(fileSend) }
                check(!model.sends.contains { $0.name == "Selftest file send" }, "Send: delete file Send")

                // Updates: Sparkle is embedded with its installer service and pointed at the release appcast.
                let info = Bundle.main.infoDictionary ?? [:]
                let sparkle = Bundle.main.privateFrameworksURL?.appending(path: "Sparkle.framework")
                check(FileManager.default.fileExists(atPath: sparkle?.path ?? "")
                      && (info["SUFeedURL"] as? String)?.hasSuffix("/releases/latest/download/appcast.xml") == true
                      && info["SUEnableInstallerLauncherService"] as? Bool == true
                      && info["SUEnableAutomaticChecks"] as? Bool == false,
                      "updates: Sparkle embedded, appcast feed, installer service, checks opt-in")

                // Auto-type: the bundled helper starts, answers Triwarden over its socket, and reports whether it
                // may type (Accessibility is the user's to grant, so either answer passes).
                let typing = await AutoType.isAllowed()
                var me: SecCode?
                var staticMe: SecStaticCode?
                var signing: CFDictionary?
                let teamSigned = SecCodeCopySelf([], &me) == errSecSuccess && me.map { SecCodeCopyStaticCode($0, [], &staticMe) } == errSecSuccess
                    && staticMe.map { SecCodeCopySigningInformation($0, SecCSFlags(rawValue: kSecCSSigningInformation), &signing) } == errSecSuccess
                    && (signing as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] != nil
                if typing == nil, !teamSigned {
                    // Unsigned, the helper has no App Group entitlement, so macOS won't let it open its socket.
                    print("SKIP auto-type helper (unsigned build: start it by hand to test)")
                } else {
                    check(typing != nil, "auto-type helper answers the app (Accessibility \(typing == true ? "allowed" : "not allowed yet"))")
                }

                // The AutoFill extension's flow, in-process: register a passkey for a site, then sign in with it.
                let ext = AutoFillState()
                var registered: ASPasskeyRegistrationCredential?
                var asserted: ASPasskeyAssertionCredential?
                ext.completeRegistration = { registered = $0 }
                ext.completeAssertion = { asserted = $0 }
                ext.begin(passkey: .init(rpId: "passkeys.example", clientDataHash: hash, userName: "usagi",
                                         userHandle: Data("u-2".utf8), algorithms: [-7]), registering: true)
                ext.selectedAccountID = firstID
                await ext.unlock(password: password)
                await ext.register(accountId: firstID, itemId: nil)
                check(registered != nil && ext.error == nil, "AutoFill: unlock and save a new passkey to the server \(ext.error ?? "")")
                let signIn = AutoFillState()
                signIn.completeAssertion = { asserted = $0 }
                signIn.begin(passkey: .init(rpId: "passkeys.example", clientDataHash: hash), registering: false)
                signIn.selectedAccountID = firstID
                await signIn.unlock(password: password)
                if let c = signIn.passkeyCandidates.first { await signIn.signIn(c.item, c.passkey) }
                check(asserted != nil && asserted?.credentialID == registered?.credentialID
                      && asserted?.userHandle == Data("u-2".utf8), "AutoFill: sign in with that passkey from the cached vault")
                try? await model.refresh()
                if let made = model.items.first(where: { $0.passkeys.first?.rpId == "passkeys.example" }) { await model.deleteForever(made) }
            }

            // Second account: merged list, per-account lock and unlock.
            var secondID: String?
            if let (email2, password2) = second {
                model.beginAddAccount()
                model.serverKind = .selfHosted
                model.serverURL = server
                model.email = email2
                await model.login(password: password2)
                let id2 = SavedAccount.makeID(serverKind: "selfHosted", serverURL: server, email: email2)
                for stale in model.items.filter({ $0.accountId == id2 && $0.name == "Sidebar bulk B" }) { await model.deleteForever(stale) }
                secondID = id2
                let fromFirst = model.items.filter { $0.accountId == firstID }.count
                let fromSecond = model.items.filter { $0.accountId == id2 }.count
                check(model.accounts.count == 2 && model.sessions.count == 2 && fromFirst == count && fromSecond > 0,
                      "second account merged (\(fromFirst) + \(fromSecond) items)")
                let created2 = await model.createItem(.secureNote, edit: CipherEdit(name: "Second-account note", notes: "x"), accountId: id2)
                let note = model.items.first { $0.name == "Second-account note" }
                check(created2 && note?.accountId == id2, "new item goes to the chosen account")
                if let note { await model.deleteForever(note) }

                let oldFocus = model.accountFocus
                model.accountFocus = nil
                let favorites = model.sidebarActions(for: .section(.favorites))
                favorites.first?.children.first?.run()
                for _ in 0..<20 where model.newItemForm == nil { try? await Task.sleep(for: .milliseconds(10)) }
                check(model.newItemForm?.prefill?.accountIDs?.count == 2 && model.newItemForm?.prefill?.favorite == true,
                      "favorite creation captures both accounts for an explicit destination choice")
                model.closeNewItemForm(restoringSelection: false)
                model.accountFocus = oldFocus

                let a = await model.createItem(.secureNote, edit: CipherEdit(name: "Sidebar bulk A"), accountId: firstID)
                let b = await model.createItem(.secureNote, edit: CipherEdit(name: "Sidebar bulk B"), accountId: id2)
                let targets = model.items.filter { ["Sidebar bulk A", "Sidebar bulk B"].contains($0.name) }
                for item in targets { await model.trash(item) }
                let frozen = model.items.filter { targets.map(\.id).contains($0.id) }
                let frozenScope = SidebarScope(accountIDs: [firstID, id2], vaultFilter: .personal, destination: .section(.trash))
                model.confirmSidebarBulk(frozen, scope: frozenScope, delete: false)
                let pending = model.confirming
                model.confirming = nil
                _ = await model.createItem(.secureNote, edit: CipherEdit(name: "Sidebar bulk late arrival"), accountId: firstID)
                if let late = model.items.first(where: { $0.name == "Sidebar bulk late arrival" }) { await model.trash(late) }
                // Lock one account and change the visible scope after confirmation was built.
                model.lock(id2)
                model.accountFocus = firstID
                model.vaultFilter = .all
                await pending?.run()
                let restored = model.items.first { $0.name == "Sidebar bulk A" }
                check(a && b && restored?.isDeleted == false && model.sidebarActionError != nil,
                      "scoped restore continues past locked account and reports partial failure")
                let late = model.items.first { $0.name == "Sidebar bulk late arrival" }
                check(late?.isDeleted == true, "bulk restore excludes items arriving after confirmation")
                if let late { await model.deleteForever(late) }
                if let restored { await model.deleteForever(restored) }
                await model.unlock(password: password2, accountId: id2)
                for _ in 0..<100 where model.session(for: id2)?.lastSynced == nil {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                check(model.session(for: id2)?.lastSynced != nil, "reopened account reconnects before online writes")
                if let cleanup = model.items.first(where: { $0.name == "Sidebar bulk B" }) { await model.deleteForever(cleanup) }
                model.sidebarActionError = nil
                model.errorMessage = nil
                model.accountFocus = oldFocus

                // Account security, on the second account (everything put back afterwards).
                if let s2 = model.session(for: id2) {
                    let temporary = password2 + "-changed"
                    do {
                        guard let spki = s2.publicKeySPKI() else { throw AccountSession.SecurityError.wrongPassword }
                        let serverKey = try await s2.client?.publicKey(userId: s2.userId ?? "")
                        check(serverKey == spki.base64EncodedString() && s2.fingerprint().count == 5,
                              "fingerprint phrase from the account's public key (\(s2.fingerprint().joined(separator: "-")))")
                        let devices = try await s2.devices()
                        check(!devices.isEmpty && devices.first?.isCurrent == true,
                              "devices signed in (\(devices.count)), this Mac first as the current session (\(devices.first?.title ?? ""))")

                        // Steps that sign in again (another device, password and KDF changes) use up the server's login
                        // rate limit; they run with `make selftest-security`.
                        let securityRun = ProcessInfo.processInfo.environment["TRIWARDEN_SELFTEST_SECURITY"] == "1"
                        if securityRun {
                        // Another device asks to sign in; this Mac approves; that device unwraps the same user key.
                        let asker = VaultClient(environment: .selfHosted(URL(string: server)!), deviceIdentifier: UUID().uuidString.lowercased())
                        _ = try await asker.loginDetailed(email: email2, password: password2)
                        let askerKey = try RSAPrivateKey.generate()
                        let accessCode = String(UUID().uuidString.prefix(20))
                        let requestID = try await asker.requestSignIn(email: email2, publicKeySPKI: askerKey.publicKeySPKI(), accessCode: accessCode)
                        let pending = try await s2.pendingSignIns()
                        if let request = pending.first(where: { $0.id == requestID }) {
                            try await s2.answer(request, approve: true)
                            let response = try await asker.signInResponse(id: requestID, accessCode: accessCode)
                            let unwrapped = try response.key.map { try askerKey.decrypt($0) }
                            let mine = AccountStore.unlock(id2, password: password2)
                            check(response.approved == true && unwrapped == mine.map { $0.encryptionKey + $0.macKey }
                                  && s2.fingerprint(of: request).count == 5,
                                  "approve a sign-in from another device (it unwraps the same user key)")
                            // …and that device finishes signing in with the approved request (no master password).
                            let finished = try await asker.loginWithApprovedRequest(email: email2, requestId: requestID, accessCode: accessCode)
                            // The master-password-wrapped copy it got opens with the master password, to the same user key.
                            let master = try KDF.masterKey(password: password2, email: email2, config: finished.kdf)
                            let opened = try EncString(finished.protectedUserKey).decrypt(with: SymmetricKeyPair.stretched(masterKey: master))
                            check(finished.refreshToken != nil && opened == mine.map { $0.encryptionKey + $0.macKey },
                                  "log in with another device: signed in with the approved request")
                        } else {
                            check(false, "approve a sign-in from another device: request not listed")
                        }
                        }

                        // Emergency access: account 1 trusts account 2 (view-only, then takeover).
                        if let s1 = model.session(for: firstID) {
                            for takeover in [false, true] {
                                try await s1.inviteEmergencyContact(email: email2, takeover: takeover, waitDays: 1)
                                guard let listed = try await s1.emergencyContacts(granted: false).first(where: { $0.email == email2 }) else {
                                    check(false, "emergency access: invitation not listed"); break
                                }
                                var invited = listed
                                if invited.status == .invited {
                                    // The server emails the invitation: read it from the dev server's Mailpit and accept.
                                    if let link = await HeadlessIdP.mailpitLink(server: server, to: email2, containing: invited.id) {
                                        try await s2.acceptEmergencyInvite(link: link)
                                        invited = try await s1.emergencyContacts(granted: false).first { $0.id == invited.id } ?? invited
                                    }
                                }
                                guard invited.status == .accepted else {
                                    check(false, "emergency access: invitation not accepted (no Mailpit?)")
                                    try await s1.emergencyAccess("delete", invited); break
                                }
                                let (contactKey, phrase) = try await s1.contactKey(invited)
                                try await s1.confirmEmergencyContact(invited, key: contactKey)
                                let granted = try await s2.emergencyContacts(granted: true).first { $0.email == email }
                                if let granted { try await s2.emergencyAccess("initiate", granted) }
                                if let trusted = try await s1.emergencyContacts(granted: false).first(where: { $0.id == invited.id }) {
                                    try await s1.emergencyAccess("approve", trusted)
                                }
                                if let approved = try await s2.emergencyContacts(granted: true).first(where: { $0.email == email }),
                                   approved.status == .recoveryApproved {
                                    if takeover {
                                        let (_, key) = try await s2.emergencyTakeoverKey(approved)
                                        check(key == AccountStore.unlock(firstID, password: password), "emergency takeover: the other account's key, unwrapped")
                                    } else {
                                        let theirs = try await s2.emergencyView(approved)
                                        let mine = model.items.filter { $0.accountId == firstID && $0.organizationId == nil && !$0.isDeleted }
                                        check(phrase.count == 5 && theirs.count == mine.count
                                              && Set(theirs.map(\.name)) == Set(mine.map(\.name))
                                              && theirs.first { $0.name == "GitHub" }?.password == mine.first { $0.name == "GitHub" }?.password,
                                              "emergency access: invite, confirm, request, approve, view (\(theirs.count) items)")
                                    }
                                } else {
                                    check(false, "emergency access: recovery not approved")
                                }
                                try await s1.emergencyAccess("delete", invited)
                            }
                        }

                        let secret = try await s2.authenticatorSecret(password: password2)
                        let code = TOTP(secret.key)?.code() ?? ""
                        try await s2.enableAuthenticator(key: secret.key, code: code, password: password2)
                        let on = try await s2.twoFactorProviders()[0] == true
                        let recovery = try await s2.recoveryCode(password: password2)
                        try await s2.disableTwoFactor(type: 0, password: password2)
                        let off = try await s2.twoFactorProviders()[0] != true
                        check(on && recovery?.isEmpty == false && off, "authenticator two-step login: turn on with a code, recovery code, turn off")

                        if securityRun {
                        try await s2.changeMasterPassword(current: password2, new: temporary, hint: nil)
                        let opensWithNew = AccountStore.unlock(id2, password: temporary) != nil && AccountStore.unlock(id2, password: password2) == nil
                        try await s2.changeMasterPassword(current: temporary, new: password2, hint: nil)
                        let opensWithOld = AccountStore.unlock(id2, password: password2) != nil
                        let stillSyncs = (try? await s2.refresh()) != nil
                        check(opensWithNew && opensWithOld && stillSyncs, "change the master password (and back), still signed in")

                        let original = s2.account.kdf
                        let stronger: KDFConfig = switch original {
                        case .pbkdf2(let n): .pbkdf2(iterations: n + 10_000)
                        case .argon2id(let t, let m, let p): .argon2id(iterations: t + 1, memoryMiB: m, parallelism: p)
                        }
                        try await s2.changeMasterPassword(current: password2, new: password2, kdf: stronger, hint: nil)
                        let changed = AccountStore.load(id2)?.kdf == stronger && AccountStore.unlock(id2, password: password2) != nil
                        try await s2.changeMasterPassword(current: password2, new: password2, kdf: original, hint: nil)
                        check(changed && AccountStore.load(id2)?.kdf == original, "change the KDF (and back)")
                        }

                        // An organization's event log (empty unless the server keeps events).
                        if let s1 = model.session(for: firstID), let org = s1.organizations.first {
                            let log = try await s1.organizationEvents(org.id, days: 7)
                            check(true, "organization event log readable (\(log.events.count) events, \(log.names.count) names)")
                        }
                    } catch {
                        check(false, "account security: \(error)")
                        // Never leave the test account on the temporary password.
                        if AccountStore.unlock(id2, password: temporary) != nil {
                            try? await s2.changeMasterPassword(current: temporary, new: password2, hint: nil)
                        }
                    }
                }

                // Import / export: account 1's vault, password-protected, imported into account 2; compare; clean up.
                if let s1 = model.session(for: firstID), let s2 = model.session(for: id2) {
                    do {
                        let mine = model.items.filter { $0.accountId == firstID && !$0.isDeleted && $0.organizationId == nil }
                        let file = try s1.export(.encryptedJSON, filePassword: "selftest-file").data
                        check(!String(decoding: file, as: UTF8.self).contains(mine.first?.name ?? "\u{0}"), "protected export hides the vault")
                        let preview = try s2.previewImport(file, password: "selftest-file")
                        let beforeItems = Set(model.items.filter { $0.accountId == id2 }.map(\.id))
                        let beforeFolders = Set(s2.folders.map(\.id))
                        try await s2.importItems(preview.items, folders: preview.folders)
                        let imported = model.items.filter { $0.accountId == id2 && !beforeItems.contains($0.id) }
                        func identical(_ a: VaultItem, _ b: VaultItem) -> Bool {
                            guard a.name == b.name, a.kind == b.kind, a.username == b.username, a.password == b.password else { return false }
                            guard a.notes == b.notes, a.totp?.code() == b.totp?.code() else { return false }
                            // The easy-to-lose parts: favorite, folder, website, passkeys.
                            guard a.favorite == b.favorite, a.folderName == b.folderName, a.uri == b.uri,
                                  a.passkeys.map(\.credentialId) == b.passkeys.map(\.credentialId) else { return false }
                            return a.customFields == b.customFields && a.properties == b.properties
                        }
                        let same = imported.count == mine.count && imported.allSatisfy { copy in mine.contains { identical($0, copy) } }
                        check(same, "export → import round trip: \(imported.count) of \(mine.count) items identical")
                        for item in imported { await model.deleteForever(item) }
                        for folder in s2.folders where !beforeFolders.contains(folder.id) { try? await s2.deleteFolder(folder.id) }

                        // Plain JSON the same way.
                        let plainPreview = try s2.previewImport(try s1.export(.json).data, password: nil)
                        let beforePlain = Set(model.items.filter { $0.accountId == id2 }.map(\.id))
                        let beforePlainFolders = Set(s2.folders.map(\.id))
                        try await s2.importItems(plainPreview.items, folders: plainPreview.folders)
                        let importedPlain = model.items.filter { $0.accountId == id2 && !beforePlain.contains($0.id) }
                        check(importedPlain.count == mine.count && importedPlain.allSatisfy { copy in mine.contains { identical($0, copy) } },
                              "plain JSON export → import: \(importedPlain.count) of \(mine.count) items identical")
                        for item in importedPlain { await model.deleteForever(item) }
                        for folder in s2.folders where !beforePlainFolders.contains(folder.id) { try? await s2.deleteFolder(folder.id) }

                        // Organization vault: export, read back, import a copy into the organization, clean up.
                        if let org = s1.transferVaults().first(where: { $0.id != nil }), let orgId = org.id {
                            let orgItems = model.items.filter { $0.organizationId == orgId && !$0.isDeleted }
                            let orgFile = try s1.export(.encryptedJSON, filePassword: "selftest-file", organizationId: orgId).data
                            let orgPreview = try s1.previewImport(orgFile, password: "selftest-file")
                            check(orgPreview.items.count == orgItems.count && !orgItems.isEmpty,
                                  "organization export: \(orgPreview.items.count) items, \(orgPreview.folders.count) collections")
                            let before = Set(model.items.map(\.id))
                            // Without collections, so repeated runs don't leave duplicate collections behind.
                            let copies = orgPreview.items.map { item -> ImportedItem in var item = item; item.folder = nil; return item }
                            try await s1.importItems(copies, folders: [], organizationId: orgId)
                            let imported = model.items.filter { !before.contains($0.id) }
                            check(imported.count == orgItems.count && imported.allSatisfy { $0.organizationId == orgId }
                                  && imported.allSatisfy { copy in orgItems.contains { $0.name == copy.name && $0.password == copy.password } },
                                  "import into the organization (\(imported.count) items, organization key)")
                            for item in imported { await model.deleteForever(item) }
                        } else {
                            check(false, "organization export: no organization with import/export access")
                        }

                        let csv = try VaultImport.preview(try s1.export(.csv).data)
                        let csvKinds: Set<VaultItem.Kind> = [.login, .note]
                        let expected = mine.filter { csvKinds.contains($0.kind) }.count
                        check(csv.items.count == expected, "CSV export holds every login and note (\(csv.items.count))")
                    } catch {
                        check(false, "export → import round trip: \(error)")
                    }
                }
                model.lock(id2)
                check(model.isUnlocked && model.sessions.count == 1 && !model.items.contains { $0.accountId == id2 },
                      "lock one account, keep the other open")
                await model.unlock(password: password2, accountId: id2)
                check(model.sessions.count == 2 && model.items.contains { $0.accountId == id2 }, "unlock that account again")

                // PIN unlock: set, wrong once (tries left), right; five wrong erase it; a PIN can outlive a restart.
                let pinSet = await model.setPIN("2468", persistent: false, for: id2)
                model.lock(id2)
                await model.unlockWithPIN("1111", accountId: id2)
                let wrongSays = model.errorMessage ?? ""
                await model.unlockWithPIN("2468", accountId: id2)
                check(pinSet && wrongSays.contains("4") && model.isUnlocked(id2) && model.items.contains { $0.accountId == id2 },
                      "PIN unlock: a wrong PIN counts down, the right one opens the account")
                model.lock(id2)
                for _ in 0..<AccountStore.pinAttempts { await model.unlockWithPIN("0000", accountId: id2) }
                check(!model.isUnlocked(id2) && !model.isPINEnabled(id2), "five wrong PINs turn PIN unlock off")
                await model.unlock(password: password2, accountId: id2)
                _ = await model.setPIN("8642", persistent: true, for: id2)
                let onDisk = model.isPINPersistent(id2)
                model.setPINPersistent(false, for: id2)
                check(onDisk && model.isPINEnabled(id2) && !model.isPINPersistent(id2), "a PIN moves between this run and disk")
                model.disablePIN(for: id2)
                model.errorMessage = nil

                // Timeouts per account: only the account whose own time ran out locks.
                let globalMinutes = UserDefaults.standard.object(forKey: Pref.autoLockMinutes)
                UserDefaults.standard.set(0, forKey: Pref.autoLockMinutes)
                model.setOwnAutoLockMinutes(1, id2)
                model.applyTimeouts(idle: 30)
                let stillOpen = model.isUnlocked(id2)
                model.applyTimeouts(idle: 120)
                check(stillOpen && !model.isUnlocked(id2) && model.sessions.count == 1,
                      "an account's own timeout locks it alone, after its own time")
                model.setOwnAutoLockMinutes(nil, id2)
                UserDefaults.standard.set(globalMinutes, forKey: Pref.autoLockMinutes)
                await model.unlock(password: password2, accountId: id2)
            }

            // Custom environment: no server URL, explicit per-service URLs.
            model.beginAddAccount()
            model.serverKind = .selfHosted
            model.serverURL = "http://example.com"
            model.email = email
            await model.login(password: password)
            check(model.errorMessage?.contains("https://") == true, "public http:// server rejected")
            model.serverURL = ""
            model.customAPI = server + "/api"
            model.customIdentity = server + "/identity"
            model.customNotifications = server + "/notifications"
            model.errorMessage = nil
            await model.login(password: password)
            let customAccount = model.accounts.first { $0.customURLs != nil }
            check(customAccount != nil && model.session(for: customAccount!.id)?.items.isEmpty == false
                  && model.session(for: customAccount!.id)?.environment.map { if case .custom = $0 { true } else { false } } == true,
                  "log in through custom API / Identity URLs, saved with the account")
            if let customAccount { model.logOut(customAccount.id) }

            // Single sign-on (dev stack: dex + SSO-enabled Vaultwarden next door on :18881).
            let ssoServer = server.replacingOccurrences(of: ":18880", with: ":18881")
            if ssoServer != server,
               (try? await URLSession.shared.data(from: URL(string: ssoServer + "/identity/sso/prevalidate?domainHint=x")!))
                .map({ ($0.1 as? HTTPURLResponse)?.statusCode == 200 }) == true {
                model.beginAddAccount()
                model.serverKind = .selfHosted
                model.serverURL = ssoServer
                model.ssoAuthenticator = { url in try await HeadlessIdP.signIn(url, login: email, password: password) }
                await model.loginWithSSO(identifier: "triwarden")
                check(model.phase.id == AppModel.Phase.ssoPassword.id && model.email == email,
                      "SSO: identity provider sign-in, then asks for the master password \(model.errorMessage ?? "")")
                await model.completeSSO(password: "wrong")
                check(model.phase.id == AppModel.Phase.ssoPassword.id && model.errorMessage != nil, "SSO: wrong master password refused")
                await model.completeSSO(password: password)
                let ssoAccount = model.accounts.first { $0.serverURL == ssoServer }
                check(ssoAccount != nil && model.session(for: ssoAccount!.id)?.items.isEmpty == false && AccountStore.refreshToken(ssoAccount!.id) != nil,
                      "SSO: vault unlocked, account and session saved")
                if let ssoAccount { model.logOut(ssoAccount.id) }
                model.ssoAuthenticator = WebAuthentication.run
            } else {
                print("SKIP SSO (no SSO server at \(ssoServer))")
            }

            model.lock()
            check(model.phase.id == AppModel.Phase.locked.id && model.items.isEmpty, "lock clears vault, shows unlock")
            check(!FileManager.default.fileExists(atPath: AttachmentFiles.root.path) && model.previewURL == nil,
                  "lock wipes decrypted attachment copies")

            let fresh = AppModel() // simulates relaunch
            check(fresh.phase.id == AppModel.Phase.locked.id && fresh.accounts.count == (second == nil ? 1 : 2),
                  "relaunch starts locked with \(fresh.accounts.count) saved account(s)")
            // Regression: the previously focused account is locked, but the user unlocks another target.
            check(fresh.unlockTargetID == (fresh.focusedAccountID ?? fresh.accounts.first?.id), "relaunch unlock chooser follows the saved account focus")
            fresh.accountFocus = secondID
            fresh.unlockTargetID = firstID
            await fresh.unlock(password: "definitely-wrong")
            check(!fresh.isUnlocked && fresh.errorMessage != nil, "wrong password rejected offline")
            await fresh.unlock(password: password)
            check(fresh.accountFocus == firstID && fresh.accountDoor == nil && fresh.unlockTargetID == firstID,
                  "explicit unlock replaces stale locked account focus")
            fresh.updateAccountDoor()
            check(fresh.phase.id == AppModel.Phase.vault.id && fresh.accountDoor == nil,
                  "unlock stays in vault after account door recomputes")
            check(fresh.isUnlocked && fresh.items.count == count, "offline unlock restores \(fresh.items.count) items from cache")
            try? await Task.sleep(for: .seconds(3))
            check(fresh.lastSynced != nil, "session resumed with refresh token and re-synced")

            // Another device changes the vault → live notification → automatic re-sync.
            let before = fresh.lastSynced ?? .distantPast
            if let url = URL(string: server) {
                let other = VaultClient(environment: .selfHosted(url), deviceIdentifier: UUID().uuidString.lowercased())
                if let key = try? await other.login(email: email, password: password),
                   let folder = try? await other.createFolder(encryptedName: EncString.encrypt(Data("selftest".utf8), with: key).description) {
                    try? await Task.sleep(for: .seconds(4))
                    check((fresh.lastSynced ?? .distantPast) > before, "live sync picked up a change from another device")
                    try? await other.deleteFolder(id: folder)
                } else {
                    check(false, "second device could not change the vault")
                }
            }

            if let secondID {
                // Logged out by its own timeout (action: log out), while the other account has none. Timeouts act on
                // open accounts, so it's unlocked first.
                if let second { await fresh.unlock(password: second.1, accountId: secondID) }
                let globalMinutes = UserDefaults.standard.object(forKey: Pref.autoLockMinutes)
                UserDefaults.standard.set(0, forKey: Pref.autoLockMinutes)
                fresh.setOwnAutoLockMinutes(5, secondID)
                fresh.setOwnTimeoutAction(.logOut, secondID)
                fresh.applyTimeouts(idle: 6 * 60)
                UserDefaults.standard.set(globalMinutes, forKey: Pref.autoLockMinutes)
                fresh.setOwnAutoLockMinutes(nil, secondID)
                fresh.setOwnTimeoutAction(nil, secondID)
                check(fresh.accounts.count == 1 && AccountStore.load(secondID) == nil && fresh.isUnlocked,
                      "log out one account by its timeout, the other stays")
            }
            fresh.logOut(firstID)
            check(AccountStore.load(firstID) == nil && AccountStore.refreshToken(firstID) == nil && fresh.phase.id == AppModel.Phase.login.id,
                  "log out erases account and token")
            print(failures == 0 ? "SELFTEST OK" : "SELFTEST FAILED (\(failures))")
            UserDefaults.standard.set(savedFocus, forKey: "accountFocus")
            UserDefaults.standard.set(savedVaultFilter, forKey: "vaultFilter")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif

/// Plays a browser through dex's password form, for the SSO self-test.
enum HeadlessIdP {
    /// The dev environment's Mailpit (port 18826 on the server's host): the newest link in an email to `to` that
    /// mentions `containing`.
    static func mailpitLink(server: String, to: String, containing: String) async -> String? {
        guard let host = URL(string: server)?.host(),
              let search = URL(string: "http://\(host):18826/api/v1/search?query=to:\(to)&limit=5") else { return nil }
        for _ in 0..<10 {
            if let (data, _) = try? await URLSession.shared.data(from: search),
               let list = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["messages"] as? [[String: Any]] {
                for message in list {
                    guard let id = message["ID"] as? String, let url = URL(string: "http://\(host):18826/api/v1/message/\(id)"),
                          let (body, _) = try? await URLSession.shared.data(from: url),
                          let text = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["Text"] as? String else { continue }
                    if let link = text.split(whereSeparator: \.isWhitespace).map(String.init)
                        .first(where: { $0.contains(containing) && $0.contains("token=") }) { return link }
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    final class Browser: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        var callback: URL?
        lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            if request.url?.scheme == "bitwarden" { callback = request.url; return nil }
            return request
        }
    }

    static func signIn(_ url: URL, login: String, password: String) async throws -> URL {
        let browser = Browser()
        let (pageData, pageResponse) = try await browser.session.data(from: url)
        let page = String(decoding: pageData, as: UTF8.self)
        guard var formURL = pageResponse.url else { throw URLError(.badServerResponse) }
        if let range = page.range(of: #"action="([^"]*)""#, options: .regularExpression) {
            let action = String(page[range]).dropFirst(8).dropLast().replacingOccurrences(of: "&amp;", with: "&")
            formURL = URL(string: action, relativeTo: formURL)?.absoluteURL ?? formURL
        }
        var post = URLRequest(url: formURL)
        post.httpMethod = "POST"
        post.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))
        post.httpBody = Data("login=\(login.addingPercentEncoding(withAllowedCharacters: allowed)!)&password=\(password.addingPercentEncoding(withAllowedCharacters: allowed)!)".utf8)
        _ = try? await browser.session.data(for: post)
        guard let callback = browser.callback else { throw URLError(.userAuthenticationRequired) }
        return callback
    }
}
