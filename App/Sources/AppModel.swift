import AppKit
import TriCrypto
import LocalAuthentication
import Foundation
import Observation
import SwiftUI
import UserNotifications
import VaultwardenAPI

/// Drives the item form in the detail panel.
struct EditRequest: Identifiable {
    let id = UUID()
    let mode: EditItemSheet.Mode
    /// For a new item: what to start the form with (the command palette's "New Login “acme.com”").
    var prefill: EditItemSheet.Prefill?
}

@MainActor @Observable
final class AppModel {
    enum Phase {
        case login
        case twoFactor(providers: [String])
        /// Official cloud emailed a one-time code for this new device.
        case deviceVerification
        /// Single sign-on succeeded; the master password still has to decrypt the vault.
        case ssoPassword
        /// Signed in on this Mac, vault locked: unlock offline with the master password or Touch ID.
        case locked
        case vault
        var id: Int {
            switch self { case .login: 0; case .twoFactor: 1; case .deviceVerification: 3; case .ssoPassword: 5; case .locked: 4; case .vault: 2 }
        }
    }

    enum ServerKind: String, CaseIterable, Identifiable {
        // Self-hosted first: Triwarden is made for Vaultwarden.
        case selfHosted, bitwardenUS, bitwardenEU
        var id: Self { self }
        var label: LocalizedStringResource {
            switch self {
            case .bitwardenUS: "bitwarden.com"
            case .bitwardenEU: "bitwarden.eu"
            case .selfHosted: "Self-hosted"
            }
        }
    }

    var phase: Phase = .login
    /// Every account saved on this Mac, oldest first.
    private(set) var accounts: [SavedAccount] = AccountStore.accounts()
    /// Unlocked accounts. Items from all of them are merged into `items`.
    private(set) var sessions: [AccountSession] = []
    /// The account the unlock screen is asking for.
    var unlockTargetID: String?
    var unlockTarget: SavedAccount? { accounts.first { $0.id == unlockTargetID } ?? accounts.first }
    /// Sidebar filter: show one account only.
    var accountFilter: String?

    /// Which vaults the lists show, like Bitwarden's vault switcher: everything, your own items, one shared vault, or
    /// several together (your own and one shared vault, say). Vaults are named by key: "personal", or an organization id.
    enum VaultFilter: Hashable {
        case all, personal, organization(String)
        /// Two or more vaults (keys as above).
        case several(Set<String>)

        static let personalKey = "personal"

        /// "personal", "org:<id>", "set:<key>,<key>", or nil for all: how it's saved, and how the Focus filter names it.
        init(raw: String?) {
            switch raw {
            case "personal": self = .personal
            case let id? where id.hasPrefix("org:"): self = .organization(String(id.dropFirst(4)))
            case let list? where list.hasPrefix("set:"):
                self = VaultFilter(keys: Set(list.dropFirst(4).split(separator: ",").map(String.init)))
            default: self = .all
            }
        }
        var raw: String? {
            switch self {
            case .all: nil
            case .personal: "personal"
            case .organization(let id): "org:" + id
            case .several(let keys): "set:" + keys.sorted().joined(separator: ",")
            }
        }

        /// The simplest filter for a set of vaults: none (or every one in `all`) is every vault.
        init(keys: Set<String>, all: Set<String>? = nil) {
            if keys.isEmpty || all.map(keys.isSuperset) == true { self = .all }
            else if keys.count == 1, let key = keys.first {
                self = key == Self.personalKey ? .personal : .organization(key)
            } else { self = .several(keys) }
        }

        /// The vaults it lets through; nil for every vault.
        var keys: Set<String>? {
            switch self {
            case .all: nil
            case .personal: [Self.personalKey]
            case .organization(let id): [id]
            case .several(let keys): keys
            }
        }
    }

    /// Every vault there is to show: your own, and each shared vault of the account in focus.
    var allVaultKeys: Set<String> { Set([VaultFilter.personalKey] + visibleOrganizations.map(\.id)) }

    /// Whether a vault is shown (every one is, while the filter shows all vaults).
    func vaultShown(_ key: String) -> Bool { vaultFilter.keys?.contains(key) ?? true }

    /// A vault's checkbox: shows it alongside the others, or hides it. The last one shown stays (an empty list would
    /// just look broken); checking them all is All vaults again.
    func toggleVault(_ key: String) {
        var keys = vaultFilter.keys ?? allVaultKeys
        if keys.contains(key) {
            guard keys.count > 1 else { return }
            keys.remove(key)
        } else {
            keys.insert(key)
        }
        vaultFilter = VaultFilter(keys: keys, all: allVaultKeys)
    }

    /// Just this vault.
    func showOnlyVault(_ key: String) { vaultFilter = VaultFilter(keys: [key], all: allVaultKeys) }

    /// How many items a vault holds (of the account in focus), for the switcher.
    func vaultCount(_ key: String?) -> Int {
        focusedItems.filter { !$0.isDeleted && !$0.isArchived && (key == nil || ($0.organizationId ?? VaultFilter.personalKey) == key) }.count
    }

    /// Drops shared vaults that are gone (left, or their account locked) from the filter.
    private func pruneVaultFilter() {
        guard let keys = vaultFilter.keys, !organizations.isEmpty else { return }
        let known = Set([VaultFilter.personalKey] + organizations.map(\.id))
        let kept = keys.intersection(known)
        if kept != keys { vaultFilter = VaultFilter(keys: kept) }
    }

    /// The vault filter in words: "All vaults", "My vault", "Northwind", "My vault + Northwind", "3 vaults".
    var vaultFilterTitle: String {
        guard let keys = vaultFilter.keys else { return String(localized: "All vaults") }
        let names = keys.sorted { a, b in a == VaultFilter.personalKey || (b != VaultFilter.personalKey && a < b) }.map { key in
            key == VaultFilter.personalKey ? String(localized: "My vault")
                : organizations.first { $0.id == key }?.name ?? String(localized: "Shared vault")
        }
        return names.count <= 2 ? names.joined(separator: " + ") : String(localized: "\(names.count) vaults")
    }
    var vaultFilter = AppModel.keepsSearchFilters ? VaultFilter(raw: UserDefaults.standard.string(forKey: "vaultFilter")) : .all {
        didSet { if Self.keepsSearchFilters { UserDefaults.standard.set(vaultFilter.raw, forKey: "vaultFilter") } }
    }

    /// The vault list's search filters (type, folder, favorites, codes, passkeys, Watchtower issues), kept between
    /// launches. Renders and demo runs start clear and leave the saved ones alone.
    var searchFilters = AppModel.keepsSearchFilters ? SearchFilters.load() : SearchFilters() {
        didSet { if Self.keepsSearchFilters { searchFilters.save() } }
    }
    /// Renders and demo runs start clear and leave the saved vault and filters alone.
    private static let keepsSearchFilters = !CommandLine.arguments.contains { $0 == "--snapshot" || $0.hasPrefix("--demo") }
    /// Set by ⌘F: the vault list's search field takes focus (and clears it).
    var wantsSearchFocus = false

    /// Whether an item passes the search filters (the vault itself is `vaultFilter`'s).
    func passesSearchFilters(_ item: VaultItem) -> Bool {
        let f = searchFilters
        if let type = f.type, item.kind != VaultItem.Kind(type) { return false }
        if let folder = f.folder, !(item.folderName == folder || item.folderName?.hasPrefix(folder + "/") == true) { return false }
        if f.favorites, !item.favorite { return false }
        if f.hasCode, !item.hasTOTP { return false }
        if f.hasPasskey, !item.hasPasskey { return false }
        if f.hasIssue, item.passwordIssue(breaches: breachCounts) == nil { return false }
        return true
    }

    /// Clears every search filter and shows every vault again.
    func clearSearchFilters() {
        searchFilters = SearchFilters()
        if vaultFilter != .all { vaultFilter = .all }
    }

    /// The vault a Focus asked for (Focus filter), and the one chosen before it, to go back to when the Focus ends.
    private var focusVault: String?
    private var vaultBeforeFocus: VaultFilter?

    func applyFocusVault(_ raw: String?) {
        if let raw {
            if focusVault == nil { vaultBeforeFocus = vaultFilter }
            focusVault = raw
            vaultFilter = VaultFilter(raw: raw)
        } else if focusVault != nil {
            vaultFilter = vaultBeforeFocus ?? .all
            focusVault = nil
            vaultBeforeFocus = nil
        }
    }

    /// One account in focus (picked in the sidebar's account switcher), or nil for every open account together.
    var accountFocus: String? = UserDefaults.standard.string(forKey: "accountFocus") {
        didSet {
            UserDefaults.standard.set(accountFocus, forKey: "accountFocus")
            updateAccountDoor()
        }
    }
    /// A locked account picked while the vault is open: its vault door lies over the window until it's unlocked (the
    /// door opens onto its vault) or left (Show all accounts, Esc).
    var accountDoor: String?

    /// Shows the door for the focused account when it's locked; lifts it when the focus moves to an open one.
    func updateAccountDoor() {
        guard !unlockOpening else { return } // mid-opening: enterVault lifts it
        guard phase.id == Phase.vault.id, let id = focusedAccountID, !isUnlocked(id) else {
            if accountDoor != nil { withAnimation(.easeOut(duration: 0.25)) { accountDoor = nil } }
            return
        }
        if accountDoor != id { errorMessage = nil }
        unlockTargetID = id
        if accountDoor == nil {
            withAnimation(.easeOut(duration: 0.25)) { accountDoor = id }
        } else {
            accountDoor = id
        }
    }
    /// The focused account, while it still exists and there's more than one to choose from.
    var focusedAccountID: String? {
        guard accounts.count > 1, let id = accountFocus, accounts.contains(where: { $0.id == id }) else { return nil }
        return id
    }
    /// The items of the account in focus (every open account's when none is).
    var focusedItems: [VaultItem] {
        guard let id = focusedAccountID else { return items }
        return items.filter { $0.accountId == id }
    }
    /// The organizations of the account in focus (all of them when none is).
    var visibleOrganizations: [Grouping] {
        guard let id = focusedAccountID else { return organizations }
        return session(for: id)?.organizations ?? []
    }

    /// Whether an item is in the vault the filter (and the account in focus) shows.
    func inVault(_ item: VaultItem) -> Bool {
        if let focus = focusedAccountID, item.accountId != focus { return false }
        return switch vaultFilter {
        case .all: true
        case .personal: item.organizationId == nil
        case .organization(let id): item.organizationId == id
        case .several(let keys): keys.contains(item.organizationId ?? VaultFilter.personalKey)
        }
    }

    /// Every open account's equivalent domains.
    var equivalentDomains: EquivalentDomains { EquivalentDomains(groups: sessions.flatMap(\.equivalents.groups)) }

    /// The items in the chosen vault.
    var vaultItems: [VaultItem] { vaultFilter == .all && focusedAccountID == nil ? items : items.filter(inVault) }
    /// True while adding another account from an unlocked vault (login screen can be cancelled).
    var addingAccount = false
    var items: [VaultItem] = []
    /// Items picked together in the list (⌘-click, ⇧-click, ⌘A) for one action on all of them.
    var multiSelection: Set<String> = []

    /// Moving items into an organization, or changing an organization item's collections.
    enum OrganizationSheet: Identifiable {
        case share([String]), collections(String)
        var id: String {
            switch self { case .share(let ids): "share:" + ids.joined(separator: ","); case .collections(let id): "collections:" + id }
        }
    }
    var organizationSheet: OrganizationSheet?
    /// The organization whose event log is open.
    var eventLogFor: String?

