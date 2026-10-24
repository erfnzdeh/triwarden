import SecretsAgent
import SSHAgent
import SwiftUI

struct AccessPane: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var source = Source.all
    @State private var history = false
    @State private var outcome = HistoryFilter.all
    @State private var revokeAll = false
    @State private var clearHistory = false
    @FocusState private var searchFocused: Bool
    #if DEBUG
    var previewProfiles: [SecretsProfile]?
    var previewGrants: [SecretsActiveGrant]?
    var previewSSHTrusts: [SSHTrust]?
    var previewAlways: [SSHAllowlistEntry]?
    var previewHistory: [SSHAccessEvent]?
    var previewShowsHistory = false
    #endif

    enum Source: String, CaseIterable {
        case all, apiKeys, ssh
        var title: String { switch self { case .all: String(localized: "All access"); case .apiKeys: String(localized: "API keys"); case .ssh: "SSH" } }
    }
    enum HistoryFilter: String, CaseIterable {
        case all, allowed, refused
        var title: String { switch self { case .all: String(localized: "All results"); case .allowed: String(localized: "Allowed"); case .refused: String(localized: "Not allowed") } }
        func includes(_ value: SSHAccessOutcome) -> Bool {
            let refused = [.denied, .timedOut, .locked].contains(value)
            switch self { case .all: return true; case .allowed: return !refused; case .refused: return refused }
        }
    }

    private var profiles: [SecretsProfile] {
        #if DEBUG
        if let previewProfiles { return previewProfiles }
        #endif
        return model.secrets.profiles
    }
    private var grants: [SecretsActiveGrant] {
        #if DEBUG
        if let previewGrants { return previewGrants.filter { $0.deadline.map { .now < $0 } ?? true } }
        #endif
        return model.secrets.activeGrants
    }
    private var sshTrusts: [SSHTrust] {
        #if DEBUG
        if let previewSSHTrusts { return previewSSHTrusts.filter { $0.until.map { $0 > .now } ?? true } }
        #endif
        return model.sshAgent.activeTrusts
    }
    private var alwaysAllowed: [SSHAllowlistEntry] {
        #if DEBUG
        if let previewAlways { return previewAlways }
        #endif
        return model.sshAgent.allowlist.entries
    }
    private var events: [SSHAccessEvent] {
        #if DEBUG
        if let previewHistory { return previewHistory }
        #endif
        return model.sshAgent.accessLog.events
    }
    private var showsAPIKeys: Bool { model.showsAPIKeyTools || !grants.isEmpty }

    var body: some View {
        let index = ToolBrowserIndex(profiles: profiles, items: model.items, unlocked: Set(model.sessions.map(\.id)))
        let lookup = Dictionary(index.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Access").font(.system(size: 20, weight: .bold))
                    Spacer()
                    AppSegmented(options: [(false, LocalizedStringKey("Permissions")), (true, "History")], selection: $history)
                        .frame(width: 220)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Access view")
                        .accessibilityIdentifier("accessTabs")
                }
                ViewThatFits(in: .horizontal) {
                    HStack { search; filters }
                    VStack { search; HStack { filters; Spacer() } }
                }
            }.padding(18)
            Divider().opacity(0.5)
            if history {
                historyList
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { _ in permissions(lookup) }
            }
        }
        .onAppear {
            #if DEBUG
            history = previewShowsHistory
            #endif
        }
        .onChange(of: model.wantsAccessSearchFocus, initial: true) { _, wants in
            if wants { model.wantsAccessSearchFocus = false; searchFocused = true }
        }
        .onChange(of: showsAPIKeys) { _, visible in if !visible { source = .all } }
        .confirmationDialog("Revoke all temporary access?", isPresented: $revokeAll) {
            Button("Revoke Temporary Access", role: .destructive) { model.secrets.reset(); model.sshAgent.reset() }
        } message: {
            Text(showsAPIKeys ? "Temporary API-key and SSH approvals will end, and pending requests will be cancelled. Always Allowed SSH apps are kept; remove them separately below. Keys already delivered and established SSH connections cannot be recalled." : "Temporary SSH approvals will end. Always Allowed SSH apps are kept. Established SSH connections cannot be recalled.")
        }
        .confirmationDialog("Clear SSH history?", isPresented: $clearHistory) {
            Button("Clear SSH History", role: .destructive) { model.sshAgent.clearAccessLog() }
        } message: { Text("This removes the local SSH request history. It does not revoke any permissions.") }
    }

    private var search: some View {
        WorkspaceSearchField(prompt: showsAPIKeys ? "Search apps, tools or keys" : "Search apps or keys", text: $query, focused: $searchFocused)
            .frame(minWidth: 140).accessibilityIdentifier("accessSearch")
    }
    private var filters: some View {
        Group {
            if showsAPIKeys {
                WorkspaceFilter(title: "Access type", options: Source.allCases.map { ($0, $0.title) }, selection: $source)
            }
            if history {
                WorkspaceFilter(title: "Result", options: HistoryFilter.allCases.map { ($0, $0.title) }, selection: $outcome)
            }
        }
    }
    private func matches(_ parts: [String]) -> Bool {
        let text = parts.joined(separator: " ")
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { text.localizedStandardContains(String($0)) }
    }

    private func permissions(_ lookup: [String: ToolBrowserIndex.Entry]) -> some View {
        let api = !showsAPIKeys || source == .ssh ? [] : grants.filter { grant in
            let entry = lookup[grant.tool]
            return matches([entry?.profile.title ?? grant.tool, grant.caller.label] + (entry?.keys.flatMap { [$0.name, $0.binding.variable] } ?? []))
        }
        let temporary = source == .apiKeys ? [] : sshTrusts.filter { matches([$0.displayName, $0.keyName]) }
        let persistent = source == .apiKeys ? [] : alwaysAllowed.filter { matches([$0.displayName]) }
        return VStack(spacing: 0) {
            HStack {
                Text("\(api.count + temporary.count + persistent.count) matching permissions").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Revoke Temporary…") { revokeAll = true }.buttonStyle(.appSecondarySmall)
                    .disabled(grants.isEmpty && sshTrusts.isEmpty).accessibilityIdentifier("revokeTemporaryAccess")
            }.padding(.horizontal, 18).padding(.vertical, 12)
            if api.isEmpty && temporary.isEmpty && persistent.isEmpty {
                ContentUnavailableView(query.isEmpty && source == .all ? "No active permissions" : "No matching permissions", systemImage: "checkmark.shield",
                                       description: Text(showsAPIKeys ? "Temporary approvals appear after you allow a launch or SSH signature. Saving a tool does not grant access." : "SSH approvals appear after you allow a signature."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if !api.isEmpty {
                            sectionTitle("API key delivery", note: "A specific saved tool and launcher process. Delivered keys cannot be recalled.")
                            ForEach(api) { grant in
                                let entry = lookup[grant.tool]
                                VStack(alignment: .leading, spacing: 8) {
                                    permissionHeader(entry?.profile.title ?? String(localized: "Unavailable tool"), subtitle: grant.caller.label, action: "Revoke") {
                                        model.secrets.revokeGrant(grant.id)
                                    }
                                    Label(apiExpiry(grant), systemImage: grant.deadline == nil ? "lock" : "clock")
                                        .font(.system(size: 12)).foregroundStyle(.secondary)
                                    if let entry {
                                        DisclosureGroup("\(entry.keys.count) key bindings") {
                                            ForEach(entry.keys) { key in
                                                Text(verbatim: key.name + " → " + key.binding.variable)
                                                    .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                        }.font(.system(size: 12))
                                    }
                                    Divider().opacity(0.5)
                                }.accessibilityIdentifier("apiAccess-\(grant.id)")
                            }
                        }
                        if !temporary.isEmpty {
                            sectionTitle("Temporary SSH signing", note: "The app may request signatures with the listed SSH key. Private keys stay in Triwarden.")
                            ForEach(temporary) { trust in
                                VStack(alignment: .leading, spacing: 8) {
                                    permissionHeader(trust.displayName, subtitle: trust.keyName, action: "Revoke") { model.sshAgent.revokeTrust(id: trust.id) }
                                    if let until = trust.until {
                                        Text("\(max(0, Int(ceil(until.timeIntervalSinceNow)))) seconds remaining").monospacedDigit()
                                            .font(.system(size: 12)).foregroundStyle(.secondary)
                                    } else { Label("Until the vault locks", systemImage: "lock").font(.system(size: 12)).foregroundStyle(.secondary) }
                                    Divider().opacity(0.5)
                                }
                            }
                        }
                        if !persistent.isEmpty {
                            sectionTitle("Always Allowed SSH apps", note: "Applies to available SSH keys while the vault is unlocked. This permission survives lock and restart.")
                            ForEach(persistent) { entry in
                                VStack(alignment: .leading, spacing: 8) {
                                    permissionHeader(entry.displayName, subtitle: String(localized: "Persistent SSH permission"), action: "Remove") {
                                        model.sshAgent.revokeAllowlist(trustKey: entry.trustKey)
                                    }
                                    Divider().opacity(0.5)
                                }
                            }
                        }
                    }.padding(20).frame(maxWidth: 800, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading)
                }.thinScroller()
            }
        }
    }

    private var historyList: some View {
        let filtered = source == .apiKeys ? [] : events.filter { event in
            outcome.includes(event.outcome) && matches([event.appName, event.keyName, event.via, event.path ?? ""])
        }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SSH · \(filtered.count) records").font(.system(size: 12, weight: .medium))
                Spacer()
                Button("Clear SSH History…") { clearHistory = true }.buttonStyle(.appSecondarySmall).disabled(events.isEmpty)
            }.padding(.horizontal, 18).padding(.top, 14)
            Text(showsAPIKeys ? "SSH requests only · most recent 200 records. API-key launch history is not recorded." : "The most recent 200 SSH requests appear here.")
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 10)
            if filtered.isEmpty {
                ContentUnavailableView(source == .apiKeys ? "API-key history is not available" : "No matching SSH records",
                                       systemImage: "clock", description: Text(source == .apiKeys ? "You can review and revoke current API-key approvals in Permissions." : "Try another search or result filter."))
            } else {
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    List(filtered) { event in SSHAccessRecordRow(event: event).padding(.vertical, 5) }
                        .listStyle(.inset).scrollContentBackground(.hidden).thinScroller().accessibilityIdentifier("sshAccessHistory")
                }
            }
        }
    }
    private func sectionTitle(_ title: LocalizedStringKey, note: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(note).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.top, 5)
    }
    private func permissionHeader(_ title: String, subtitle: String, action: LocalizedStringKey, perform: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: SecretsController.display(title)).font(.system(size: 14, weight: .semibold))
                Text(verbatim: SecretsController.display(subtitle)).font(.system(size: 12)).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button(action, action: perform).buttonStyle(.appSecondarySmall)
                .accessibilityLabel(Text("\(Text(action)) \(Text(verbatim: SecretsController.display(title)))"))
        }
    }
    private func apiExpiry(_ grant: SecretsActiveGrant) -> String {
        guard let deadline = grant.deadline else { return String(localized: "Until Triwarden locks") }
        let parts = ContinuousClock.now.duration(to: deadline).components
        let seconds = max(0, parts.seconds + (parts.attoseconds > 0 ? 1 : 0))
        return String(localized: "\(seconds / 60)m \(seconds % 60)s remaining")
    }
}
