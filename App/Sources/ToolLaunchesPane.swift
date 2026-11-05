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
    @State private var importingEnv = false
    @State private var helperSetup = false
    @State private var helperCheck = 0
    @State private var helperState: TerminalHelperInstallation.State?
    @State private var replacement: SecretsProfile?
    @State private var chosenKey: VaultItem?
    @State private var exportingReferences: SecretsProfile?
    @State private var showAllKeys = false
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
                         configurationError: model.secrets.lastError != nil, configuredAccounts: Set(model.accounts.map(\.id)),
                         accountLabels: Dictionary(uniqueKeysWithValues: model.accounts.map {
                             ($0.id, $0.email + " · " + $0.serverSummary)
                         }))
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
                } else if profiles.count == 1, query.isEmpty, let only = results.first {
                    // One tool needs no list beside it.
                    detail(only, index: index, back: false)
                } else if wide {
                    HStack(spacing: 0) {
                        toolList(results, selection: selection, wide: true).frame(width: 300)
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
        .sheet(isPresented: $importingEnv) { EnvKeyImportSheet().environment(model) }
        .sheet(isPresented: Binding(get: { exportingReferences != nil }, set: { if !$0 { exportingReferences = nil } })) {
            if let profile = exportingReferences { EnvReferenceExport(profile: profile).environment(model) }
        }
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Secrets").font(.system(size: 22, weight: .bold))
                if total > 0 {
                    Text(verbatim: String(total)).font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Button("Setup Guide", systemImage: "questionmark") { model.showToolGuide() }
                        .labelStyle(.iconOnly).font(.system(size: 12, weight: .semibold)).buttonStyle(.plain)
                        .frame(width: 30, height: 30).modifier(HeaderChrome(shape: .circle))
                        .help("Setup Guide").accessibilityIdentifier("toolSetupGuide")
                    ActionMenu(entries: workspaceActions) { moreIcon }
                        .accessibilityLabel("Secrets options")
                    if total > 0 {
                        Button { replacement = nil; choosingKey = true } label: { Label("Add Tool", systemImage: "plus") }
                            .buttonStyle(.appPrimarySmall).accessibilityIdentifier("addTool")
                            .disabled(total >= 64)
                            .help(total >= 64 ? "The 64-tool limit is reached. Remove an unused tool setup first." : "Choose a saved API key and set up a tool")
                    }
                }.alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            }
            // Search earns its place once there is something to look through.
            if total >= 4 {
                HStack(spacing: 8) { searchField.frame(maxWidth: 360); toolbarMenus; Spacer(minLength: 0) }
            }
        }.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)
    }

    private var helperNeedsSetup: Bool { helperState.map { $0 != .installed } ?? false }

    private var workspaceActions: [ActionMenuEntry] {
        [ActionMenuEntry(title: String(localized: "Import .env File…"), symbol: "square.and.arrow.down") { importingEnv = true },
         ActionMenuEntry(title: String(localized: "Setup Guide…"), symbol: "questionmark.circle") { model.showToolGuide() },
         ActionMenuEntry(title: String(localized: "Terminal Helper Setup…"), symbol: "terminal") { helperSetup = true },
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
                    LazyVStack(spacing: 2) {
                    ForEach(results) { entry in
                        ToolBrowserRow(entry: entry, state: ToolState(entry, helperReady: !helperNeedsSetup), selected: selection == entry.id)
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
                    }.padding(.horizontal, 10).padding(.vertical, 8)
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
            listFooter(results)
        }
    }

    /// One quiet line: how many are shown, and the helper only when it blocks every launch.
    private func listFooter(_ results: [ToolBrowserIndex.Entry]) -> some View {
        HStack(spacing: 6) {
            if helperNeedsSetup {
                Button { helperSetup = true } label: {
                    Label("Install terminal helper", systemImage: "exclamationmark.circle")
                }.buttonStyle(.plain).foregroundStyle(.orange).accessibilityIdentifier("toolsHelperSetup")
            } else {
                Text(verbatim: results.count == profiles.count
                     ? (profiles.count == 1 ? String(localized: "1 tool") : String(localized: "\(profiles.count) tools"))
                     : String(localized: "\(results.count) of \(profiles.count) tools"))
            }
            Spacer(minLength: 0)
            if profiles.count >= 64 { Text("Limit reached").help("Remove an unused tool setup before adding another. Your vault keys are kept.") }
        }
        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
        .padding(.horizontal, 20).frame(height: 36)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }

    private func step(_ delta: Int, in results: [ToolBrowserIndex.Entry], selection: String?, proxy: ScrollViewProxy) {
        if let id = ToolBrowserIndex.stepping(selection, by: delta, in: results) { selected = id; proxy.scrollTo(id) }
    }

    @ViewBuilder private func detail(_ entry: ToolBrowserIndex.Entry?, index: ToolBrowserIndex, back: Bool) -> some View {
        if let entry {
            let state = ToolState(entry, helperReady: !helperNeedsSetup)
            VStack(spacing: 0) {
                if back {
                    HStack {
                        Button { compactDetail = false } label: {
                            Label("Secrets", systemImage: "chevron.left").font(.system(size: 13, weight: .medium))
                        }.buttonStyle(.plain).accessibilityIdentifier("backToTools")
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 24).padding(.top, 14)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        identity(entry, state: state, index: index)
                        hero(entry, state: state, index: index)
                        keysSection(entry, index: index)
                        detailsSection(entry)
                    }
                    .padding(.horizontal, 32).padding(.top, back ? 14 : 28).padding(.bottom, 32)
                    .frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity, alignment: .top)
                }.thinScroller()
            }.id(entry.id).accessibilityIdentifier("toolDetail").onChange(of: entry.id) { _, _ in showAllKeys = false }
        } else {
            ContentUnavailableView("Select a tool", systemImage: "terminal", description: Text("Choose a tool to see how to start it."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func identity(_ entry: ToolBrowserIndex.Entry, state: ToolState, index: ToolBrowserIndex) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ToolGlyph(profile: entry.profile, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: entry.profile.title).font(.system(size: 20, weight: .semibold))
                    .textSelection(.enabled).lineLimit(2).accessibilityAddTraits(.isHeader)
                Label { Text(verbatim: Self.abbreviated(entry.profile.directory)).lineLimit(1).truncationMode(.middle) } icon: { Image(systemName: "folder") }
                    .font(.system(size: 12)).foregroundStyle(.secondary).labelStyle(.titleAndIcon).help(entry.profile.directory)
            }
            Spacer(minLength: 12)
            ActionMenu(entries: detailActions(entry, index: index)) { moreIcon }
                .accessibilityLabel("Manage \(entry.profile.title)")
        }
    }

    /// The one thing to do next. Ready tools show the command; anything else shows why not, and the fix.
    @ViewBuilder private func hero(_ entry: ToolBrowserIndex.Entry, state: ToolState, index: ToolBrowserIndex) -> some View {
        if state == .ready {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    StatusDot(state: state)
                    Text(verbatim: state.headline).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                }
                CommandWell(command: (try? SavedToolCommands.launch(entry.profile)) ?? "", copyLabel: "Copy", prominent: true) {
                    copyLaunch(entry.profile)
                }
                .accessibilityIdentifier("copyToolLaunchCommand")
                .accessibilityLabel("Copy Launch for \(entry.profile.title)")
                Text("Paste into any terminal. Triwarden asks you to approve, then starts the tool in \(entry.folder) with its keys.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider().opacity(0.4)
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Shortcut").font(.system(size: 12, weight: .semibold))
                        Text("Add the alias to ~/.zshrc, then type its name.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(verbatim: SavedToolCommands.aliasName(entry.profile))
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Copy Alias") { copyAlias(entry.profile) }.buttonStyle(.appSecondarySmall).fixedSize()
                        .accessibilityIdentifier("copyToolAlias")
                }
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.panelStrong, in: .rect(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.panelEdge))
            .shadow(color: .black.opacity(0.06), radius: 14, y: 6)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    StatusDot(state: state)
                    Text(verbatim: state.headline).font(.system(size: 12, weight: .semibold))
                }
                Text(verbatim: state.explanation(entry)).font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                primaryAction(entry, index: index)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func primaryAction(_ entry: ToolBrowserIndex.Entry, index: ToolBrowserIndex) -> some View {
        switch entry.nextAction {
        case .copyLaunch:
            Button("Install Terminal Helper…") { helperSetup = true }.buttonStyle(.appSecondarySmall)
                .accessibilityIdentifier("toolsHelperSetup")
        case .resume:
            Button("Resume Tool") { setEnabled(true, entry.profile) }.buttonStyle(.appSecondarySmall)
        case .repairKey(let id):
            if let key = entry.keys.first(where: { $0.id == id }) {
                HStack(spacing: 10) {
                    Button(repairTitle(key.repair, key: key, entry: entry)) {
                        repair(key.repair, key: key, entry: entry, index: index)
                    }.buttonStyle(.appSecondarySmall)
                    if let alternate = key.alternateRepair {
                        Button(repairTitle(alternate, key: key, entry: entry)) {
                            repair(alternate, key: key, entry: entry, index: index)
                        }.buttonStyle(.appSecondarySmall)
                    }
                }
            }
        case .editSetup:
            Button("Edit Setup…") { edit(entry, index: index) }.buttonStyle(.appSecondarySmall)
        }
    }

    private func keysSection(_ entry: ToolBrowserIndex.Entry, index: ToolBrowserIndex) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(entry.keys.count == 1 ? "1 key" : "\(entry.keys.count) keys")
            let shown = showAllKeys || entry.keys.count <= 6 ? entry.keys : Array(entry.keys.prefix(5))
            VStack(spacing: 0) {
                ForEach(shown) { key in
                    keyRow(key, entry: entry, index: index)
                    if key.id != shown.last?.id || shown.count < entry.keys.count { Divider().opacity(0.4).padding(.leading, 52) }
                }
                if shown.count < entry.keys.count {
                    Button { withAnimation(.snappy(duration: 0.2)) { showAllKeys = true } } label: {
                        Text("Show all \(entry.keys.count) keys").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 10).contentShape(.rect)
                    }.buttonStyle(.plain)
                }
            }
            .background(Color.panel, in: .rect(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.panelEdge))
        }
    }

    private func keyRow(_ key: ToolBrowserIndex.Key, entry: ToolBrowserIndex.Entry, index: ToolBrowserIndex) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: key.problem == nil ? "key.fill" : "exclamationmark.triangle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(key.problem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                .frame(width: 28, height: 28)
                .background(.primary.opacity(0.05), in: .rect(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: key.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if let problem = key.problem, entry.nextAction != .repairKey(key.id) {
                    Text(verbatim: problem).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: key.binding.variable)
                .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.primary.opacity(0.05), in: .rect(cornerRadius: 6, style: .continuous))
                .textSelection(.enabled).lineLimit(1)
                .help("Environment variable the tool reads")
            if key.repair != nil {
                if entry.nextAction != .repairKey(key.id) {
                    Button(repairTitle(key.repair, key: key, entry: entry)) {
                        repair(key.repair, key: key, entry: entry, index: index)
                    }.buttonStyle(.appSecondarySmall)
                }
            } else {
                Button {
                    if let item = index.item(for: key.binding) {
                        model.requestedVaultItem = .init(accountID: item.accountId, itemID: item.id)
                    }
                } label: {
                    Image(systemName: "arrow.up.forward").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary).frame(width: 24, height: 24).contentShape(.rect)
                }.buttonStyle(.plain).disabled(!key.canView)
                    .accessibilityLabel("View \(key.name) in the vault").help("Open in vault")
            }
        }.padding(.horizontal, 12).padding(.vertical, 10).help(keyAccountSummary(key))
    }

    private func detailsSection(_ entry: ToolBrowserIndex.Entry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Details")
            VStack(alignment: .leading, spacing: 0) {
                detailRow("Program", entry.profile.executable)
                if !entry.profile.arguments.isEmpty {
                    detailRow("Arguments", entry.profile.arguments.joined(separator: "  "))
                }
                detailRow("Folder", Self.abbreviated(entry.profile.directory))
                detailRow("Account", Array(Set(entry.keys.map { keyAccountSummary($0) })).sorted().joined(separator: "\n"))
                detailRow("Alias line", (try? SavedToolCommands.alias(entry.profile)) ?? "", last: true)
            }
            .background(Color.panel, in: .rect(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.panelEdge))
            Label("The program receives the keys after you approve and can keep them. Lock or revoke stops future launches only.",
                  systemImage: "info.circle")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    /// `~/Projects/app` rather than the full home path; the full path stays in the hover help.
    static func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private func sectionLabel(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .textCase(.uppercase).tracking(0.4).padding(.leading, 4)
    }

    private func detailRow(_ title: LocalizedStringKey, _ value: String, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
                Text(verbatim: value).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .lineLimit(3).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 14).padding(.vertical, 10)
            if !last { Divider().opacity(0.4).padding(.leading, 14) }
        }
    }

    private func keyAccountSummary(_ key: ToolBrowserIndex.Key) -> String {
        guard let account = model.accounts.first(where: { $0.id == key.binding.accountID }) else { return key.binding.accountID }
        return account.email + " · " + account.serverSummary
    }

    private func repairTitle(_ repair: ToolBrowserIndex.Key.Repair?, key: ToolBrowserIndex.Key,
                             entry: ToolBrowserIndex.Entry) -> String {
        switch repair {
        case .unlockVault: String(localized: "Unlock Vault")
        case .signInToVault: String(localized: "Sign In to Vault…")
        case .selectKey: entry.profile.bindings.first == key.binding ? String(localized: "Select Key…") : String(localized: "Edit Key Setup…")
        case nil: String(localized: "Edit Setup…")
        }
    }

    private func repair(_ repair: ToolBrowserIndex.Key.Repair?, key: ToolBrowserIndex.Key,
                        entry: ToolBrowserIndex.Entry, index: ToolBrowserIndex) {
        switch repair {
        case .unlockVault: model.accountFocus = key.binding.accountID
        case .signInToVault: model.beginAddAccount()
        case .selectKey:
            if entry.profile.bindings.first == key.binding { replacement = entry.profile; choosingKey = true }
            else { edit(entry, index: index) }
        case nil: edit(entry, index: index)
        }
    }

    private func detailActions(_ entry: ToolBrowserIndex.Entry, index: ToolBrowserIndex) -> [ActionMenuEntry] {
        [ActionMenuEntry(title: String(localized: "Edit Setup…"), symbol: "pencil") { edit(entry, index: index) },
         ActionMenuEntry(title: String(localized: "Copy Shell Alias"), symbol: "doc.on.doc") { copyAlias(entry.profile) },
         ActionMenuEntry(title: String(localized: "Save .env References…"), symbol: "doc.badge.arrow.up") { exportingReferences = entry.profile },
         ActionMenuEntry(title: entry.profile.enabled ? String(localized: "Pause Tool") : String(localized: "Resume Tool"),
                         symbol: entry.profile.enabled ? "pause" : "play", separatorBefore: true) { setEnabled(!entry.profile.enabled, entry.profile) }]
        + workspaceActions + [
         ActionMenuEntry(title: String(localized: "Remove Tool…"), symbol: "trash", destructive: true, separatorBefore: true) { removing = entry.profile }]
    }

    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "terminal").font(.system(size: 26, weight: .light)).foregroundStyle(.secondary)
                    Text("Start your tools with keys from your vault").font(.system(size: 20, weight: .semibold))
                    Text("Keep API keys out of plain .env files. Triwarden asks you to approve each launch, then gives the keys only to the tool you chose.")
                        .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 10) {
                    StartChoiceCard(symbol: "doc.text", title: "Import from an .env file", note: "The quickest start. Pick keys from a masked preview; your file is left unchanged.",
                                    badge: "Recommended") { importingEnv = true }
                        .accessibilityIdentifier("toolsImportEnv")
                    StartChoiceCard(symbol: "key.horizontal", title: "Use a key already in the vault", note: "Choose a saved API key, then the program and folder that use it.") {
                        replacement = nil; choosingKey = true
                    }.accessibilityIdentifier("toolsAddFromVault")
                    StartChoiceCard(symbol: "map", title: "Walk me through it", note: "A five-step guide, with a dummy key you can practise on.") { model.showToolGuide() }
                }
            }
            .padding(32).frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity)
        }.thinScroller()
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
            model.flash(String(localized: "Alias copied. Add it to ~/.zshrc, then open a new terminal."))
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
    let state: ToolState
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 11) {
            ToolGlyph(profile: entry.profile, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.profile.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(verbatim: entry.folder + " · " + (entry.keys.count == 1 ? String(localized: "1 key") : String(localized: "\(entry.keys.count) keys")))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if state != .ready { StatusDot(state: state).help(state.headline) }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.rowSelected)
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
            } else if hovering {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.04))
            }
        }
        .contentShape(.rect).onHover { hovering = $0 }
        .help(entry.profile.title + "\n" + entry.profile.directory)
        .accessibilityValue(Text(verbatim: state.headline))
    }
}

