import AppKit
import SSHAgent
import TriCrypto
import QuickLook
import SwiftUI
import TipKit
import UniformTypeIdentifiers
import VaultwardenAPI

// Implements the "Vault window (static spec)" artboard: floating glass sidebar, rounded item list,
// dark hero card with password/code tiles, grouped detail rows.

extension Color {
    /// A color that resolves per appearance.
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
    }

    /// Sidebar selection: the tail sky deepened so white text reads on it (light: like the primary buttons).
    static let sidebarSelection = adaptive(light: Color(red: 0x2E / 255, green: 0x8F / 255, blue: 0xD3 / 255),
                                           dark: Color(red: 0x2C / 255, green: 0x6E / 255, blue: 0x9E / 255))

    /// Window base under all panels.
    static let windowBase = adaptive(light: Color(red: 0.945, green: 0.947, blue: 0.965), dark: Color(red: 0.105, green: 0.108, blue: 0.125))

    /// Panels floating on the window base.
    static let panel = adaptive(light: .white.opacity(0.62), dark: .white.opacity(0.05))
    static let panelStrong = adaptive(light: .white.opacity(0.78), dark: .white.opacity(0.09))
    static let panelEdge = adaptive(light: .white.opacity(0.9), dark: .white.opacity(0.08))
    static let rowSelected = adaptive(light: .white, dark: .white.opacity(0.12))
    static let hero = adaptive(light: Color(red: 0.08, green: 0.09, blue: 0.11), dark: Color(red: 0.15, green: 0.16, blue: 0.19))
}

struct VaultView: View {
    /// A full-page section's left inset inside the pane: the same as the item list panel's, so its left edge sits under
    /// the header's search field. On the right, content runs to the pane's edge, as far from the window's edge as the
    /// sidebar is on the left.
    static let pageInset: CGFloat = 6
    var initialSelection: VaultItem.ID?
    /// The section to open on (snapshots).
    var initialSection: SidebarSelection?
    /// Narrow windows: the strip's starting pane (snapshots and previews).
    var initialDepth = 1
    /// Search text to start with (snapshots).
    var initialQuery = ""
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var section: SidebarSelection = .section(.all)
    @AppStorage("itemSort") private var sortRaw = ItemSort.title.rawValue
    @AppStorage("itemSortAscending") private var ascending = true
    /// Window width, to adapt from three columns down to a single phone-width column.
    @State private var width: CGFloat = 1120
    @State private var columns = NavigationSplitViewVisibility.all
    /// Where the detail column (and so the header's leading slot) starts in the window.
    @State private var detailX: CGFloat = 0
    /// Narrow windows: which pane of the strip is in view (0 sidebar, 1 list or page, 2 detail).
    @State private var depth = 1


    /// Below this width the sidebar, list and detail become one sliding strip (Reeder-style).
    /// The item list's width beside the details (wide windows).
    static let listWidth: CGFloat = 330
    /// Below this the panes slide one at a time; it grows with the list so the details keep their room.
    private var compact: Bool { width < 900 + (Self.listWidth - 300) }

    /// The command palette's trigger: centred over the window when it's wide, beside the back button when narrow.
    /// The header's leading slot starts this far into the detail column.
    static let headerSlotInset: CGFloat = 8
    /// From the header's leading slot to the list's edge below it, so the + and the list line up.
    static let plusInset: CGFloat = 6
    private var searchWidth: CGFloat { compact ? (width < 560 ? 150 : 228) : min(320, max(280, width * 0.24)) }
    /// The window's controls (Sync, Lock) floating over `content`'s bottom-right corner, under the header's right end
    /// (an item's actions, or a page's edge). No row of their own: the panels run to the window's bottom, and scrolling
    /// content keeps room at its end so its last line can scroll clear of them.
    /// `toBottomEdge`: a full-page tool (Codes, Watchtower…) scrolls right to the window's bottom edge, through the
    /// column's 8 pt margin; the list and detail panels keep it.
    private func withFooter(_ content: some View, toBottomEdge: Bool = false) -> some View {
        ZStack(alignment: .bottomTrailing) {
            content
                .frame(maxHeight: .infinity)
                .contentMargins(.bottom, vaultOpen ? 44 : 0, for: .scrollContent)
                .padding(.bottom, toBottomEdge ? -8 : 0)
            if vaultOpen {
                AppFooter()
                    // Its bottom edge level with the sidebar's account card (11 pt above the window's bottom, with the
                    // column's own 8 pt inset).
                    .padding(.trailing, 10).padding(.bottom, 1.5)
                    .transition(.opacity)
            }
        }
    }

    /// An item's detail is showing, with its actions in the header.
    private var detailHasActions: Bool { isItemSection && model.selectedItem != nil && (!compact || depth == 2) }
    private var isItemSection: Bool { ![.codes, .generator, .sends, .watchtower].contains(section) }
    private var maxDepth: Int { isItemSection ? (model.selectedItem == nil && model.newItemForm == nil ? 1 : 2) : 1 }

    /// The sidebar's choice; leaving a new item with input in it asks first.
    private var sidebarSection: Binding<SidebarSelection> {
        Binding(get: { section }, set: { new in model.leaveNewItemForm { section = new } })
    }

    private var sort: ItemSort { ItemSort(rawValue: sortRaw) ?? .title }

    private var filtered: [VaultItem] {
        let matching = model.vaultItems
            .filter(section.includes)
            .filter(model.passesSearchFilters)
            .filter { AppModel.searchMatches($0, query) }
        return ItemSort.sorted(matching, by: sort, ascending: ascending)
    }

    var body: some View {
        // Measure the space the window offers (not the content, which may refuse to shrink) and lay out for it.
        GeometryReader { geo in
            newItemFormHandling(content)
                .frame(width: geo.size.width, height: geo.size.height)
                .onChange(of: geo.size.width, initial: true) { old, new in resized(from: initialMeasure ? 1120 : old, to: new) }
                .environment(\.windowMidY, geo.frame(in: .global).midY)
        }
    }

    /// An item form opens in the detail panel: from a tool page, go to the items; on a narrow window, slide to
    /// it. Leaving it with input in it asks first.
    private func newItemFormHandling(_ content: some View) -> some View {
        content
            .animation(.snappy(duration: 0.25), value: model.newItemForm?.id)
            .onChange(of: model.newItemForm?.id) { _, id in
                guard id != nil else { return }
                if !isItemSection { section = .section(.all) }
                if compact { depth = 2 }
            }
            .confirmationDialog(discardFormTitle, isPresented: Binding(get: { model.pendingLeave != nil },
                                                                        set: { if !$0 { model.pendingLeave = nil } })) {
                Button("Discard", role: .destructive) { withAnimation(.snappy(duration: 0.25)) { model.discardNewItemAndLeave() } }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                if model.editing?.mode.isEdit == true {
                    Text("What you've typed here isn't saved yet.")
                } else {
                    Text("What you've typed for it isn't saved yet.")
                }
            }
    }

    private var discardFormTitle: LocalizedStringKey {
        model.editing?.mode.isEdit == true ? "Discard your changes?" : "Discard this new item?"
    }

    @State private var initialMeasure = true
    @State private var appliedInitialDepth = false

    private func resized(from old: CGFloat, to new: CGFloat) {
        initialMeasure = false
        width = new
        if !appliedInitialDepth { appliedInitialDepth = true; depth = initialDepth }
        // Fold the sidebar away as the window narrows; bring it back when it widens again.
        if new < 900, old >= 900 { columns = .detailOnly }
        if new >= 900, old < 900 { columns = .all }
    }

    // MARK: Panes

    private var compactPanes: [AnyView] {
        let sidebar = AnyView(sidebarPane)
        guard isItemSection else { return [sidebar, AnyView(sectionPane)] }
        return [sidebar, AnyView(listPane), AnyView(detailPane.environment(\.showsDetailToolbar, depth == 2))]
    }

    /// The sidebar as a pane on the narrow-window strip: the same list, on the app's panel.
    private var sidebarPane: some View {
        Sidebar(section: sidebarSection)
            .scrollContentBackground(.hidden)
            .background(Color.panel, in: .rect(cornerRadius: 22, style: .continuous))
            .clipShape(.rect(cornerRadius: 22, style: .continuous))
    }

    @ViewBuilder private var sectionPane: some View {
        switch section {
        case .codes: CodesPane()
        case .generator: GeneratorPane()
        case .sends: SendsPane()
        default:
            WatchtowerView { item in
                section = .section(item.isDeleted ? .trash : .all)
                model.selectedID = item.id
                if compact { depth = 2 }
            }
        }
    }

    /// The locked account the list column asks to unlock, if any.
    private var lockedFocus: SavedAccount? {
        // The focused account's door covers the window (RootView); this pane is for the sidebar's account section.
        guard case .account(let id) = section, model.accountDoor == nil, !model.isUnlocked(id) else { return nil }
        return model.accounts.first { $0.id == id }
    }

    private var listPane: some View {
        let locked = lockedFocus
        return ZStack {
            if let account = locked {
                AccountUnlockPane(account: account) // the account in focus is locked: unlock it right here
                    .id(account.id)
                    .transition(.opacity)
            } else {
                ItemColumn(items: filtered, isTrash: section == .section(.trash), selection: Binding(get: { model.selectedID }, set: { id in
                    // Picking an item leaves a new item's form (asking first when it has input).
                    model.leaveNewItemForm {
                        model.selectedID = id
                        if compact, id != nil { depth = 2 } // tapping an item slides to it
                    }
                }), query: $query, sort: $sortRaw, ascending: $ascending, listID: section)
                    .transition(.opacity)
            }
        }
        .animation(pageAnimation, value: locked?.id)
    }

    /// Sidebar page changes: a plain crossfade.
    private var pageTransition: AnyTransition { .opacity }
    private var pageAnimation: Animation { .easeInOut(duration: reduceMotion ? 0.15 : 0.22) }

    @ViewBuilder private var detailPane: some View {
        if let request = model.newItemForm {
            // New, clone, and edit all happen right here, where the item shows.
            EditItemSheet(mode: request.mode, prefill: request.prefill, inPanel: true)
                .id(request.id)
                .transition(.opacity.combined(with: .offset(y: 8)))
        } else if let item = model.selectedItem {
            ItemDetail(item: item)
                .id(item.id)
                .transition(.opacity.combined(with: .offset(y: 8)))
        } else {
            ContentUnavailableView {
                Label("No Item Selected", systemImage: "key.viewfinder")
            }
            .modifier(WindowCentered())
        }
    }

    /// False while the lock layer lies over the vault: the header's controls are kept in place but out of sight.
    private var vaultOpen: Bool { model.phase.id == AppModel.Phase.vault.id && model.accountDoor == nil }

    private var content: some View {
        @Bindable var model = model
        return NavigationSplitView(columnVisibility: $columns) {
            Sidebar(section: sidebarSection)
                .modifier(SidebarWidth())
                // Narrow windows navigate with the strip's own back button; one sidebar control is enough. None under
                // the lock layer (the toolbar itself stays, so the window keeps its controls and the layout doesn't move).
                .toolbar(removing: compact || !vaultOpen ? .sidebarToggle : nil)
        } detail: {
            ZStack {
                if compact {
                    withFooter(PaneStrip(panes: compactPanes, depth: $depth, maxDepth: maxDepth))
                } else if isItemSection {
                    HStack(spacing: 8) {
                        listPane.frame(width: Self.listWidth) // full height: the footer stays under the right column
                        withFooter(detailPane.frame(maxWidth: .infinity, maxHeight: .infinity))
                    }
                    .transition(pageTransition)
                } else {
                    // A tool (Send, Generator, Codes, Watchtower): each one its own page.
                    withFooter(sectionPane.id(section), toBottomEdge: true)
                        .transition(pageTransition)
                }
            }
            .animation(compact ? nil : pageAnimation, value: compact ? nil : section)
            .padding(8)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { detailX = $0 }
            .background(WindowBackdrop())
            .toolbar(removing: .title)
            // The header stays clear over the backdrop (a wide item in it would otherwise bring up a tinted bar).
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .toolbar {
                // Back (narrow windows) and search at the header's start.
                ToolbarItem(placement: .navigation) {
                    HStack(spacing: 8) {
                        if compact && depth > 0 {
                            Button { depth = max(depth - 1, 0) } label: {
                                Image(systemName: depth == 1 ? "sidebar.left" : "chevron.left").font(.system(size: 14, weight: .medium))
                                    .contentTransition(.symbolEffect(.replace))
                                    .frame(width: 36, height: 36).contentShape(.circle)
                            }
                            .buttonStyle(.plain)
                            .modifier(HeaderChrome(shape: .circle))
                            .keyboardShortcut("[", modifiers: .command)
                            .help(Text("Back (⌘[)"))
                            .accessibilityLabel(Text("Back"))
                        }
                        // On a phone-width detail, the header belongs to the item's actions (search and + are the list's).
                        if !(compact && width < PaneStrip.pairWidth && depth == 2) {
                            // New items of every kind, first in the header (beside the sidebar's toggle).
                            NewItemButton()
                                .padding(.leading, Self.plusInset) // its edge over the list's
                            // Wide windows: centred on the window (`.principal` isn't honoured in a split view's header, so
                            // this leading slot is inset to the middle, less the + before it).
                            PaletteTrigger(compactLabel: searchWidth < 260)
                                .frame(width: searchWidth)
                                .padding(.leading, compact ? 0 : max(0, width / 2 - detailX - Self.headerSlotInset - searchWidth / 2
                                                                         - Self.plusInset - NewItemButton.size - 8))
                            SSHRequestsButton()
                            // A slot holding a single view lays it out at zero size; a zero-width sibling keeps it measured.
                            Text(verbatim: " ").frame(width: 0).accessibilityHidden(true)
                        }
                    }
                    // Under the lock layer: present (so the header keeps its height and nothing moves on unlock)
                    // but invisible and inert.
                    .opacity(vaultOpen ? 1 : 0)
                    .disabled(!vaultOpen) // shortcuts too
                    .accessibilityHidden(!vaultOpen)
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .background {
                // Keyboard: ⌘K is Help › Command Palette, ⌘F the list's search, ⌘G the generator.
                    Group {
                    Button("") { focusSearch() }.keyboardShortcut("f", modifiers: .command)
                    Button("") { section = .generator }.keyboardShortcut("g", modifiers: .command)
                }
                .hidden()
            }
        }
        .animation(.snappy(duration: 0.25), value: model.selectedID)
        .onChange(of: section) {
            query = "" // a filter belongs to the list it was typed in
            // A tool page has no detail panel for a new item's form.
            if !isItemSection { model.closeNewItemForm(restoringSelection: false) }
            if compact { depth = model.newItemForm == nil ? 1 : 2 } // picked a section: slide to it (or stay on the form)
        }
        .onChange(of: model.selectedItem == nil) { _, none in if none, depth == 2, model.newItemForm == nil { depth = 1 } }
        // The system sidebar toggle on a narrow window: show the strip's sidebar pane instead.
        .onChange(of: columns) { _, new in
            if compact, new != .detailOnly { columns = .detailOnly; depth = 0 }
        }
        // When the selected item leaves the list (trashed, restored, deleted, filtered out), select its neighbour
        // so the list and the detail never disagree.
        .onChange(of: filtered.map(\.id)) { old, new in
            guard let selected = model.selectedID, !new.contains(selected) else { return }
            let at = old.firstIndex(of: selected) ?? 0
            model.selectedID = new.isEmpty ? nil : new[min(at, new.count - 1)]
        }
        .onChange(of: model.requestedSection) { _, requested in
            if let requested { section = requested; model.requestedSection = nil }
        }
        .onChange(of: model.requestedFilter) { _, requested in
            guard let requested else { return }
            model.requestedFilter = nil
            section = .section(.all)
            // After the section change has cleared the old filter.
            Task { @MainActor in query = requested }
        }
        .onChange(of: model.showingGenerator) { _, show in
            if show { section = .generator; model.showingGenerator = false }
        }
        .sheet(item: $model.repromptRequest) { request in RepromptSheet(request: request) }
        .sheet(item: $model.signInPrompt) { prompt in SignInApprovalSheet(prompt: prompt) }
        .sheet(isPresented: Binding(get: { model.eventLogFor != nil }, set: { if !$0 { model.eventLogFor = nil } })) {
            if let id = model.eventLogFor { EventLogSheet(organizationId: id) }
        }
        .sheet(item: $model.organizationSheet) { sheet in
            switch sheet {
            case .share(let ids): MoveToOrganizationSheet(itemIDs: ids)
            case .collections(let id): CollectionsSheet(itemID: id)
            }
        }
        .sheet(item: $model.transfer) { transfer in
            switch transfer {
            case .export(let accountId): ExportSheet(initialAccount: accountId)
            case .importFile(let url): ImportSheet(initialFile: url)
            }
        }
        // Drop an export file (from any supported app) on the window to import it.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, ["csv", "json", "xml", "1pux"].contains(url.pathExtension.lowercased()), !model.sessions.isEmpty else { return false }
            model.beginImport(url)
            return true
        }
        .quickLookPreview($model.previewURL)
        .onChange(of: model.previewURL) { old, _ in
            if let old { AttachmentFiles.remove(old) } // decrypted copy only lives while previewed
        }
        .sheet(isPresented: Binding(get: { model.renamingFolder != nil }, set: { if !$0 { model.renamingFolder = nil } })) {
            if let path = model.renamingFolder { RenameFolderSheet(path: path) }
        }
        // A renamed folder that's open in the sidebar stays open under its new name.
        .onChange(of: model.renamedFolder?.new) {
            guard let rename = model.renamedFolder, case .folder(let open) = section,
                  open == rename.old || open.hasPrefix(rename.old + "/") else { return }
            section = .folder(rename.new + open.dropFirst(rename.old.count))
        }
        .sheet(isPresented: $model.promptingNewFolder, onDismiss: { model.newFolderParent = nil }) {
            NewFolderSheet(parent: model.newFolderParent)
        }
        // Full-frame overlay so the toast never participates in layout (no jump when it appears).
        .overlay {
            ToastView()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(model.toast != nil)
        }
        .onAppear {
            if let initialSection { section = initialSection }
            if !initialQuery.isEmpty { query = initialQuery }
            selectFirst()
        }
        // Under the lock layer the vault starts empty; pick an item once unlocking fills it.
        .onChange(of: model.items.isEmpty) { _, empty in if !empty { selectFirst() } }
    }

    /// ⌘F: to the list's search field (from a tool page, back to All Items first).
    private func focusSearch() {
        if !isItemSection { section = .section(.all) }
        if compact { depth = 1 }
        model.wantsSearchFocus = true
    }

    private func selectFirst() {
        if model.selectedID == nil, model.newItemForm == nil { model.selectedID = initialSelection ?? model.items.first(where: \.favorite)?.id ?? model.items.first?.id }
    }
}

// MARK: Sidebar

/// What the sidebar has selected: a built-in category, a folder, an organization or a collection.
enum SidebarSelection: Hashable {
    case section(VaultSection)
    case folder(String)
    /// Your own items (not in any shared vault).
    case myVault
    case organization(String)
    case collection(String)
    case account(String)
    case watchtower
    case sends
    case generator
    case codes

