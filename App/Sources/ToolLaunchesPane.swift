import SecretsAgent
import SwiftUI

struct ToolLaunchesPane: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var filter = ToolBrowserIndex.Filter.all
    @State private var order = ToolBrowserIndex.Order.ascending
    @State private var selected: String?
    @State private var compactDetail = false
    @State private var removing: SecretsProfile?
    @State private var resetting = false
    @State private var choosingKey = false
    @State private var helperSetup = false
    @State private var helperCheck = 0
    @State private var helperState: TerminalHelperInstallation.State?
    @State private var advanced = false
    @State private var replacement: SecretsProfile?
    @State private var chosenKey: VaultItem?
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool
    #if DEBUG
    var previewProfile: SecretsProfile?
    var previewProfiles: [SecretsProfile]?
    var previewQuery = ""
    var previewFilter = ToolBrowserIndex.Filter.all
    var previewDetail = false
    var previewAdvanced = false
    var previewHelperState = TerminalHelperInstallation.State.installed
    #endif

    private var profiles: [SecretsProfile] {
        #if DEBUG
        if let previewProfiles { return previewProfiles }
        if let previewProfile { return [previewProfile] }
        #endif
        return model.secrets.profiles
    }
    private var unlockedAccounts: Set<String> {
        var unlocked = Set(model.sessions.map(\.id))
        #if DEBUG
        if previewProfile != nil || previewProfiles != nil { unlocked.formUnion(model.accounts.map(\.id)) }
        #endif
        return unlocked
    }
    private var index: ToolBrowserIndex {
        ToolBrowserIndex(profiles: profiles, items: model.items, unlocked: unlockedAccounts,
                         configurationError: model.secrets.lastError != nil, configuredAccounts: Set(model.accounts.map(\.id)))
    }

    var body: some View {
        let index = index
        let results = index.results(query: query, filter: filter, order: order)
        GeometryReader { geometry in
            let wide = geometry.size.width >= 780
            let selection = ToolBrowserIndex.selection(selected, in: results, automatic: wide)
            let showsDetail = !wide && compactDetail && results.contains { $0.id == selection }
            VStack(spacing: 0) {
                if !showsDetail { header(total: profiles.count) }
                if let error = model.secrets.lastError { errorBanner(error) }
                if !showsDetail { Divider().opacity(0.5) }
                if profiles.isEmpty {
                    emptyState
                } else if results.isEmpty {
                    toolList(results, selection: nil, wide: wide)
                } else if wide {
                    HStack(spacing: 0) {
                        toolList(results, selection: selection, wide: true).frame(width: 280)
                        Divider().opacity(0.5)
                        detail(selection.flatMap { id in results.first { $0.id == id } }, index: index, back: false)
                    }
                } else if compactDetail, let entry = results.first(where: { $0.id == selection }) {
                    detail(entry, index: index, back: true)
                } else {
                    toolList(results, selection: selection, wide: false)
                }
            }
        }
        .onChange(of: results.map(\.id)) { _, _ in
            // A newly saved tool may also clear the old query in this update.
            if let selected, !index.results(query: query, filter: filter, order: order).contains(where: { $0.id == selected }) {
                self.selected = nil; compactDetail = false
            }
        }
        .onChange(of: model.wantsToolsSearchFocus, initial: true) { _, wants in
            if wants { model.wantsToolsSearchFocus = false; compactDetail = false; searchFocused = true }
        }
        .onChange(of: model.requestedToolSelection, initial: true) { _, name in
            guard let name, profiles.contains(where: { $0.name == name }) else { return }
            query = ""; filter = .all; selected = name; compactDetail = true
            model.requestedToolSelection = nil
        }
        .onChange(of: compactDetail) { _, showing in if !showing { listFocused = true } }
        .task(id: helperCheck) {
            #if DEBUG
            if previewProfiles != nil || previewProfile != nil || model.previewUnlocked {
                helperState = previewHelperState; return
            }
            #endif
            let app = Bundle.main.bundleURL
            let result = await Task.detached(priority: .utility) { TerminalHelperInstallation.inspect(appURL: app) }.value
            guard !Task.isCancelled else { return }
            helperState = result.state
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in helperCheck += 1 }
        .onAppear {
            #if DEBUG
            query = previewQuery; filter = previewFilter
            advanced = previewAdvanced
            if previewDetail { selected = profiles.first?.name; compactDetail = true }
            #endif
        }
        .onKeyPress(.escape) {
            if compactDetail { compactDetail = false; return .handled }
            return .ignored
        }
        .sheet(isPresented: $choosingKey, onDismiss: openChosenKey) {
            ToolKeyPicker { key in chosenKey = key; choosingKey = false }.environment(model)
        }
        .sheet(isPresented: $helperSetup, onDismiss: { helperCheck += 1 }) { TerminalHelperSetup().environment(model) }
        .confirmationDialog("Remove this tool setup?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove Tool", role: .destructive) {
                guard let removing else { return }
                do { try model.secrets.remove(removing.name) } catch { model.flash(error.localizedDescription) }
                self.removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { Text("The setup is removed from this Mac. Your vault keys are kept.") }
        .confirmationDialog("Reset all local tool setups?", isPresented: $resetting) {
            Button("Reset Tool Setups", role: .destructive) {
                do { try model.secrets.clearSetups() } catch { model.flash(error.localizedDescription) }
            }
        } message: { Text("Saved launch commands and temporary approvals are removed. Vault keys are kept; you will need to set up your tools again.") }
    }

    private func header(total: Int) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Text("Tools").font(.system(size: 20, weight: .bold))
                Text(verbatim: String(total)).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button { replacement = nil; choosingKey = true } label: { Label("Add Tool", systemImage: "plus") }
                    .buttonStyle(.appPrimarySmall).accessibilityIdentifier("addTool")
                    .disabled(total >= 64)
                    .help(total >= 64 ? "The 64-tool limit is reached. Remove an unused tool setup first." : "Choose a saved API key and set up a tool")
                ActionMenu(entries: workspaceActions) { moreIcon }
                    .accessibilityLabel("Tools options")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { searchField; toolbarMenus }
                VStack(spacing: 8) { searchField; HStack(spacing: 8) { toolbarMenus; Spacer() } }
            }
            if helperNeedsSetup {
                HStack(spacing: 8) {
                    Label("Set up the terminal helper to start tools.", systemImage: "terminal")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Set Up…") { helperSetup = true }.buttonStyle(.appSecondarySmall)
                        .accessibilityIdentifier("toolsHelperSetup")
                }
            }
        }.padding(18)
    }

    private var helperNeedsSetup: Bool { helperState.map { $0 != .installed } ?? false }

    private var workspaceActions: [ActionMenuEntry] {
        [ActionMenuEntry(title: String(localized: "Terminal Helper Setup…"), symbol: "terminal") { helperSetup = true },
         ActionMenuEntry(title: String(localized: "View Access"), symbol: "checkmark.shield") { model.requestedSection = .access }]
    }

    private var moreIcon: some View {
        Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
            .frame(width: 32, height: 32).modifier(HeaderChrome(shape: .circle)).contentShape(.circle)
    }

    private var searchField: some View {
        WorkspaceSearchField(prompt: "Search tools, folders or keys", text: $query, focused: $searchFocused) {
            listFocused = true
            if selected == nil { selected = index.results(query: query, filter: filter, order: order).first?.id }
        }.frame(minWidth: 140).accessibilityIdentifier("toolsSearch")
    }

    private var toolbarMenus: some View {
        Group {
            WorkspaceFilter(title: "Status", options: ToolBrowserIndex.Filter.allCases.map { ($0, $0.title) }, selection: $filter)
                .accessibilityIdentifier("toolsStatusFilter")
            ActionMenu(entries: ToolBrowserIndex.Order.allCases.map { choice in
                ActionMenuEntry(title: choice.title, checked: order == choice) { order = choice }
            }) {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 13, weight: .semibold))
                    .frame(width: 32, height: 32).modifier(HeaderChrome(shape: .circle)).contentShape(.circle)
            }.fixedSize().accessibilityLabel("Sort tools")
        }
    }

    private func toolList(_ results: [ToolBrowserIndex.Entry], selection: String?, wide: Bool) -> some View {
        VStack(spacing: 0) {
            if results.isEmpty {
                ContentUnavailableView {
                    Label("No matching tools", systemImage: "magnifyingglass")
                } description: { Text("Try a different name, folder, key or status.") } actions: {
                    Button("Clear Filters") { query = ""; filter = .all }.buttonStyle(.appSecondarySmall)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                    ForEach(results) { entry in
                        ToolBrowserRow(entry: entry, selected: selection == entry.id)
                        .id(entry.id)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(selection == entry.id ? [.isButton, .isSelected] : .isButton)
                        .accessibilityIdentifier("toolRow-\(entry.id)")
                        .onTapGesture { selected = entry.id; listFocused = true; if !wide { compactDetail = true } }
                        .accessibilityAction { selected = entry.id; if !wide { compactDetail = true } }
                        .appContextMenu([
                            ActionMenuEntry(title: String(localized: "Copy Launch for \(entry.profile.title)")) { copyLaunch(entry.profile) },
                            ActionMenuEntry(title: String(localized: "Copy Shell Alias")) { copyAlias(entry.profile) },
                            ActionMenuEntry(title: entry.profile.enabled ? String(localized: "Pause") : String(localized: "Resume")) { setEnabled(!entry.profile.enabled, entry.profile) },
                            ActionMenuEntry(title: String(localized: "Remove Tool…"), destructive: true, separatorBefore: true) { removing = entry.profile }
                        ])
                    }
                    }.padding(6)
                }
                .focusable().focused($listFocused).focusEffectDisabled()
                .onKeyPress(.downArrow) { step(1, in: results, selection: selection, proxy: proxy); return .handled }
                .onKeyPress(.upArrow) { step(-1, in: results, selection: selection, proxy: proxy); return .handled }
                .accessibilityIdentifier("toolsList").accessibilityLabel("Saved tools")
                .onKeyPress(.return) {
                    guard !wide, selection != nil else { return .ignored }
                    compactDetail = true; return .handled
                }
                .onChange(of: selection, initial: true) { _, id in if let id { proxy.scrollTo(id) } }
                }.thinScroller()
            }
            HStack {
                Text("\(results.count) of \(profiles.count) tools")
                Spacer()
                if profiles.count >= 64 { Text("64-tool limit reached").help("Remove an unused tool setup before adding another. Your vault keys are kept.") }
            }
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(12)
        }
    }

    private func step(_ delta: Int, in results: [ToolBrowserIndex.Entry], selection: String?, proxy: ScrollViewProxy) {
        if let id = ToolBrowserIndex.stepping(selection, by: delta, in: results) { selected = id; proxy.scrollTo(id) }
    }

    @ViewBuilder private func detail(_ entry: ToolBrowserIndex.Entry?, index: ToolBrowserIndex, back: Bool) -> some View {
        if let entry {
            VStack(spacing: 0) {
                if back {
                    HStack {
                        Button { compactDetail = false } label: {
                            Label("Tools", systemImage: "chevron.left").font(.system(size: 13, weight: .medium))
                        }.buttonStyle(.plain).accessibilityIdentifier("backToTools")
                        Spacer(minLength: 0)
                        ActionMenu(entries: detailActions(entry, index: index)) { moreIcon }
                            .accessibilityLabel("Manage \(entry.profile.title)")
                    }.padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 6)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 12) {
                                Text(verbatim: entry.profile.title).font(.system(size: 22, weight: .bold))
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    .accessibilityAddTraits(.isHeader)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if !back {
                                    ActionMenu(entries: detailActions(entry, index: index)) { moreIcon }
                                        .accessibilityLabel("Manage \(entry.profile.title)")
                                }
                            }
                            Label { Text(verbatim: entry.folder) } icon: { Image(systemName: "folder") }
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).help(entry.profile.directory)
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            if entry.nextAction == .copyLaunch && helperNeedsSetup {
                                Label("Terminal helper setup needed", systemImage: "terminal")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            } else {
                                Label(entry.availability.title, systemImage: entry.availability.symbol)
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            if case .repairKey(let id) = entry.nextAction,
                               let problem = entry.keys.first(where: { $0.id == id })?.problem {
                                Text(verbatim: problem).font(.system(size: 12)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            primaryAction(entry, index: index)
                            if entry.nextAction == .copyLaunch && !helperNeedsSetup {
                                Text("Paste the command into your terminal to start this tool.")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        launchDetails(entry)
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 6) {
                                Text("API keys").font(.system(size: 13, weight: .semibold))
                                Text(verbatim: String(entry.keys.count)).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            VStack(spacing: 0) {
                                ForEach(entry.keys) { key in
                                    keyRow(key, entry: entry, index: index)
                                    if key.id != entry.keys.last?.id { Divider().opacity(0.4).padding(.leading, 16) }
                                }
                            }
                            .background(Color.panelStrong, in: .rect(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.panelEdge))
                        }
                    }.padding(.horizontal, 22).padding(.top, back ? 6 : 22).padding(.bottom, 24)
                        .frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading)
                }.thinScroller()
            }.id(entry.id).accessibilityIdentifier("toolDetail")
        } else {
            ContentUnavailableView("Select a tool", systemImage: "terminal", description: Text("Choose a tool to view its keys and launch settings."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func primaryAction(_ entry: ToolBrowserIndex.Entry, index: ToolBrowserIndex) -> some View {
        switch entry.nextAction {
        case .copyLaunch:
            if helperNeedsSetup {
                Button("Set Up Terminal Helper…") { helperSetup = true }.buttonStyle(.appPrimary)
                    .accessibilityIdentifier("toolsHelperSetup")
            } else {
                Button { copyLaunch(entry.profile) } label: { Label("Copy Launch", systemImage: "doc.on.doc") }
                    .buttonStyle(.appPrimary).accessibilityIdentifier("copyToolLaunchCommand")
                    .accessibilityLabel("Copy Launch for \(entry.profile.title)").help("Copy Launch for \(entry.profile.title)")
            }
        case .resume:
            Button("Resume Tool") { setEnabled(true, entry.profile) }.buttonStyle(.appPrimary)
        case .repairKey(let id):
            if let key = entry.keys.first(where: { $0.id == id }) {
                Button(repairTitle(key, entry: entry)) { repair(key, entry: entry, index: index) }.buttonStyle(.appPrimary)
            }
        case .editSetup:
            Button("Edit Setup…") { edit(entry, index: index) }.buttonStyle(.appPrimary)
        }
    }

    private func keyRow(_ key: ToolBrowserIndex.Key, entry: ToolBrowserIndex.Entry, index: ToolBrowserIndex) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: key.name).font(.system(size: 13, weight: .medium))
                Text(verbatim: key.binding.variable).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let problem = key.problem, entry.nextAction != .repairKey(key.id) {
                    Text(verbatim: problem).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 3)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if key.repair != nil {
                if entry.nextAction != .repairKey(key.id) {
                    Button(repairTitle(key, entry: entry)) { repair(key, entry: entry, index: index) }.buttonStyle(.appSecondarySmall)
                }
            } else {
                Button {
                    if let item = index.item(for: key.binding) {
                        model.requestedVaultItem = .init(accountID: item.accountId, itemID: item.id)
                    }
                } label: {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary).frame(width: 28, height: 28).contentShape(.rect)
                }.buttonStyle(.plain).disabled(!key.canView)
                    .accessibilityLabel("View \(key.name) in the vault").help("View key in the vault")
            }
        }.padding(16).help(keyAccountSummary(key))
    }

    private func launchDetails(_ entry: ToolBrowserIndex.Entry) -> some View {
        DisclosureGroup("Launch details", isExpanded: $advanced) {
            VStack(alignment: .leading, spacing: 16) {
                launchField("Project folder", value: entry.profile.directory)
                launchField("Shell command", value: (try? SavedToolCommands.launch(entry.profile)) ?? "")
                Button("Copy Shell Command") { copyLaunch(entry.profile) }.buttonStyle(.appSecondarySmall)
                launchField("Suggested shell alias", value: (try? SavedToolCommands.alias(entry.profile)) ?? "")
                Button("Copy Shell Alias") { copyAlias(entry.profile) }.buttonStyle(.appSecondarySmall)
                Text("Paste the alias into your terminal. Change its name if another tool uses it. The alias uses the saved tool ID.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                launchField("Executable", value: entry.profile.executable)
                if !entry.profile.arguments.isEmpty {
                    launchField("Arguments", value: entry.profile.arguments.enumerated().map { "\($0.offset + 1): \($0.element)" }.joined(separator: "\n"))
                }
                launchField("Vault accounts", value: Array(Set(entry.keys.map { keyAccountSummary($0) })).sorted().joined(separator: "\n"))
                Text("Keys are supplied after you approve access. The receiving program can read and retain them.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(.top, 14).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 12)).tint(.secondary)
    }

    private func keyAccountSummary(_ key: ToolBrowserIndex.Key) -> String {
        guard let account = model.accounts.first(where: { $0.id == key.binding.accountID }) else { return key.binding.accountID }
        return account.email + " · " + account.serverSummary
    }

    private func launchField(_ title: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(verbatim: value).font(.system(size: 12, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func repairTitle(_ key: ToolBrowserIndex.Key, entry: ToolBrowserIndex.Entry) -> String {
        switch key.repair {
        case .unlockAccount: String(localized: "Unlock Account")
        case .addAccount: String(localized: "Add Account…")
        case .selectKey: entry.profile.bindings.first == key.binding ? String(localized: "Select Key…") : String(localized: "Edit Key Setup…")
        case nil: String(localized: "Edit Setup…")
        }
    }

    private func repair(_ key: ToolBrowserIndex.Key, entry: ToolBrowserIndex.Entry, index: ToolBrowserIndex) {
        switch key.repair {
        case .unlockAccount: model.accountFocus = key.binding.accountID
        case .addAccount: model.beginAddAccount()
        case .selectKey:
            if entry.profile.bindings.first == key.binding { replacement = entry.profile; choosingKey = true }
            else { edit(entry, index: index) }
        case nil: edit(entry, index: index)
        }
    }

    private func detailActions(_ entry: ToolBrowserIndex.Entry, index: ToolBrowserIndex) -> [ActionMenuEntry] {
        [ActionMenuEntry(title: String(localized: "Edit Setup…"), symbol: "pencil") { edit(entry, index: index) },
         ActionMenuEntry(title: String(localized: "Copy Shell Alias"), symbol: "doc.on.doc") { copyAlias(entry.profile) },
         ActionMenuEntry(title: entry.profile.enabled ? String(localized: "Pause Tool") : String(localized: "Resume Tool"),
                         symbol: entry.profile.enabled ? "pause" : "play", separatorBefore: true) { setEnabled(!entry.profile.enabled, entry.profile) }]
        + workspaceActions + [
         ActionMenuEntry(title: String(localized: "Remove Tool…"), symbol: "trash", destructive: true, separatorBefore: true) { removing = entry.profile }]
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Use saved keys with your tools", systemImage: "terminal")
        } description: { Text("Choose a saved API key and set up the tool that needs it. Keys stay in your vault.") } actions: {
            Button("Add Tool…") { replacement = nil; choosingKey = true }.buttonStyle(.appPrimary)
            Button("Save an API Key") { model.beginAPIKey() }.buttonStyle(.appSecondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(verbatim: error).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Reset Setups…") { resetting = true }.buttonStyle(.appSecondarySmall)
        }.padding(.horizontal, 18).padding(.bottom, 14)
    }
    private func copyLaunch(_ profile: SecretsProfile) {
        do {
            model.copyPlain(try SavedToolCommands.launch(profile))
            model.flash(String(localized: "Copied launch for \(profile.title)."))
        } catch { model.flash(error.localizedDescription) }
    }
    private func copyAlias(_ profile: SecretsProfile) {
        do {
            model.copyPlain(try SavedToolCommands.alias(profile))
            model.flash(String(localized: "Alias copied. Paste it into your terminal to use it."))
        } catch { model.flash(error.localizedDescription) }
    }
    private func setEnabled(_ enabled: Bool, _ profile: SecretsProfile) {
        var updated = profile; updated.enabled = enabled
        do { try model.secrets.save(updated) } catch { model.flash(error.localizedDescription) }
    }
    private func edit(_ entry: ToolBrowserIndex.Entry, index: ToolBrowserIndex) {
        let primary = entry.profile.bindings[0]
        if primary.field == .hidden(APIKeyTemplate.keyField) {
            if index.item(for: primary)?.isAPIKey == true {
                model.toolLaunchReference = .init(accountID: primary.accountID, itemID: primary.itemID, toolName: entry.id)
            } else { replacement = entry.profile; choosingKey = true }
        } else { model.showSettings(.secrets) }
    }
    private func openChosenKey() {
        defer { chosenKey = nil; replacement = nil }
        guard let chosenKey else { return }
        model.toolLaunchReference = .init(accountID: chosenKey.accountId, itemID: chosenKey.id, toolName: replacement?.name)
    }
}

private struct ToolBrowserRow: View {
    let entry: ToolBrowserIndex.Entry
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: entry.profile.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text(verbatim: entry.folder)
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 8) {
                Label("\(entry.keys.count) keys", systemImage: "key.horizontal")
                Label(entry.availability.title, systemImage: entry.availability.symbol)
            }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.rowSelected)
                    .shadow(color: .black.opacity(0.12), radius: 9, y: 6)
            } else if hovering {
                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.primary.opacity(0.04))
            }
        }
        .contentShape(.rect).onHover { hovering = $0 }
        .help(entry.profile.title + "\n" + entry.profile.directory + "\n" + entry.id)
    }
}