/// One answer to "can I start this tool?", shared by the list and the detail so they never disagree.
enum ToolState: Equatable {
    case ready, helper, paused, locked, attention

    init(_ entry: ToolBrowserIndex.Entry, helperReady: Bool) {
        switch entry.availability {
        case .paused: self = .paused
        case .locked: self = .locked
        case .needsRepair: self = .attention
        case .ready: self = helperReady ? .ready : .helper
        }
    }

    var headline: String {
        switch self {
        case .ready: String(localized: "Ready to run")
        case .helper: String(localized: "Install the terminal helper")
        case .paused: String(localized: "Paused")
        case .locked: String(localized: "Account locked")
        case .attention: String(localized: "Needs attention")
        }
    }

    func explanation(_ entry: ToolBrowserIndex.Entry) -> String {
        if case .repairKey(let id) = entry.nextAction, let problem = entry.keys.first(where: { $0.id == id })?.problem { return problem }
        switch self {
        case .helper: return String(localized: "Install tw once, and every saved tool can start from your terminal. Setup shows each step before anything changes.")
        case .paused: return String(localized: "Paused tools never ask for approval or receive keys.")
        case .locked: return String(localized: "Unlock the account that holds this tool's keys.")
        case .attention: return String(localized: "This setup can no longer be used as saved. Review it to continue.")
        case .ready: return ""
        }
    }