    /// The vault a row stands for ("personal" or an organization id), for the vault filter.
    var vaultKey: String? {
        switch self {
        case .myVault: AppModel.VaultFilter.personalKey
        case .organization(let id): id
        default: nil
        }
    }

    func includes(_ item: VaultItem) -> Bool {
        switch self {
        case .watchtower, .sends, .generator, .codes: false
        case .account(let id): !item.isDeleted && !item.isArchived && item.accountId == id
        case .section(let s): s.includes(item)
        case .folder(let path): !item.isDeleted && !item.isArchived && (item.folderName == path || item.folderName?.hasPrefix(path + "/") == true)
        case .myVault: !item.isDeleted && !item.isArchived && item.organizationId == nil
        case .organization(let id): !item.isDeleted && !item.isArchived && item.organizationId == id
        case .collection(let id): !item.isDeleted && !item.isArchived && item.collectionIds.contains(id)
        }
    }
}

enum VaultSection: Hashable, CaseIterable {
    case all, favorites, logins, passkeys, cards, identities, notes, sshKeys, archive, trash

    /// Shown nested under All Items: narrower views of the same items.
    static let underAll: [VaultSection] = [.favorites, .logins, .passkeys, .cards, .identities, .notes, .sshKeys]

    var title: LocalizedStringKey {
        switch self {
        case .all: "All Items"; case .favorites: "Favorites"; case .logins: "Logins"; case .passkeys: "Passkeys"
        case .sshKeys: "SSH Keys"; case .cards: "Cards"; case .identities: "Identities"; case .notes: "Secure Notes"
        case .archive: "Archive"; case .trash: "Trash"
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"; case .favorites: "star"; case .logins: "key"; case .passkeys: "person.badge.key"
        case .sshKeys: "terminal"; case .cards: "creditcard"; case .identities: "person.crop.rectangle"; case .notes: "note.text"
        case .archive: "archivebox"; case .trash: "trash"
        }
    }

    func includes(_ item: VaultItem) -> Bool {
        if self == .trash { return item.isDeleted }
        if item.isDeleted { return false }
        // Archived items live only in Archive (as in Bitwarden): out of every other list.
        if self == .archive { return item.isArchived }
        if item.isArchived { return false }
        switch self {
        case .trash, .archive: return true
        case .all: return true
        case .favorites: return item.favorite
        case .logins: return item.kind == .login
        case .passkeys: return item.hasPasskey
        case .sshKeys: return item.kind == .sshKey
        case .cards: return item.kind == .card
        case .identities: return item.kind == .identity
        case .notes: return item.kind == .note
        }
    }
}

/// Native macOS sidebar (system source-list style, adapts to the OS look).
private struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var section: SidebarSelection

    @AppStorage("sidebarTypesExpanded") private var typesExpanded = false
    @AppStorage("sidebarFoldersExpanded") private var foldersExpanded = true

    private func count(_ selection: SidebarSelection) -> Int { model.vaultItems.filter(selection.includes).count }

    @ViewBuilder private var newFolderMenu: some View {
        Button("New Folder…", systemImage: "folder.badge.plus") { model.promptNewFolder() }
            .labelStyle(.titleAndIcon)
            .tint(Color(nsColor: .labelColor))
    }

    private func row(_ s: VaultSection) -> some View {
        SidebarLabel(s.title, symbol: s.symbol, tag: .section(s), count: count(.section(s)))
            .tag(SidebarSelection.section(s))
    }

    /// A row picked. A vault with ⌘ held joins (or leaves) the vaults shown everywhere instead of opening; opening a
    /// vault the filter hides shows it again.
    private func pick(_ new: SidebarSelection) {
        if let key = new.vaultKey {
            if NSEvent.modifierFlags.contains(.command) {
                withAnimation(.snappy(duration: 0.25)) { model.toggleVault(key) }
                return
            }
            if !model.vaultShown(key) { withAnimation(.snappy(duration: 0.25)) { model.toggleVault(key) } }
        }
        section = new
    }

    var body: some View {
        List(selection: Binding(get: { section }, set: { if let s = $0 { pick(s) } })) {
            Section {
                // All Items, with its narrower views folded under it (closed at first: the sidebar stays short).
                DisclosureGroup(isExpanded: $typesExpanded) {
                    ForEach(VaultSection.underAll, id: \.self) { row($0) }
                } label: {
                    row(.all)
                }
            } header: {
                Text("Items").font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                    .padding(.bottom, 6)
            }
            // Where items live: your own vault, then each shared vault (opening onto its shared folders). A click opens
            // one; ⌘-click shows it alongside the others everywhere. Vaults the filter hides are dimmed.
            if !model.visibleOrganizations.isEmpty {
                Section("Vaults") {
                    SidebarLabel("My vault", symbol: "person", tag: .myVault, count: count(.myVault))
                        .tag(SidebarSelection.myVault)
                        .opacity(model.vaultShown(AppModel.VaultFilter.personalKey) ? 1 : 0.45)
                    ForEach(model.visibleOrganizations) { org in
                        SharedVaultRow(org: org, count: count)
                            .opacity(model.vaultShown(org.id) ? 1 : 0.45)
                    }
                }
            }
            // Things to do with the vault, rather than kinds of items in it.
            Section("Tools") {
                SidebarLabel("Send", symbol: "paperplane", tag: .sends, count: model.sends.count)
                    .tag(SidebarSelection.sends)
                SidebarLabel("One-Time Codes", symbol: "clock.badge.checkmark", tag: .codes,
                             count: model.vaultItems.filter { !$0.isDeleted && !$0.isArchived && $0.totp != nil }.count)
                    .tag(SidebarSelection.codes)
                SidebarLabel("Generator", symbol: "dice", tag: .generator)
                    .tag(SidebarSelection.generator)
                SidebarLabel("Watchtower", symbol: "checkmark.shield", tag: .watchtower, count: model.watchtowerIssueCount)
                    .tag(SidebarSelection.watchtower)
            }
            // Your own ways of sorting items, and items set aside: kept (Archive) or on their way out (Trash).
            Section("Manage") {
                if model.folders.isEmpty {
                    SidebarLabel("My Folders", symbol: "folder")
                        .contextMenu { newFolderMenu }
                } else {
                    DisclosureGroup(isExpanded: $foldersExpanded) {
                        ForEach(FolderNode.tree(model.folders)) { node in
                            FolderRow(node: node, count: count)
                        }
                    } label: {
                        SidebarLabel("My Folders", symbol: "folder")
                            .contextMenu { newFolderMenu }
                    }
                }
                row(.archive)
                row(.trash)
            }
        }
        .listStyle(.sidebar)
        .thinScroller() // the app's slim scroller, not the system's wide track
        .environment(\.sidebarCurrent, section)
        // Switching accounts or vaults: sections and counts move rather than jump.
        .animation(.snappy(duration: 0.3), value: model.focusedAccountID)
        .animation(.snappy(duration: 0.3), value: model.vaultFilter)
        .listItemTint(.monochrome) // icons in the text's own colour, not the brand blue
        // Selection: a calm sky (deep in dark mode) that white text reads well on, not the bright accent.
        .tint(Color.sidebarSelection)
        .background(SidebarCalmSelection()) // always the soft selection, never the focused (solid) one
        .safeAreaInset(edge: .bottom) { SidebarAccountCard().padding(10) }
    }
}

/// Who's signed in, where, and how fresh the vault is — with sync and lock at hand. A click opens the account
/// switcher: every account (or all of them together), the locked ones a click from unlocking, and the rest.
private struct SidebarAccountCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    @State private var switching = false

    /// The account the card stands for: the one in focus, the only one, or none (several together).
    private var account: (index: Int, account: SavedAccount)? {
        let id = model.focusedAccountID ?? (model.accounts.count == 1 ? model.accounts.first?.id : nil)
        return model.accounts.enumerated().first { $0.element.id == id }.map { ($0.offset, $0.element) }
    }

    private var title: String {
        if let account { return account.account.email }
        let open = model.sessions.count
        return open == 0 ? String(localized: "Vault") : String(localized: "All accounts")
    }

    var body: some View {
        let dark = scheme == .dark
        HStack(spacing: 10) {
            Button { switching.toggle() } label: {
                HStack(spacing: 10) {
                    if let account {
                        AccountAvatar(account: account.account, size: 30)
                    } else {
                        AccountAvatarStack(accounts: model.accounts, size: 24)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: title).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                            .contentTransition(.opacity)
                        SyncStatusText().font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    // The switcher's pop-up mark, centred on the card's right end.
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Accounts"))
            .accessibilityValue(Text(verbatim: title))
            .popover(isPresented: $switching, arrowEdge: .top) {
                AccountSwitcher(close: { switching = false })
            }
        }
        .padding(.leading, 8).padding(.trailing, 8).padding(.vertical, 8)
        .background {
            // Frosted underneath: rows scrolling below the card blur away instead of showing through its text.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(dark ? Color.white.opacity(hovering || switching ? 0.09 : 0.06) : Color.white.opacity(hovering || switching ? 0.75 : 0.55))
                .background(.thickMaterial, in: .rect(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(dark ? 0.08 : 0.05)))
                .shadow(color: .black.opacity(dark ? 0.25 : 0.06), radius: 8, y: 2)
        }
        .onHover { h in withAnimation(.snappy(duration: 0.15)) { hovering = h } }
        .animation(.snappy(duration: 0.25), value: model.focusedAccountID)
    }

}

/// The window's footer, under the panels: Sync Now and Lock at the right end, in the header's pill style.
private struct AppFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Countdown is its own floating pill to the left — Sync/Lock stay a fixed size so they don't jump.
        HStack(spacing: 6) {
            if model.clipboardClearsAt != nil {
                ClipboardCountdown()
                    .padding(.horizontal, 3)
                    .frame(height: 30)
                    .modifier(FloatingChrome())
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
            }
            HStack(spacing: 0) {
                SyncFooterButton { Task { try? await model.refresh() } }
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 14).padding(.horizontal, 2)
                Button { model.lock(animated: true) } label: {
                    Image(systemName: "lock")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(.rect)
                }
                .buttonStyle(HeaderIconStyle())
                .help(Text("Lock Vault (⇧⌘L)"))
                .accessibilityLabel(Text("Lock Vault"))
            }
            .padding(.horizontal, 3)
            .frame(height: 30)
            .modifier(FloatingChrome())
        }
        .animation(.spring(duration: 0.35, bounce: 0.2), value: model.clipboardClearsAt)
    }
}

/// Glass for controls floating over content (the window's Sync / Lock): a frosted material under a light fill, a
/// hairline edge and a soft shadow, in both appearances, so it reads over a list, a card or the backdrop alike.
struct FloatingChrome: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        content
            .background {
                Capsule().fill(dark ? Color.white.opacity(0.08) : Color.white.opacity(0.7))
                    .background(.regularMaterial, in: .capsule)
                    .shadow(color: .black.opacity(dark ? 0.35 : 0.12), radius: 10, y: 3)
            }
            .overlay {
                Capsule().strokeBorder(dark ? Color.white.opacity(0.12)
                                            : Color.black.opacity(0.08), lineWidth: 0.5)
            }
            .compositingGroup()
    }
}

/// The footer's Sync Now: spins while syncing, then shows a tick for a moment when a sync you asked for is done.
private struct SyncFooterButton: View {
    @Environment(AppModel.self) private var model
    let action: () -> Void
    @State private var asked = false
    @State private var done = false

    var body: some View {
        Button {
            asked = true
            action()
        } label: {
            Image(systemName: done ? "checkmark" : "arrow.triangle.2.circlepath")
                .font(.system(size: 12, weight: done ? .semibold : .medium))
                .foregroundStyle(.secondary)
                .symbolEffect(.rotate, isActive: model.isSyncing)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 26, height: 26)
                .contentShape(.rect)
        }
        .buttonStyle(HeaderIconStyle())
        .disabled(model.isSyncing)
        .help(Text("Sync Now"))
        .accessibilityLabel(Text("Sync Now"))
        .onChange(of: model.isSyncing) { was, now in
            guard was, !now, asked else { return }
            asked = false
            guard model.lastSynced.map({ Date.now.timeIntervalSince($0) < 5 }) ?? false else { return } // it failed
            done = true
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                done = false
            }
        }
    }
}