    /// Selected item, shared by the list, detail and the Item menu commands.
    var selectedID: VaultItem.ID?
    var selectedItem: VaultItem? { items.first { $0.id == selectedID } }
    /// True while the New Folder prompt is showing.
    var promptingNewFolder = false
    /// Set to open the Keyboard Shortcuts window (from the palette); the root view opens it and clears this.
    var showingShortcuts = false
    /// The folder (path) whose Rename sheet is open.
    var renamingFolder: String?
    /// The last rename (old path, new path), so the sidebar's selection can follow it.
    var renamedFolder: (old: String, new: String)?
    /// The folder a new one goes inside (its path), when it was asked for from that folder's menu.
    var newFolderParent: String?

    /// The New Folder prompt, for a folder inside `parent` (a path like "Work/Servers"), or at the top.
    func promptNewFolder(in parent: String? = nil) {
        newFolderParent = parent
        promptingNewFolder = true
    }
    /// Non-nil while an item form is open in the detail panel (new, clone, or edit).
    var editing: EditRequest?
    /// The form in the detail panel, if one is open.
    var newItemForm: EditRequest? { editing }
    /// The form has input in it (it reports this), so leaving it asks first.
    var newItemFormDirty = false
    /// What to do once "Discard this new item?" is answered with Discard.
    var pendingLeave: (() -> Void)?
    /// The item selected before the new-item form opened, shown again if it's cancelled.
    private var selectionBeforeForm: VaultItem.ID?

    /// Opens an item form in the detail panel. A new item or clone steps the list's selection aside; an edit keeps
    /// that item selected. Leaving a form with input in it asks first.
    func beginEditing(_ request: EditRequest) {
        leaveNewItemForm { [self] in
            if case .edit(let item) = request.mode {
                selectionBeforeForm = nil
                selectedID = item.id
            } else {
                selectionBeforeForm = selectedID
                selectedID = nil
            }
            editing = request
        }
    }

    /// Runs `action` once the new-item form (if open) is out of the way: at once when it's empty, after
    /// "Discard this new item?" when it has input.
    func leaveNewItemForm(then action: @escaping () -> Void) {
        guard newItemForm != nil else { action(); return }
        if newItemFormDirty { pendingLeave = action } else { closeNewItemForm(restoringSelection: false); action() }
    }

    /// The answer to "Discard this new item?".
    func discardNewItemAndLeave() {
        let action = pendingLeave
        pendingLeave = nil
        closeNewItemForm(restoringSelection: false)
        action?()
    }

    /// Closes the form. Cancelling a new item or clone shows the item selected before it; cancelling an edit
    /// shows that same item.
    func closeNewItemForm(restoringSelection: Bool = true) {
        guard let editing else { return }
        let restore = restoringSelection && !editing.mode.isEdit
        self.editing = nil
        newItemFormDirty = false
        if restore, selectedID == nil { selectedID = selectionBeforeForm }
        selectionBeforeForm = nil
    }
    /// The import or export sheet; an import may start with a file (dropped on the window).
    var transfer: Transfer?

    enum Transfer: Identifiable {
        case export(accountId: String?)
        case importFile(URL?)
        var id: String {
            switch self {
            case .export(let account): "export-" + (account ?? "")
            case .importFile(let url): "import-" + (url?.path ?? "")
            }
        }
    }

    func beginExport(accountId: String? = nil) { bringToFront(); transfer = .export(accountId: accountId) }
    func beginImport(_ url: URL? = nil) { bringToFront(); transfer = .importFile(url) }

    /// Checks a master password offline (re-entry before an export).
    /// An item that asks for the master password, waiting for it before `action` runs.
    struct RepromptRequest: Identifiable {
        let id = UUID()
        let item: VaultItem
        let action: () -> Void
    }
    var repromptRequest: RepromptRequest?
    /// Items confirmed a moment ago: reveal then copy shouldn't ask twice.
    private var repromptPassed: [String: Date] = [:]

    /// Runs `action` at once, unless the item asks for the master password first (Bitwarden's "master password
    /// re-prompt"): then after it's entered (or Touch ID), and for the next minute without asking again.
    func guarded(_ item: VaultItem, _ action: @escaping () -> Void) {
        guard item.reprompt, repromptPassed[item.id].map({ Date.now.timeIntervalSince($0) > 60 }) ?? true else {
            action(); return
        }
        bringToFront()
        repromptRequest = RepromptRequest(item: item, action: action)
    }

    func passReprompt(_ request: RepromptRequest) {
        repromptPassed[request.item.id] = .now
        repromptRequest = nil
        request.action()
    }

    func isRepromptPassed(_ item: VaultItem) -> Bool {
        !item.reprompt || (repromptPassed[item.id].map { Date.now.timeIntervalSince($0) <= 60 } ?? false)
    }

    func verifyMasterPassword(_ password: String, accountId: String) -> Bool {
        AccountStore.unlock(accountId, password: password) != nil
    }
    /// True while ⌥ is held: reveals masked fields.
    var optionHeld = false
    var isOnline: Bool { sessions.contains { $0.lastSynced != nil } }
    var folders: [Grouping] = []
    var sends: [SendItem] = []
    var selectedSendID: SendItem.ID?
    var composingSend = false
    /// The Send being edited in the composer.
    var editingSend: SendItem?
    /// Organizations, each with its collections as children.
    var organizations: [Grouping] = []
    var skippedOrgItems = 0
    var isBusy = false
    var errorMessage: String?

    var serverKind = ServerKind(rawValue: UserDefaults.standard.string(forKey: "serverKind") ?? "") ?? .selfHosted
    var serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? "https://"
    var email = UserDefaults.standard.string(forKey: "email") ?? ""
    /// Optional "Custom environment" fields for self-hosted servers (empty = derive from the server URL).
    var customWebVault = ""
    var customAPI = ""
    var customIdentity = ""
    var customIcons = ""
    var customNotifications = ""
    var hasCustomURLs: Bool {
        ![customWebVault, customAPI, customIdentity, customIcons, customNotifications]
            .allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var isUnlocked: Bool { phase.id == Phase.vault.id && (!sessions.isEmpty || previewUnlocked) }
    /// Snapshots and `--demo`: treat demo items as an unlocked vault.
    var previewUnlocked = false

    /// Most recent successful sync across accounts; nil while showing cached data only.
    var lastSynced: Date? { sessions.compactMap(\.lastSynced).max() }
    var isSyncing: Bool { sessions.contains(where: \.isSyncing) }
    /// Whether any locked account can be opened with Touch ID (unlock screen).
    var touchIDEnabled = false

    /// Serves SSH key items to ssh/git while unlocked (Settings › SSH).
    @ObservationIgnored private(set) var sshAgent: SSHAgentService!
    @ObservationIgnored private(set) var cli: CLIBridge!
    let updates: Updater
    /// Fork-style licensing: everything works unregistered; official builds remind now and then.
    let license = License()

    /// The app's live model, for App Intents and the CLI bridge.
    nonisolated(unsafe) static weak var current: AppModel?

    init() {
        // No updater while testing, rendering snapshots, previewing or showing the demo vault.
        let quiet = CommandLine.arguments.contains { ["--selftest", "--snapshot"].contains($0) || $0.hasPrefix("--selftest") || $0.hasPrefix("--demo") }
            || ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        updates = Updater(start: !quiet)
        AttachmentFiles.wipe() // leftovers from a crash
        Self.current = self
        sshAgent = SSHAgentService(model: self)
        let tooling = CommandLine.arguments.contains { $0 == "--selftest" || $0 == "--snapshot" }
            || ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" // Xcode canvas
        if !tooling, UserDefaults.standard.bool(forKey: Pref.sshAgent) { sshAgent.start() }
        cli = CLIBridge(model: self)
        if !tooling { cli.refreshRunning() }
        if !tooling {
            trackForegroundApps()
            // The palette and its global shortcut from launch, not from when a window first appears (the app may
            // start in the menu bar only).
            DispatchQueue.main.async { [weak self] in self?.installPalette() }
        }
        IconStore.shared.makeSession = { [weak self] in self?.makeSession() ?? .shared }
        refreshAccounts()
        if !accounts.isEmpty { phase = .locked }
    }

    private func refreshAccounts() {
        accounts = AccountStore.accounts()
        if unlockTargetID == nil || !accounts.contains(where: { $0.id == unlockTargetID }) {
            unlockTargetID = accounts.first { a in !sessions.contains { $0.id == a.id } }?.id ?? accounts.first?.id
        }
        touchIDEnabled = accounts.contains { a in AccountStore.isTouchIDEnabled(a.id) && !sessions.contains { $0.id == a.id } }
    }

    func session(for accountId: String) -> AccountSession? { sessions.first { $0.id == accountId } }

    // MARK: Watchtower

    /// Item id → times seen in breaches; nil until the user runs a check.
    var breachCounts: [String: Int]?
    var breachesCheckedAt: Date?
    var isCheckingBreaches = false

    func checkBreaches() async {
        isCheckingBreaches = true
        defer { isCheckingBreaches = false }
        let logins = items.filter { !$0.isDeleted && $0.password != nil }
        do {
            let counts = try await PwnedPasswords.check(Set(logins.compactMap(\.password)), session: makeSession())
            breachCounts = Dictionary(logins.map { ($0.id, counts[$0.password!] ?? 0) }, uniquingKeysWith: { a, _ in a })
            breachesCheckedAt = .now
        } catch {
            flash(String(localized: "Couldn't reach Have I Been Pwned. Try again later."))
        }
    }

    /// Logins with any locally-detectable issue (sidebar badge).
    var watchtowerIssueCount: Int { WatchtowerReport(items: items, breaches: breachCounts).problemCount }

    #if DEBUG
    /// Snapshot/demo only: pretend these accounts are saved.
    /// Previews, snapshots and `--demo`: in-memory accounts, no Touch ID (it would prompt for real).
    func setPreviewAccounts(_ accounts: [SavedAccount]) {
        self.accounts = accounts
        unlockTargetID = accounts.first?.id
        touchIDEnabled = false
    }
    #endif
    func isUnlocked(_ accountId: String) -> Bool { session(for: accountId) != nil }
    func isTouchIDEnabled(_ accountId: String) -> Bool { AccountStore.isTouchIDEnabled(accountId) }

    // MARK: Sign-in requests

    /// Another device asking this one to approve its sign-in.
    struct SignInPrompt: Identifiable {
        var id: String { request.id }
        let accountId: String
        let email: String
        let request: SignInRequest
        let fingerprint: [String]
    }
    var signInPrompt: SignInPrompt?
    private var signInWatch: Task<Void, Never>?
    private var answeredSignIns: Set<String> = []

    /// While a vault is open, looks for sign-in requests every 30 seconds.
    private func watchSignIns() {
        guard signInWatch == nil, !sessions.isEmpty, !previewUnlocked else { return }
        signInWatch = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkSignIns()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func checkSignIns() async {
        guard signInPrompt == nil else { return }
        for session in sessions {
            guard let pending = try? await session.pendingSignIns() else { continue }
            // Requests expire after 15 minutes.
            let fresh = pending.filter { request in
                !answeredSignIns.contains(request.id)
                    && (request.created.flatMap(VaultDecoder.date).map { Date.now.timeIntervalSince($0) < 15 * 60 } ?? true)
            }
            if let request = fresh.first {
                signInPrompt = SignInPrompt(accountId: session.id, email: session.account.email, request: request,
                                            fingerprint: session.fingerprint(of: request))
                bringToFront()
                NSApp.requestUserAttention(.criticalRequest)
                return
            }
        }
    }

    func answerSignIn(_ prompt: SignInPrompt, approve: Bool) async {
        answeredSignIns.insert(prompt.request.id)
        signInPrompt = nil
        guard let session = session(for: prompt.accountId) else { return }
        do {
            try await session.answer(prompt.request, approve: approve)
            flash(approve ? String(localized: "Sign-in approved") : String(localized: "Sign-in denied"))
        } catch { _ = failed(error) }
    }

    /// Merges every unlocked account into one list.
    private func rebuild() {
        let multi = sessions.count > 1
        items = sessions.flatMap(\.items).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        folders = sessions.flatMap(\.folders)
        organizations = sessions.flatMap(\.organizations)
        sends = sessions.flatMap(\.sends)
        if let id = selectedSendID, !sends.contains(where: { $0.id == id }) { selectedSendID = nil }
        skippedOrgItems = sessions.reduce(0) { $0 + $1.hiddenCount }
        if !multi { accountFilter = nil }
        pruneVaultFilter()
        if let id = selectedID, !items.contains(where: { $0.id == id }) { selectedID = nil }
        AutoFillIdentities.publish(items, equivalents: equivalentDomains)
        if sessions.isEmpty { signInWatch?.cancel(); signInWatch = nil } else { watchSignIns() }
    }

    enum ServerStatus: Equatable {
        case unknown, checking
        case reachable(product: String, version: String?)
        case unreachable(String)
    }
    var serverStatus: ServerStatus = .unknown
    private var statusTask: Task<Void, Never>?

    /// Bumped each time Quick Search opens, so the panel resets and focuses.
    var quickSearchNonce = 0
    /// Bumped when Quick Search closes, so the palette plays its way out before the panel hides.
    var quickSearchDismissNonce = 0
    /// Where the palette or the menu bar panel was called from (see ForegroundContext).
    var foreground: ForegroundContext?
    /// The last app the user was in other than Triwarden.
    @ObservationIgnored var lastOtherApp: NSRunningApplication?
    /// Snapshots: keep the context they set instead of reading the real front app.
    @ObservationIgnored var foregroundPinned = false
    @ObservationIgnored private var palette: QuickSearchController?

    /// The floating palette, and every system-wide shortcut (Settings › Shortcuts).
    func installPalette() {
        guard palette == nil else { return }
        let controller = QuickSearchController(model: self)
        palette = controller
        controller.prepare()
        openPalette = { controller.show() }
        paletteClosed = { await controller.waitUntilClosed() }
        let keys = HotKeys.shared
        keys.install(.palette) { controller.toggle() }
        keys.install(.fill) { [weak self] in self?.fillForeground() }
        keys.install(.showWindow) { [weak self] in self?.bringToFront() }
        keys.install(.generate) { [weak self] in
            self?.copy(PasswordGenerator.saved.generate(), label: String(localized: "New password"))
        }
        keys.install(.lock) { [weak self] in
            guard let self, self.isUnlocked else { return }
            self.lock(animated: true)
        }
    }

    /// Opens the command palette (set by the app; the search box, ⌘K/⌘F and the global shortcut all use it).
    @ObservationIgnored var openPalette: () -> Void = {}
    /// The vault window, so Help and Keyboard Shortcuts can sit in its center and dim it.
    @ObservationIgnored weak var mainWindow: NSWindow?
    /// True while Help or Keyboard Shortcuts is open. The vault window draws a scrim from this.
    var helpScrim = false
    @ObservationIgnored private var shortcutsWindow: GlassWindow?
    @ObservationIgnored private var helpWindow: GlassWindow?

    func showShortcuts() {
        if shortcutsWindow == nil {
            shortcutsWindow = GlassWindow(model: self, title: String(localized: "Keyboard Shortcuts"),
                                          size: NSSize(width: 960, height: 680), minSize: NSSize(width: 860, height: 560)) {
                AnyView(KeyboardShortcutsView())
            }
        }
        shortcutsWindow?.show()
    }

    func showHelp() {
        if helpWindow == nil {
            helpWindow = GlassWindow(model: self, title: String(localized: "Triwarden Help"),
                                     size: NSSize(width: 820, height: 560), minSize: NSSize(width: 720, height: 480)) {
                AnyView(HelpGuideView())
            }
        }
        helpWindow?.show()
    }

    func dismissHelpPanels() {
        shortcutsWindow?.close()
        helpWindow?.close()
    }

    func refreshHelpScrim() {
        let on = (shortcutsWindow?.isShown == true) || (helpWindow?.isShown == true)
        guard helpScrim != on else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            helpScrim = on
        } else {
            withAnimation(.easeOut(duration: 0.22)) { helpScrim = on }
        }
    }
    /// Waits for the palette to finish closing: it holds the keyboard until then, even over another app.
    @ObservationIgnored var paletteClosed: () async -> Void = {}
    /// SwiftUI's `openSettings`, captured by the main window (it only exists inside a scene).
    @ObservationIgnored var openSettingsAction: () -> Void = {}

    /// Brings the app forward and opens Settings (from the menu bar, the palette, the account menu).
    func showSettings(_ pane: SettingsView.Pane? = nil) {
        if let pane { UserDefaults.standard.set(pane.rawValue, forKey: SettingsView.paneKey) }
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate()
        openSettingsAction()
    }
    /// Sidebar destination asked for from outside the vault view (palette commands).
    var requestedSection: SidebarSelection?
    /// An item to point out on the Watchtower page (from its detail): the page scrolls to it and highlights it.
    var watchtowerFocus: String?

    /// Opens Watchtower at an item's issue.
    func showInWatchtower(_ item: VaultItem) {
        watchtowerFocus = item.id
        requestedSection = .watchtower
    }
    /// Asks the vault window to show its list filtered by this text (the palette's "Show all results").
    var requestedFilter: String?
    var showingGenerator = false

    /// A destructive action waiting for “Are you sure?” (one dialog for the whole app).
    struct ConfirmRequest: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let action: String
        let run: @MainActor () async -> Void
    }
    var confirming: ConfirmRequest?

