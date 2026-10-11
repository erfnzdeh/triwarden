import AppKit
import TriCrypto
import SwiftUI

/// The menu bar panel: search right here, your favorites, codes and recent items one click from the clipboard,
/// quick actions into the app, a fresh password, the SSH agent, and sync / Watchtower at a glance. Same cards, capsules and type as the main window.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @FocusState private var searching: Bool

    /// The account in focus (from the switcher) is open; with none in focus, any is.
    private var focusedOpen: Bool { model.focusedAccountID.map(model.isUnlocked) ?? true }

    var body: some View {
        VStack(spacing: 8) {
            if let pending = model.sshAgent.pending {
                SSHApprovalCard(prompt: pending, leadsWithUntilLock: model.sshAgent.pendingLeadsWithUntilLock) { choice in
                    model.sshAgent.choose(choice)
                }
            }
            topRow
            if model.isUnlocked, focusedOpen {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    FrontTabMatchPrompt()
                    SiteCard()
                    ShelfCard()
                    QuickActions()
                    GeneratorCard()
                    SSHRow()
                } else {
                    SearchResults(query: query)
                }
            } else {
                LockedCard(account: model.focusedAccountID.flatMap { id in model.accounts.first { $0.id == id } })
            }
            footer
        }
        .padding(10)
        .frame(width: 380)
        // Light: a soft grey wash over the system's near-white glass, so the white cards have something to stand on.
        .background(Color.menuWash)
        .onAppear {
            MenuBarOpener.isOpen = true
            model.captureForeground()
        }
        .onDisappear { MenuBarOpener.isOpen = false }
        .animation(.snappy(duration: 0.22), value: query.isEmpty)
    }

    private var topRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                TextField("Search vault", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searching)
                    .disabled(!model.isUnlocked)
                    .onSubmit {
                        // Return fills the top login into the app the panel was opened over, else copies its password.
                        guard let first = SearchResults.matches(model.focusedItems, query).first else { return }
                        if QuickCopy.canFill(first, model) { QuickCopy.fill(first, model) } else { QuickCopy.primary(first, model) }
                    }
                if query.isEmpty {
                    Button {
                        NSApp.keyWindow?.orderOut(nil) // the palette takes the panel's place
                        DispatchQueue.main.async { model.openPalette() }
                    } label: {
                        ShortcutKeycaps(keys: Shortcut.current(for: .palette)?.parts ?? ["⌘", "K"])
                    }
                    .buttonStyle(.plain)
                    .help(Text("Open the command palette"))
                } else {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Clear"))
                }
            }
            .padding(.horizontal, 12).frame(height: 36)
            .background(Color.menuCard, in: .capsule)
            .overlay(Capsule().strokeBorder(searching ? Color.primary.opacity(0.3) : Color.menuEdge, lineWidth: searching ? 1.5 : 1))
            .animation(.easeOut(duration: 0.15), value: searching)

            if model.accounts.count > 1 { AccountMenu() }
            if model.isUnlocked {
                CircleButton(symbol: "lock", help: "Lock Vault") { model.lock(animated: true) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(model.isOnline ? Color.green : Color.secondary).frame(width: 7, height: 7)
            Group {
                if model.isSyncing {
                    Text("Syncing…")
                } else if let synced = model.lastSynced {
                    Text("Synced \(synced.formatted(.relative(presentation: .named)))")
                } else {
                    Text(model.isUnlocked ? "Offline · saved vault" : "Locked")
                }
            }
            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            .help(Text(verbatim: model.serverDisplayName))
            if model.isUnlocked {
                FooterButton(symbol: "arrow.triangle.2.circlepath", help: "Sync Now", spinning: model.isSyncing) {
                    Task { try? await model.refresh() }
                }
                .disabled(model.isSyncing)
            }
            Spacer()
            FooterButton(symbol: "macwindow", help: "Open Triwarden") { model.bringToFront() }
            FooterButton(symbol: "gearshape", help: "Settings…") { model.showSettings() }
            FooterButton(symbol: "power", help: "Quit Triwarden") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 6)
    }
}