/// The sidebar column: 200–280 pt, 220 to start. Snapshots pin it at 220 (an offscreen window has no width to start from).
private struct SidebarWidth: ViewModifier {
    func body(content: Content) -> some View {
        if Motion.plays {
            // Wide enough that names and counts never crowd (e.g. "Browser extensions" with its count).
            content.navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 320)
        } else {
            content.navigationSplitViewColumnWidth(240)
        }
    }
}

/// The account switcher: all accounts together or one at a time (a locked one unlocks in the list), then the
/// account actions.
struct AccountSwitcher: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void
    private static let stackSize: CGFloat = 22
    private static let rowAvatarSize: CGFloat = 30

    /// Shared leading column: wide enough for the "All accounts" stack *and* a single 30pt row avatar,
    /// so every row's text lines up. Stack width comes from `AccountAvatarStack` (still caps at 3 circles
    /// when there are many accounts — 2 avatars + "+N").
    private var leadingWidth: CGFloat {
        max(
            Self.rowAvatarSize,
            AccountAvatarStack.width(forAccountCount: model.accounts.count, size: Self.stackSize)
        )
    }

    var body: some View {
        let leading = leadingWidth
        VStack(alignment: .leading, spacing: 2) {
            if model.accounts.count > 1 {
                row(selected: model.focusedAccountID == nil, action: { focus(nil) }) {
                    AccountAvatarStack(accounts: model.accounts, size: Self.stackSize)
                        .frame(width: leading, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("All accounts").font(.system(size: 13, weight: .semibold))
                        Text("\(model.sessions.count) of \(model.accounts.count) unlocked")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Divider().padding(.vertical, 4).padding(.horizontal, 8)
            }
            ForEach(model.accounts) { account in
                let open = model.isUnlocked(account.id)
                row(selected: model.focusedAccountID == account.id || model.accounts.count == 1, action: { focus(account.id) }) {
                    AccountAvatar(account: account, size: Self.rowAvatarSize, showsLock: true)
                        .frame(width: leading, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: account.email).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        HStack(spacing: 4) {
                            if !open { Image(systemName: "lock.fill").font(.system(size: 9)) }
                            Text(verbatim: open ? account.serverSummary : String(localized: "Locked · \(account.serverSummary)"))
                        }
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        if open {
                            let count = model.items.filter { $0.accountId == account.id && !$0.isDeleted }.count
                            Text(count == 1 ? String(localized: "1 item") : String(localized: "\(count) items"))
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .contextMenu {
                    Group {
                        if open { Button("Lock", systemImage: "lock") { model.lock(account.id) } }
                        Button("Log Out…", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                            close(); model.confirmLogOut(account.id)
                        }
                    }
                    .labelStyle(.titleAndIcon)
                }
            }
            Divider().padding(.vertical, 4).padding(.horizontal, 8)
            action("Add Account…", "person.badge.plus") { model.beginAddAccount() }
            action("Sync Now", "arrow.triangle.2.circlepath") { Task { try? await model.refresh() } }
            action("Import…", "square.and.arrow.down", keys: "⇧⌘I") { model.beginImport() }
            action("Export Vault…", "square.and.arrow.up", keys: "⇧⌘E") { model.beginExport() }
            action("Settings…", "gearshape", keys: "⌘,") { model.showSettings() }
            Divider().padding(.vertical, 4).padding(.horizontal, 8)
            action("Lock Vault", "lock", keys: "⇧⌘L") { model.lock(animated: true) }
            action("Log Out…", "rectangle.portrait.and.arrow.right", destructive: true) {
                model.confirmLogOut(model.focusedAccountID ?? (model.sessions.count == 1 ? model.sessions[0].account.id : nil))
            }
        }
        .padding(6)
        .frame(width: 300)
    }

    private func focus(_ id: String?) {
        withAnimation(.snappy(duration: 0.3)) {
            model.accountFocus = id
            model.vaultFilter = .all // an organization of another account wouldn't be there
        }
        close()
    }

    private func row<Content: View>(selected: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        SwitcherRow(selected: selected, action: action, content: content())
    }

    private func action(_ title: LocalizedStringKey, _ symbol: String, keys: String? = nil, destructive: Bool = false,
                        run: @escaping () -> Void) -> some View {
        SwitcherAction(title: title, symbol: symbol, keys: keys, destructive: destructive) { close(); run() }
    }
}

private struct SwitcherRow<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    let content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                content
                Spacer(minLength: 6)
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                    .opacity(selected ? 1 : 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color.primary.opacity(hovering ? 0.07 : selected ? 0.04 : 0), in: .rect(cornerRadius: 9, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.snappy(duration: 0.12)) { hovering = h } }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SwitcherAction: View {
    let title: LocalizedStringKey
    let symbol: String
    /// The menu-bar shortcut, drawn on the right the way a menu shows it.
    var keys: String?
    var destructive = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Label(title, systemImage: symbol)
                    .foregroundStyle(destructive ? Color.red : .primary)
                Spacer(minLength: 8)
                if let keys {
                    Text(verbatim: keys).foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8).frame(height: 28)
            .background(Color.primary.opacity(hovering ? 0.07 : 0), in: .rect(cornerRadius: 7, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.snappy(duration: 0.12)) { hovering = h } }
    }
}

private struct SyncStatusText: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isSyncing {
            Text("Syncing…")
        } else if model.previewUnlocked {
            Text("Synced just now") // the demo vault (screenshots, UI tests): there's no server to be offline from
        } else if let date = model.lastSynced {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                if context.date.timeIntervalSince(date) < 60 {
                    Text("Synced just now")
                } else {
                    Text("Synced \(date, format: .relative(presentation: .named))")
                }
            }
        } else {
            Text("Offline · saved vault")
        }
    }
}

// MARK: Folders

/// A folder in the sidebar tree. "Work/Servers" nests under "Work"; parents without a real folder are virtual.
struct FolderNode: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    var folderIds: [String] = []
    var children: [FolderNode] = []

    static func tree(_ folders: [Grouping]) -> [FolderNode] {
        var roots: [FolderNode] = []
        for folder in folders {
            let parts = folder.name.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !parts.isEmpty else { continue }
            insert(parts[...], prefix: "", folderId: folder.id, into: &roots)
        }
        return sorted(roots)
    }

    private static func insert(_ parts: ArraySlice<String>, prefix: String, folderId: String, into nodes: inout [FolderNode]) {
        guard let head = parts.first else { return }
        let path = prefix.isEmpty ? head : prefix + "/" + head
        var index = nodes.firstIndex { $0.path == path }
        if index == nil { nodes.append(FolderNode(path: path, name: head)); index = nodes.count - 1 }
        if parts.count == 1 { nodes[index!].folderIds.append(folderId) } else {
            insert(parts.dropFirst(), prefix: path, folderId: folderId, into: &nodes[index!].children)
        }
    }

    private static func sorted(_ nodes: [FolderNode]) -> [FolderNode] {
        nodes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { var n = $0; n.children = sorted(n.children); return n }
    }
}

/// Recursive folder row; items dropped on a real folder move into it.
/// A shared vault in the sidebar: its name (all of its items), with its shared folders under it, and what you can do
/// with it on a right-click.
private struct SharedVaultRow: View {
    @Environment(AppModel.self) private var model
    let org: Grouping
    let count: (SidebarSelection) -> Int
    @State private var expanded = true

    private var label: some View {
        SidebarLabel(verbatim: org.name, symbol: "building.2", tag: .organization(org.id), count: count(.organization(org.id)))
            .tag(SidebarSelection.organization(org.id))
            .contextMenu {
                Group {
                    Button("Event Log…", systemImage: "list.bullet.rectangle") { model.eventLogFor = org.id }
                    Button("Leave Shared Vault…", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        model.leaveOrganization(org.id)
                    }
                }
                .labelStyle(.titleAndIcon)
                .tint(Color(nsColor: .labelColor))
            }
    }

    var body: some View {
        let tree = FolderNode.tree(org.children)
        if tree.isEmpty {
            label
        } else {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(tree) { SharedFolderRow(node: $0, count: count) }
            } label: { label }
        }
    }
}

/// A shared folder (collection) in the sidebar, with the ones nested under it. A level that's only part of others'
/// names ("Engineering" for "Engineering/Backend") is a heading, not something to select.
private struct SharedFolderRow: View {
    let node: FolderNode
    let count: (SidebarSelection) -> Int
    @State private var expanded = true

    @ViewBuilder private var label: some View {
        if let id = node.folderIds.first {
            SidebarLabel(verbatim: node.name, symbol: "rectangle.stack", tag: .collection(id), count: count(.collection(id)))
                .tag(SidebarSelection.collection(id))
        } else {
            SidebarLabel(verbatim: node.name, symbol: "rectangle.stack")
        }
    }

    var body: some View {
        if node.children.isEmpty {
            label
        } else {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(node.children) { SharedFolderRow(node: $0, count: count) }
            } label: { label }
        }
    }
}

private struct FolderRow: View {
    @Environment(AppModel.self) private var model
    let node: FolderNode
    let count: (SidebarSelection) -> Int
    @State private var expanded = true
    @State private var targeted = false

    var body: some View {
        let label = SidebarLabel(verbatim: node.name, symbol: node.folderIds.isEmpty ? "folder.badge.questionmark" : "folder",
                                 tag: .folder(node.path), count: count(.folder(node.path)))
            .tag(SidebarSelection.folder(node.path))
            .listRowBackground(targeted ? Color.brand.opacity(0.18).clipShape(.rect(cornerRadius: 6)) : nil)
            .dropDestination(for: String.self) { ids, _ in
                guard !node.folderIds.isEmpty else { return false }
                Task { await model.move(itemIDs: ids, toFolderIn: node.folderIds) }
                return true
            } isTargeted: { targeted = $0 }
            .contextMenu {
                Group {
                    Button("New Subfolder…", systemImage: "folder.badge.plus") { model.promptNewFolder(in: node.path) }
                    Button("Rename…", systemImage: "pencil") { model.renamingFolder = node.path }
                    if !node.folderIds.isEmpty {
                        Divider()
                        Button("Delete Folder…", systemImage: "folder.badge.minus", role: .destructive) {
                            model.confirmDeleteFolder(name: node.name, ids: node.folderIds)
                        }
                    }
                }
                .labelStyle(.titleAndIcon)
                .tint(Color(nsColor: .labelColor)) // the sidebar's selection tint would colour the menu's icons blue
            }
        if node.children.isEmpty {
            label
        } else {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(node.children) { FolderRow(node: $0, count: count) }
            } label: { label }
        }
    }
}

// MARK: Search

/// Centered toolbar search, ⌘F to focus.
/// Looks like a search field; opens the command palette (⌘K / ⌘F).
private struct PaletteTrigger: View {
    @Environment(AppModel.self) private var model
    /// Matches the + and the bell so the header controls share one height.
    static let height: CGFloat = 32
    /// A narrow header: just "Search".
    var compactLabel = false
    @State private var hovering = false

    /// A tappable view rather than a `Button`: a toolbar slot holding only a button is replaced by a native toolbar
    /// button, which loses this capsule.
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium))
            Text(compactLabel ? "Search" : "Search or run a command").font(.system(size: 13)).lineLimit(1)
            Spacer()
            Text(verbatim: "⌘K")
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 4))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .modifier(HeaderChrome(shape: .capsule, hovering: hovering))
        .contentShape(.capsule)
        .onTapGesture { model.openPalette() }
        .onHover { hovering = $0 }
        .help(Text("Search or run a command (⌘K)"))
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text("Search or run a command"))
        .accessibilityAction { model.openPalette() }
    }
}

/// The + for new items of every kind, in the window's header beside the sidebar's toggle: round, like the header's
/// other controls.
private struct NewItemButton: View {
    @Environment(AppModel.self) private var model
    static let size: CGFloat = PaletteTrigger.height
    @State private var hovering = false

    var body: some View {
        Menu {
            Group {
                Button("New Login", systemImage: "key") { model.beginEditing(EditRequest(mode: .create(.login))) }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Secure Note", systemImage: "note.text") { model.beginEditing(EditRequest(mode: .create(.secureNote))) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Card", systemImage: "creditcard") { model.beginEditing(EditRequest(mode: .create(.card))) }
                Button("New Identity", systemImage: "person.crop.rectangle") { model.beginEditing(EditRequest(mode: .create(.identity))) }
                Button("New SSH Key", systemImage: "terminal") { model.beginEditing(EditRequest(mode: .create(.sshKey))) }
                Divider()
                Button("New Send", systemImage: "paperplane") {
                    model.requestedSection = .sends
                    model.composingSend = true
                }
                Button("New Folder…", systemImage: "folder.badge.plus") { model.promptNewFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Divider()
                Button("Import…", systemImage: "square.and.arrow.down") { model.beginImport() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(model.sessions.isEmpty)
            }
            .labelStyle(.titleAndIcon)
        } label: {
            Image(systemName: "plus").font(.system(size: 14, weight: .medium))
                .frame(width: Self.size, height: Self.size)
                .modifier(HeaderChrome(shape: .circle, hovering: hovering))
                .contentShape(.circle)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .tint(Color(nsColor: .labelColor)) // in the sidebar, whose selection tint would colour the menu's icons blue
        .onHover { hovering = $0 }
        .help(Text("New Item (⌘N)"))
        .accessibilityLabel(Text("New Item"))
    }
}

/// Shows `content` in an AppKit popover attached to the bottom edge of this view. SwiftUI's toolbar popover
/// does not appear when asked to open downward.
private struct BelowPopover<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isPresented = $isPresented
        if isPresented {
            let popover = context.coordinator.makePopover()
            context.coordinator.host?.rootView = AnyView(content())
            guard !popover.isShown, !context.coordinator.pendingShow, nsView.window != nil else { return }
            context.coordinator.pendingShow = true
            DispatchQueue.main.async {
                context.coordinator.pendingShow = false
                guard context.coordinator.isPresented.wrappedValue, nsView.window != nil, popover.isShown == false else { return }
                context.coordinator.host?.view.layoutSubtreeIfNeeded()
                popover.show(relativeTo: nsView.bounds, of: nsView, preferredEdge: .minY)
            }
        } else if let popover = context.coordinator.popover, popover.isShown {
            popover.performClose(nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSPopoverDelegate {
        var popover: NSPopover?
        var host: NSHostingController<AnyView>?
        var isPresented: Binding<Bool> = .constant(false)
        var pendingShow = false

        func makePopover() -> NSPopover {
            if let popover { return popover }
            let host = NSHostingController(rootView: AnyView(EmptyView()))
            host.sizingOptions = .preferredContentSize
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            popover.contentViewController = host
            popover.delegate = self
            self.host = host
            self.popover = popover
            return popover
        }

        func popoverDidClose(_ notification: Notification) {
            popover = nil
            host = nil
            if isPresented.wrappedValue { isPresented.wrappedValue = false }
        }
    }
}

/// Header bell, just right of search. Opens whatever is waiting: an SSH signature, and the other notices.
private struct SSHRequestsButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    @State private var open = false
    @State private var emergency: [EmergencyNotice] = []

    var body: some View {
        let count = Inbox.badgeCount(model: model, emergency: emergency)
        Button { open.toggle() } label: {
            Image(systemName: "bell")
                .font(.system(size: 14, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .frame(width: PaletteTrigger.height, height: PaletteTrigger.height)
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        Text(verbatim: count > 9 ? "9+" : "\(count)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .frame(minWidth: 14, minHeight: 14)
                            .background(Color.red, in: .capsule)
                            .offset(x: 3, y: -1)
                    }
                }
                .modifier(HeaderChrome(shape: .circle, hovering: hovering))
                .contentShape(.circle)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(Text("Notifications"))
        .accessibilityLabel(Text("Notifications"))
        .accessibilityValue(Text("^[\(count) waiting](inflect: true)"))
        .onAppear { revealIfAsked() }
        .onChange(of: model.presentInbox) { _, _ in revealIfAsked() }
        .task(id: model.isUnlocked) {
            await loadEmergency()
            model.announceInbox()
        }
        .onChange(of: model.sessions.map { $0.lastSyncError ?? "" }) { _, _ in model.announceInbox() }
        .onChange(of: model.updates.availableVersion) { _, _ in model.announceInbox() }
        .background {
            // A toolbar popover with `arrowEdge: .bottom` never appears. Anchor an AppKit popover to this button instead.
            BelowPopover(isPresented: $open) {
                SSHRequestsPopover(emergency: emergency, close: { open = false }) { await loadEmergency() }
                    .environment(model)
                    .environment(\.colorScheme, scheme)
            }
        }
    }

    private func revealIfAsked() {
        guard model.presentInbox else { return }
        open = true
        model.presentInbox = false
    }

    private func loadEmergency() async {
        guard model.isUnlocked else { emergency = []; return }
        var notes: [EmergencyNotice] = []
        for session in model.sessions {
            guard let trusted = try? await session.emergencyContacts(granted: false),
                  let granted = try? await session.emergencyContacts(granted: true) else { continue }
            for contact in trusted where contact.status == .recoveryInitiated || contact.status == .accepted {
                notes.append(EmergencyNotice(sessionID: session.id, contact: contact, granted: false))
            }
            for contact in granted where contact.status == .recoveryApproved {
                notes.append(EmergencyNotice(sessionID: session.id, contact: contact, granted: true))
            }
        }
        emergency = notes
    }
}

/// The request list for the header bell: the waiting signature, other notices, trusts, and the recent log.
private struct SSHRequestsPopover: View {
    @Environment(AppModel.self) private var model
    var emergency: [EmergencyNotice]
    var close: () -> Void
    var reloadEmergency: () async -> Void

    var body: some View {
        let agent = model.sshAgent!
        let notes = Inbox.notes(model: model, emergency: emergency, dismiss: close, reload: reloadEmergency)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Notifications")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                if !agent.accessLog.events.isEmpty {
                    Button("Clear") { agent.clearAccessLog() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            if let prompt = agent.pending {
                SSHApprovalCard(prompt: prompt, leadsWithUntilLock: agent.pendingLeadsWithUntilLock) { choice in
                    agent.choose(choice)
                }
            }
            if !agent.trustedUntilLock.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Trusted until lock")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    ForEach(agent.trustedUntilLock) { trust in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: trust.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text(verbatim: trust.keyName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Button("Remove") { agent.revokeTrust(id: trust.id) }
                                .buttonStyle(.appSecondarySmall)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 12, style: .continuous))
                    }
                }
            }
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Needs attention")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(notes) { note in
                                InboxRow(note: note)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                    .scrollBounceBehavior(.basedOnSize)
                    .thinScroller()
                }
            }
            if agent.accessLog.events.isEmpty, agent.pending == nil, notes.isEmpty {
                Text("Nothing waiting.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else if !agent.accessLog.events.isEmpty {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(agent.accessLog.events.prefix(8)) { event in
                            SSHAccessRow(event: event) {
                                guard let item = model.items.first(where: {
                                    $0.kind == .sshKey && !$0.isDeleted && $0.name == event.keyName
                                }) else { return }
                                close()
                                model.showItem(item.id)
                            }
                        }
                    }
                }
                .frame(maxHeight: 280)
                .scrollBounceBehavior(.basedOnSize)
                .thinScroller()
            }
        }
        .padding(14)
        .frame(width: 380)
        .task { await reloadEmergency() }
    }

}