    func confirm(_ title: String, message: String, action: String, run: @escaping @MainActor () async -> Void) {
        confirming = ConfirmRequest(title: title, message: message, action: action, run: run)
    }

    /// Asks, then moves the item to Trash (the toast and ⌘Z can still take it back). Every delete asks first.
    func confirmTrash(_ item: VaultItem) {
        let message = isCloud(item.accountId) ? String(localized: "You can restore it from Trash for \(Self.cloudTrashDays) days.")
                                    : String(localized: "You can restore it from Trash later.")
        confirm(String(localized: "Move “\(item.name)” to Trash?"), message: message,
                action: String(localized: "Move to Trash")) { [weak self] in await self?.trash(item) }
    }

    /// Asks, then deletes a trashed item for good.
    func confirmDeleteForever(_ item: VaultItem) {
        confirm(String(localized: "Delete “\(item.name)” forever?"), message: String(localized: "This can't be undone."),
                action: String(localized: "Delete Forever")) { [weak self] in await self?.deleteForever(item) }
    }

    /// Asks, then deletes a Send (its link stops working).
    func confirmDeleteSend(_ send: SendItem) {
        confirm(String(localized: "Delete “\(send.name)”?"), message: String(localized: "Its link stops working right away."),
                action: String(localized: "Delete")) { [weak self] in await self?.deleteSend(send) }
    }

    /// Asks, then deletes a folder; its items stay, with no folder.
    func confirmDeleteFolder(name: String, ids: [String]) {
        confirm(String(localized: "Delete the folder “\(name)”?"), message: String(localized: "Its items aren't deleted; they move out of the folder."),
                action: String(localized: "Delete Folder")) { [weak self] in
            for id in ids { await self?.deleteFolder(id) }
        }
    }

    /// Asks, then logs the account out (removing it from this Mac).
    func confirmLogOut(_ accountId: String?) {
        let email = accountId.flatMap { id in accounts.first { $0.id == id }?.email } ?? ""
        confirm(String(localized: "Log out of \(email)?"),
                message: String(localized: "The account and its saved vault are removed from this Mac. Your vault stays on the server."),
                action: String(localized: "Log Out")) { [weak self] in self?.logOut(accountId) }
    }

    /// Generated values the user copied or used, newest first. Memory only; cleared on lock.
    struct GeneratedEntry: Identifiable { let id = UUID(); let value: String; let kind: String; let date: Date }
    var generatorHistory: [GeneratedEntry] = []

    func rememberGenerated(_ value: String, kind: String) {
        guard !value.isEmpty, generatorHistory.first?.value != value else { return }
        generatorHistory.insert(GeneratedEntry(value: value, kind: kind, date: .now), at: 0)
        if generatorHistory.count > 50 { generatorHistory.removeLast() }
    }

    static let mainWindowID = "main"
    /// Opens (or brings back) the vault window; set by the window's scene.
    @ObservationIgnored var openMainWindowAction: () -> Void = {}

