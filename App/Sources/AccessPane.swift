import SecretsAgent
import SSHAgent
import SwiftUI

struct AccessPane: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var history = false
    @State private var outcome = HistoryFilter.all
    @State private var permissionSearchRevealed = false
    @State private var revokeAll = false
    @State private var clearHistory = false
    @State private var removeAlways: SSHAllowlistEntry?
    @FocusState private var searchFocused: Bool
    #if DEBUG
    var previewProfiles: [SecretsProfile]?
    var previewGrants: [SecretsActiveGrant]?
    var previewSSHTrusts: [SSHTrust]?
    var previewAlways: [SSHAllowlistEntry]?
    var previewHistory: [SSHAccessEvent]?
    var previewShowsHistory = false
    #endif

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
    private static let permissionSearchThreshold = 8

    var body: some View {
        let index = ToolBrowserIndex(profiles: profiles, items: model.items, unlocked: Set(model.sessions.map(\.id)))
        let lookup = Dictionary(index.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let permissionCount = grants.count + sshTrusts.count + alwaysAllowed.count
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center) {
                    Text("Access").font(.system(size: 22, weight: .bold))
                    Spacer()
                    AppSegmented(options: [(false, LocalizedStringKey("Permissions")), (true, "History")], selection: $history)
                        .frame(width: 220)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Access view")
                        .accessibilityIdentifier("accessTabs")
                }
                if history || permissionCount >= Self.permissionSearchThreshold || permissionSearchRevealed || !query.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { search.frame(maxWidth: 360); filters; Spacer(minLength: 0) }
                        VStack(alignment: .leading, spacing: 8) { search; HStack { filters; Spacer() } }
                    }
                }
            }.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)
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
            if wants {
                model.wantsAccessSearchFocus = false
                if !history { permissionSearchRevealed = true }
                Task { @MainActor in
                    await Task.yield()
                    searchFocused = true
                }
            }
        }
        .confirmationDialog("End all temporary access?", isPresented: $revokeAll) {
            Button("End Temporary Access", role: .destructive) { model.secrets.reset(); model.sshAgent.reset() }
        } message: {
            Text(showsAPIKeys ? "Temporary API-key and SSH approvals will end, and pending requests will be cancelled. Always Allowed SSH apps are kept; remove them separately below. Keys already delivered and established SSH connections cannot be recalled." : "Temporary SSH approvals will end. Always Allowed SSH apps are kept. Established SSH connections cannot be recalled.")
        }
        .confirmationDialog("Remove this Always Allowed app?", isPresented: Binding(get: { removeAlways != nil }, set: { if !$0 { removeAlways = nil } }),
                            presenting: removeAlways) { entry in
            Button("Remove", role: .destructive) { model.sshAgent.revokeAllowlist(trustKey: entry.trustKey) }
        } message: { entry in
            Text("\(SecretsController.display(entry.displayName)) will ask again before its next SSH signature.")
        }
        .confirmationDialog("Clear SSH history?", isPresented: $clearHistory) {
            Button("Clear History", role: .destructive) { model.sshAgent.clearAccessLog() }
        } message: { Text("This removes the local SSH request history. It does not revoke any permissions.") }
    }

    private var search: some View {
        WorkspaceSearchField(prompt: history ? "Search SSH apps or keys" : showsAPIKeys ? "Search apps, tools or keys" : "Search apps or keys",
                             text: $query, focused: $searchFocused)
            .frame(minWidth: 140).accessibilityIdentifier("accessSearch")
    }
    private var filters: some View {
        Group {
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
        let api = !showsAPIKeys ? [] : grants.filter { grant in
            let entry = lookup[grant.tool]
            return matches([entry?.profile.title ?? grant.tool, grant.caller.label] + (entry?.keys.flatMap { [$0.name, $0.binding.variable] } ?? []))
        }
        let temporary = sshTrusts.filter { matches([$0.displayName, $0.keyName]) }
        let persistent = alwaysAllowed.filter { matches([$0.displayName]) }
        let none = api.isEmpty && temporary.isEmpty && persistent.isEmpty
        return Group {
            if none {
                VStack(spacing: 14) {
                    Image(systemName: "checkmark.shield").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                    Text(query.isEmpty ? "Nothing has access right now" : "No matching permissions")
                        .font(.system(size: 15, weight: .semibold))
                    Text(showsAPIKeys ? "When you approve a tool launch or an SSH signature for a while, it appears here so you can end it early. Saving a tool grants nothing."
                                      : "When you approve an SSH signature for a while, it appears here so you can end it early.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(32)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(verbatim: summary(api.count + temporary.count, persistent.count))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer()
                            Button("End All Temporary Access…") { revokeAll = true }.buttonStyle(.appSecondarySmall)
                                .disabled(grants.isEmpty && sshTrusts.isEmpty).accessibilityIdentifier("revokeTemporaryAccess")
                        }
                        if !api.isEmpty {
                            group("Tool launches", note: "Each approval covers one saved tool started from one terminal window. Keys already delivered stay with the program.") {
                                ForEach(api) { grant in
                                    let entry = lookup[grant.tool]
                                    permissionRow(symbol: entry.map { ToolGlyph.symbol($0.profile) } ?? "terminal",
                                                  title: entry?.profile.title ?? String(localized: "Unavailable tool"),
                                                  subtitle: [grant.caller.label, entry.map { $0.keys.count == 1 ? String(localized: "1 key") : String(localized: "\($0.keys.count) keys") }]
                                                      .compactMap { $0 }.joined(separator: " · "),
                                                  expiry: apiExpiry(grant), forever: grant.deadline == nil,
                                                  action: "End", last: grant.id == api.last?.id) {
                                        model.secrets.revokeGrant(grant.id)
                                    }.accessibilityIdentifier("apiAccess-\(grant.id)")
                                }
                            }
                        }
                        if !temporary.isEmpty {
                            group("SSH signing", note: "These apps can sign with the listed key without asking. The private key never leaves Triwarden.") {
                                ForEach(temporary) { trust in
                                    permissionRow(symbol: "key.fill", title: trust.displayName, subtitle: trust.keyName,
                                                  expiry: trust.until.map { Self.remaining(until: $0) } ?? String(localized: "Until the vault locks"),
                                                  forever: trust.until == nil, action: "End", last: trust.id == temporary.last?.id) {
                                        model.sshAgent.revokeTrust(id: trust.id)
                                    }
                                }
                            }
                        }
                        if !persistent.isEmpty {
                            group("Always allowed", note: "Never asks while the vault is unlocked, and survives lock and restart. Remove an app to be asked again.") {
                                ForEach(persistent) { entry in
                                    permissionRow(symbol: "checkmark.seal", title: entry.displayName, subtitle: String(localized: "All available SSH keys"),
                                                  expiry: nil, forever: true, action: "Remove…", last: entry.id == persistent.last?.id) {
                                        removeAlways = entry
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 32)
                    .frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity, alignment: .top)
                }.thinScroller()
            }
        }
    }

    private func summary(_ temporary: Int, _ always: Int) -> String {
        switch (temporary, always) {
        case (0, _): String(localized: "\(always) always allowed")
        case (_, 0): String(localized: "\(temporary) temporary")
        default: String(localized: "\(temporary) temporary · \(always) always allowed")
        }
    }

    private func group<Content: View>(_ title: LocalizedStringKey, note: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .textCase(.uppercase).tracking(0.4).padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .background(Color.panelStrong, in: .rect(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.panelEdge))
            Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        }
    }

    private func permissionRow(symbol: String, title: String, subtitle: String, expiry: String?, forever: Bool,
                               action: LocalizedStringKey, last: Bool, perform: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(.primary.opacity(0.05), in: .rect(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: SecretsController.display(title)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(verbatim: SecretsController.display(subtitle)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if let expiry {
                    Label(expiry, systemImage: forever ? "lock" : "timer")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
                Button(action, action: perform).buttonStyle(.appSecondarySmall).fixedSize()
                    .accessibilityLabel(Text("\(Text(action)) \(Text(verbatim: SecretsController.display(title)))"))
            }.padding(.horizontal, 12).padding(.vertical, 10)
            if !last { Divider().opacity(0.4).padding(.leading, 54) }
        }
    }

    private var historyList: some View {
        let filtered = events.filter { event in
            outcome.includes(event.outcome) && matches([event.appName, event.keyName, event.via, event.path ?? ""])
        }
        return Group {
            if filtered.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "clock").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                    Text(events.isEmpty ? "No SSH requests yet" : "No matching requests")
                        .font(.system(size: 15, weight: .semibold))
                    Text(events.isEmpty ? "Each time an app asks to sign with an SSH key, the request and its outcome appear here. Tool launches are not recorded."
                                        : "Try another search or result.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(32)
            } else {
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("SSH request history · last 200. Tool launches are not recorded.")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                Spacer()
                                Button("Clear History…") { clearHistory = true }.buttonStyle(.appSecondarySmall).disabled(events.isEmpty)
                            }
                            ForEach(Self.days(filtered), id: \.day) { day in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(verbatim: Self.dayTitle(day.day)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                        .textCase(.uppercase).tracking(0.4).padding(.leading, 4)
                                    VStack(spacing: 0) {
                                        ForEach(day.events) { event in
                                            SSHAccessRecordRow(event: event).padding(.horizontal, 14).padding(.vertical, 9)
                                            if event.id != day.events.last?.id { Divider().opacity(0.4).padding(.leading, 14) }
                                        }
                                    }
                                    .background(Color.panelStrong, in: .rect(cornerRadius: 14, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.panelEdge))
                                }
                            }
                        }
                        .padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 32)
                        .frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity, alignment: .top)
                    }.thinScroller().accessibilityIdentifier("sshAccessHistory")
                }
            }
        }
    }

    private static func days(_ events: [SSHAccessEvent]) -> [(day: Date, events: [SSHAccessEvent])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var groups: [Date: [SSHAccessEvent]] = [:]
        for event in events {
            let day = calendar.startOfDay(for: event.date)
            if groups[day] == nil { order.append(day) }
            groups[day, default: []].append(event)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    private static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
    private func apiExpiry(_ grant: SecretsActiveGrant) -> String {
        guard let deadline = grant.deadline else { return String(localized: "Until the vault locks") }
        let parts = ContinuousClock.now.duration(to: deadline).components
        return Self.remaining(seconds: Int(parts.seconds) + (parts.attoseconds > 0 ? 1 : 0))
    }
    private static func remaining(until date: Date) -> String { remaining(seconds: Int(ceil(date.timeIntervalSinceNow))) }
    private static func remaining(seconds: Int) -> String {
        let seconds = max(0, seconds)
        return String(localized: "\(seconds / 60):\(String(format: "%02d", seconds % 60)) left")
    }
}