/// One SSH access record: app, what it signed with, and how the request ended.
private struct SSHAccessRow: View {
    let event: SSHAccessEvent
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            row
        }
        .buttonStyle(PressableRowStyle())
    }

    private var row: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.16), in: .rect(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: event.appName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text("SSH access")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08), in: .capsule)
                        .layoutPriority(1)
                }
                Text("via \(event.via) · \(event.keyName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(tint.opacity(0.16), in: .capsule)
                Text(verbatim: SSHAccessClock.label(since: event.date))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(.rect(cornerRadius: 12, style: .continuous))
    }

    private var symbol: String {
        switch event.outcome {
        case .allowedOnce, .allowedForTenMinutes, .allowedUntilLock, .reusedTrust: "checkmark"
        case .allowlisted: "checkmark.seal"
        case .denied: "xmark"
        case .timedOut: "clock"
        case .locked: "lock"
        }
    }

    private var tint: Color {
        switch event.outcome {
        case .allowedOnce, .allowedForTenMinutes, .allowedUntilLock, .allowlisted, .reusedTrust:
            Color(red: 0.35, green: 0.78, blue: 0.55)
        case .denied: Color(red: 0.95, green: 0.45, blue: 0.42)
        case .timedOut: Color(red: 0.95, green: 0.72, blue: 0.38)
        case .locked: .secondary
        }
    }

    private var label: LocalizedStringKey {
        switch event.outcome {
        case .allowedOnce: "Allowed once"
        case .allowedForTenMinutes: "Allowed for 10 minutes"
        case .allowedUntilLock: "Trusted until lock"
        case .allowlisted: "Always allowed"
        case .denied: "Denied"
        case .timedOut: "Timed out"
        case .locked: "Vault locked"
        case .reusedTrust: "Used an existing grant"
        }
    }
}

/// One person involved in emergency access who needs a decision.
private struct EmergencyNotice: Identifiable {
    let sessionID: String
    let contact: EmergencyContact
    /// A vault that trusts this account, rather than someone trusted with this vault.
    let granted: Bool
    var id: String { sessionID + contact.id + (granted ? "-g" : "-t") }
    var person: String { contact.name.map { "\($0) · \(contact.email)" } ?? contact.email }
}

/// A row in the bell that is not an SSH signature.
private struct InboxNote: Identifiable {
    let id: String
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    var primaryTitle: LocalizedStringKey?
    var primary: () -> Void = {}
    var secondaryTitle: LocalizedStringKey?
    var secondary: () -> Void = {}
}