    /// Shows the main window, e.g. after a palette command run from another app — reopening it if it was closed, and
    /// back in the Dock if it was waiting in the menu bar.
    func bringToFront() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate()
        openMainWindowAction()
    }

    /// The vault window is showing: Triwarden belongs in the Dock again.
    func windowDidOpen() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    /// A window is closing. If it was the last ordinary one and "Keep running in the menu bar" is on, leave the Dock
    /// (the menu bar icon, shortcuts, AutoFill and the palette keep working).
    func windowWillClose(_ window: NSWindow?) {
        guard UserDefaults.standard.bool(forKey: Pref.closeToMenuBar), UserDefaults.standard.bool(forKey: Pref.showMenuBar),
              let window, window.canBecomeMain else { return }
        let others = NSApp.windows.contains { $0 !== window && $0.isVisible && $0.canBecomeMain }
        guard !others else { return }
        // After the window has gone, so the switch doesn't fight its closing.
        DispatchQueue.main.async {
            guard !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Selects an item in the vault list.
    func showItem(_ id: String) {
        bringToFront()
        requestedSection = .section(.all)
        selectedID = id
    }

    /// Transient confirmation shown after copying.
    var toast: String?
    /// A button on the toast: Undo, or Copy Code after a password.
    struct ToastAction {
        let title: String
        let run: @MainActor () -> Void
    }
    var toastAction: ToastAction?
    /// Goes up with every copy, so the control that asked for it can tick (see CopyTick).
    var copyCount = 0
    /// When the clipboard empties itself (Settings › Security), while a copied secret is still waiting there.
    var clipboardClearsAt: Date?
    /// How long it was set to wait, for the countdown's ring.
    var clipboardHoldSeconds: Double?
    /// The pasteboard's change count right after our copy: anything newer was copied by someone else, so it stays.
    @ObservationIgnored private var copiedChange = 0
    /// The item just created, for its row to pop as it lands in the list.
    var arrivedID: String?
    private var toastTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?

    /// Login-in-progress client (kept between the password and 2FA steps).
    private var client: VaultClient?

    private func makeClient(_ environment: ServerEnvironment) -> VaultClient { Connection.makeClient(environment) }
    private func makeSession() -> URLSession { Connection.makeSession() }

    func scheduleSync() {
        guard isUnlocked else { return }
        sessions.forEach { $0.scheduleSync() }
    }

    /// Re-sync when the app comes to the front if the last sync is stale.
    func appDidBecomeActive() {
        // AutoFill may have just been switched on in System Settings.
        if isUnlocked { AutoFillIdentities.publish(items, equivalents: equivalentDomains) }
        for session in sessions where session.lastSynced.map({ Date.now.timeIntervalSince($0) > 60 }) ?? true {
            session.scheduleSync()
        }
        announceInbox()
    }

    /// The bell should open. A system notification tap sets this; the header button consumes it.
    var presentInbox = false

    /// Brings the vault forward and opens the bell.
    func revealInbox() {
        bringToFront()
        presentInbox = true
    }

    private var inboxAnnounce: Task<Void, Never>?

    /// Posts a system banner for each new thing waiting in the bell. SSH signatures keep their own banner.
    func announceInbox() {
        inboxAnnounce?.cancel()
        inboxAnnounce = Task { await announceInboxNow() }
    }

    private func announceInboxNow() async {
        guard isUnlocked else { return }
        var banners: [InboxBanner] = []
        if sessions.contains(where: { $0.lastSyncError != nil }) {
            banners.append(InboxBanner(id: "sync", title: String(localized: "Couldn't sync"),
                                       body: String(localized: "The vault on this Mac is unchanged."), sound: true))
        }
        if let version = updates.availableVersion {
            banners.append(InboxBanner(id: "update-\(version)", title: String(localized: "Update \(version) is ready"),
                                       body: String(localized: "Install when you're ready.")))
        }
        let report = WatchtowerReport(items: items, breaches: breachCounts)
        let breached = report.issues[.breached]?.count ?? 0
        if breached > 0 {
            let body = breached == 1
                ? String(localized: "A password was found in a data breach.")
                : String(localized: "\(breached) passwords were found in data breaches.")
            banners.append(InboxBanner(id: "breached-\(breached)", title: String(localized: "Watchtower"), body: body))
        }
        let cards = report.issues[.cardExpiring]?.count ?? 0
        if cards > 0 {
            let body = cards == 1
                ? String(localized: "A card expires soon.")
                : String(localized: "\(cards) cards expire soon.")
            banners.append(InboxBanner(id: "cards-\(cards)", title: String(localized: "Watchtower"), body: body))
        }
        let soon = Date.now.addingTimeInterval(48 * 60 * 60)
        for send in sends.prefix(3) where !send.disabled && !send.isExpired {
            guard let date = send.expirationDate ?? send.deletionDate, date > .now, date < soon else { continue }
            banners.append(InboxBanner(id: "send-\(send.id)", title: send.name, body: String(localized: "Send expires soon")))
        }
        if !Task.isCancelled {
            for session in sessions {
                guard let trusted = try? await session.emergencyContacts(granted: false),
                      let granted = try? await session.emergencyContacts(granted: true) else { continue }
                for contact in trusted where contact.status == .recoveryInitiated {
                    let person = contact.name ?? contact.email
                    banners.append(InboxBanner(id: "emergency-\(contact.id)", title: person,
                                               body: String(localized: "Asked for emergency access"), sound: true))
                }
                for contact in trusted where contact.status == .accepted {
                    let person = contact.name ?? contact.email
                    banners.append(InboxBanner(id: "emergency-confirm-\(contact.id)", title: person,
                                               body: String(localized: "Needs confirming")))
                }
                for contact in granted where contact.status == .recoveryApproved {
                    let person = contact.name ?? contact.email
                    banners.append(InboxBanner(id: "emergency-granted-\(contact.id)", title: person,
                                               body: String(localized: "Emergency access granted"), sound: true))
                }
            }
        }
        guard !Task.isCancelled else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined, !banners.isEmpty {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        guard !Task.isCancelled else { return }
        InboxAnnouncer.deliver(banners)
    }

    /// Drop the cached client so new headers / certificates take effect on the next request.
    func resetClient() {
        client = nil
        checkServer()
    }

    var serverSummary: String {
        switch serverKind {
        case .bitwardenUS: "bitwarden.com"
        case .bitwardenEU: "bitwarden.eu"
        case .selfHosted: serverURL
        }
    }

    /// Sign one account out on this Mac: forget its session, cached vault, token and Touch ID.
    /// With no id: the account the unlock screen shows.
    func logOut(_ accountId: String? = nil) {
        guard let id = accountId ?? unlockTarget?.id else { return }
        if let session = session(for: id) { session.close() }
        sessions.removeAll { $0.id == id }
        AccountStore.erase(id)
        if accountFilter == id { accountFilter = nil }
        unlockTargetID = nil
        refreshAccounts()
        rebuild()
        updateAccountDoor()
        if accounts.isEmpty {
            AutoFillIdentities.clear()
            email = ""
            UserDefaults.standard.removeObject(forKey: "email")
            phase = .login
        } else if sessions.isEmpty {
            phase = .locked
        }
    }

    /// Opens the login screen to add another account (cancellable back to the vault, or the unlock screen).
    /// With `sameServerAs`, the server fields start out as that account's, so only the email is new.
    func beginAddAccount(sameServerAs account: SavedAccount? = nil) {
        addingAccount = true
        client = nil
        errorMessage = nil
        email = ""
        serverURL = "https://"
        (customWebVault, customAPI, customIdentity, customIcons, customNotifications) = ("", "", "", "", "")
        if let account, let kind = ServerKind(rawValue: account.serverKind) {
            serverKind = kind
            if kind == .selfHosted {
                serverURL = account.serverURL
                if let c = account.customURLs {
                    if let base = c.base { serverURL = base.absoluteString }
                    let text = { (url: URL?) in url?.absoluteString ?? "" }
                    (customWebVault, customAPI, customIdentity, customIcons, customNotifications) =
                        (text(c.webVault), text(c.api), text(c.identity), text(c.icons), text(c.notifications))
                }
            }
        }
        phase = .login
    }

    func cancelAddAccount() {
        addingAccount = false
        errorMessage = nil
        phase = sessions.isEmpty ? (accounts.isEmpty ? .login : .locked) : .vault
    }

    /// Why the self-hosted URLs can't be used, or nil when they're fine.
    var serverURLProblem: String? {
        guard serverKind == .selfHosted else { return nil }
        let fields = [serverURL, customWebVault, customAPI, customIdentity, customIcons, customNotifications]
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != "https://" && $0 != "http://" }
        for text in fields {
            guard let url = Self.parseURL(text) else { return String(localized: "“\(text)” isn't a valid URL.") }
            if url.scheme == "http", WatchtowerReport.isInsecure(url.absoluteString) {
                return String(localized: "Use https:// for servers on the internet. http:// is only allowed on your local network.")
            }
        }
        return nil
    }

    /// Accepts "vault.example.com" (adds https://) and trims trailing slashes, like the official clients.
    static func parseURL(_ text: String) -> URL? {
        var t = text.trimmingCharacters(in: .whitespaces)
        while t.hasSuffix("/") { t.removeLast() }
        guard !t.isEmpty else { return nil }
        if !t.contains("://") {
            // A half-typed scheme ("https:/") isn't a host called "https".
            let lower = t.lowercased()
            if lower.hasPrefix("http:") || lower.hasPrefix("https:") { return nil }
            t = "https://" + t
        }
        guard let url = URL(string: t), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host() != nil else { return nil }
        return url
    }

    private var customURLs: CustomURLs? {
        guard hasCustomURLs else { return nil }
        let urls = CustomURLs(base: Self.parseURL(serverURL), webVault: Self.parseURL(customWebVault), api: Self.parseURL(customAPI),
                              identity: Self.parseURL(customIdentity), icons: Self.parseURL(customIcons),
                              notifications: Self.parseURL(customNotifications))
        return urls.isUsable ? urls : nil
    }

    private func environment() -> ServerEnvironment? {
        switch serverKind {
        case .bitwardenUS: return .bitwardenUS
        case .bitwardenEU: return .bitwardenEU
        case .selfHosted:
            guard serverURLProblem == nil else { return nil }
            if hasCustomURLs { return customURLs.map(ServerEnvironment.custom) }
            return Self.parseURL(serverURL).map(ServerEnvironment.selfHosted)
        }
    }

    /// The server address changed: what was said about the old one no longer applies. Checked again on leaving the field.
    func serverURLEdited() {
        statusTask?.cancel()
        serverStatus = .unknown
    }

    /// Pings the selected server's public `/api/config`.
    func checkServer() {
        statusTask?.cancel()
        guard let environment = environment() else { serverStatus = .unknown; return }
        serverStatus = .checking
        statusTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            let probe = makeClient(environment)
            do {
                let config = try await probe.config()
                guard !Task.isCancelled else { return }
                serverStatus = .reachable(product: config.productName, version: config.version)
            } catch {
                guard !Task.isCancelled else { return }
                serverStatus = .unreachable(String(localized: "Can't reach this server"))
            }
        }
    }

    enum HintResult { case success(String?), failure(String) }

    func requestPasswordHint(email: String) async -> HintResult {
        guard let environment = environment() else { return .failure(String(localized: "Enter a valid server URL.")) }
        do {
            let hint = try await makeClient(environment).requestPasswordHint(email: email)
            return .success(hint)
        } catch {
            if case .http(_, let message?) = error as? APIError { return .failure(message) }
            return .failure(String(localized: "Couldn't send the hint. Check the server and try again."))
        }
    }

    /// Copies a secret, hides it from clipboard managers, and clears it after the configured delay if unchanged.
    /// Copies non-secret text (config snippets, public keys) without the clipboard timer.
    func copyPlain(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        flash(String(localized: "Copied"))
    }

    /// - Parameter afterPaste: runs once the value has been pasted somewhere (the clipboard hands it out lazily, so
    ///   Triwarden hears when another app reads it).
    func copy(_ value: String, label: String, afterPaste: (@MainActor () -> Void)? = nil) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        if let afterPaste {
            let item = NSPasteboardItem()
            let promise = PastePromise(value: value) {
                // Let the paste finish before the clipboard changes under it.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    afterPaste()
                }
            }
            pastePromise = promise
            item.setDataProvider(promise, forTypes: [.string])
            item.setString("", forType: concealed)
            pb.writeObjects([item])
        } else {
            pastePromise = nil
            pb.setString(value, forType: .string)
            pb.setString("", forType: concealed)
        }
        let change = pb.changeCount
        copiedChange = change
        let seconds = UserDefaults.standard.integer(forKey: Pref.clipboardSeconds)
        clearTask?.cancel()
        copyCount += 1
        if seconds > 0 {
            clipboardClearsAt = .now.addingTimeInterval(TimeInterval(seconds))
            clipboardHoldSeconds = Double(seconds)
            clearTask = Task {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                if pb.changeCount == change { pb.clearContents() }
                clipboardClearsAt = nil
            }
            toast = String(localized: "\(label) copied · clears in \(seconds) s")
        } else {
            clipboardClearsAt = nil
            toast = String(localized: "\(label) copied")
        }
        toastAction = nil
        noteActivity()
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(1.8))
            if !Task.isCancelled { toast = nil; toastAction = nil }
        }
    }

    /// Empties the clipboard before its time (the countdown's button), if what we copied is still there.
    func clearClipboardNow() {
        clearTask?.cancel()
        clearTask = nil
        if clipboardClearsAt != nil, NSPasteboard.general.changeCount == copiedChange { NSPasteboard.general.clearContents() }
        clipboardClearsAt = nil
        flash(String(localized: "Clipboard cleared"))
    }

    /// Shows an item's password in big letters, to type it on another device.
    func showLargeType(_ item: VaultItem) {
        guard let password = item.password, !password.isEmpty else { return }
        guarded(item) {
            LargeType.show(password)
            self.noteActivity()
        }
    }

    /// Hands the copied password to the app that pastes it, then tells Triwarden it went.
    @ObservationIgnored private var pastePromise: PastePromise?

    /// Copies an item's password (asking for the master password first if the item wants it). When the login has a
    /// one-time code too, the code follows: the clipboard switches to it once the password is pasted (Settings ›
    /// Security), and the toast offers it as a button.
    func copyPassword(_ item: VaultItem) {
        guard let password = item.password else { return }
        guarded(item) { [weak self] in
            guard let self else { return }
            let label = String(localized: "Password")
            guard let totp = item.totp else { copy(password, label: label); return }
            let copyCode: @MainActor () -> Void = { [weak self] in self?.copy(totp.code(), label: String(localized: "Code")) }
            if UserDefaults.standard.bool(forKey: Pref.codeAfterPassword) {
                copy(password, label: label, afterPaste: copyCode)
                toast = String(localized: "Password copied · the code follows once you paste")
            } else {
                copy(password, label: label)
            }
            toastAction = ToastAction(title: String(localized: "Copy Code"), run: copyCode)
            toastTask?.cancel()
            toastTask = Task {
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled { toast = nil; toastAction = nil }
            }
        }
    }

    /// - Parameters:
    ///   - code: the authenticator code in `.twoFactor`, or the emailed code in `.deviceVerification`.
    func login(password: String, code: String? = nil) async {
        guard let environment = environment() else {
            errorMessage = serverURLProblem ?? String(localized: "Enter a valid server URL.")
            return
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        let client = self.client?.environment == environment ? self.client! : makeClient(environment)
        self.client = client
        let isDeviceCode: Bool = if case .deviceVerification = phase { true } else { false }
        do {
            // Provider "0" is the authenticator app (TOTP).
            let result = try await client.loginDetailed(email: email, password: password,
                                                        twoFactor: isDeviceCode ? nil : code.map { ("0", $0) },
                                                        newDeviceOTP: isDeviceCode ? code : nil)
            try await finishLogin(environment: environment, client: client, kdf: result.kdf, protectedUserKey: result.protectedUserKey,
                                  userKey: result.userKey, refreshToken: result.refreshToken)
        } catch {
            handle(error)
        }
    }

    // MARK: Log in with another device

    /// Waiting for another device to approve this sign-in: the phrase to compare on it.
    struct DeviceLogin: Equatable {
        var fingerprint: [String]
        var requestId: String
    }
    var deviceLogin: DeviceLogin?
    private var deviceLoginTask: Task<Void, Never>?

    /// Asks the account's other devices (signed in and unlocked) to approve this sign-in, then waits up to five
    /// minutes. The approval carries the user key, wrapped for a key made here just for this request.
    func loginWithDevice() async {
        guard let environment = environment() else {
            errorMessage = serverURLProblem ?? String(localized: "Enter a valid server URL.")
            return
        }
        let email = self.email.trimmingCharacters(in: .whitespaces)
        guard email.contains("@") else { errorMessage = String(localized: "Enter your email first."); return }
        errorMessage = nil
        let client = self.client?.environment == environment ? self.client! : makeClient(environment)
        self.client = client
        do {
            let key = try RSAPrivateKey.generate()
            let spki = try key.publicKeySPKI()
            let accessCode = Self.accessCode()
            let id = try await client.requestSignIn(email: email, publicKeySPKI: spki, accessCode: accessCode)
            deviceLogin = DeviceLogin(fingerprint: Fingerprint.phrase(publicKeySPKI: spki, material: KDF.normalizedEmail(email)),
                                      requestId: id)
            deviceLoginTask?.cancel()
            deviceLoginTask = Task { [weak self] in
                let deadline = Date.now.addingTimeInterval(5 * 60)
                while !Task.isCancelled, Date.now < deadline {
                    try? await Task.sleep(for: .seconds(3))
                    guard let self, self.deviceLogin?.requestId == id else { return }
                    do {
                        let answer = try await client.signInResponse(id: id, accessCode: accessCode)
                        guard answer.approved == true, let wrapped = answer.key else { continue }
                        let userKey = try SymmetricKeyPair(combined: key.decrypt(wrapped))
                        let login = try await client.loginWithApprovedRequest(email: email, requestId: id, accessCode: accessCode)
                        self.deviceLogin = nil
                        self.isBusy = true
                        defer { self.isBusy = false }
                        try await self.finishLogin(environment: environment, client: client, kdf: login.kdf,
                                                   protectedUserKey: login.protectedUserKey, userKey: userKey,
                                                   refreshToken: login.refreshToken)
                        return
                    } catch {
                        // Denied requests are deleted: the answer stops existing.
                        if case APIError.http(let status, _)? = error as? APIError, status == 404 || status == 400 {
                            self.deviceLogin = nil
                            self.errorMessage = String(localized: "The sign-in wasn't approved.")
                            return
                        }
                    }
                }
                if self?.deviceLogin?.requestId == id {
                    self?.deviceLogin = nil
                    self?.errorMessage = String(localized: "No device approved the sign-in in time.")
                }
            }
        } catch {
            // Vaultwarden only takes requests from devices it already knows for the account.
            if case APIError.http(_, let message?)? = error as? APIError, message.lowercased().contains("doesn't exist") {
                errorMessage = String(localized: "This Mac isn't known to the server for this account yet. Log in with your master password once.")
            } else {
                handle(error)
            }
        }
    }

    func cancelDeviceLogin() {
        deviceLoginTask?.cancel()
        deviceLoginTask = nil
        deviceLogin = nil
    }

    /// 25 random letters and digits: the request's one-time secret.
    private static func accessCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        return String((0..<25).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }

    /// Saves the account, opens its session and syncs — shared by password and SSO login.
    private func finishLogin(environment: ServerEnvironment, client: VaultClient, kdf: KDFConfig, protectedUserKey: String,
                             userKey: SymmetricKeyPair, refreshToken: String?) async throws {
        UserDefaults.standard.set(serverKind.rawValue, forKey: "serverKind")
        UserDefaults.standard.set(serverURL, forKey: "serverURL")
        UserDefaults.standard.set(email, forKey: "email")
        let custom: CustomURLs? = if case .custom(let urls) = environment { urls } else { nil }
        let id = SavedAccount.makeID(serverKind: serverKind.rawValue, serverURL: serverURL, email: email, customURLs: custom)
        let account = SavedAccount(id: id, email: email, serverKind: serverKind.rawValue, serverURL: serverURL,
                                   kdf: kdf, protectedUserKey: protectedUserKey, customURLs: custom)
        AccountStore.save(account)
        AccountStore.setRefreshToken(refreshToken, id)
        let session = open(account, key: userKey, client: client)
        self.client = nil
        try await session.refresh()
        addingAccount = false
        enterVault()
    }

    // MARK: Single sign-on

    /// SSO handshake waiting for the master password.
    @ObservationIgnored private var pendingSSO: (client: VaultClient, session: VaultClient.SSOSession, environment: ServerEnvironment)?
    /// Shows the identity provider and returns the `bitwarden://sso-callback…` URL. Swapped in the self-test.
    @ObservationIgnored var ssoAuthenticator: @MainActor (URL) async throws -> URL = WebAuthentication.run

    func loginWithSSO(identifier: String) async {
        guard let environment = environment() else {
            errorMessage = serverURLProblem ?? String(localized: "Enter a valid server URL.")
            return
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        let client = makeClient(environment)
        do {
            let start = try await client.beginSSO(identifier: identifier)
            let callback = try await ssoAuthenticator(start.authorizeURL)
            let session = try await client.finishSSO(callback: callback, start: start)
            UserDefaults.standard.set(identifier, forKey: "ssoIdentifier")
            email = session.email
            pendingSSO = (client, session, environment)
            phase = .ssoPassword
        } catch WebAuthentication.Cancelled.byUser {
            // Closed the sign-in window: stay on the login form.
        } catch {
            handle(error)
        }
    }

    func completeSSO(password: String) async {
        guard let pending = pendingSSO else { phase = .login; return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let key = try await Task.detached { try pending.client.unlockSSO(pending.session, password: password) }.value
            try await finishLogin(environment: pending.environment, client: pending.client, kdf: pending.session.kdf,
                                  protectedUserKey: pending.session.protectedUserKey, userKey: key,
                                  refreshToken: pending.session.refreshToken)
            pendingSSO = nil
        } catch {
            handle(error)
        }
    }

    /// Syncs every unlocked account now.
    func refresh() async throws {
        for session in sessions { try await session.refresh() }
    }

    // MARK: Unlock

    @discardableResult
    private func open(_ account: SavedAccount, key: SymmetricKeyPair, client: VaultClient? = nil) -> AccountSession {
        if let existing = session(for: account.id) { existing.close() }
        sessions.removeAll { $0.id == account.id }
        let session = AccountSession(account: account, userKey: key, client: client,
                                     makeClient: { [weak self] env in self?.makeClient(env) ?? VaultClient(environment: env, deviceIdentifier: "") },
                                     makeSession: { [weak self] in self?.makeSession() ?? .shared })
        session.onChange = { [weak self] in self?.rebuild() }
        sessions.append(session)
        sessions.sort { a, b in
            (accounts.firstIndex { $0.id == a.id } ?? 0) < (accounts.firstIndex { $0.id == b.id } ?? 0)
        }
        refreshAccounts()
        rebuild()
        return session
    }

    /// Offline unlock of one account (the unlock screen's target, or `accountId`).
    func unlock(password: String, accountId: String? = nil) async {
        guard let target = accountId.flatMap({ id in accounts.first { $0.id == id } }) ?? unlockTarget else { phase = .login; return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        let id = target.id
        Bench.begin("unlock-password-key")
        Bench.begin("unlock-password-open")
        let derived = await Task.detached(priority: .userInitiated) { AccountStore.unlock(id, password: password) }.value
        Bench.end("unlock-password-key")
        guard let derived else {
            errorMessage = String(localized: "Wrong master password.")
            return
        }
        finishUnlock([target.id: derived])
    }

    /// One Touch ID prompt unlocks every locked account that has it turned on.
    /// - Parameter context: pass the context shown by an embedded Touch ID view to prompt inline.
    func unlockWithTouchID(context: LAContext = LAContext()) async {
        errorMessage = nil
        let locked = accounts.map(\.id).filter { !isUnlocked($0) }
        Bench.begin("unlock-touchid-prompt") // includes the person's finger: not the app's own time
        let keys = await AccountStore.unlockAllWithTouchID(locked, reason: String(localized: "unlock your vault"), context: context)
        Bench.end("unlock-touchid-prompt")
        if !keys.isEmpty { Bench.begin("unlock-touchid-open"); finishUnlock(keys) }
    }

    private func finishUnlock(_ keys: [String: SymmetricKeyPair]) {
        for (id, key) in keys {
            guard let account = accounts.first(where: { $0.id == id }) else { continue }
            let session = open(account, key: key)
            Task { await session.resume() }
        }
        noteActivity()
        enterVault()
    }

    /// From the lock or login screen: the gate's plates part over the vault (with the full door animation, the vault
    /// door opens first). Instant for tooling and when already in the vault; a fade with Reduce Motion.
    private func enterVault() {
        let tooling = CommandLine.arguments.contains { $0.hasPrefix("--selftest") || $0 == "--snapshot" }
        // An account's own door, over the open vault: it opens the same way, then lifts instead of changing phase.
        let fromAccountDoor = phase.id == Phase.vault.id && accountDoor != nil
        let fromDoor = phase.id == Phase.locked.id || phase.id == Phase.login.id || fromAccountDoor
        guard fromDoor, !tooling, Self.gateAnimates else {
            phase = .vault
            accountDoor = nil
            updateAccountDoor()
            Bench.endAfterCommit(["unlock-password-open", "unlock-touchid-open"])
            return
        }
        guard Self.doorAnimates else { return openGate(fromAccountDoor: fromAccountDoor) }
        unlockOpenedAt = .now
        withAnimation(.spring(duration: DoorMotion.release, bounce: 0.3)) { unlockOpening = true }
        let fromLock = phase.id == Phase.locked.id || fromAccountDoor
        Task {
            // The door transforms open (~1.2 s, DoorMotion): pins light in turn and energy runs the seams, the rings
            // ratchet to their stops, the bolts snap back, then the pieces cascade out inside-out into the light.
            // The gate starts while the outer rings are still flying out (they finish at 1.05 / openSpeed s): no pause between.
            try? await Task.sleep(for: .seconds(DoorMotion.gateDelay))
            if fromLock {
                // Then the gate: plates that look exactly like the lock screen go on top, the lock screen leaves
                // under them, and the plates part over the vault (GatePlates).
                gateApart = false
                gate = .opening
                try? await Task.sleep(for: .milliseconds(30))
                if fromAccountDoor { accountDoor = nil } else { phase = .vault }
                await Task.yield()
                // Leaves with the door's momentum (already moving, then a long glide), not from a standstill.
                withAnimation(.timingCurve(0.22, 0.5, 0.12, 1, duration: DoorMotion.gateParting)) { gateApart = true }
                try? await Task.sleep(for: .seconds(DoorMotion.gateParting))
                gate = nil
            } else {
                // Login: its screen parts like a gate (RootView's transition).
                phase = .vault
                try? await Task.sleep(for: .seconds(0.85))
            }
            unlockOpening = false
            unlockOpenedAt = nil
            updateAccountDoor() // still focused on a locked account (another was unlocked): its door
            Bench.endAfterCommit(["unlock-password-open", "unlock-touchid-open"])
        }
    }

    /// The calm unlock (the default): the door stays put; the hub's field and Touch ID fade, then the gate's plates part
    /// top and bottom over the vault. From login, its screen parts the same way (RootView's transition).
    private func openGate(fromAccountDoor: Bool) {
        let fromLock = phase.id == Phase.locked.id || fromAccountDoor
        guard fromLock else {
            phase = .vault
            Bench.endAfterCommit(["unlock-password-open", "unlock-touchid-open"])
            return
        }
        withAnimation(.easeOut(duration: Self.gateFade)) { unlockOpening = true }
        Task {
            // The plates carry the door but not the hub's controls: those leave first, so nothing pops off.
            try? await Task.sleep(for: .seconds(Self.gateFade))
            gateApart = false
            gate = .opening
            try? await Task.sleep(for: .milliseconds(30)) // the plates draw over the lock screen before it goes
            if fromAccountDoor { accountDoor = nil } else { phase = .vault }
            await Task.yield()
            withAnimation(.timingCurve(0.45, 0, 0.15, 1, duration: Self.gateOpen)) { gateApart = true }
            try? await Task.sleep(for: .seconds(Self.gateOpen))
            gate = nil
            unlockOpening = false
            updateAccountDoor()
            Bench.endAfterCommit(["unlock-password-open", "unlock-touchid-open"])
        }
    }
    /// The lock screen's door as typed (pins lit, tumbler notches turned), so the calm gate's plates carry the same door.
    var doorDial = (typed: 0, turns: 0)
    /// The calm unlock's tempo: the hub's controls fade, then the plates part.
    static let gateFade = 0.2
    static let gateOpen = 0.6

    /// True for the moment between a successful unlock and the vault appearing (the lock-opening animation).
    var unlockOpening = false
    /// When the door started opening. Shared, so every copy of the door (the gate's two halves) runs the same moment.
    var unlockOpenedAt: Date?

    func setTouchID(_ enabled: Bool, for accountId: String) {
        guard let session = session(for: accountId) else { return }
        do { try session.setTouchID(enabled) } catch { flash(String(localized: "Couldn't turn on Touch ID")) }
        refreshAccounts()
    }

    // MARK: PIN

    func isPINEnabled(_ accountId: String) -> Bool {
        _ = pinRevision // observed, so views follow a change
        return AccountStore.isPINEnabled(accountId)
    }
    func isPINPersistent(_ accountId: String) -> Bool {
        _ = pinRevision
        return AccountStore.isPINPersistent(accountId)
    }
    /// Bumped when a PIN is set, moved or erased (AccountStore isn't observable).
    var pinRevision = 0

    /// Sets the PIN for an unlocked account; off with nil. It stretches the PIN with the account's KDF, so it's slow.
    func setPIN(_ pin: String?, persistent: Bool, for accountId: String) async -> Bool {
        guard let session = session(for: accountId) else { return false }
        let ok = await session.setPIN(pin, persistent: persistent)
        pinRevision += 1
        return ok
    }

    /// Turns the PIN off (works locked too: it only removes the sealed key).
    func disablePIN(for accountId: String) {
        AccountStore.disablePIN(accountId)
        pinRevision += 1
    }

    func setPINPersistent(_ persistent: Bool, for accountId: String) {
        AccountStore.setPINPersistent(persistent, accountId)
        pinRevision += 1
    }

    /// Unlocks one account with its PIN; a wrong one says how many tries are left, the fifth turns the PIN off.
    func unlockWithPIN(_ pin: String, accountId: String? = nil) async {
        guard let id = accountId ?? unlockTarget?.id else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        let result = await Task.detached(priority: .userInitiated) { AccountStore.unlockWithPIN(id, pin: pin) }.value
        switch result {
        case .unlocked(let key)?: finishUnlock([id: key])
        case .wrong(let left)?:
            errorMessage = String(localized: "Wrong PIN. ^[\(left) try](inflect: true) left.")
        case .erased?:
            pinRevision += 1
            errorMessage = String(localized: "Too many wrong PINs, so the PIN is off. Use your master password.")
        case nil:
            pinRevision += 1
            errorMessage = String(localized: "PIN unlock isn't set up any more. Use your master password.")
        }
    }

    // MARK: Trash

    /// Bitwarden's cloud empties the Trash after 30 days; Vaultwarden keeps items unless its admin set
    /// TRASH_AUTO_DELETE_DAYS (which the client can't see).
    static let cloudTrashDays = 30

    func isCloud(_ accountId: String) -> Bool {
        guard let kind = accounts.first(where: { $0.id == accountId })?.serverKind else { return false }
        return kind == "bitwardenUS" || kind == "bitwardenEU"
    }

    /// When the server will delete a trashed item for good, if we know: cloud accounts only.
    func purgeDate(_ item: VaultItem) -> Date? {
        guard item.isDeleted, isCloud(item.accountId), let deleted = item.deleted else { return nil }
        return Calendar.current.date(byAdding: .day, value: Self.cloudTrashDays, to: deleted)
    }

    /// Locks one account; the others stay open.
    func lock(_ accountId: String) {
        session(for: accountId)?.close()
        sessions.removeAll { $0.id == accountId }
        if accountFilter == accountId { accountFilter = nil }
        refreshAccounts()
        rebuild()
        if sessions.isEmpty { lock() }
    }

    // MARK: Editing

    enum NewItemKind {
        case login, secureNote, card, identity, sshKey
        init(_ kind: VaultItem.Kind) {
            switch kind { case .login: self = .login; case .note: self = .secureNote; case .card: self = .card
                          case .identity: self = .identity; case .sshKey: self = .sshKey }
        }
        var itemKind: VaultItem.Kind {
            switch self { case .login: .login; case .secureNote: .note; case .card: .card; case .identity: .identity; case .sshKey: .sshKey }
        }
        var editorKind: CipherEditor.Kind {
            switch self { case .login: .login; case .secureNote: .secureNote; case .card: .card; case .identity: .identity; case .sshKey: .sshKey }
        }
    }

    /// Where new items go: the filtered account, else the first unlocked one.
    var defaultAccountId: String? { accountFilter ?? sessions.first?.id }

    @discardableResult
    func createItem(_ kind: NewItemKind, edit: CipherEdit, accountId: String? = nil) async -> Bool {
        guard let session = (accountId ?? defaultAccountId).flatMap(session(for:)) else { return offline() }
        do {
            let id = try await session.create(kind.editorKind, edit: edit)
            selectedID = id
            arrivedID = id
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if arrivedID == id { arrivedID = nil }
            }
            flash(String(localized: "Item created"))
            return true
        } catch { return failed(error) }
    }

    private func session(for item: VaultItem) -> AccountSession? {
        session(for: item.accountId) ?? sessions.first { s in s.items.contains { $0.id == item.id } }
    }

    @discardableResult
    func updateItem(_ id: String, edit: CipherEdit) async -> Bool {
        guard let item = items.first(where: { $0.id == id }), let session = session(for: item) else { return offline() }
        do {
            try await session.update(id, edit: edit)
            return true
        } catch { return failed(error) }
    }

    /// Creates a folder ("Parent/Child" nests) in the filtered or first account.
    @discardableResult
    func createFolder(name: String, accountId: String? = nil) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let session = (accountId ?? defaultAccountId).flatMap(session(for:)) else { return nil }
        do {
            let id = try await session.createFolder(name: trimmed)
            flash(String(localized: "Folder created"))
            return id
        } catch { _ = failed(error); return nil }
    }

    /// Renames the folder at `path` (the last part of it) in every open account, and its subfolders with it: they
    /// nest by name ("Work/Servers"), so each one under it gets the new name too. Filters on it follow.
    @discardableResult
    func renameFolder(_ path: String, to newName: String) async -> Bool {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return false }
        let parent = path.split(separator: "/").dropLast().joined(separator: "/")
        let newPath = parent.isEmpty ? name : parent + "/" + name
        guard newPath != path else { return true }
        do {
            for session in sessions {
                var names: [String: String] = [:]
                for folder in session.folders where folder.name == path || folder.name.hasPrefix(path + "/") {
                    names[folder.id] = newPath + folder.name.dropFirst(path.count)
                }
                if !names.isEmpty { try await session.renameFolders(names) }
            }
        } catch { _ = failed(error); return false }
        if let f = searchFilters.folder, f == path || f.hasPrefix(path + "/") {
            searchFilters.folder = newPath + f.dropFirst(path.count)
        }
        renamedFolder = (path, newPath)
        flash(String(localized: "Folder renamed"))
        return true
    }

    func deleteFolder(_ id: String) async {
        guard let session = sessions.first(where: { $0.folders.contains { $0.id == id } }) else { return }
        do { try await session.deleteFolder(id) } catch { _ = failed(error) }
    }

    /// Moves items into a folder. A folder belongs to one account, so only that account's items move.
    func move(itemIDs: [String], toFolderIn folderIds: [String]) async {
        var moved: [VaultItem] = []
        for id in itemIDs {
            guard let item = items.first(where: { $0.id == id }), let session = session(for: item),
                  let folderId = folderIds.first(where: { fid in session.folders.contains { $0.id == fid } }),
                  item.folderId != folderId else { continue }
            do { try await session.update(id, edit: CipherEdit(folderId: .some(folderId))); moved.append(item) } catch { _ = failed(error); return }
        }
        if !moved.isEmpty {
            offerUndo(String(localized: "Moved \(moved.count) item(s)"), actionName: String(localized: "Move")) { [weak self] in
                await self?.moveBack(moved)
            }
        }
    }

    // MARK: Organizations and bulk edits

    /// Moves personal items into an organization's collections (one request each; the server needs every item
    /// re-encrypted with the organization key).
    func share(_ itemIDs: [String], organizationId: String, collectionIds: [String]) async -> Bool {
        var moved = 0
        for id in itemIDs {
            guard let item = items.first(where: { $0.id == id }), let session = session(for: item) else { continue }
            do {
                try await session.share(id, organizationId: organizationId, collectionIds: collectionIds)
                moved += 1
            } catch CipherEditor.ShareError.hasAttachments {
                flash(String(localized: "“\(item.name)” has an old-style attachment; move it from the web vault."))
                return false
            } catch {
                _ = failed(error); return false
            }
        }
        if moved > 0 {
            let org = organizations.first { $0.id == organizationId }?.name ?? ""
            flash(String(localized: "Moved \(moved) item(s) to \(org)"))
        }
        return true
    }

    func setCollections(_ item: VaultItem, collectionIds: [String]) async -> Bool {
        guard let session = session(for: item) else { return offline() }
        do {
            try await session.setCollections(item.id, collectionIds: collectionIds)
            flash(String(localized: "Shared folders updated"))
            return true
        } catch { return failed(error) }
    }

    /// The same action on many items, one request per account; shown at once and rolled back if it fails.
    func bulk(_ action: AccountSession.Bulk, _ itemIDs: [String], undoable: Bool = true) async {
        let chosen = items.filter { itemIDs.contains($0.id) }
        withAnimation(.snappy(duration: 0.3)) {
            switch action {
            case .trash: for i in items.indices where itemIDs.contains(items[i].id) { items[i].isDeleted = true }
            case .restore: for i in items.indices where itemIDs.contains(items[i].id) { items[i].isDeleted = false }
            case .archive: for i in items.indices where itemIDs.contains(items[i].id) { items[i].archived = .now }
            case .delete: items.removeAll { itemIDs.contains($0.id) }
            case .move: break
            }
            // Items that leave the current list take the selection with them (a move keeps them listed).
            var stays = false
            if case .move = action { stays = true }
            if !stays, let id = selectedID, itemIDs.contains(id) { selectedID = nil }
        }
        if sessions.isEmpty, previewUnlocked { return }
        do {
            for session in sessions {
                let ids = chosen.filter { $0.accountId == session.id }.map(\.id)
                if case .move(let folderId) = action {
                    // A folder belongs to one account; only that account's personal items move.
                    guard folderId == nil || session.folders.contains(where: { $0.id == folderId }) else { continue }
                    try await session.bulk(action, ids: chosen.filter { $0.accountId == session.id && $0.organizationId == nil }.map(\.id))
                } else {
                    try await session.bulk(action, ids: ids)
                }
            }
            let n = chosen.count
            let ids = chosen.map(\.id)
            switch action {
            case .trash where undoable:
                offerUndo(String(localized: "Moved \(n) item(s) to Trash"), actionName: String(localized: "Move to Trash")) { [weak self] in
                    await self?.bulk(.restore, ids, undoable: false)
                }
            case .trash: flash(String(localized: "Moved \(n) item(s) to Trash"))
            case .restore: flash(String(localized: "Restored \(n) item(s)"))
            case .delete: flash(String(localized: "Deleted \(n) item(s) permanently"))
            case .archive where undoable:
                offerUndo(String(localized: "Archived \(n) item(s)"), actionName: String(localized: "Archive")) { [weak self] in
                    await self?.unarchive(chosen)
                }
            case .archive: flash(String(localized: "Archived \(n) item(s)"))
            case .move where undoable:
                offerUndo(String(localized: "Moved \(n) item(s)"), actionName: String(localized: "Move")) { [weak self] in
                    await self?.moveBack(chosen)
                }
            case .move: flash(String(localized: "Moved \(n) item(s)"))
            }
        } catch {
            revert(); _ = failed(error)
        }
    }

    /// Takes items out of the archive (undoing a bulk archive; the server has no bulk unarchive).
    private func unarchive(_ chosen: [VaultItem]) async {
        for item in chosen { optimistic(item.id) { $0.archived = nil } }
        do {
            for item in chosen { try await session(for: item)?.unarchive(item.id) }
            flash(String(localized: "Moved \(chosen.count) item(s) out of the archive"))
        } catch { revert(); _ = failed(error) }
    }

    /// Puts moved items back in the folders they came from.
    private func moveBack(_ chosen: [VaultItem]) async {
        for (folderId, group) in Dictionary(grouping: chosen, by: \.folderId) {
            await bulk(.move(folderId: folderId), group.map(\.id), undoable: false)
        }
    }

    func confirmBulk(_ action: AccountSession.Bulk, _ itemIDs: [String], then done: @escaping () -> Void = {}) {
        let n = itemIDs.count
        switch action {
        case .trash:
            confirm(String(localized: "Move \(n) item(s) to Trash?"), message: String(localized: "You can restore them from Trash later."),
                    action: String(localized: "Move to Trash")) { [weak self] in await self?.bulk(.trash, itemIDs); done() }
        case .delete:
            confirm(String(localized: "Delete \(n) item(s) forever?"), message: String(localized: "This can't be undone."),
                    action: String(localized: "Delete Forever")) { [weak self] in await self?.bulk(.delete, itemIDs); done() }
        default:
            Task { await bulk(action, itemIDs); done() }
        }
    }

    func leaveOrganization(_ id: String) {
        guard let org = organizations.first(where: { $0.id == id }),
              let session = sessions.first(where: { $0.organizations.contains { $0.id == id } }) else { return }
        confirm(String(localized: "Leave “\(org.name)”?"),
                message: String(localized: "Its items leave this Mac. An admin has to invite you again to get them back."),
                action: String(localized: "Leave Shared Vault")) { [weak self] in
            do {
                try await session.leaveOrganization(id)
                if let self, let keys = self.vaultFilter.keys, keys.contains(id) {
                    self.vaultFilter = VaultFilter(keys: keys.subtracting([id]))
                }
                self?.flash(String(localized: "Left “\(org.name)”"))
            } catch { _ = self?.failed(error) }
        }
    }

    // MARK: Send

    func updateSend(_ send: SendItem, draft: SendDraft, removePassword: Bool) async -> Bool {
        guard let session = session(for: send.accountId) else { return offline() }
        do {
            try await session.updateSend(send, draft: draft, removePassword: removePassword)
            flash(String(localized: "Send updated — the link is the same"))
            return true
        } catch { return failed(error) }
    }

    func sendLink(_ send: SendItem) -> URL? {
        session(for: send.accountId)?.environment?.sendLink(accessId: send.accessId, keyMaterial: send.keyMaterial)
    }

    /// Creates a Send, copies its link and selects it.
    @discardableResult
    func createSend(_ draft: SendDraft, accountId: String?) async -> Bool {
        guard let session = accountId.flatMap({ session(for: $0) }) ?? sessions.first else { return offline() }
        do {
            let link = try await session.createSend(draft)
            if let link { copyPlain(link.absoluteString) }
            selectedSendID = sends.first { $0.name == draft.name && link?.absoluteString.contains($0.accessId) == true }?.id
            flash(String(localized: "Send created — link copied"))
            return true
        } catch { return failed(error) }
    }

    func deleteSend(_ send: SendItem) async {
        guard let session = session(for: send.accountId) else { _ = offline(); return }
        withAnimation(.snappy(duration: 0.3)) {
            sends.removeAll { $0.id == send.id }
            if selectedSendID == send.id { selectedSendID = nil }
        }
        do {
            try await session.deleteSend(send.id)
            flash(String(localized: "Deleted “\(send.name)”"))
        } catch { revert(); _ = failed(error) }
    }

    // MARK: Attachments

    /// Decrypted copy being previewed with Quick Look; deleted when the preview closes or on lock.
    var previewURL: URL?
    var attachmentBusy: Set<String> = []
    /// Bitwarden's per-file limit; also keeps the whole file comfortably in memory.
    static let attachmentLimit = 500 * 1_024 * 1_024

    func previewAttachment(_ attachment: VaultItem.Attachment, of item: VaultItem) async {
        guard let data = await attachmentContents(attachment, of: item) else { return }
        do { previewURL = try AttachmentFiles.write(data, named: attachment.fileName) } catch { _ = failed(error) }
    }

    func saveAttachment(_ attachment: VaultItem.Attachment, of item: VaultItem) async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.fileName
        guard panel.runModal() == .OK, let url = panel.url,
              let data = await attachmentContents(attachment, of: item) else { return }
        do {
            try data.write(to: url, options: .atomic)
            flash(String(localized: "Saved “\(attachment.fileName)”"))
        } catch { _ = failed(error) }
    }

    private func attachmentContents(_ attachment: VaultItem.Attachment, of item: VaultItem) async -> Data? {
        guard let session = session(for: item) else { _ = offline(); return nil }
        attachmentBusy.insert(attachment.id)
        defer { attachmentBusy.remove(attachment.id) }
        noteActivity()
        do { return try await session.attachmentContents(item.id, attachment) } catch { _ = failed(error); return nil }
    }

    @discardableResult
    func addAttachments(_ urls: [URL], to item: VaultItem) async -> Bool {
        guard let session = session(for: item) else { return offline() }
        attachmentBusy.insert(item.id)
        defer { attachmentBusy.remove(item.id) }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= Self.attachmentLimit else {
                    flash(String(localized: "“\(url.lastPathComponent)” is larger than 500 MB."))
                    continue
                }
                try await session.addAttachment(item.id, name: url.lastPathComponent, contents: Data(contentsOf: url))
                flash(String(localized: "Attached “\(url.lastPathComponent)”"))
            } catch { return failed(error) }
        }
        return true
    }

    func deleteAttachment(_ attachment: VaultItem.Attachment, of item: VaultItem) async {
        guard let session = session(for: item) else { _ = offline(); return }
        do {
            try await session.deleteAttachment(item.id, attachment.id)
            flash(String(localized: "Deleted “\(attachment.fileName)”"))
        } catch { _ = failed(error) }
    }

    /// Shows a change at once, with animation, while the server catches up; the next rebuild (after the server's
    /// answer) replaces it with the real state, or puts it back if the write failed.
    private func optimistic(_ id: String, _ change: (inout VaultItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.snappy(duration: 0.3)) { change(&items[i]) }
    }

    private func optimisticRemove(_ id: String) {
        withAnimation(.snappy(duration: 0.3)) {
            items.removeAll { $0.id == id }
            if selectedID == id { selectedID = nil }
        }
    }

    func toggleFavorite(_ item: VaultItem) async {
        optimistic(item.id) { $0.favorite.toggle() }
        // `--demo` / previews have no server: the change above is all there is.
        if sessions.isEmpty, previewUnlocked { return }
        if !(await updateItem(item.id, edit: CipherEdit(favorite: !item.favorite))) { revert() }
    }

    func trash(_ item: VaultItem) async {
        if sessions.isEmpty, previewUnlocked { // demo vault: no server
            optimistic(item.id) { $0.isDeleted = true }
            offerUndo(String(localized: "Moved “\(item.name)” to Trash"), actionName: String(localized: "Move to Trash")) { [weak self] in
                self?.optimistic(item.id) { $0.isDeleted = false }
            }
            return
        }
        guard let session = session(for: item) else { _ = offline(); return }
        optimistic(item.id) { $0.isDeleted = true }
        do {
            try await session.trash(item.id)
            offerUndo(String(localized: "Moved “\(item.name)” to Trash"), actionName: String(localized: "Move to Trash")) { [weak self] in
                await self?.restore(item)
            }
        } catch { revert(); _ = failed(error) }
    }

    func restore(_ item: VaultItem) async {
        guard let session = session(for: item) else { _ = offline(); return }
        optimistic(item.id) { $0.isDeleted = false }
        do {
            try await session.restore(item.id)
            flash(String(localized: "Restored"))
        } catch { revert(); _ = failed(error) }
    }

    /// Back to what the accounts hold, after a write that didn't go through.
    private func revert() { withAnimation(.snappy(duration: 0.3)) { rebuild() } }

    /// Archive: keep the item, but out of the lists, search and AutoFill. Unarchive brings it back.
    func setArchived(_ item: VaultItem, _ archived: Bool) async {
        if sessions.isEmpty, previewUnlocked, let i = items.firstIndex(where: { $0.id == item.id }) {
            withAnimation(.snappy(duration: 0.3)) { items[i].archived = archived ? .now : nil } // demo vault: no server
            return
        }
        guard let session = session(for: item) else { _ = offline(); return }
        optimistic(item.id) { $0.archived = archived ? .now : nil }
        do {
            if archived { try await session.archive(item.id) } else { try await session.unarchive(item.id) }
            if archived {
                offerUndo(String(localized: "Archived “\(item.name)”"), actionName: String(localized: "Archive")) { [weak self] in
                    await self?.setArchived(item, false)
                }
            } else {
                flash(String(localized: "Moved out of the archive"))
            }
        } catch {
            // Older servers (Vaultwarden before 1.36) don't know the endpoint; Bitwarden's cloud needs a paid plan.
            revert()
            if case APIError.http(let status, _)? = error as? APIError, status == 404 || status == 405 {
                flash(String(localized: "This server doesn't support archiving yet."))
            } else {
                _ = failed(error)
            }
        }
    }

    func deleteForever(_ item: VaultItem) async {
        guard let session = session(for: item) else { _ = offline(); return }
        optimisticRemove(item.id)
        do {
            try await session.deleteForever(item.id)
            flash(String(localized: "Deleted permanently"))
        } catch { revert(); _ = failed(error) }
    }

    private func offline() -> Bool {
        flash(String(localized: "You're offline — changes need a connection to your server."))
        return false
    }

    private func failed(_ error: Error) -> Bool {
        if error is AccountSession.WriteError { return offline() }
        if case .http(let status, let message)? = error as? APIError {
            flash(message ?? String(localized: "Server error (\(status))."))
        } else {
            flash(error.localizedDescription)
        }
        return false
    }

    func flash(_ message: String, action: ToastAction? = nil) {
        toast = message
        toastAction = action
        toastTask?.cancel()
        toastTask = Task {
            // Long enough to reach the button.
            try? await Task.sleep(for: .seconds(action == nil ? 2.2 : 5))
            if !Task.isCancelled { toast = nil; toastAction = nil }
        }
    }

    // MARK: Undo

    /// The last change that can be taken back. One at a time, like the toast that offers it.
    @ObservationIgnored private var pendingUndo: (@MainActor () async -> Void)?
    private var undoManager: UndoManager? { NSApp.windows.first { $0.canBecomeMain }?.undoManager }

    /// Offers to take a change back: a button on the toast, and Edit › Undo (⌘Z).
    private func offerUndo(_ message: String, actionName: String, undo: @escaping @MainActor () async -> Void) {
        pendingUndo = undo
        if let manager = undoManager {
            manager.registerUndo(withTarget: self) { model in MainActor.assumeIsolated { model.performUndo() } }
            manager.setActionName(actionName)
        }
        flash(message, action: ToastAction(title: String(localized: "Undo")) { [weak self] in
            guard let self else { return }
            if let manager = undoManager, manager.canUndo, manager.undoActionName == actionName { manager.undo() } else { performUndo() }
        })
    }

    private func performUndo() {
        guard let undo = pendingUndo else { return }
        pendingUndo = nil
        toast = nil
        toastAction = nil
        Task { await undo() }
    }

    private func forgetUndo() {
        pendingUndo = nil
        undoManager?.removeAllActions(withTarget: self)
    }

    // MARK: Auto-lock

    private var lastActivity = Date()
    private var monitors: [Any] = []
    private var autoLockTimer: Timer?

    func noteActivity() { lastActivity = .now }

    // MARK: Timeout, per account

    /// What inactivity does to an account: lock it, or log it out (erase it from this Mac).
    enum TimeoutAction: String, CaseIterable { case lock, logOut }

    /// An account's own inactivity minutes, or nil to follow Settings › Security (0 = never).
    func ownAutoLockMinutes(_ accountId: String) -> Int? {
        _ = timeoutRevision
        return UserDefaults.standard.object(forKey: "autoLock." + accountId) as? Int
    }
    func setOwnAutoLockMinutes(_ minutes: Int?, _ accountId: String) {
        UserDefaults.standard.set(minutes, forKey: "autoLock." + accountId)
        timeoutRevision += 1
    }
    func ownTimeoutAction(_ accountId: String) -> TimeoutAction? {
        _ = timeoutRevision
        return UserDefaults.standard.string(forKey: "timeoutAction." + accountId).flatMap(TimeoutAction.init)
    }
    func setOwnTimeoutAction(_ action: TimeoutAction?, _ accountId: String) {
        UserDefaults.standard.set(action?.rawValue, forKey: "timeoutAction." + accountId)
        timeoutRevision += 1
    }
    /// Bumped when an account's timeout changes (UserDefaults isn't observable).
    var timeoutRevision = 0

    func autoLockMinutes(for accountId: String) -> Int {
        ownAutoLockMinutes(accountId) ?? UserDefaults.standard.integer(forKey: Pref.autoLockMinutes)
    }
    func timeoutAction(for accountId: String) -> TimeoutAction {
        ownTimeoutAction(accountId) ?? TimeoutAction(rawValue: UserDefaults.standard.string(forKey: Pref.timeoutAction) ?? "") ?? .lock
    }

    /// Each open account whose inactivity time has run out is locked or logged out, by its own setting.
    /// `idle` overrides the time since the last activity (self-test).
    func applyTimeouts(idle: TimeInterval? = nil) {
        let idle = idle ?? Date.now.timeIntervalSince(lastActivity)
        for session in sessions {
            let id = session.id
            let minutes = autoLockMinutes(for: id)
            guard minutes > 0, idle > Double(minutes) * 60 else { continue }
            switch timeoutAction(for: id) {
            case .lock: lock(id)
            case .logOut: logOut(id)
            }
        }
    }

    /// Locks after inactivity and on sleep / screen lock, per Settings.
    func startAutoLock() {
        guard monitors.isEmpty else { return }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .scrollWheel, .mouseMoved], handler: { [weak self] e in
            self?.noteActivity(); return e
        }) { monitors.append(m) }
        // Hold ⌥ to reveal masked fields (only ⌥, so ⌥-shortcuts don't flash secrets).
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] e in
            let flags = e.modifierFlags.intersection([.shift, .control, .option, .command])
            self?.optionHeld = flags == .option
            return e
        }) { monitors.append(m) }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            monitors.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lockIfConfiguredOnSleep() }
            })
        }
        monitors.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockIfConfiguredOnSleep() }
        })
        autoLockTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isUnlocked else { return }
                self.applyTimeouts()
            }
        }
    }

    private func lockIfConfiguredOnSleep() {
        if isUnlocked, UserDefaults.standard.bool(forKey: Pref.lockOnSleep) { lock() }
    }

    /// Locks every account. `animated` (a lock the user asked for): the keys go at once, but the vault's contents stay
    /// on screen a moment longer, so the door can close over them before they're cleared.
    func lock(animated: Bool = false) {
        accountDoor = nil
        previewURL = nil
        forgetUndo()
        LargeType.close()
        generatorHistory = []
        AttachmentFiles.wipe()
        sshAgent?.reset()
        cli?.reset()
        breachCounts = nil
        breachesCheckedAt = nil
        sessions.forEach { $0.close() }
        sessions = []
        refreshAccounts()
        addingAccount = false
        let tooling = CommandLine.arguments.contains { $0.hasPrefix("--selftest") || $0 == "--snapshot" }
        let closing = animated && phase.id == Phase.vault.id && !accounts.isEmpty && !tooling && Self.gateAnimates
        guard closing else {
            phase = accounts.isEmpty ? .login : .locked
            clearVaultContents()
            return
        }
        // The gate's plates slide in over the vault (GatePlates, ~0.6 s). Once they meet, the lock screen is put in
        // place underneath and the plates go; with the full door animation, the door then assembles (~1.2 s, from
        // lockClosedAt), otherwise the hub's controls just fade in (UnlockView).
        let assembles = Self.doorAnimates
        doorDial = (0, 0) // the lock screen comes back with an empty field
        lockClosedAt = assembles ? .now.addingTimeInterval(Self.gateClose) : nil
        lockClosing = true
        gateApart = true
        gate = .closing
        Task {
            await Task.yield() // the plates are drawn apart first, then close
            withAnimation(.easeInOut(duration: Self.gateClose)) { gateApart = false }
            try? await Task.sleep(for: .seconds(Self.gateClose))
            phase = .locked
            try? await Task.sleep(for: .milliseconds(60)) // the lock screen draws under the plates before they go
            gate = nil
            if sessions.isEmpty { clearVaultContents() } // covered now; unless Touch ID already opened it again
            try? await Task.sleep(for: .seconds(assembles ? 1.3 : 0.3))
            lockClosing = false
            lockClosedAt = nil
        }
    }

    /// The gate's plates sliding apart and together on unlock and lock: off with Reduce Motion (the lock screen fades).
    static var gateAnimates: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The vault door's open/close sequences before and after the gate: opt-in, Settings › Security › Full vault-door
    /// animation (and never with Reduce Motion).
    static var doorAnimates: Bool { gateAnimates && UserDefaults.standard.bool(forKey: Pref.fullDoorAnimation) }

    /// True while the lock layer closes over the vault (an animated lock).
    var lockClosing = false

    /// The gate between the vault and the lock screen: two plates over everything while they move.
    enum GateMotion { case closing, opening }
    var gate: GateMotion?
    /// The plates' position: apart (off the window) or meeting in the middle. Animated.
    var gateApart = false
    /// When the door starts assembling (just after the gate has closed). Shared by every copy of the door.
    var lockClosedAt: Date?
    /// How long the gate takes to close over the vault when locking.
    static let gateClose = 0.6

    private func clearVaultContents() {
        selectedID = nil
        repromptPassed = [:]
        repromptRequest = nil
        accountFilter = nil
        items = []
        sends = []
        selectedSendID = nil
        folders = []
        organizations = []
    }

    func cancelChallenge() {
        errorMessage = nil
        pendingSSO = nil
        phase = .login
    }

    var serverDisplayName: String {
        sessions.count > 1 ? String(localized: "\(sessions.count) accounts") : (sessions.first?.account.serverSummary ?? "")
    }

    private func handle(_ error: Error) {
        switch error as? APIError {
        case .twoFactorRequired(let providers)?:
            phase = .twoFactor(providers: providers)
        case .newDeviceVerificationRequired?:
            phase = .deviceVerification
        case .captchaRequired?:
            errorMessage = String(localized: "Bitwarden asked for a captcha. Log in once at vault.bitwarden.com from this network, then try again.")
        case .crypto(.unsupported)?:
            errorMessage = String(localized: "This account uses Argon2id, which isn't supported yet.")
        case .crypto(.kdfOutOfBounds)?:
            errorMessage = String(localized: "The server sent unsafe key-derivation settings. Login was stopped.")
        case .crypto?:
            errorMessage = String(localized: "Wrong email or master password.")
        case .http(let status, let message)?:
            errorMessage = message ?? String(localized: "Server error (\(status)).")
        default:
            errorMessage = error.localizedDescription
        }
    }
}

/// A clipboard value handed out on request, so Triwarden learns when it's pasted (`AppModel.copyPassword`).
final class PastePromise: NSObject, NSPasteboardItemDataProvider {
    private let value: String
    private var onPaste: (() -> Void)?

    init(value: String, onPaste: @escaping () -> Void) {
        self.value = value
        self.onPaste = onPaste
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        item.setString(value, forType: type)
        let run = onPaste
        onPaste = nil
        run?()
    }
}