    /// Graphite when nothing is needed; orange only when the user has to act.
    var tint: Color {
        switch self { case .ready: .green; case .paused: .secondary; default: .orange }
    }
}

struct StatusDot: View {
    let state: ToolState
    var body: some View {
        Group {
            if state == .paused {
                Circle().strokeBorder(state.tint, lineWidth: 1.5)
            } else {
                Circle().fill(state.tint)
            }
        }.frame(width: 8, height: 8).accessibilityHidden(true)
    }
}

/// A monochrome tile for the program a tool runs, so rows read at a glance without colour.
struct ToolGlyph: View {
    let profile: SecretsProfile
    var size: CGFloat = 32

    static func symbol(_ profile: SecretsProfile) -> String {
        switch (profile.executable as NSString).lastPathComponent.lowercased() {
        case "claude", "codex", "gemini", "cursor-agent", "aider", "opencode": "sparkles"
        case "npm", "node", "npx", "pnpm", "yarn", "bun", "deno": "shippingbox"
        case "uv": "chevron.left.forwardslash.chevron.right"
        case let name where name.hasPrefix("python"): "chevron.left.forwardslash.chevron.right"
        default: "terminal"
        }
    }

    var body: some View {
        Image(systemName: Self.symbol(profile))
            .font(.system(size: size * 0.4, weight: .medium)).foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(.primary.opacity(0.06), in: .rect(cornerRadius: size * 0.28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(.primary.opacity(0.06)))
            .accessibilityHidden(true)
    }
}

struct ToolKeyPicker: View {
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
                .overlay { if keys.isEmpty { emptyState } }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.appSecondary).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Continue") {
                    if let key = keys.first(where: { ToolBrowserIndex.Reference(account: $0.accountId, item: $0.id) == selected }) { choose(key) }
                }.buttonStyle(.appPrimary).keyboardShortcut(.defaultAction)
                    .disabled(!keys.contains { ToolBrowserIndex.Reference(account: $0.accountId, item: $0.id) == selected })
            }
        }.padding(22).frame(width: 480, height: 500).background { WindowBackdrop() }
    }

    /// Offers the next step instead of a dead end: save a key, or say which account to unlock.
    @ViewBuilder private var emptyState: some View {
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if model.sessions.isEmpty {
            ContentUnavailableView("Unlock your vault first", systemImage: "lock",
                                   description: Text("Saved API keys appear here after you unlock their account."))
        } else {
            ContentUnavailableView {
                Label("No saved API keys yet", systemImage: "key.horizontal")
            } description: {
                Text("Save a key once, then choose which tool receives it.")
            } actions: {
                Button("Save a Key…") { dismiss(); model.beginAPIKey() }.buttonStyle(.appPrimarySmall)
            }
        }
    }
}