/// Press and hover for a row in the bell. The fill lives here so a click is visible.
private struct PressableRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.16 : (hovering ? 0.10 : 0.05)),
                in: .rect(cornerRadius: 12, style: .continuous)
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct InboxRow: View {
    let note: InboxNote

    var body: some View {
        HStack(spacing: 0) {
            Button(action: note.primary) {
                HStack(spacing: 10) {
                    Image(systemName: note.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(note.tint)
                        .frame(width: 26, height: 26)
                        .background(note.tint.opacity(0.16), in: .rect(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: note.title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        Text(verbatim: note.subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if note.secondaryTitle == nil, let primaryTitle = note.primaryTitle {
                        Text(primaryTitle)
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(.rect(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(PressableRowStyle())
            .disabled(note.primaryTitle == nil)
            if let secondaryTitle = note.secondaryTitle {
                Button(secondaryTitle, action: note.secondary)
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .medium))
                if let primaryTitle = note.primaryTitle {
                    Button(primaryTitle, action: note.primary)
                        .buttonStyle(.borderless)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.trailing, 10)
                }
            }
        }
    }
}

/// What the bell counts and lists, besides the SSH card and its log.
@MainActor
private enum Inbox {
    static func badgeCount(model: AppModel, emergency: [EmergencyNotice]) -> Int {
        var count = model.sshAgent?.pending == nil ? 0 : 1
        if model.sessions.contains(where: { $0.lastSyncError != nil }) { count += 1 }
        if model.updates.availableVersion != nil { count += 1 }
        if !expiringOrOpened(model.sends).isEmpty { count += 1 }
        if hasUrgentWatchtower(model) { count += 1 }
        if !emergency.isEmpty { count += 1 }
        return count
    }

    static func notes(model: AppModel, emergency: [EmergencyNotice], dismiss: @escaping () -> Void, reload: @escaping () async -> Void) -> [InboxNote] {
        var notes: [InboxNote] = []
        if model.sessions.contains(where: { $0.lastSyncError != nil }) {
            notes.append(InboxNote(
                id: "sync",
                symbol: "arrow.triangle.2.circlepath",
                tint: Color(red: 0.95, green: 0.72, blue: 0.38),
                title: String(localized: "Couldn't sync"),
                subtitle: String(localized: "The vault on this Mac is unchanged."),
                primaryTitle: "Retry",
                primary: { model.scheduleSync() }
            ))
        }
        if let version = model.updates.availableVersion {
            notes.append(InboxNote(
                id: "update",
                symbol: "arrow.down.circle",
                tint: Color(red: 0.35, green: 0.78, blue: 0.55),
                title: String(localized: "Update \(version) is ready"),
                subtitle: String(localized: "Install when you're ready."),
                primaryTitle: "Install",
                primary: {
                    model.updates.checkForUpdates()
                    dismiss()
                }
            ))
        }
        for notice in emergency {
            guard let session = model.session(for: notice.sessionID) else { continue }
            if notice.granted {
                notes.append(InboxNote(
                    id: "emergency-" + notice.id,
                    symbol: "person.badge.key",
                    tint: Color(red: 0.95, green: 0.45, blue: 0.42),
                    title: notice.person,
                    subtitle: String(localized: "Emergency access granted"),
                    primaryTitle: "Review",
                    primary: {
                        model.showSettings(.accounts)
                        dismiss()
                    }
                ))
            } else if notice.contact.status == .recoveryInitiated {
                notes.append(InboxNote(
                    id: "emergency-" + notice.id,
                    symbol: "person.badge.key",
                    tint: Color(red: 0.95, green: 0.72, blue: 0.38),
                    title: notice.person,
                    subtitle: String(localized: "Asked for emergency access"),
                    primaryTitle: "Approve",
                    primary: {
                        Task {
                            try? await session.emergencyAccess("approve", notice.contact)
                            await reload()
                        }
                    },
                    secondaryTitle: "Reject",
                    secondary: {
                        Task {
                            try? await session.emergencyAccess("reject", notice.contact)
                            await reload()
                        }
                    }
                ))
            } else {
                notes.append(InboxNote(
                    id: "emergency-" + notice.id,
                    symbol: "person.badge.key",
                    tint: .secondary,
                    title: notice.person,
                    subtitle: String(localized: "Needs confirming"),
                    primaryTitle: "Review",
                    primary: {
                        model.showSettings(.accounts)
                        dismiss()
                    }
                ))
            }
        }
        let report = WatchtowerReport(items: model.items, breaches: model.breachCounts)
        for item in (report.issues[.breached] ?? []).prefix(3) {
            notes.append(InboxNote(
                id: "watch-" + item.id,
                symbol: "exclamationmark.shield",
                tint: Color(red: 0.95, green: 0.45, blue: 0.42),
                title: item.name,
                subtitle: String(localized: "Password found in a data breach"),
                primaryTitle: "Open",
                primary: {
                    model.showInWatchtower(item)
                    dismiss()
                }
            ))
        }
        for item in (report.issues[.cardExpiring] ?? []).prefix(2) {
            notes.append(InboxNote(
                id: "card-" + item.id,
                symbol: "creditcard",
                tint: Color(red: 0.95, green: 0.72, blue: 0.38),
                title: item.name,
                subtitle: String(localized: "Card expiring soon"),
                primaryTitle: "Open",
                primary: {
                    model.showInWatchtower(item)
                    dismiss()
                }
            ))
        }
        for send in expiringOrOpened(model.sends).prefix(4) {
            let expiring = isExpiringSoon(send)
            notes.append(InboxNote(
                id: "send-" + send.id,
                symbol: "paperplane",
                tint: expiring ? Color(red: 0.95, green: 0.72, blue: 0.38) : .secondary,
                title: send.name,
                subtitle: expiring
                    ? String(localized: "Send expires soon")
                    : String(localized: "Opened \(send.accessCount) times"),
                primaryTitle: "Open",
                primary: {
                    model.requestedSection = .sends
                    dismiss()
                }
            ))
        }
        return notes
    }

    private static func hasUrgentWatchtower(_ model: AppModel) -> Bool {
        let report = WatchtowerReport(items: model.items, breaches: model.breachCounts)
        return !(report.issues[.breached] ?? []).isEmpty || !(report.issues[.cardExpiring] ?? []).isEmpty
    }

    private static func isExpiringSoon(_ send: SendItem) -> Bool {
        let soon = Date.now.addingTimeInterval(48 * 60 * 60)
        guard let date = send.expirationDate ?? send.deletionDate else { return false }
        return date > .now && date < soon
    }

    private static func expiringOrOpened(_ sends: [SendItem]) -> [SendItem] {
        var seen = Set<String>()
        var picked: [SendItem] = []
        for send in sends where !send.disabled && !send.isExpired {
            let opened = send.accessCount > 0 && !send.isUsedUp
            guard isExpiringSoon(send) || opened else { continue }
            guard seen.insert(send.id).inserted else { continue }
            picked.append(send)
        }
        return picked.sorted { isExpiringSoon($0) && !isExpiringSoon($1) }
    }
}

/// Sidebar › Generator: passwords, passphrases and usernames as a page.
private struct GeneratorPane: View {
    var body: some View {
        GeometryReader { geo in
            ScrollView {
                GeneratorView()
                    .padding(.leading, VaultView.pageInset)
                    .padding(.bottom, 24) // the header row at the top, like the vault page's search row
                    .frame(maxWidth: 1180)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .topLeading)
            }
            .modifier(SideOverflowClip())
            .thinScroller()
        }
    }
}

// MARK: Item column

/// How the item list is ordered, and the section headers that go with it.
enum ItemSort: String, CaseIterable, Identifiable {
    case title, edited, created
    var id: Self { self }

    var title: LocalizedStringKey {
        switch self { case .title: "Title"; case .edited: "Date Edited"; case .created: "Date Created" }
    }
    var symbol: String {
        switch self { case .title: "textformat"; case .edited: "pencil"; case .created: "calendar" }
    }
    func orderTitle(ascending: Bool) -> LocalizedStringKey {
        switch self {
        case .title: ascending ? "A to Z" : "Z to A"
        case .edited, .created: ascending ? "Oldest First" : "Newest First"
        }
    }

    /// The index letter for a title: A–Z, with Chinese and Japanese romanised (銀行 → Y) and everything else "#".
    static func letter(_ name: String) -> String {
        let latin = name.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) ?? name
        guard let first = latin.trimmingCharacters(in: .whitespacesAndNewlines).first.map({ String($0).uppercased() }),
              first.count == 1, ("A"..."Z").contains(first) else { return "#" }
        return first
    }

    private func date(_ item: VaultItem) -> Date? { self == .created ? item.created : item.revised }

    static func sorted(_ items: [VaultItem], by sort: ItemSort, ascending: Bool) -> [VaultItem] {
        switch sort {
        case .title:
            // Letters A–Z, then # (numbers and symbols), then by name within a letter.
            let keyed = items.map { (item: $0, letter: letter($0.name)) }
            let ordered = keyed.sorted { a, b in
                if a.letter != b.letter {
                    if a.letter == "#" || b.letter == "#" { return b.letter == "#" }
                    return a.letter < b.letter
                }
                return a.item.name.localizedStandardCompare(b.item.name) == .orderedAscending
            }.map(\.item)
            return ascending ? ordered : ordered.reversed()
        case .edited, .created:
            // Items without a date go last either way.
            let dated = items.filter { sort.date($0) != nil }.sorted { sort.date($0)! < sort.date($1)! }
            return (ascending ? dated : dated.reversed()) + items.filter { sort.date($0) == nil }
        }
    }

    /// Consecutive runs of the (already sorted) items under one header each.
    static func sections(_ items: [VaultItem], by sort: ItemSort) -> [(title: String, items: [VaultItem])] {
        let month = Date.FormatStyle().month(.wide).year()
        var out: [(title: String, items: [VaultItem])] = []
        for item in items {
            let title: String
            switch sort {
            case .title: title = letter(item.name)
            case .edited, .created: title = sort.date(item).map { $0.formatted(month) } ?? String(localized: "No Date")
            }
            if out.last?.title == title { out[out.count - 1].items.append(item) } else { out.append((title, [item])) }
        }
        return out
    }
}

/// A line of the item list: a section's header, or an item. Identified by the item's id alone, so an item keeps its
/// row wherever its section goes.
private enum ListLine: Identifiable {
    case header(String)
    case item(VaultItem)

    var id: String {
        switch self {
        case .header(let title): "header:" + title
        case .item(let item): item.id
        }
    }

    static func lines(_ sections: [(title: String, items: [VaultItem])]) -> [ListLine] {
        sections.flatMap { [.header($0.title)] + $0.items.map(ListLine.item) }
    }
}

/// A pinned list header ("A", "October 2026"): plain text on the list's surface, like Contacts and 1Password.
private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(verbatim: title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(height: 20)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct ItemColumn: View {
    let items: [VaultItem]
    /// The Trash: a note on when its items go for good.
    var isTrash = false
    @Binding var selection: VaultItem.ID?
    @Binding var query: String
    @Binding var sort: String
    @Binding var ascending: Bool
    /// What the list shows (the sidebar section): another one fades the rows, while the filter and sort stay put.
    var listID: SidebarSelection? = nil

    @Environment(AppModel.self) private var model
    @FocusState private var filterFocused: Bool
    @FocusState private var listFocused: Bool

    private func picked(_ item: VaultItem) -> Bool {
        model.multiSelection.isEmpty ? item.id == selection : model.multiSelection.contains(item.id)
    }

    /// A click: plain selects one; ⌘ adds or removes; ⇧ extends from the selected item in list order.
    private func click(_ item: VaultItem, ordered: [VaultItem]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            var picked = model.multiSelection.isEmpty ? Set(selection.map { [$0] } ?? []) : model.multiSelection
            if picked.contains(item.id) { picked.remove(item.id) } else { picked.insert(item.id) }
            withAnimation(.snappy(duration: 0.2)) { model.multiSelection = picked.count > 1 ? picked : [] }
            if picked.count <= 1 { selection = picked.first ?? item.id }
        } else if flags.contains(.shift), let anchor = selection, let a = ordered.firstIndex(where: { $0.id == anchor }),
                  let b = ordered.firstIndex(where: { $0.id == item.id }), a != b {
            withAnimation(.snappy(duration: 0.2)) { model.multiSelection = Set(ordered[min(a, b)...max(a, b)].map(\.id)) }
        } else {
            if !model.multiSelection.isEmpty { withAnimation(.snappy(duration: 0.2)) { model.multiSelection = [] } }
            selection = item.id
        }
    }

    private func step(_ delta: Int, _ proxy: ScrollViewProxy) {
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selection } ?? (delta > 0 ? -1 : items.count)
        let next = items[min(max(current + delta, 0), items.count - 1)].id
        selection = next
        proxy.scrollTo(next)
    }

    var body: some View {
        let order = ItemSort(rawValue: sort) ?? .title
        VStack(spacing: 10) {
            // Narrow the list by typing, and choose its order.
            HStack(spacing: 6) {
                VaultSearchField(query: $query, focused: $filterFocused) {
                    listFocused = true
                    if selection == nil || !items.contains(where: { $0.id == selection }) { selection = items.first?.id }
                }
                SearchFilterMenu()
                Menu {
                    Picker("Sort By", selection: $sort) {
                        ForEach(ItemSort.allCases) { Label($0.title, systemImage: $0.symbol).tag($0.rawValue) }
                    }
                    .pickerStyle(.inline)
                    Picker("Order", selection: $ascending) {
                        Text(order.orderTitle(ascending: true)).tag(true)
                        Text(order.orderTitle(ascending: false)).tag(false)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .modifier(HeaderChrome(shape: .circle))
                        .contentShape(.circle)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(Text("Sort"))
                .accessibilityLabel(Text("Sort"))
            }
            // Flush with the list's panel (and the header's + above it).
            .zIndex(1) // the search's suggestions hang over the list

            // Once, the first time the search is used: filters can be typed and they stay on.
            if Motion.plays { // never in renders, which must look the same every run
                TipView(SearchFiltersTip())
                    .tipImageStyle(.secondary)
            }

            // The filters that are on, under the field, until they're cleared.
            if model.hasSearchFilters {
                SearchFilterBar(resultCount: items.count)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if isTrash, !items.isEmpty { TrashNotice(items: items) }

            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    // A–Z (then #) by title, or by month by date. One flat run, headers in line with the rows: with a
                    // ForEach per section, a row whose item moved to another section (renamed "Arm…" → "Oracle…")
                    // kept drawing its old self.
                    ForEach(ListLine.lines(ItemSort.sections(items, by: order))) { line in
                        switch line {
                        case .header(let title):
                            SectionHeader(title: title)
                        case .item(let item):
                            ItemRow(item: item, isSelected: picked(item), highlight: query)
                                .modifier(ArrivalPop(arrived: model.arrivedID == item.id))
                                .onTapGesture { click(item, ordered: ItemSort.sections(items, by: order).flatMap(\.items)) }
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(item.id == selection ? [.isButton, .isSelected] : .isButton)
                                .accessibilityAction { selection = item.id }
                                .draggable(item.id) { ItemRow(item: item, isSelected: true).frame(width: 260) }
                                .contextMenu { ItemContextMenu(item: item) }
                                // Trashed, archived or deleted: the row slips out; restored ones fade back in.
                                .transition(.asymmetric(insertion: .opacity,
                                                        removal: .opacity.combined(with: .scale(scale: 0.96)).combined(with: .move(edge: .leading))))
                        }
                    }
                }
                .padding(6)
                .id(listID) // another section: only the rows crossfade; the panel, filter and sort stay
                .transition(.opacity)
            }
            // ↑/↓ move the selection; the filter field hands focus here with ↓ too.
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { step(1, proxy); return .handled }
            .onKeyPress(.upArrow) { step(-1, proxy); return .handled }
            .onKeyPress(.escape) {
                guard !model.multiSelection.isEmpty else { return .ignored }
                withAnimation(.snappy(duration: 0.2)) { model.multiSelection = [] }
                return .handled
            }
            .onKeyPress(characters: ["a"], phases: .down) { press in
                guard press.modifiers.contains(.command), items.count > 1 else { return .ignored }
                withAnimation(.snappy(duration: 0.2)) { model.multiSelection = Set(items.map(\.id)) }
                return .handled
            }
            }
            .thinScroller() // the app's slim scroller: on hover and while scrolling
            .background(Color.panel, in: .rect(cornerRadius: 18, style: .continuous))
            .overlay {
                if items.isEmpty {
                    let searching = !query.isEmpty || model.hasSearchFilters
                    ContentUnavailableView {
                        Label(searching ? "No Results" : "No Items", systemImage: searching ? "magnifyingglass" : "tray")
                    } description: {
                        if model.hasSearchFilters { Text("Filters are on.") }
                    } actions: {
                        if model.hasSearchFilters {
                            Button("Clear Filters") { withAnimation(.snappy(duration: 0.25)) { model.clearSearchFilters() } }
                        } else if !searching, !isTrash, !model.accounts.isEmpty {
                            // Nothing here yet: bring items over from another app (or drop its export on the window).
                            Button("Import…", systemImage: "square.and.arrow.down") { model.beginImport() }
                                .buttonStyle(.appSecondary)
                        }
                    }
                    .modifier(WindowCentered())
                }
            }
            .overlay(alignment: .bottom) {
                let picked = items.filter { model.multiSelection.contains($0.id) }
                if picked.count > 1 {
                    SelectionBar(items: picked)
                        .padding(10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.25), value: model.multiSelection.count > 1)
        }
        .padding(.horizontal, 6)
        .animation(.snappy(duration: 0.25), value: model.hasSearchFilters)
        .onChange(of: model.hasSearchFilters) { _, on in if on { SearchFiltersTip().invalidate(reason: .actionPerformed) } }
        .onChange(of: items.isEmpty, initial: true) { _, empty in if !empty { Bench.markAfterCommit("vault-ready") } }
        // ⌘F, also when the list has only just appeared for it.
        .onChange(of: model.wantsSearchFocus, initial: true) { _, wants in
            guard wants else { return }
            model.wantsSearchFocus = false
            Task { @MainActor in filterFocused = true } // after the field is in the window
        }
    }
}

struct ItemRow: View {
    @Environment(AppModel.self) private var model
    let item: VaultItem
    var isSelected = false
    /// Search text to highlight in the name and username.
    var highlight = ""
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            ItemIcon(item: item, size: 38)
            VStack(alignment: .leading, spacing: 1) {
                // Whose it is, when several accounts are open: the account's letters at the end of the name.
                HStack(spacing: 6) {
                    Text(Highlight.marked(item.name, highlight)).font(.system(size: 14, weight: .bold)).lineLimit(1)
                    Spacer(minLength: 0)
                    AccountTag(accountId: item.accountId)
                }
                if let username = item.username {
                    Text(Highlight.marked(username, highlight)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                // Marks in one row under the name, so the name keeps the full width.
                let issue = item.passwordIssue(breaches: model.breachCounts)
                let purge = model.purgeDate(item)
                if issue != nil || item.favorite || item.hasTOTP || purge != nil {
                    HStack(spacing: 6) {
                        if let purge { PurgeChip(date: purge) }
                        if let issue {
                            HStack(spacing: 3) {
                                Image(systemName: issue.rowSymbol).font(.system(size: 9, weight: .bold))
                                Text(issue.shortLabel).font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundStyle(issue.tint)
                            .padding(.horizontal, 6).frame(height: 17)
                            .background(issue.tint.opacity(0.14), in: .capsule)
                            .help(Text(issue.rowLabel))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text(issue.rowLabel))
                        }
                        if item.favorite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.yellow)
                                .accessibilityLabel(Text("Favorite"))
                        }
                        if item.hasTOTP {
                            Image(systemName: "clock.badge.checkmark")
                                .font(.system(size: 11, weight: .medium))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.secondary)
                                .help(Text("Has a one-time code"))
                                .accessibilityLabel(Text("Has a one-time code"))
                        }
                    }
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.rowSelected)
                    .shadow(color: .black.opacity(0.12), radius: 9, y: 6)
            } else if hovered {
                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.primary.opacity(0.04))
            }
        }
        .contentShape(.rect)
        .onHover { hovered = $0 }
        .animation(.snappy(duration: 0.18), value: isSelected)
    }
}

// MARK: Detail

extension EnvironmentValues {
    /// False while the detail pane sits off-screen on the narrow-window strip.
    @Entry var showsDetailToolbar = true
    /// The vault window's vertical middle, in window coordinates: empty states line up on it across columns.
    @Entry var windowMidY: CGFloat?
}

/// An empty state centred on the window's middle rather than its own column's, so the list's and the detail's sit on
/// one line however their panels are inset (the filter bar above one, the footer below the other).
struct WindowCentered: ViewModifier {
    @Environment(\.windowMidY) private var windowMidY

    func body(content: Content) -> some View {
        GeometryReader { geo in
            let own = geo.frame(in: .global).midY
            content
                .frame(width: geo.size.width, height: geo.size.height)
                .offset(y: windowMidY.map { $0 - own } ?? 0)
        }
    }
}

struct ItemDetail: View {
    /// The cards' inset from the list (on the right they run to the pane's edge, like the header and footer).
    static let detailInset: CGFloat = 18
    @Environment(\.showsDetailToolbar) private var showsToolbar
    @Environment(AppModel.self) private var model
    let item: VaultItem
    @State private var revealToggle = false
    /// ⌥ peek, after a short hold. Releasing ⌥ waits a moment, then the secret rolls back into dots.
    @State private var optionPeek = false
    @State private var peekWait: Task<Void, Never>?
    @State private var starBurst = 0
    @State private var confirmDelete = false
    @State private var dropping = false
    /// Revealed by the eye, or by holding ⌥.
    private var secretsVisible: Bool { revealToggle || optionPeek }

    /// Holding ⌥ alone peeks. A quick tap does nothing; letting go waits, then the mask rolls back.
    private func setOptionPeek(_ held: Bool) {
        peekWait?.cancel()
        peekWait = Task {
            if held {
                try? await Task.sleep(for: .milliseconds(260))
                guard !Task.isCancelled, model.isRepromptPassed(item) else { return }
                optionPeek = true
            } else {
                try? await Task.sleep(for: .milliseconds(160))
                guard !Task.isCancelled else { return }
                optionPeek = false
            }
        }
    }