/// A shortcut as keycaps, one per key (⇧ ⌘ Space), like the palette's hints; it brightens on hover.
private struct ShortcutKeycaps: View {
    let keys: [String]
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(verbatim: key)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(hovering ? .primary : .secondary)
                    .padding(.horizontal, key.count > 1 ? 6 : 0)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Color.primary.opacity(scheme == .dark ? (hovering ? 0.16 : 0.10) : (hovering ? 0.10 : 0.06)),
                                in: .rect(cornerRadius: 5, style: .continuous))
                    .fixedSize()
            }
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// What a click copies (or fills), and how the panel says so.
enum QuickCopy {
    /// A login, and an app or page to type it into.
    @MainActor static func canFill(_ item: VaultItem, _ model: AppModel) -> Bool {
        model.foreground != nil && item.kind == .login && (item.username != nil || item.password != nil)
    }

    /// Closes the panel and types the login into the app it was opened over.
    @MainActor static func fill(_ item: VaultItem, _ model: AppModel) {
        guard let context = model.foreground else { return }
        NSApp.keyWindow?.orderOut(nil)
        model.fillLogin(item, into: context)
    }

    /// The most useful secret: the password, else the code, else the username.
    @MainActor static func primary(_ item: VaultItem, _ model: AppModel) {
        if item.password != nil { model.copyPassword(item) }
        else if let totp = item.totp { model.guarded(item) { model.copy(totp.code(), label: String(localized: "Code")) } }
        else if let username = item.username { model.copy(username, label: String(localized: "Username")) }
    }
}

/// A card on the panel: the window's raised surface.
private struct PanelCard<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.menuCard, in: .rect(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.menuEdge))
            .shadow(color: .menuShadow, radius: 5, y: 1)
    }
}

private struct CircleButton: View {
    let symbol: String
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .frame(width: 36, height: 36)
                .background(Color.menuCard, in: .circle)
                .overlay(Circle().strokeBorder(Color.menuEdge))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(Text(help))
        .accessibilityLabel(Text(help))
    }
}

private struct FooterButton: View {
    let symbol: String
    let help: LocalizedStringKey
    var spinning = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .symbolEffect(.rotate, isActive: spinning)
                .frame(width: 26, height: 26).contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(Text(help))
        .accessibilityLabel(Text(help))
    }
}

/// A small icon button that copies, and flashes a check.
private struct CopyIcon: View {
    let symbol: String
    let help: LocalizedStringKey
    let action: () -> Void
    @State private var done = false

