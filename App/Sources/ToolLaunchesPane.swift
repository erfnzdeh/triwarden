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
    @State private var replacement: SecretsProfile?
    @State private var chosenKey: VaultItem?
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool
    #if DEBUG
    var previewProfile: SecretsProfile?
    var previewProfiles: [SecretsProfile]?
    var previewGrants: [SecretsActiveGrant]?
    var previewQuery = ""
    var previewFilter = ToolBrowserIndex.Filter.all
    var previewDetail = false
    #endif

    private var profiles: [SecretsProfile] {
        #if DEBUG
        if let previewProfiles { return previewProfiles }
        if let previewProfile { return [previewProfile] }
        #endif
        return model.secrets.profiles
    }
    private var index: ToolBrowserIndex {
        var unlocked = Set(model.sessions.map(\.id))
        #if DEBUG
        if previewProfile != nil || previewProfiles != nil { unlocked.formUnion(model.accounts.map(\.id)) }
        #endif
        return ToolBrowserIndex(profiles: profiles, items: model.items, unlocked: unlocked,
                                configurationError: model.secrets.lastError != nil)
    }

    var body: some View {
        let index = index
        let results = index.results(query: query, filter: filter, order: order)
        GeometryReader { geometry in
            let wide = geometry.size.width >= 780
            let selection = ToolBrowserIndex.selection(selected, in: results, automatic: wide)
            VStack(spacing: 0) {
                header(total: profiles.count)
                if let error = model.secrets.lastError { errorBanner(error) }
                Divider().opacity(0.5)
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
            if wants { model.wantsToolsSearchFocus = false; searchFocused = true }
        }
        .onChange(of: model.requestedToolSelection, initial: true) { _, name in
            guard let name, profiles.contains(where: { $0.name == name }) else { return }
            query = ""; filter = .all; selected = name; compactDetail = true
            model.requestedToolSelection = nil
        }
        .onChange(of: compactDetail) { _, showing in if !showing { listFocused = true } }
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
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Button { model.requestedSection = .access } label: {
                        Label("Access · \(temporaryCount)", systemImage: "checkmark.shield")
                    }.buttonStyle(.appSecondarySmall).help("View and revoke API-key and SSH access")
                }
                Button { replacement = nil; choosingKey = true } label: { Label("Add Tool", systemImage: "plus") }
                    .buttonStyle(.appPrimarySmall).accessibilityIdentifier("addTool")
                    .disabled(total >= 64)
                    .help(total >= 64 ? "The 64-tool limit is reached. Remove an unused tool setup first." : "Choose a saved API key and set up a tool")
            }
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search tools, folders or keys", text: $query).textFieldStyle(.plain)
                        .focused($searchFocused).accessibilityIdentifier("toolsSearch")
                        .onKeyPress(.escape) { guard !query.isEmpty else { return .ignored }; query = ""; return .handled }
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel("Clear tool search")
                    }
                }
                .padding(8).background(Color.formInputFill, in: .rect(cornerRadius: 8))
                Picker("Status", selection: $filter) {
                    ForEach(ToolBrowserIndex.Filter.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                }.labelsHidden().pickerStyle(.menu).fixedSize().accessibilityIdentifier("toolsStatusFilter")
                Menu {
                    Picker("Sort tools", selection: $order) {
                        ForEach(ToolBrowserIndex.Order.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                    }
                    Divider()
                    Button("Terminal Helper Setup…") { model.showSettings(.developer) }
                } label: { Image(systemName: "arrow.up.arrow.down") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Sort tools and helper setup")
            }
            .font(.system(size: 12))
        }.padding(18)
    }

    private var temporaryCount: Int {
        #if DEBUG
        if let previewGrants { return previewGrants.filter { $0.deadline.map { .now < $0 } ?? true }.count }
        #endif
        return model.secrets.activeGrantCount + model.sshAgent.activeTrusts.count
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
                List(selection: Binding(get: { selection }, set: { value in
                    selected = value
                })) {
                    ForEach(results) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(verbatim: entry.profile.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                            Text(verbatim: entry.folder + " · " + entry.profile.name)
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            HStack(spacing: 8) {
                                Label("\(entry.keys.count) keys", systemImage: "key.horizontal")
                                Label(entry.availability.title, systemImage: entry.availability.symbol)
                            }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.vertical, 6).tag(entry.id)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("toolRow-\(entry.id)")
                        .onTapGesture { selected = entry.id; if !wide { compactDetail = true } }
                        .accessibilityAction { selected = entry.id; if !wide { compactDetail = true } }
                        .contextMenu {
                            Button("Copy Launch Command") { model.copyPlain("tw run --profile " + entry.id) }
                            Button(entry.profile.enabled ? "Pause" : "Resume") { setEnabled(!entry.profile.enabled, entry.profile) }
                            Divider()
                            Button("Remove Tool…", role: .destructive) { removing = entry.profile }
                        }
                    }
                }
                .listStyle(.inset).scrollContentBackground(.hidden).focused($listFocused)
                .accessibilityIdentifier("toolsList").accessibilityLabel("Saved tools")
                .onKeyPress(.return) {
                    guard !wide, selected != nil else { return .ignored }
                    compactDetail = true; return .handled
                }
            }
            HStack {
                Text("\(results.count) of \(profiles.count) tools")
                Spacer()
                if profiles.count >= 64 { Text("64-tool limit reached").help("Remove an unused tool setup before adding another. Your vault keys are kept.") }
            }
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(12)
        }
    }

    @ViewBuilder private func detail(_ entry: ToolBrowserIndex.Entry?, index: ToolBrowserIndex, back: Bool) -> some View {
        if let entry {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if back {
                        Button { compactDetail = false } label: { Label("All Tools", systemImage: "chevron.left") }
                            .buttonStyle(.plain).accessibilityIdentifier("backToTools")
                    }
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: entry.profile.title).font(.system(size: 22, weight: .bold)).textSelection(.enabled)
                            Label(entry.availability.title, systemImage: entry.availability.symbol)
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Menu {
                            Button(entry.profile.enabled ? "Pause" : "Resume") { setEnabled(!entry.profile.enabled, entry.profile) }
                            Button("View Access") { model.requestedSection = .access }
                            Divider()
                            Button("Remove Tool…", role: .destructive) { removing = entry.profile }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Manage \(entry.profile.title)")
                    }
                    Text(verbatim: entry.profile.directory).font(.system(size: 12)).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Copy Launch Command") { model.copyPlain("tw run --profile " + entry.id) }
                            .buttonStyle(.appPrimarySmall).accessibilityIdentifier("copyToolLaunchCommand")
                        Button("Edit Setup…") { edit(entry, index: index) }.buttonStyle(.appSecondarySmall)
                    }
                    Text(verbatim: "tw run --profile " + entry.id).font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Divider().opacity(0.5)
                    Text("Keys provided to this tool").font(.system(size: 13, weight: .semibold))
                    ForEach(entry.keys) { key in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top) {
                                Text(verbatim: key.name).font(.system(size: 13, weight: .medium))
                                Spacer(minLength: 8)
                                if !key.canView, !model.isUnlocked(key.binding.accountID), model.accounts.contains(where: { $0.id == key.binding.accountID }) {
                                    Button("Unlock Account") { model.accountFocus = key.binding.accountID }
                                        .buttonStyle(.appSecondarySmall)
                                } else {
                                    Button("View") {
                                        if let item = index.item(for: key.binding) {
                                            model.requestedVaultItem = .init(accountID: item.accountId, itemID: item.id)
                                        }
                                    }.buttonStyle(.appSecondarySmall).disabled(!key.canView)
                                        .accessibilityLabel("View \(key.name) in the vault")
                                }
                            }
                            Text(verbatim: key.binding.variable).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            if let account = model.accounts.first(where: { $0.id == key.binding.accountID }) {
                                Text(verbatim: account.email + " · " + account.serverSummary).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            if let problem = key.problem {
                                Text(verbatim: problem).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Divider().opacity(0.4)
                    }
                    DisclosureGroup("Saved command details") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: entry.profile.executable)
                            ForEach(Array(entry.profile.arguments.enumerated()), id: \.offset) { i, value in Text(verbatim: "\(i + 1): \(value.isEmpty ? "(empty)" : value)") }
                        }.font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }.font(.system(size: 12))
                    Text("Keys are supplied only when you start this saved command and approve access. The receiving program can read and retain them.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(22).frame(maxWidth: 740, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading)
            }.thinScroller().id(entry.id).accessibilityIdentifier("toolDetail")
        } else {
            ContentUnavailableView("Select a tool", systemImage: "terminal", description: Text("Choose a tool to view its keys and launch settings."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
            }.listStyle(.inset).overlay { if keys.isEmpty { ContentUnavailableView("No available API keys", systemImage: "key.horizontal", description: Text("Save a key in your vault or unlock its account.")) } }
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