    var body: some View {
        ScrollView {
            StaggeredStack(spacing: 18) {
                if item.isDeleted {
                    Group {
                        if let purge = model.purgeDate(item) {
                            Label("In Trash until \(purge.formatted(date: .abbreviated, time: .omitted)), when Bitwarden deletes it for good. Restore it to use it again.",
                                  systemImage: "trash")
                        } else {
                            Label("In Trash. Restore it to use it again, or delete it forever.", systemImage: "trash")
                        }
                    }
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                HeroCard(item: item, reveal: secretsVisible)

                if !item.fields.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(item.fields.enumerated()), id: \.element.id) { index, field in
                            FieldLine(item: item, field: field, reveal: secretsVisible)
                                .overlay(alignment: .top) { if index > 0 { Divider().opacity(0.6).padding(.leading, 16) } }
                        }
                    }
                    .background(Color.panelStrong, in: .rect(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.panelEdge))
                }

                VStack(spacing: 0) {
                    ForEach(Array(item.websites.enumerated()), id: \.offset) { index, address in
                        let url = URL(string: address.contains("://") ? address : "https://" + address)
                        DetailRow(symbol: "globe", title: index == 0 ? "Website" : "Website \(index + 1)") {
                            Button { if let url { NSWorkspace.shared.open(url) } } label: {
                                HStack(spacing: 5) {
                                    Text(verbatim: address).lineLimit(1).truncationMode(.middle)
                                    Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .foregroundStyle(.primary)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .disabled(url == nil)
                            .help(Text("Open in your browser"))
                            .contextMenu {
                                Button("Copy", systemImage: "doc.on.doc") { model.copyPlain(address) }
                            }
                        }
                    }
                    // Which vault it's in: the same names as the sidebar's Vaults (My vault, or a shared vault › its folders).
                    if item.organizationId == nil {
                        DetailRow(symbol: "person", title: "Vault") {
                            // Drawn like the Folder row's path (the place in the medium, stronger tone), so the two
                            // rows read alike; the account, when several are open, after it in grey.
                            let email = model.accounts.count > 1 ? model.accounts.first { $0.id == item.accountId }?.email : nil
                            HStack(spacing: 6) {
                                PathCrumbs(parts: [String(localized: "My vault")])
                                if let email {
                                    Text(verbatim: "· " + email).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                            }
                        }
                    }
                    if let orgId = item.organizationId, let org = model.organizations.first(where: { $0.id == orgId }) {
                        DetailRow(symbol: "building.2", title: "Vault") {
                            let paths = org.children.filter { item.collectionIds.contains($0.id) }.map(\.name)
                                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                            Button { model.organizationSheet = .collections(item.id) } label: {
                                HStack(spacing: 8) {
                                    if paths.count == 1 {
                                        // One shared folder: the whole path, from the vault down.
                                        PathCrumbs(parts: [org.name] + PathCrumbs.split(paths[0]), lead: true)
                                    } else {
                                        // Several: the vault, then each folder as a pill (its full path on hover).
                                        Text(verbatim: org.name).fontWeight(.medium)
                                        ForEach(paths, id: \.self) { path in
                                            PathCrumbs(parts: PathCrumbs.split(path))
                                                .padding(.horizontal, 8).frame(height: 22)
                                                .background(Color.primary.opacity(0.06), in: .capsule)
                                                .help(Text(verbatim: PathCrumbs.split(path).joined(separator: " › ")))
                                        }
                                    }
                                    Image(systemName: "pencil").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                                }
                                .foregroundStyle(.secondary).contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .help(Text("Change shared folders"))
                        }
                    } else if let folderId = item.folderId, let folder = model.folders.first(where: { $0.id == folderId }) {
                        DetailRow(symbol: "folder", title: "Folder") {
                            PathCrumbs(parts: PathCrumbs.split(folder.name)).foregroundStyle(.secondary)
                        }
                    }
                    if item.kind == .sshKey, let publicKey = item.properties["publicKey"], !publicKey.isEmpty {
                        DetailRow(symbol: "signature", title: "Git signing") {
                            Button("Copy Setup") {
                                model.copyPlain("""
                                git config --global gpg.format ssh
                                git config --global user.signingkey "key::\(publicKey)"
                                git config --global commit.gpgsign true
                                """)
                            }
                            .buttonStyle(.borderless)
                            .help(Text("Commands that make git sign commits with this key through the Triwarden SSH agent"))
                        }
                    }
                    if item.hasPasskey {
                        DetailRow(symbol: "person.badge.key", title: "Passkey") {
                            if let pk = item.passkeys.first {
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(verbatim: [pk.userName, pk.rpId].compactMap { $0 }.joined(separator: " · "))
                                    if pk.creationDate > .distantPast {
                                        Text("Created \(pk.creationDate.formatted(date: .abbreviated, time: .omitted))")
                                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                                    }
                                }
                                .foregroundStyle(.secondary)
                            } else {
                                Text("Stored with a key type Triwarden can't use").foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let expiry = item.cardExpiry, expiry < WatchtowerReport.expiryHorizon, let text = item.cardExpiryText {
                        DetailRow(symbol: "creditcard", title: "Card") {
                            HStack(spacing: 7) {
                                Circle().fill(item.isCardExpired ? Color.red : Color.orange).frame(width: 7, height: 7)
                                Text(verbatim: text)
                            }
                        }
                    }
                    if item.password != nil {
                        let issue = item.passwordIssue(breaches: model.breachCounts)
                        DetailRow(symbol: "checkmark.shield", title: "Watchtower") {
                            HStack(spacing: 10) {
                                HStack(spacing: 7) {
                                    Circle().fill(health.tint).frame(width: 7, height: 7)
                                    Text(health.text)
                                }
                                if let issue, issue != .insecure, let host = item.host, !host.isEmpty, !item.isDeleted {
                                    ChangeOnSiteButton(host: host)
                                }
                                if issue != nil, !item.isDeleted {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        // With an issue, the row opens Watchtower at it (the item's other reuses, what to do).
                        .modifier(TappableRow(enabled: issue != nil && !item.isDeleted) { model.showInWatchtower(item) })
                        .help(issue != nil ? Text("Show in Watchtower") : Text(verbatim: ""))
                    }
                    if let notes = item.notes, !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Notes").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                .textCase(.uppercase).tracking(0.6)
                            Text(verbatim: notes).font(.system(size: 13)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 14)
                        .overlay(alignment: .top) { Divider().opacity(0.6) }
                    }
                }
                .background(Color.panelStrong, in: .rect(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.panelEdge))

                if !item.attachments.isEmpty || !item.isDeleted {
                    AttachmentsSection(item: item)
                }

                // When it was made and changed, and the passwords it had before.
                if item.revised != nil || item.created != nil || !item.passwordHistory.isEmpty {
                    ItemHistoryCard(item: item)
                }
            }
            .padding(.leading, Self.detailInset)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
        }
        .modifier(SideOverflowClip())
        .thinScroller()
        .dropDestination(for: URL.self) { urls, _ in
            guard !item.isDeleted, !urls.isEmpty else { return false }
            Task { await model.addAttachments(urls, to: item) }
            return true
        } isTargeted: { dropping = $0 }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.brand, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .background(Color.brand.opacity(0.06), in: .rect(cornerRadius: 18, style: .continuous))
                    .overlay {
                        Label("Drop to attach", systemImage: "paperclip")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                    }
                    .padding(10)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: dropping)
        .toolbar {
            // Item actions sit in the header, top right (Liquid layout) — only while this detail is in view, and not
            // under the lock layer.
            if showsToolbar, model.phase.id == AppModel.Phase.vault.id, model.accountDoor == nil {
                ToolbarSpacer(.flexible)
                // Inset by the detail's own side padding, so the pill's edge lines up with the cards below.
                ToolbarItem { actions }
                    .sharedBackgroundVisibility(.hidden)
            }
        }
        .confirmationDialog("Delete “\(item.name)” forever?", isPresented: $confirmDelete) {
            Button("Delete Forever", role: .destructive) { Task { await model.deleteForever(item) } }
        } message: {
            Text("This can't be undone.")
        }
        .onChange(of: model.optionHeld, initial: true) { _, held in setOptionPeek(held) }
        .onDisappear { peekWait?.cancel() }
    }

    /// What Watchtower says about this password: the same checks as the list's mark.
    private var health: (text: LocalizedStringKey, tint: Color) {
        guard item.password != nil else { return ("", .secondary) }
        switch item.passwordIssue(breaches: model.breachCounts) {
        case .breached?: return ("Seen in \(model.breachCounts?[item.id] ?? 0) data breaches", .red)
        case .reused?: return ("Reused in \(item.reuseCount + 1) items", .orange)
        case .weak?: return ("Weak password", .orange)
        case .insecure?: return ("Sent unencrypted (http://)", .yellow)
        default: return ("Strong · unique", .green)
        }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            if item.isDeleted {
                toolbarButton("arrow.uturn.backward", help: "Restore", effect: .wiggleBack) { Task { await model.restore(item) } }
                toolbarButton("trash.slash", help: "Delete Forever", effect: .bounce) { confirmDelete = true }
                    .foregroundStyle(.red)
            } else {
                // Reveal, then a divider, whenever the item has anything secret (password, private key, card code…).
                if item.password != nil || item.fields.contains(where: \.secret) {
                    toolbarButton(secretsVisible ? "eye.slash" : "eye", help: secretsVisible ? "Hide" : "Reveal (hold ⌥)",
                                  spoken: secretsVisible ? "Hide" : "Reveal") {
                        if secretsVisible {
                            revealToggle = false
                            optionPeek = false
                            peekWait?.cancel()
                        } else {
                            model.guarded(item) { revealToggle = true }
                        }
                    }
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 16).padding(.horizontal, 3)
                }
                toolbarButton(item.isArchived ? "archivebox.fill" : "archivebox", help: item.isArchived ? "Unarchive" : "Archive",
                              spoken: item.isArchived ? "Unarchive" : "Archive", effect: .bounceDown) {
                    Task { await model.setArchived(item, !item.isArchived) }
                }
                toolbarButton(item.favorite ? "star.fill" : "star", help: "Favorite", effect: .bounce) {
                    if !item.favorite { starBurst += 1 }
                    Task { await model.toggleFavorite(item) }
                }
                    .foregroundStyle(item.favorite ? .yellow : .primary)
                    .overlay { Burst(trigger: starBurst) }
                toolbarButton("pencil", help: "Edit (⌘E)", spoken: "Edit", effect: .wiggle) { model.guarded(item) { model.beginEditing(EditRequest(mode: .edit(item))) } }
                toolbarButton("trash", help: "Move to Trash… (⌘⌫)", spoken: "Move to Trash", effect: .bounce) { model.confirmTrash(item) }
            }
        }
        .padding(.horizontal, 3)
        .frame(height: 32)
        .modifier(HeaderChrome(shape: .capsule))
    }

    /// `spoken`: the VoiceOver label when the tooltip carries a shortcut hint, e.g. "Edit" for "Edit (⌘E)".
    private func toolbarButton(_ symbol: String, help: LocalizedStringKey, spoken: LocalizedStringKey? = nil,
                               effect: ToolbarSymbolButton.Effect = .none, action: @escaping () -> Void) -> some View {
        ToolbarSymbolButton(symbol: symbol, effect: effect, action: action)
            .help(Text(help))
            .accessibilityLabel(Text(spoken ?? help))
    }
}

extension HeroCard {
    /// The password and one-time-code tiles.
    @ViewBuilder func tiles(_ style: HeroStyle) -> some View {
                if let password = item.password {
                    Tile(style: style) {
                        passwordArmed = model.copyCount
                        model.copyPassword(item)
                    } content: {
                        let strength = StrengthMeter(password: password).level
                        HStack {
                            CopyCaption(copied: passwordCopied) { Text("Password · click to copy") }
                            Spacer(minLength: 6)
                            Text(strength.1)
                        }
                        .font(.system(size: 12)).foregroundStyle(style.muted)
                        MaskedSecret(secret: password, revealed: reveal)
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .tracking(0.5)
                            .lineLimit(1)
                            .frame(height: 24, alignment: .leading)
                        // Same place and size as the code's countdown bar, so the tiles line up.
                        LevelBar(level: strength.0, color: strength.0 <= 1 ? .red : strength.0 == 2 ? .orange : .green)
                    }
                    .copyTick(armed: $passwordArmed, copied: $passwordCopied)
                    .contextMenu {
                        Button("Copy Password", systemImage: "doc.on.doc") { model.copyPassword(item) }
                        Button("Show in Large Type", systemImage: "textformat.size") { model.showLargeType(item) }
                    }
                }
                if let totp = item.totp {
                    // The code and ring read the app's shared clock; the tile itself never ticks.
                    Tile(style: style) {
                        codeArmed = model.copyCount
                        model.guarded(item) { model.copy(totp.code(at: .now), label: String(localized: "Code")) }
                    } content: {
                        CopyCaption(copied: codeCopied) { Text("One-time code") }
                            .font(.system(size: 12)).foregroundStyle(style.muted)
                        HStack(alignment: .center) {
                            LiveOTPCode(totp: totp, size: 22)
                            Spacer(minLength: 8)
                            LiveCountdownRing(totp: totp, size: 34)
                        }
                    }
                    .copyTick(armed: $codeArmed, copied: $codeCopied)
                }
                }
}

/// Light: a plain white card. Dark: the deep neutral card. Same layout in both.
private struct HeroStyle {
    let dark: Bool
    var ink: Color { dark ? .white : Color(red: 0.07, green: 0.09, blue: 0.16) }
    var muted: Color { dark ? .white.opacity(0.72) : Color(red: 0.07, green: 0.09, blue: 0.16).opacity(0.58) }
    var tile: Color { dark ? .white.opacity(0.06) : Color.black.opacity(0.035) }
    var tileEdge: Color { dark ? .white.opacity(0.07) : Color.black.opacity(0.04) }
    var track: Color { dark ? .white.opacity(0.15) : Color.brand.opacity(0.14) }
    var bar: Color { dark ? .white : .brand }
    var avatar: Color { dark ? .white.opacity(0.14) : Color.brand.opacity(0.10) }
    var avatarInk: Color { dark ? .white : .brand }
    var secondaryButton: Color { dark ? .white.opacity(0.14) : Color.primary.opacity(0.06) }
}

private struct HeroCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    let item: VaultItem
    let reveal: Bool
    @State var passwordArmed: Int?
    @State var passwordCopied = false
    @State var codeArmed: Int?
    @State var codeCopied = false

    var body: some View {
        let style = HeroStyle(dark: scheme == .dark)
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                // Same icon as the list row (website icon, else the letter tile).
                ItemIcon(item: item, size: 52)
                    .shadow(color: .black.opacity(style.dark ? 0.3 : 0.08), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.system(size: 30, weight: .heavy)).tracking(-0.8).lineLimit(1)
                    Text(verbatim: [item.username, item.host].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(style.muted).lineLimit(1)
                }
            }

            // Tiles share one height: the row sizes to the tallest, each tile fills it. Stacked when the card is narrow
            // (decided in the layout pass, so it's always right for the current width).
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) { tiles(style) }
                    .frame(minWidth: 0, idealWidth: 440, maxWidth: .infinity)
                VStack(spacing: 10) { tiles(style) }
            }
            .fixedSize(horizontal: false, vertical: true)

        }
        .foregroundStyle(style.ink)
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // Plain surface, no colour wash.
            Color.panelStrong // the same surface as every other card, in both modes
            .clipShape(.rect(cornerRadius: 24, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(style.dark ? Color.white.opacity(0.08) : Color.panelEdge))
        .shadow(color: .black.opacity(style.dark ? 0.3 : 0.07), radius: style.dark ? 24 : 18, y: style.dark ? 16 : 8)
    }
}

private struct Tile<Content: View>: View {
    let style: HeroStyle
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) { content }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(style.tile, in: .rect(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(style.tileEdge))
                .contentShape(.rect)
        }
        .buttonStyle(PressScale())
    }
}

/// A tile's caption that reads "Copied" with a tick for a moment after its copy.
private struct CopyCaption<Label: View>: View {
    let copied: Bool
    @ViewBuilder let label: Label

    var body: some View {
        ZStack(alignment: .leading) {
            label.lineLimit(1).opacity(copied ? 0 : 1).offset(y: copied ? -6 : 0)
            HStack(spacing: 4) {
                Image(systemName: "checkmark").fontWeight(.bold)
                    .symbolEffect(.bounce, value: copied)
                Text("Copied")
            }
            .opacity(copied ? 1 : 0).offset(y: copied ? 0 : 6)
        }
    }
}

private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// A label/value row with copy; secrets stay masked until revealed.
private struct FieldLine: View {
    @Environment(AppModel.self) private var model
    let item: VaultItem
    let field: ItemField
    let reveal: Bool
    @State private var armed: Int?
    @State private var copied = false

    /// Card numbers are shown grouped (4-4-4-4 / Amex 4-6-5); the clipboard still gets the raw digits.
    private var shown: String {
        item.kind == .card && field.label == String(localized: "Card number")
            ? field.value.formattedAsCardNumber : field.value
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: field.label)
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Group {
                if field.secret {
                    MaskedSecret(secret: shown, revealed: reveal, dots: 10)
                } else {
                    Text(verbatim: shown)
                        .contentTransition(.opacity)
                }
            }
                .font(.system(size: 13, design: field.monospaced ? .monospaced : .default))
                .lineLimit(field.monospaced ? 3 : 2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                armed = model.copyCount
                if field.secret { model.guarded(item) { model.copy(field.value, label: field.label) } } else { model.copy(field.value, label: field.label) }
            } label: {
                // Fixed frame: doc.on.doc ↔ checkmark differ in size, and .replace would otherwise grow the row.
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20, height: 20)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityLabel(Text("Copy \(field.label)"))
            }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(Text("Copy"))
                .copyTick(armed: $armed, copied: $copied)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .frame(minHeight: 44)
    }
}

/// A folder path as breadcrumbs ("Northwind › Engineering › Frontend"): small chevrons between the parts, the last
/// part (where the item is) a little stronger; `lead` sets the first one (the vault) in medium weight too. Long paths
/// give way in the middle.
struct PathCrumbs: View {
    let parts: [String]
    var lead = false