    var body: some View {
        Button {
            action()
            withAnimation(.snappy) { done = true }
            Task { try? await Task.sleep(for: .seconds(1.2)); withAnimation(.snappy) { done = false } }
        } label: {
            Image(systemName: done ? "checkmark" : symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(done ? Color.primary : .secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.06), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(Text(help))
        .accessibilityLabel(Text(help))
    }
}


/// The logins for the page (or app) the panel was opened over; a click types it in there.
private struct SiteCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let context = model.foreground {
            let focus = model.focusedAccountID
            let items = context.items(in: model).filter { focus == nil || $0.accountId == focus }
            if !items.isEmpty {
                PanelCard(padding: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if let icon = NSRunningApplication(processIdentifier: context.pid)?.icon {
                                Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                            }
                            Text(context.host != nil ? "On \(context.label)" : "For \(context.label)")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Text("Click to fill").font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 8).padding(.top, 2)
                        VStack(spacing: 0) {
                            ForEach(items) { item in
                                QuickRow(item: item, fillsOnClick: true)
                            }
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// Favorites, codes and recently changed items, a tab each; a click copies, hover shows the rest.
private struct ShelfCard: View {
    enum Tab: Hashable { case favorites, codes, recent }
    @Environment(AppModel.self) private var model
    @AppStorage("menuBarShelf") private var tabRaw = "codes"

    private var tab: Binding<Tab> {
        Binding(get: { switch tabRaw { case "favorites": .favorites; case "recent": .recent; default: .codes } },
                set: { tabRaw = switch $0 { case .favorites: "favorites"; case .recent: "recent"; case .codes: "codes" } })
    }

    private var items: [VaultItem] {
        let live = model.focusedItems.filter { !$0.isDeleted && !$0.isArchived }
        switch tab.wrappedValue {
        case .favorites: return Array(live.filter(\.favorite).prefix(6))
        case .codes: return Array(live.filter { $0.totp != nil }.prefix(6))
        case .recent: return Array(live.sorted { ($0.revised ?? .distantPast) > ($1.revised ?? .distantPast) }.prefix(6))
        }
    }

    var body: some View {
        PanelCard(padding: 8) {
            VStack(spacing: 6) {
                AppSegmented(options: [(Tab.favorites, LocalizedStringKey("Favorites")), (.codes, "Codes"), (.recent, "Recent")],
                             selection: tab)
                if items.isEmpty {
                    Text(tab.wrappedValue == .favorites ? "Star items to keep them here." : tab.wrappedValue == .codes
                         ? "Add a code secret to a login to see it here." : "Nothing yet.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 64)
                } else {
                    VStack(spacing: 0) {
                        ForEach(items) { item in
                            QuickRow(item: item, preferCode: tab.wrappedValue == .codes)
                        }
                    }
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: tabRaw)
    }
}

/// One item: icon and name; its code when it has one; copy buttons on hover. A click copies the main thing.
private struct QuickRow: View {
    @Environment(AppModel.self) private var model
    let item: VaultItem
    var preferCode = false
    /// A click types the login into the app the panel was opened over (the site card), rather than copying.
    var fillsOnClick = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ItemIcon(item: item, size: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let username = item.username, !preferCode || item.totp == nil {
                    Text(verbatim: username).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if hovering {
                HStack(spacing: 4) {
                    if QuickCopy.canFill(item, model), !fillsOnClick, let context = model.foreground {
                        CopyIcon(symbol: "keyboard", help: "Fill into \(context.app)") { QuickCopy.fill(item, model) }
                    }
                    if let username = item.username {
                        CopyIcon(symbol: "person", help: "Copy Username") { model.copy(username, label: String(localized: "Username")) }
                    }
                    if let password = item.password {
                        CopyIcon(symbol: "key", help: "Copy Password") { model.copyPassword(item) }
                    }
                    if let host = item.host, let url = URL(string: "https://\(host)") {
                        CopyIcon(symbol: "arrow.up.right", help: "Open Website") { NSWorkspace.shared.open(url) }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            if let totp = item.totp {
                Button { model.guarded(item) { model.copy(totp.code(), label: String(localized: "Code")) } } label: {
                    // On the app's shared clock: only the code and ring refresh, never the list around them.
                    HStack(spacing: 8) {
                        LiveOTPCode(totp: totp, size: 14)
                        LiveCountdownRing(totp: totp, size: 22)
                    }
                    .fixedSize() // the code keeps its width; the name truncates instead
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(Text("Copy code"))
            }
        }
        .padding(.horizontal, 8).frame(height: 44)
        .background(hovering ? Color.primary.opacity(0.05) : .clear, in: .rect(cornerRadius: 11, style: .continuous))
        .contentShape(.rect)
        .onTapGesture {
            if fillsOnClick, QuickCopy.canFill(item, model) {
                QuickCopy.fill(item, model)
            } else if preferCode, let totp = item.totp {
                model.guarded(item) { model.copy(totp.code(), label: String(localized: "Code")) }
            } else {
                QuickCopy.primary(item, model)
            }
        }
        .onHover { inside in withAnimation(.snappy(duration: 0.15)) { hovering = inside } }
        .contextMenu { ItemContextMenu(item: item) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: item.name))
    }
}

/// Typing in the panel's search: the best matches, each a click from the clipboard.
private struct SearchResults: View {
    @Environment(AppModel.self) private var model
    let query: String

    /// Ranked like the command palette (name, word, website, username, then loose matches).
    static func matches(_ items: [VaultItem], _ query: String) -> [VaultItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return Array(PaletteRank.rank(items.filter { !$0.isDeleted && !$0.isArchived }, q, recents: PaletteRecents.ids).prefix(8))
    }

    var body: some View {
        let results = Self.matches(model.focusedItems, query)
        PanelCard(padding: 8) {
            if results.isEmpty {
                Text("No results").font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 64)
            } else {
                VStack(spacing: 0) {
                    ForEach(results) { QuickRow(item: $0) }
                    Text(model.foreground != nil && results.first.map { QuickCopy.canFill($0, model) } == true
                         ? "Return fills the first login · hover for more" : "Return copies the first password · hover for more")
                        .font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 6)
                }
            }
        }
        .transition(.opacity)
    }
}

/// Into the app, straight to the thing: new login, new Send, the generator, Watchtower.
private struct QuickActions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            tile("plus", "New Login") {
                model.bringToFront()
                model.beginEditing(EditRequest(mode: .create(.login)))
            }
            tile("paperplane", "New Send") {
                model.bringToFront()
                model.requestedSection = .sends
                model.composingSend = true
            }
            tile("clock.badge.checkmark", "Codes") {
                model.bringToFront()
                model.requestedSection = .codes
            }
            tile("checkmark.shield", "Watchtower", badge: model.watchtowerIssueCount) {
                model.bringToFront()
                model.requestedSection = .watchtower
            }
        }
    }

    private func tile(_ symbol: String, _ title: LocalizedStringKey, badge: Int = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(.primary)
                    .frame(height: 18)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            Text(verbatim: "\(badge)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15)
                                .background(Color.orange, in: .capsule)
                                .fixedSize() // its own width: laid out in the icon's, "56" came out as "5…"
                                .offset(x: 12, y: -7)
                        }
                    }
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity).frame(height: 58)
            .background(Color.menuCard, in: .rect(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.menuEdge))
            .shadow(color: .menuShadow, radius: 5, y: 1)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityValue(badge > 0 ? Text("^[\(badge) issue](inflect: true)") : Text(verbatim: ""))
    }
}

/// A fresh password or passphrase: switch the kind, regenerate, copy.
private struct GeneratorCard: View {
    enum Kind: Hashable { case password, passphrase }
    @Environment(AppModel.self) private var model
    @AppStorage("menuBarGeneratorKind") private var passphrase = false
    @State private var value = PasswordGenerator.saved.generate()

    var body: some View {
        PanelCard(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Generator").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    AppSegmented(options: [(false, LocalizedStringKey("Password")), (true, "Passphrase")], selection: $passphrase)
                        .frame(width: 200)
                        .controlSize(.small)
                }
                HStack(spacing: 6) {
                    Text(verbatim: value)
                        .font(.system(size: 13, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                        .contentTransition(.opacity)
                    Spacer(minLength: 4)
                    CopyIcon(symbol: "arrow.clockwise", help: "Regenerate password") { regenerate() }
                    CopyIcon(symbol: "doc.on.doc", help: "Copy generated password") {
                        model.copy(value, label: String(localized: "Password"))
                    }
                }
                StrengthMeter(password: value)
            }
        }
        .onChange(of: passphrase) { regenerate() }
        .onAppear { regenerate() }
    }

    private func regenerate() {
        withAnimation(.snappy) { value = passphrase ? PassphraseGenerator().generate() : PasswordGenerator.saved.generate() }
    }
}

/// SSH agent status: on or off, how many keys, the last request.
private struct SSHRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let agent = model.sshAgent!
        let keys = model.items.filter { $0.kind == .sshKey && !$0.isDeleted && !$0.isArchived }.count
        if agent.isRunning || keys > 0 {
            PanelCard(padding: 12) {
                HStack(spacing: 10) {
                        Image(systemName: "terminal").font(.system(size: 14, weight: .medium))
                            .foregroundStyle(agent.isRunning ? Color.green : .secondary)
                            .frame(width: 30, height: 30)
                            .background((agent.isRunning ? Color.green : Color.primary).opacity(0.1), in: .rect(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("SSH agent").font(.system(size: 13, weight: .semibold))
                            Group {
                                if !agent.isRunning {
                                    Text("Off · ^[\(keys) key](inflect: true) in the vault")
                                } else if let last = agent.recent.first {
                                    Text("^[\(keys) key](inflect: true) · \(last.program) used \(last.key) \(last.date.formatted(.relative(presentation: .named)))")
                                } else {
                                    Text("^[\(keys) key](inflect: true) ready")
                                }
                            }
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(agent.isRunning ? "On" : "Off")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(agent.isRunning ? Color.green : .secondary)
                            .padding(.horizontal, 8).frame(height: 20)
                            .background((agent.isRunning ? Color.green : Color.primary).opacity(0.1), in: .capsule)
                }
            }
        }
    }
}

private struct LockedCard: View {
    @Environment(AppModel.self) private var model
    /// The account in focus, when it's the one that's locked (others may be open).
    var account: SavedAccount?

    var body: some View {
        PanelCard {
            VStack(spacing: 10) {
                if let account {
                    AccountAvatar(account: account, size: 44, showsLock: true)
                    Text(verbatim: account.email).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                } else {
                    Image(systemName: "lock.fill").font(.system(size: 20)).foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 12, style: .continuous))
                    Text("Vault locked").font(.system(size: 14, weight: .semibold))
                }
                Button("Unlock…") { model.bringToFront() }
                    .buttonStyle(.appPrimarySmall)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }
}

/// Which account the panel shows: its avatar (or the accounts together) as a round button; the menu switches, like
/// the vault window's account switcher (the two stay in step).
private struct AccountMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let focused = model.focusedAccountID.flatMap { id in model.accounts.first { $0.id == id } }
        Menu {
            Button {
                model.accountFocus = nil
            } label: {
                if focused == nil { Label("All accounts", systemImage: "checkmark") } else { Text("All accounts") }
            }
            Divider()
            ForEach(model.accounts) { account in
                let title = model.isUnlocked(account.id) ? account.email : String(localized: "\(account.email) — Locked")
                Button {
                    model.accountFocus = account.id
                } label: {
                    if focused?.id == account.id { Label(title, systemImage: "checkmark") } else { Text(verbatim: title) }
                }
            }
            Divider()
            Button("Add Account…") {
                NSApp.keyWindow?.orderOut(nil)
                model.beginAddAccount()
                model.bringToFront()
            }
        } label: {
            Group {
                if let focused {
                    AccountAvatar(account: focused, size: 26, showsLock: true)
                } else {
                    AccountAvatarStack(accounts: model.accounts, size: 20)
                }
            }
            .frame(minWidth: 36, minHeight: 36)
            .padding(.horizontal, focused == nil ? 6 : 0)
            .background(Color.menuCard, in: .capsule)
            .overlay(Capsule().strokeBorder(Color.menuEdge))
            .contentShape(.capsule)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text(focused?.email ?? String(localized: "All accounts")))
        .accessibilityLabel(Text("Accounts"))
        .accessibilityValue(Text(verbatim: focused?.email ?? String(localized: "All accounts")))
    }
}

/// Menu bar glyph: a compact vault dial. A fine bezel and three rings share their opening at six o'clock, below the
/// keyhole. It remains legible at menu-bar size without the visual noise of the full application icon. A template image.
/// `pending` adds a filled mark at the top trailing while an SSH signature is waiting.
enum MenuBarGlyph {
    static func image(pending: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let c = NSPoint(x: rect.midX, y: rect.midY)
            NSColor.black.set()
            let rim = NSBezierPath(ovalIn: NSRect(x: c.x - 7.75, y: c.y - 7.75, width: 15.5, height: 15.5))
            rim.lineWidth = 1.1
            rim.stroke()
            // AppKit measures angles from the right, counter-clockwise: -90° is six o'clock. The rings and keyhole
            // therefore all resolve on one vertical axis, like the application icon's dial just before it opens.
            let width: CGFloat = 1.1, gap: CGFloat = 1.65, notch: CGFloat = -90
            for r: CGFloat in [5.6, 4.0, 2.45] {
                let half = asin((gap + width) / 2 / r) * 180 / .pi
                let ring = NSBezierPath()
                ring.appendArc(withCenter: c, radius: r, startAngle: notch + half, endAngle: notch + 360 - half)
                ring.lineWidth = width
                ring.lineCapStyle = .round
                ring.stroke()
            }
            // The keyhole: a round head and a slot widening downwards.
            NSBezierPath(ovalIn: NSRect(x: c.x - 1.05, y: c.y + 0.45 - 1.05, width: 2.1, height: 2.1)).fill()
            let slot = NSBezierPath()
            slot.move(to: NSPoint(x: c.x - 0.425, y: c.y + 0.45))
            slot.line(to: NSPoint(x: c.x + 0.425, y: c.y + 0.45))
            slot.line(to: NSPoint(x: c.x + 0.675, y: c.y - 1.7))
            slot.line(to: NSPoint(x: c.x - 0.675, y: c.y - 1.7))
            slot.close()
            slot.fill()
            if pending {
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - 5, y: rect.maxY - 5, width: 4.5, height: 4.5)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = pending ? String(localized: "Triwarden, SSH signature waiting") : "Triwarden"
        return image
    }
}

extension Color {
    /// The menu bar panel's cards. Its glass is near-white in light mode (the window's cards sit on a coloured
    /// backdrop instead), so here they're nearly opaque white with a hairline and a soft shadow to stand out.
    static let menuCard = adaptive(light: .white.opacity(0.92), dark: .white.opacity(0.09))
    static let menuEdge = adaptive(light: .black.opacity(0.07), dark: .white.opacity(0.08))
    static let menuShadow = adaptive(light: .black.opacity(0.05), dark: .clear)
    static let menuWash = adaptive(light: Color(red: 0.925, green: 0.928, blue: 0.95).opacity(0.7), dark: .clear)
}