private struct ToolKeyPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: ToolBrowserIndex.Reference?
    let choose: (VaultItem) -> Void
    private struct Choice: Identifiable {
        let item: VaultItem
        var id: ToolBrowserIndex.Reference { .init(account: item.accountId, item: item.id) }
    }
    private var keys: [VaultItem] {
        model.items.filter { item in
            item.isAPIKey && !item.isDeleted && !item.isArchived && !item.reprompt && model.session(for: item.accountId) != nil &&
                (query.isEmpty || item.name.localizedStandardContains(query))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a saved API key").font(.system(size: 18, weight: .semibold))
            Text("You'll choose the tool and review its settings next.").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Search API keys", text: $query).textFieldStyle(SoftFieldStyle())
            List(selection: $selected) {
                ForEach(keys.map { Choice(item: $0) }) { choice in
                    let key = choice.item
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: key.name)
                        Text(verbatim: model.accounts.first(where: { $0.id == key.accountId })?.email ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
                    }.tag(choice.id)
                }
            }.listStyle(.inset).thinScroller()
                .overlay { if keys.isEmpty { ContentUnavailableView("No available API keys", systemImage: "key.horizontal", description: Text("Save a key in your vault or unlock its account.")) } }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.appSecondary).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Continue") {
                    if let key = keys.first(where: { ToolBrowserIndex.Reference(account: $0.accountId, item: $0.id) == selected }) { choose(key) }
                }.buttonStyle(.appPrimary).disabled(!keys.contains { ToolBrowserIndex.Reference(account: $0.accountId, item: $0.id) == selected })
            }
        }.padding(22).frame(width: 480, height: 500).background { WindowBackdrop() }
    }
}