    /// "Engineering/Frontend" → ["Engineering", "Frontend"] (folders nest by name).
    static func split(_ path: String) -> [String] {
        path.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                }
                Text(verbatim: part)
                    .fontWeight(index == parts.count - 1 || (lead && index == 0) ? .medium : .regular)
                    .foregroundStyle(index == parts.count - 1 ? AnyShapeStyle(.primary.opacity(0.75)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(index == parts.count - 1 || index == 0 ? 1 : 0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: parts.joined(separator: ", ")))
    }
}

/// A detail row that does something on click: a soft highlight on hover, and the action for VoiceOver too.
struct TappableRow: ViewModifier {
    var enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    func body(content: Content) -> some View {
        if enabled {
            content
                .background(Color.primary.opacity(hovering ? 0.04 : 0))
                .contentShape(.rect)
                .onTapGesture(perform: action)
                .onHover { hovering = $0 }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { action() }
        } else {
            content
        }
    }
}

struct DetailRow<Value: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    @ViewBuilder let value: Value

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title).font(.system(size: 13, weight: .medium))
            Spacer()
            value.font(.system(size: 13))
        }
        .padding(.horizontal, 16).frame(minHeight: 46)
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if let toast = model.toast {
                HStack(spacing: 14) {
                    Label {
                        Text(toast).contentTransition(.opacity)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").symbolEffect(.bounce, options: .speed(1.3), value: toast)
                    }
                    if let action = model.toastAction {
                        Button(action.title) { action.run() }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 12).frame(height: 28)
                            .background(.white.opacity(0.2), in: .capsule)
                            .contentShape(.capsule)
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.leading, 18).padding(.trailing, model.toastAction == nil ? 18 : 8)
                .frame(height: 44)
                .background(Color.hero, in: .capsule)
                .shadow(color: .black.opacity(0.3), radius: 16, y: 10)
                .transition(.move(edge: .bottom).combined(with: .scale(scale: 0.9)).combined(with: .opacity))
            }
        }
        .padding(.bottom, 28)
        .animation(.spring(duration: 0.35, bounce: 0.35), value: model.toast)
    }
}

/// In the footer, before Sync, while a copied secret waits on the clipboard: a ring draining to the moment it's cleared, the seconds
/// counting down. Clicking clears it now.
private struct ClipboardCountdown: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var labelWidth: CGFloat = 0

    var body: some View {
        if let clears = model.clipboardClearsAt, let total = model.clipboardHoldSeconds {
            Button { model.clearClipboardNow() } label: {
                HStack(spacing: 0) {
                    // Hovering unrolls the label leftwards out of the ring: its width opens from 0 (clipped, so the
                    // words are revealed rather than squeezed) while it fades in, all on one spring.
                    Text("Clear Clipboard Now")
                        .font(.system(size: 11, weight: .medium))
                        .fixedSize()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { labelWidth = $0 }
                        .padding(.leading, 9).padding(.trailing, 6)
                        .frame(width: hovering ? labelWidth + 15 : 0, alignment: .trailing)
                        .clipped()
                        .opacity(hovering ? 1 : 0)
                    // The same ring as a one-time code's: draining, the seconds inside. Only it redraws with the clock.
                    TimelineView(.animation(minimumInterval: 1 / 15)) { context in
                        let remaining = max(0, clears.timeIntervalSince(context.date))
                        CountdownRing(fraction: remaining / total, seconds: Int(remaining.rounded(.up)), size: 20, digits: 0.46)
                    }
                    .padding(3)
                }
                .foregroundStyle(.secondary)
                .frame(height: 26)
                .background(Color.primary.opacity(hovering ? 0.07 : 0), in: .capsule)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .onHover { h in
                withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.34, bounce: 0)) { hovering = h }
            }
            .help(Text("Clipboard clears"))
            .accessibilityLabel(Text("Clear Clipboard Now"))
        }
    }
}

/// Colored initial tile; color is derived from the name so it stays stable.
struct Monogram: View {
    let name: String
    let size: CGFloat
    @Environment(\.colorScheme) private var scheme

    /// The same tile as a site's icon (white, hairline edge), with the initial in dark grey, so letters and logos sit
    /// together as one family. (The tile is always light, so the letter is a fixed dark, not the text colour.)
    var body: some View {
        let dark = scheme == .dark
        Text(name.prefix(1).uppercased())
            .font(.system(size: size * 0.44, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.black.opacity(0.62))
            .frame(width: size, height: size)
            .background(dark ? Color(white: 0.96) : .white, in: .rect(cornerRadius: size * 0.29, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.29, style: .continuous).strokeBorder(.black.opacity(0.08)))
            .accessibilityHidden(true) // decorative: the name is read next to it
    }
}

/// Unlock one locked account in place (from the sidebar), without leaving the vault.
struct AccountUnlockPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    let account: SavedAccount
    @State private var password = ""
    @State private var usePassword = false
    @State private var refusals = 0
    @FocusState private var focused: Bool

    private var hasPIN: Bool { model.isPINEnabled(account.id) }
    private var pinMode: Bool { hasPIN && !usePassword }
    var body: some View {
        VStack(spacing: 0) {
            // Whose vault: the account's own avatar, so it reads as the one picked in the switcher.
            AccountAvatar(account: account, size: 52, showsLock: true)
                .padding(.bottom, 14)
            Text(verbatim: account.email)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1).truncationMode(.middle)
            Text("Locked · \(account.serverSummary)")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .padding(.top, 2)

            UnlockCapsuleField(pinMode: pinMode, password: $password, focused: $focused.wrappedBinding, submit: submit)
                .shake(on: refusals)
                .padding(.top, 20)

            status
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2).multilineTextAlignment(.center)
                .frame(minHeight: 28)
                .padding(.top, 6)
                .animation(.easeOut(duration: 0.2), value: model.errorMessage)

            if model.isTouchIDEnabled(account.id) {
                Button { Task { await model.unlockWithTouchID() } } label: {
                    Label("Unlock with Touch ID", systemImage: "touchid")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity).frame(height: 32)
                        .background(Color.primary.opacity(0.06), in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }

            HStack(spacing: 6) {
                if hasPIN {
                    Button(pinMode ? "Use master password" : "Use PIN") {
                        usePassword.toggle(); password = ""; model.errorMessage = nil; focused = true
                    }
                }
                if hasPIN && canShowAll { Text(verbatim: "·").foregroundStyle(.tertiary) }
                if canShowAll {
                    Button("Show all accounts") {
                        model.errorMessage = nil
                        withAnimation(.snappy(duration: 0.3)) { model.accountFocus = nil }
                    }
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.top, 14)
        }
        .frame(maxWidth: 280)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.panel, in: .rect(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 6)
        .onAppear { focused = true }
        .onChange(of: account.id) { password = ""; usePassword = false; model.errorMessage = nil; focused = true }
        .onChange(of: model.errorMessage) { _, message in
            guard message != nil else { return }
            refusals += 1
            password = ""
        }
        .onChange(of: password) { _, typed in if !typed.isEmpty, model.errorMessage != nil { model.errorMessage = nil } }
    }

    /// Only when this account is in focus (picked in the switcher) and there are others to go back to.
    private var canShowAll: Bool { model.focusedAccountID == account.id && model.accounts.count > 1 }

    @ViewBuilder private var status: some View {
        if let message = model.errorMessage {
            Text(verbatim: message).foregroundStyle(scheme == .dark ? Color(red: 1, green: 0.55, blue: 0.55) : Color(red: 0.8, green: 0.2, blue: 0.2))
        } else if model.isBusy {
            Text("Unlocking…").foregroundStyle(.secondary)
        } else {
            Text("Press Return to unlock").foregroundStyle(.tertiary)
        }
    }

    private func submit() {
        guard !password.isEmpty, !model.isBusy else { return }
        let typed = password
        Task {
            if pinMode { await model.unlockWithPIN(typed, accountId: account.id) } else { await model.unlock(password: typed, accountId: account.id) }
            if model.isUnlocked(account.id) { password = "" }
        }
    }
}

/// Marks every case/diacritic-insensitive occurrence of `query` with a tinted background.
enum Highlight {
    static func marked(_ text: String, _ query: String) -> AttributedString {
        var out = AttributedString(text)
        // Each word on its own: the list matches them anywhere, in any order.
        for q in query.split(separator: " ").map(String.init) {
            var start = text.startIndex
            while let range = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex) {
                if let r = Range(range, in: out) {
                    out[r].backgroundColor = Color.brand.opacity(0.22)
                    out[r].foregroundColor = .primary
                }
                start = range.upperBound
            }
        }
        return out
    }
}

/// Files on an item: Quick Look, Save As, delete; add with the button or by dropping files on the item.
private struct AttachmentsSection: View {
    @Environment(AppModel.self) private var model
    let item: VaultItem
    @State private var pendingDelete: VaultItem.Attachment?
    @State private var choosing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Attachments").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .textCase(.uppercase).tracking(0.6)
                Spacer()
                if model.attachmentBusy.contains(item.id) { ProgressView().controlSize(.small) }
                if !item.isDeleted {
                    Button { choosing = true } label: { Label("Add Files…", systemImage: "plus") }
                        .buttonStyle(.borderless).font(.system(size: 12, weight: .medium))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            if item.attachments.isEmpty {
                Text("Drop files here to attach them, encrypted.")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 16).padding(.bottom, 14)
            }
            ForEach(item.attachments) { file in
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (file.fileName as NSString).pathExtension) ?? .data))
                        .resizable().frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: file.fileName).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        Text(verbatim: file.sizeName).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.attachmentBusy.contains(file.id) {
                        ProgressView().controlSize(.small)
                    }
                    Button { Task { await model.previewAttachment(file, of: item) } } label: {
                        Image(systemName: "eye").accessibilityLabel(Text("Quick Look"))
                    }
                    .help(Text("Quick Look"))
                    Button { Task { await model.saveAttachment(file, of: item) } } label: {
                        Image(systemName: "square.and.arrow.down").accessibilityLabel(Text("Save As…"))
                    }
                    .help(Text("Save As…"))
                    if !item.isDeleted {
                        Button { pendingDelete = file } label: {
                            Image(systemName: "trash").accessibilityLabel(Text("Delete"))
                        }
                        .help(Text("Delete"))
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .overlay(alignment: .top) { Divider().opacity(0.6) }
                .contentShape(.rect)
                .onTapGesture(count: 2) { Task { await model.previewAttachment(file, of: item) } }
            }
        }
        .background(Color.panelStrong, in: .rect(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.panelEdge))
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await model.addAttachments(urls, to: item) } }
        }
        .confirmationDialog("Delete “\(pendingDelete?.fileName ?? "")”?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let file = pendingDelete { Task { await model.deleteAttachment(file, of: item) } }
            }
        } message: {
            Text("The file is removed from your vault on every device.")
        }
    }
}

/// One look for every header control: the same fill, hairline edge and soft shadow.
struct HeaderChrome: ViewModifier {
    enum Shape { case capsule, circle }
    let shape: Shape
    var hovering = false
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        switch shape {
        case .capsule: chrome(content, Capsule(), dark: dark)
        case .circle: chrome(content, Circle(), dark: dark)
        }
    }

    /// Dark: a quiet translucent fill. Light: glass — a bright top edge fading to a faint shade below, and a soft
    /// shadow like the cards'. Composited as one layer so the toolbar's vibrancy can't wash the edge and fill out.
    private func chrome<S: InsettableShape>(_ content: Content, _ shape: S, dark: Bool) -> some View {
        let fill = dark ? Color.white.opacity(hovering ? 0.14 : 0.10) : Color.white.opacity(hovering ? 0.95 : 0.78)
        return content
            .background {
                if dark {
                    shape.fill(fill)
                } else {
                    shape.fill(fill)
                        .background(.ultraThinMaterial, in: shape)
                        .shadow(color: .black.opacity(hovering ? 0.10 : 0.07), radius: 6, y: 2)
                }
            }
            .overlay {
                if dark {
                    shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                } else {
                    shape.strokeBorder(LinearGradient(colors: [.white, .white.opacity(0.4), .black.opacity(0.07)],
                                                      startPoint: .top, endPoint: .bottom), lineWidth: 1)
                }
            }
            .compositingGroup()
    }
}

/// Icon buttons inside the header pill: a soft highlight on hover and press.
struct HeaderIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverHighlight(pressed: configuration.isPressed) { configuration.label }
    }

    private struct HoverHighlight<Label: View>: View {
        let pressed: Bool
        @ViewBuilder let label: Label
        @State private var hovering = false
        var body: some View {
            label
                .background(Color.primary.opacity(pressed ? 0.12 : hovering ? 0.07 : 0), in: .capsule)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// New Folder, in the same form language as the item and Send forms.
/// Renames a folder: its last part ("Servers" in Work/Servers); its subfolders move with it.
struct RenameFolderSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let path: String
    @State private var name = ""
    @State private var saving = false
    @FocusState private var focused: Bool

    private var current: String { path.split(separator: "/").last.map(String.init) ?? path }
    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var hasSubfolders: Bool { model.folders.contains { $0.name.hasPrefix(path + "/") } }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                FormHeader(symbol: "folder", title: "Rename Folder", subtitle: "“\(path)”")
                FormCard {
                    FormField(label: "Name", note: hasSubfolders ? "Its subfolders move with it." : nil) {
                        TextField("Name", text: $name, prompt: Text(verbatim: current))
                            .textFieldStyle(SoftFieldStyle())
                            .focused($focused)
                            .onSubmit(save)
                    }
                }
            }
            .padding(20)
            FormFooter(action: "Rename", busy: saving, disabled: trimmed.isEmpty || trimmed == current || trimmed.contains("/"),
                       cancel: { dismiss() }, submit: save)
        }
        .frame(width: 440)
        .background(Color.windowBase)
        .onAppear { name = current; focused = true }
    }

    private func save() {
        guard !trimmed.isEmpty, trimmed != current, !trimmed.contains("/"), !saving else { return }
        saving = true
        Task {
            if await model.renameFolder(path, to: trimmed) { dismiss() }
            saving = false
        }
    }
}

struct NewFolderSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The folder it goes inside (a path), or nil for the top level.
    var parent: String?
    @State private var name = ""
    @State private var accountId: String?
    @State private var saving = false
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    /// The whole path to create: the parent's, then what was typed.
    private var fullName: String { parent.map { $0 + "/" + trimmed } ?? trimmed }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                if let parent {
                    FormHeader(symbol: "folder.badge.plus", title: "New Subfolder", subtitle: "Inside “\(parent)”.")
                } else {
                    FormHeader(symbol: "folder.badge.plus", title: "New Folder", subtitle: "Group items; folders can nest.")
                }
                FormCard {
                    if model.sessions.count > 1 && parent == nil {
                        FormField(label: "Account") {
                            SoftMenu(options: model.sessions.map { (String?.some($0.id), $0.account.email) }, selection: $accountId,
                                     accessibilityLabel: "Account")
                        }
                    }
                    FormField(label: "Name", note: parent == nil ? "Use / to nest, e.g. Work/Servers." : nil) {
                        TextField("Name", text: $name, prompt: parent == nil ? Text("e.g. Work/Servers") : Text("e.g. Servers"))
                            .textFieldStyle(SoftFieldStyle())
                            .focused($focused)
                            .onSubmit(create)
                    }
                }
            }
            .padding(20)
            FormFooter(action: "Create", busy: saving, disabled: trimmed.isEmpty, cancel: { dismiss() }, submit: create)
        }
        .frame(width: 440)
        .background(Color.windowBase)
        .onAppear {
            // Inside a folder: the account that folder belongs to.
            accountId = parent.flatMap { path in
                model.sessions.first { $0.folders.contains { $0.name == path || $0.name.hasPrefix(path + "/") } }?.id
            } ?? model.defaultAccountId
            focused = true
        }
    }

    private func create() {
        guard !trimmed.isEmpty, !saving else { return }
        saving = true
        Task {
            if await model.createFolder(name: fullName, accountId: accountId) != nil { dismiss() }
            saving = false
        }
    }
}

/// The vault picker (from the vault chip): All vaults, then each vault with its icon, item count and a checkbox; "Only" on hover
/// shows just that one. Checks animate in and out; the popover stays open so several can be picked.
struct VaultSwitcherPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            VaultPickerRow(title: String(localized: "All vaults"), symbol: "square.stack.3d.up", count: model.vaultCount(nil),
                           checked: model.vaultFilter == .all, radio: true) {
                withAnimation(.snappy(duration: 0.25)) { model.vaultFilter = .all }
            }
            Divider().padding(.vertical, 4).padding(.horizontal, 8)
            VaultPickerRow(title: String(localized: "My vault"), symbol: "person", count: model.vaultCount(AppModel.VaultFilter.personalKey),
                           checked: model.vaultShown(AppModel.VaultFilter.personalKey),
                           only: { withAnimation(.snappy(duration: 0.25)) { model.showOnlyVault(AppModel.VaultFilter.personalKey) } }) {
                withAnimation(.snappy(duration: 0.25)) { model.toggleVault(AppModel.VaultFilter.personalKey) }
            }
            ForEach(model.visibleOrganizations) { org in
                VaultPickerRow(title: org.name, symbol: "building.2", count: model.vaultCount(org.id), checked: model.vaultShown(org.id),
                               only: { withAnimation(.snappy(duration: 0.25)) { model.showOnlyVault(org.id) } }) {
                    withAnimation(.snappy(duration: 0.25)) { model.toggleVault(org.id) }
                }
            }
            Text("Check several to see them together.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
        }
        .padding(6)
        .frame(width: 280)
    }
}

/// One vault in the picker. The whole row toggles; the check is a filled circle that pops in.
private struct VaultPickerRow: View {
    let title: String
    let symbol: String
    let count: Int
    let checked: Bool
    /// All vaults: a radio (filled when every vault shows), not a checkbox.
    var radio = false
    var only: (() -> Void)?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 7, style: .continuous))
                Text(verbatim: title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 6)
                if let only, hovering, !radio {
                    Button("Only", action: only)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 7).frame(height: 20)
                        .background(Color.primary.opacity(0.08), in: .capsule)
                        .help(Text("Show only this vault"))
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
                Text(count, format: .number).font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.tertiary)
                Image(systemName: checked ? (radio ? "largecircle.fill.circle" : "checkmark.circle.fill") : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(checked ? Color.primary : Color.secondary.opacity(0.6))
                    .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
            }
            .padding(.horizontal, 8).frame(height: 36)
            .background(Color.primary.opacity(hovering ? 0.06 : 0), in: .rect(cornerRadius: 8, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}

/// My vault and each shared vault as checkable menu items (the filter menu); a click shows or hides one.
struct VaultToggles: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        toggle(AppModel.VaultFilter.personalKey, String(localized: "My vault"))
        ForEach(model.visibleOrganizations) { org in toggle(org.id, org.name) }
    }

    private func toggle(_ key: String, _ title: String) -> some View {
        Toggle(isOn: Binding(get: { model.vaultShown(key) },
                             set: { _ in withAnimation(.snappy(duration: 0.25)) { model.toggleVault(key) } })) {
            Text(verbatim: title)
        }
    }
}

/// When the item was made and last edited, when its password last changed, and its earlier passwords.
struct ItemHistoryCard: View {
    @Environment(AppModel.self) private var model
    let item: VaultItem
    @State private var showingPasswords = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Item history").font(.system(size: 13, weight: .semibold))
            VStack(spacing: 8) {
                if let revised = item.revised { row("Last edited", revised) }
                if let created = item.created { row("Created", created) }
                if item.kind == .login, let since = item.passwordSince { row("Password updated", since) }
            }
            if !item.passwordHistory.isEmpty {
                Divider().opacity(0.6)
                Button { model.guarded(item) { showingPasswords = true } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                        Text("Password history")
                        Spacer()
                        Text(item.passwordHistory.count, format: .number).foregroundStyle(.secondary).monospacedDigit()
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 13))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.panel, in: .rect(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.panelEdge))
        .sheet(isPresented: $showingPasswords) { PasswordHistorySheet(item: item) }
    }

    /// "Tue, 6 Oct 2026 at 22:50:12", and under it how long ago (kept fresh).
    private func row(_ label: LocalizedStringKey, _ date: Date) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 1) {
                Text(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year().hour().minute().second()))
                    .monospacedDigit()
                    .textSelection(.enabled)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(Self.ago(date, now: context.date)).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .help(Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute().second().timeZone())))
        }
        .font(.system(size: 12))
    }

    private static func ago(_ date: Date, now: Date) -> String {
        now.timeIntervalSince(date) < 60 ? String(localized: "Just now") : date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }
}

/// The passwords an item had before, newest first: hidden until revealed (one at a time or all), then coloured
/// like the generator's, each a click from the clipboard.
struct PasswordHistorySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: VaultItem
    @State private var revealed: Set<Int> = []

    private var entries: [VaultItem.PastPassword] {
        item.passwordHistory.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Password history").font(.system(size: 17, weight: .semibold))
                    Text(verbatim: item.name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button(revealed.count == entries.count ? "Hide All" : "Reveal All") {
                    withAnimation(.snappy(duration: 0.2)) {
                        revealed = revealed.count == entries.count ? [] : Set(entries.indices)
                    }
                }
                .buttonStyle(.appSecondarySmall)
            }
            .padding(20)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, past in
                        entry(index, past)
                    }
                }
                .padding(.horizontal, 20)
            }
            .thinScroller()
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Kept by the server when a password is changed: the last five.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.appSecondary)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
        }
        .frame(width: 460)
    }

    private func entry(_ index: Int, _ past: VaultItem.PastPassword) -> some View {
        let shown = revealed.contains(index)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if shown {
                        ColoredSecret(value: past.password).foregroundStyle(.primary)
                    } else {
                        Text(verbatim: String(repeating: "•", count: 14)).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 14, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
                .contentTransition(.opacity)
                if let date = past.date {
                    Text("Replaced \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button {
                withAnimation(.snappy(duration: 0.2)) { if shown { revealed.remove(index) } else { revealed.insert(index) } }
            } label: {
                Image(systemName: shown ? "eye.slash" : "eye").frame(width: 26, height: 26).contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .help(shown ? Text("Hide") : Text("Reveal"))
            Button { model.copy(past.password, label: String(localized: "Password")) } label: {
                Image(systemName: "doc.on.doc").frame(width: 26, height: 26).contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .help(Text("Copy"))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

/// "Ask for master password": the item's secrets wait for the master password (or Touch ID).
private struct RepromptSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: AppModel.RepromptRequest
    @State private var password = ""
    @State private var wrong = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                FormHeader(symbol: "lock.shield", title: "Confirm it's you",
                           subtitle: "“\(request.item.name)” asks for your master password.")
                FormCard {
                    PasswordField(title: "Master password", text: $password, prompt: Text("Master password"),
                                  isFocused: $focused.wrappedBinding, onSubmit: submit)
                    if wrong {
                        Label("That's not your master password.", systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 12)).foregroundStyle(.red)
                    }
                    if AccountStore.isTouchIDEnabled(request.item.accountId) {
                        Button { Task { await touchID() } } label: { Label("Use Touch ID", systemImage: "touchid") }
                            .buttonStyle(.appSecondary)
                    }
                }
            }
            .padding(20)
            FormFooter(action: "Continue", disabled: password.isEmpty, cancel: { dismiss() }, submit: submit)
        }
        .frame(width: 420)
        .background(Color.windowBase)
        .onAppear { focused = true }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        if model.verifyMasterPassword(password, accountId: request.item.accountId) {
            model.passReprompt(request)
        } else {
            withAnimation(.snappy) { wrong = true }
            password = ""
        }
    }

    private func touchID() async {
        let keys = await AccountStore.unlockAllWithTouchID([request.item.accountId], reason: String(localized: "show this item"))
        if !keys.isEmpty { model.passReprompt(request) }
    }
}

/// "Are you trying to sign in?": another device asks to sign in with this Mac's approval.
private struct SignInApprovalSheet: View {
    @Environment(AppModel.self) private var model
    let prompt: AppModel.SignInPrompt
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                FormHeader(symbol: "person.badge.key", title: "Are you trying to sign in?",
                           subtitle: "A device wants to sign in to \(prompt.email) without the master password.")
                FormCard {
                    LabeledContent("Device") { Text(verbatim: prompt.request.deviceType).foregroundStyle(.secondary) }
                    LabeledContent("IP address") { Text(verbatim: prompt.request.ipAddress).foregroundStyle(.secondary) }
                    if let created = prompt.request.created.flatMap(VaultDecoder.date) {
                        LabeledContent("Asked") { Text(created, format: .relative(presentation: .named)).foregroundStyle(.secondary) }
                    }
                    FormField(label: "Fingerprint phrase", note: "Approve only if it matches the phrase on the other device.") {
                        Text(verbatim: prompt.fingerprint.joined(separator: "-"))
                            .font(.system(size: 15, weight: .semibold, design: .monospaced)).foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                }
                .font(.system(size: 13))
            }
            .padding(20)
            HStack(spacing: 10) {
                Spacer()
                Button("Deny") { answer(false) }.buttonStyle(.appSecondary).keyboardShortcut(.cancelAction)
                Button {
                    answer(true)
                } label: {
                    HStack(spacing: 6) { if busy { ProgressView().controlSize(.small).tint(.white) }; Text("Approve") }
                }
                .buttonStyle(.appPrimary)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(alignment: .top) { Divider().opacity(0.5) }
        }
        .frame(width: 460)
        .background(Color.windowBase)
        .interactiveDismissDisabled()
    }

    private func answer(_ approve: Bool) {
        busy = true
        Task { await model.answerSignIn(prompt, approve: approve) }
    }
}

/// A sidebar row's label with its icon in the text's quiet secondary colour (the sidebar would tint it brand blue).
struct SidebarLabel: View {
    let title: Text
    let symbol: String
    /// The row's own selection: its icon bounces when it becomes the selected one.
    var tag: SidebarSelection?
    /// A count at the end of the row that rolls to its new value (hidden at 0, like a badge).
    var count: Int?

    @Environment(\.sidebarCurrent) private var current
    @State private var pulse = 0

    init(_ title: LocalizedStringKey, symbol: String, tag: SidebarSelection? = nil, count: Int? = nil) {
        self.title = Text(title); self.symbol = symbol; self.tag = tag; self.count = count
    }
    /// User data (folder and collection names), shown as is.
    init<S: StringProtocol>(verbatim title: S, symbol: String, tag: SidebarSelection? = nil, count: Int? = nil) {
        self.title = Text(title); self.symbol = symbol; self.tag = tag; self.count = count
    }

    private var selected: Bool { tag != nil && tag == current }

    var body: some View {
        Label {
            HStack(spacing: 6) {
                title
                Spacer(minLength: 4)
                if let count, count > 0 {
                    Text(count, format: .number)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText(value: Double(count)))
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
            }
            .animation(.snappy(duration: 0.3), value: count)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
                .symbolEffect(.bounce.down, options: .speed(1.4), value: pulse)
        }
        .onChange(of: selected) { _, now in if now { pulse += 1 } }
        // Something landed here (trashed, archived, starred…): a jump of one or two, not a whole sync arriving.
        .onChange(of: count ?? 0) { old, new in if new > old, new - old <= 2, old > 0 || new == 1 { pulse += 1 } }
    }
}

extension EnvironmentValues {
    /// The sidebar's selection, for its rows (their icons answer being picked).
    @Entry var sidebarCurrent: SidebarSelection?
}

/// A toolbar icon that answers its click with its own motion: the star bounces as it fills, the archive box bounces
/// down as if something dropped in, the pencil wiggles, the trash bounces; a changed symbol morphs into the new one.
/// (Reduce Motion: the symbols only swap.)
struct ToolbarSymbolButton: View {
    enum Effect { case none, bounce, bounceDown, wiggle, wiggleBack }

    let symbol: String
    var effect: Effect = .none
    let action: () -> Void
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            animated(Image(systemName: symbol).font(.system(size: 13, weight: .medium)))
                .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp.byLayer))) // star ↔ star.fill, eye ↔ eye.slash
                .frame(width: 30, height: 26).contentShape(.rect)
        }
        .buttonStyle(HeaderIconStyle())
    }

    @ViewBuilder private func animated(_ image: some View) -> some View {
        switch effect {
        case .none: image
        case .bounce: image.symbolEffect(.bounce, options: .speed(1.2), value: taps)
        case .bounceDown: image.symbolEffect(.bounce.down, options: .speed(1.2), value: taps)
        case .wiggle: image.symbolEffect(.wiggle, value: taps)
        case .wiggleBack: image.symbolEffect(.wiggle.backward, value: taps)
        }
    }
}

/// At the top of the Trash: when its items are deleted for good, which depends on the server.
private struct TrashNotice: View {
    @Environment(AppModel.self) private var model
    let items: [VaultItem]

    var body: some View {
        let cloud = items.contains { model.isCloud($0.accountId) }
        let own = items.contains { !model.isCloud($0.accountId) }
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.orange)
            Group {
                if cloud && own {
                    Text("Bitwarden deletes items for good \(AppModel.cloudTrashDays) days after they go to the Trash. Your own server keeps them until you delete them, unless its admin set it to empty the Trash.")
                } else if cloud {
                    Text("Bitwarden deletes items for good \(AppModel.cloudTrashDays) days after they go to the Trash.")
                } else {
                    Text("Items stay here until you delete them, unless your server's admin set it to empty the Trash after a while.")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.primary.opacity(0.85))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.orange.opacity(0.22)))
        .padding(.horizontal, 6)
    }
}

/// "Deleted in 12 days" on a trashed item, orange in its last three days.
private struct PurgeChip: View {
    let date: Date

    var body: some View {
        let days = max(0, Int((date.timeIntervalSinceNow / 86_400).rounded(.up))) // a day and a bit left reads "2 days"
        let soon = days <= 3
        HStack(spacing: 3) {
            Image(systemName: "clock").font(.system(size: 9, weight: .bold))
            Text(days == 0 ? "Deleted today" : "Deleted in ^[\(days) day](inflect: true)")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(soon ? Color.orange : .secondary)
        .padding(.horizontal, 6).frame(height: 17)
        .background((soon ? Color.orange : Color.primary).opacity(soon ? 0.14 : 0.07), in: .capsule)
        .help(Text(date.formatted(date: .complete, time: .shortened)))
    }
}

/// Keeps the sidebar's selection in its soft style. A sidebar that has keyboard focus draws its selection
/// "emphasized" (a solid accent fill, graphite here), and it took focus with every click — so the style flipped
/// back and forth as focus moved between the sidebar and the list. The sidebar's outline view now never takes
/// focus: clicks and drops still select, and the keyboard stays with the list and the search.
struct SidebarCalmSelection: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Finder() }
    func updateNSView(_ view: NSView, context: Context) { (view as? Finder)?.apply() }

    final class Finder: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            DispatchQueue.main.async { [weak self] in self?.apply() } // the outline view may arrive a moment later
        }

        func apply() {
            guard let root = window?.contentView else { return }
            for outline in Self.outlines(in: root) where !outline.refusesFirstResponder {
                outline.refusesFirstResponder = true
                if window?.firstResponder === outline { window?.makeFirstResponder(nil) }
            }
        }

        private static func outlines(in view: NSView) -> [NSOutlineView] {
            (view as? NSOutlineView).map { [$0] } ?? view.subviews.flatMap(outlines)
        }
    }
}
