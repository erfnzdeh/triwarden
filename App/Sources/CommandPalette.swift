import AppKit
import SSHAgent
import SwiftUI

/// Control+Return in the palette's field opens the system text menu. Catch it first and run the shortcut.
private final class ControlReturnMonitor: @unchecked Sendable {
    var onFire: (EventModifiers) -> Void = { _ in }
    private var token: Any?

    func start() {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.window is QuickSearchPanel else { return event }
            guard event.keyCode == 36 || event.keyCode == 76 else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.control) else { return event }
            if event.isARepeat { return nil }
            var modifiers: EventModifiers = [.control]
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.command) { modifiers.insert(.command) }
            MainActor.assumeIsolated { self?.onFire(modifiers) }
            return nil
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}

/// One runnable action in the palette.
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var shortcut: String?
    var keywords: [String] = []
    let run: @MainActor () -> Void

    func matches(_ q: String) -> Bool {
        title.localizedCaseInsensitiveContains(q) || keywords.contains { $0.localizedCaseInsensitiveContains(q) }
    }
}

/// The command palette (⌘K / ⌘F in the window, the global shortcut from Settings anywhere), after the Liquid search design:
/// a big field, ranked items (the highlighted one opened up with its live code and keys), and commands to run.
/// Scopes narrow it (`>` commands, `#folder`, `@account`, `card:`…); → or Tab opens an item's every action; `gen 24`
/// makes a password; a locked vault unlocks right here.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    let close: () -> Void
    /// Snapshots: start with this typed, and (optionally) the first item's actions open.
    var initialQuery = ""
    var initialActions = false
    @State private var query = ""
    /// Scopes already turned into chips (`>`, `#Work`, `card:`…), ahead of the typed text.
    @State private var scopeTokens: [String] = []
    @State private var index = 0
    @State private var appeared = false
    @FocusState private var focused: Bool
    /// The item whose actions are listed (→ / Tab), or nil for the results.
    @State private var actionsFor: VaultItem?
    /// The generator row's current value, remade when the request changes or on ⌘R.
    @State private var generated = ""
    /// Shown for a moment after a copy, before the palette goes.
    @State private var flash: String?
    /// Control+Return never reaches the field's key handler: macOS opens the text menu (Cut, Copy, Paste) instead.
    @State private var controlReturn = ControlReturnMonitor()

    enum Entry: Identifiable {
        case item(VaultItem)
        case command(PaletteCommand)
        case generated(PaletteGenerate)
        case ssh(SSHPaletteChoice)
        var id: String {
            switch self {
            case .item(let i): "i-" + i.id
            case .command(let c): "c-" + c.id
            case .generated: "generated"
            case .ssh(let choice): choice.id
            }
        }
    }

    struct Section {
        let title: String
        let entries: [Entry]
    }

    /// Called from another app: the page's (or app's) logins, which go first; ↵ types the login into it.
    private var context: ForegroundContext? { model.foreground }

    private var scopeAccounts: [(id: String, email: String)] {
        model.accounts.count > 1 ? model.accounts.map { (id: $0.id, email: $0.email) } : []
    }

    private var parsed: PaletteQuery {
        PaletteQuery((scopeTokens + [query]).joined(separator: " "), folders: model.folders.map(\.name), accounts: scopeAccounts)
    }

    /// A finished scope (followed by a space, or a leading `>`) leaves the field and becomes a chip.
    private func promoteScopes() {
        if query.hasPrefix(">"), !scopeTokens.contains(">") {
            scopeTokens.insert(">", at: 0)
            query.removeFirst()
        }
        guard query.contains(" ") else { return }
        var words = query.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let last = words.removeLast() // still being typed
        var kept: [String] = []
        for word in words where !word.isEmpty {
            if !PaletteQuery(word, folders: model.folders.map(\.name), accounts: scopeAccounts).scopes.isEmpty {
                scopeTokens.append(word)
            } else {
                kept.append(word)
            }
        }
        let rebuilt = (kept + [last]).joined(separator: " ")
        if rebuilt != query { query = kept.isEmpty ? last : rebuilt }
    }

    private var generateRequest: PaletteGenerate? {
        guard model.isUnlocked, actionsFor == nil else { return nil }
        return PaletteGenerate.parse(parsed.text)
    }

    /// The results, in sections: generator, this page's logins, items (with "Show all" when there are more), commands.
    private var sections: [Section] {
        if let item = actionsFor {
            return [Section(title: item.name, entries: itemActions(item).map(Entry.command))]
        }
        let pq = parsed
        var out: [Section] = []
        if let generate = generateRequest { out.append(Section(title: String(localized: "Generator"), entries: [.generated(generate)])) }

        var shownItems = 0
        var totalItems = 0
        if model.isUnlocked, !pq.commandsOnly {
            let recents = PaletteRecents.ids
            let live = model.items.filter { !$0.isDeleted && !$0.isArchived && pq.admits($0) }
            var site: [VaultItem] = []
            if let context {
                let candidates = context.items(in: model).filter(pq.admits)
                site = pq.text.isEmpty ? candidates : PaletteRank.rank(candidates, pq.text, recents: recents)
            }
            if !site.isEmpty {
                out.append(Section(title: context?.host != nil ? String(localized: "On \(context!.label)") : String(localized: "For \(context!.label)"),
                                   entries: site.map(Entry.item)))
            }
            let siteIDs = Set(site.map(\.id))
            let rest = live.filter { !siteIDs.contains($0.id) }
            var picked: [VaultItem]
            var title: String
            if pq.text.isEmpty && pq.scopes.isEmpty {
                // Nothing typed: what was used lately, then favorites.
                let byID = Dictionary(rest.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let recent = recents.compactMap { byID[$0] }
                let favorites = rest.filter { $0.favorite && !recents.contains($0.id) }
                picked = Array((recent + favorites).prefix(site.isEmpty ? 5 : 3))
                totalItems = picked.count
                title = recent.isEmpty ? String(localized: "Suggestions") : String(localized: "Recent")
            } else {
                let ranked = pq.text.isEmpty ? rest.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    : PaletteRank.rank(rest, pq.text, recents: recents)
                totalItems = ranked.count
                picked = Array(ranked.prefix(max(3, 7 - site.count)))
                title = String(localized: "Items")
            }
            shownItems = picked.count
            var entries = picked.map(Entry.item)
            if totalItems > shownItems, !pq.text.isEmpty {
                let text = pq.text
                entries.append(.command(PaletteCommand(id: "show-all", title: String(localized: "Show all \(totalItems) results in the vault"),
                                                       symbol: "list.bullet", shortcut: nil) {
                    model.bringToFront()
                    model.requestedFilter = text
                    close()
                }))
            }
            if !entries.isEmpty { out.append(Section(title: title, entries: entries)) }
            totalItems += site.count
        }

        var commands: [PaletteCommand] = []
        let all = Self.commands(model: model, close: close)
        if pq.commandsOnly {
            commands = pq.text.isEmpty ? all : all.filter { $0.matches(pq.text) }
        } else if pq.text.isEmpty {
            if pq.scopes.isEmpty { commands = all.filter { ["new-login", "generator", "watchtower", "lock"].contains($0.id) } }
        } else {
            commands = Array(all.filter { $0.matches(pq.text) }.prefix(5))
            // Nothing in the vault by that name: offer to make it.
            if model.isUnlocked, totalItems == 0, generateRequest == nil, let prefill = PaletteCreate.prefill(pq.text) {
                commands.insert(PaletteCommand(id: "create-typed", title: String(localized: "New Login “\(prefill.name)”"),
                                               symbol: "plus.circle", shortcut: nil) {
                    model.bringToFront()
                    model.beginEditing(EditRequest(mode: .create(.login), prefill: prefill))
                }, at: 0)
            }
        }
        if !commands.isEmpty { out.append(Section(title: String(localized: "Commands"), entries: commands.map(Entry.command))) }
        if let ssh = sshRequestSection { out.insert(ssh, at: 0) }
        return out
    }

    /// A waiting SSH signature stays above search results. Return runs the first choice.
    private var sshRequestSection: Section? {
        guard actionsFor == nil, let prompt = model.sshAgent?.pending, let agent = model.sshAgent else { return nil }
        let q = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let blob = "\(prompt.displayName) \(prompt.via) \(prompt.keyName) ssh sign request"
        guard q.isEmpty || blob.localizedCaseInsensitiveContains(q) else { return nil }
        let lead = agent.pendingLeadsWithUntilLock ? SSHGrant.untilLock : SSHGrant.once
        var grants: [(SSHGrant, LocalizedStringKey, String)] = [
            (.once, "Allow Once", "checkmark.circle"),
            (.tenMinutes, "Allow for 10 Minutes", "clock"),
            (.untilLock, "Trust Until Lock", "lock.open"),
            (.always, "Always Allow", "checkmark.seal"),
        ]
        if let first = grants.firstIndex(where: { $0.0 == lead }) {
            grants.insert(grants.remove(at: first), at: 0)
        }
        var choices = grants.enumerated().map { index, grant in
            SSHPaletteChoice(id: "ssh-\(index)", prompt: prompt, title: grant.1, symbol: grant.2, showsIdentity: index == 0) {
                agent.choose(.allow(grant.0))
                close()
            }
        }
        choices.append(SSHPaletteChoice(id: "ssh-deny", prompt: prompt, title: "Deny", symbol: "xmark.circle", showsIdentity: false) {
            agent.choose(.deny)
            close()
        })
        return Section(title: String(localized: "SSH request"), entries: choices.map(Entry.ssh))
    }

    private var entries: [Entry] { sections.flatMap(\.entries) }

    /// The palette itself: field, results, hints.
    private var card: some View {
        let dark = scheme == .dark
        return VStack(spacing: 0) {
            searchBar
            .padding(.horizontal, 18)
            .frame(height: 54)
            Divider().opacity(0.6)

            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                FrontTabMatchPrompt(horizontalPadding: 14)
            }
            results(self.sections)
            Divider().opacity(0.6)
            footer
                .padding(.horizontal, 16).frame(height: 36)
        }
        .frame(width: 704)
        .background(.regularMaterial, in: .rect(cornerRadius: 22, style: .continuous))
        .background((dark ? Color.black.opacity(0.15) : Color.white.opacity(0.55)), in: .rect(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.primary.opacity(dark ? 0.14 : 0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(dark ? 0.35 : 0.14), radius: 18, y: 8)
        .scaleEffect(x: appeared ? 1 : 0.92, y: appeared ? 1 : 0.94, anchor: .top) // a short way to grow: it feels instant
        .opacity(appeared ? 1 : 0)
    }

    var body: some View {
        card
        .padding(28) // room for the shadow inside the panel
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The transparent margin is part of the panel: a click there counts as outside.
        .background(Color.black.opacity(0.001).onTapGesture { close() })
        .onChange(of: model.quickSearchNonce, initial: true) {
            query = initialQuery; scopeTokens = []; index = 0; focused = true
            promoteScopes()
            actionsFor = nil; flash = nil
            regenerate()
            if initialActions {
                // After the query has settled (changing it closes the actions).
                Task { @MainActor in
                    if case .item(let item)? = entries.first { actionsFor = item; index = 0 }
                }
            }
            appeared = false
            withAnimation(.spring(duration: 0.24, bounce: 0.18)) { appeared = true }
        }
        .onChange(of: model.quickSearchDismissNonce) {
            focused = false
            withAnimation(.easeIn(duration: 0.1)) { appeared = false }
        }
        .onChange(of: query) {
            index = 0
            actionsFor = nil
            promoteScopes()
        }
        .onChange(of: scopeTokens) { index = 0 }
        .onChange(of: generateRequest) { regenerate() }
        // Unlocked from here: back to the search field.
        .onChange(of: model.isUnlocked) { _, open in if open { focused = true } }
        .onAppear {
            controlReturn.onFire = { run($0) }
            controlReturn.start()
        }
        .onDisappear { controlReturn.stop() }
    }

    // MARK: Pieces

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 17)).foregroundStyle(.secondary)
            ForEach(parsed.scopes) { scope in
                ScopeChip(scope: scope) { scopeTokens.removeAll { $0 == scope.token }; focused = true }
            }
            TextField("Search or run a command", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 19))
                .focused($focused)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) {
                    if actionsFor != nil { closeActions() } else { close() }
                    return .handled
                }
                .onKeyPress(.tab) { openActions() ? .handled : .ignored }
                .onKeyPress(.rightArrow) { openActions() ? .handled : .ignored }
                .onKeyPress(.leftArrow) {
                    guard actionsFor != nil else { return .ignored }
                    closeActions()
                    return .handled
                }
                .onKeyPress(.return, phases: .down) { press in run(press.modifiers); return .handled }
                // ⌫ in an empty field takes the last chip back.
                .onKeyPress(.delete) {
                    guard query.isEmpty, !scopeTokens.isEmpty else { return .ignored }
                    scopeTokens.removeLast()
                    return .handled
                }
                .onKeyPress(phases: .down) { press in commandKey(press) }
            if let context {
                ContextChip(context: context)
            } else if model.sessions.count > 1 {
                Text("\(model.sessions.count) accounts")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(Color.primary.opacity(0.06), in: .capsule)
            }
        }
    }

    /// The results scroll once they're taller than this (an identity's actions, a long command list).
    private static let resultsMaxHeight: CGFloat = 430

    private func results(_ sections: [Section]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                resultRows(sections)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: Self.resultsMaxHeight)
            .fixedSize(horizontal: false, vertical: true) // as tall as the rows, up to the limit
            .onChange(of: index) { _, i in
                let flat = sections.flatMap(\.entries)
                if flat.indices.contains(i) { proxy.scrollTo(flat[i].id) }
            }
        }
    }

    private func resultRows(_ sections: [Section]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if !model.isUnlocked && !parsed.commandsOnly {
                PaletteUnlock()
            }
            let flat = sections.flatMap(\.entries)
            ForEach(Array(flat.enumerated()), id: \.element.id) { i, entry in
                header(at: i, in: sections)
                Group {
                    switch entry {
                    case .item(let item):
                        ItemLine(item: item, selected: i == index, highlight: parsed.text)
                    case .command(let command):
                        CommandLine(command: command, selected: i == index)
                    case .generated(let request):
                        GeneratedLine(request: request, value: generated, selected: i == index)
                    case .ssh(let choice):
                        SSHPaletteLine(choice: choice, selected: i == index)
                    }
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 4)
                .animation(appeared ? .spring(duration: 0.22, bounce: 0.12).delay(0.015 * Double(min(i, 6))) : .easeIn(duration: 0.08),
                           value: appeared) // staggered in, all together out
                .contentShape(.rect)
                .onTapGesture { index = i; run([]) }
                .onHover { if $0 { index = i } }
            }
            if model.isUnlocked && flat.isEmpty {
                Text("Nothing matches “\(parsed.text)”").font(.system(size: 13)).foregroundStyle(.secondary).padding(14)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .animation(.snappy(duration: 0.18), value: index)
        .animation(.snappy(duration: 0.2), value: actionsFor?.id)
    }

    /// The section that starts at entry `i`, and whether it's the first.
    private func sectionStarting(at i: Int, in sections: [Section]) -> (section: Section, first: Bool)? {
        var start = 0
        for (n, section) in sections.enumerated() {
            if i == start, !section.entries.isEmpty { return (section, n == 0) }
            start += section.entries.count
        }
        return nil
    }

    @ViewBuilder private func header(at i: Int, in sections: [Section]) -> some View {
        if let (section, first) = sectionStarting(at: i, in: sections) {
            if actionsFor != nil {
                // The item's actions: its name, and the way back.
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text(verbatim: section.title).lineLimit(1)
                }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)
                .contentShape(.rect)
                .onTapGesture { closeActions() }
            } else {
                sectionLabel(section.title, first: first)
            }
        }
    }

    /// What the keys do for the highlighted entry (the rows stay clean); after a copy, what was copied.
    @ViewBuilder private var footer: some View {
        HStack(spacing: 16) {
            if let flash {
                Label { Text(verbatim: flash) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    .font(.system(size: 12, weight: .medium))
                    .transition(.opacity)
            } else {
                selectionHints
            }
            Spacer()
        }
        .animation(.easeOut(duration: 0.15), value: flash)
        .animation(.easeOut(duration: 0.12), value: index)
    }

    @ViewBuilder private var selectionHints: some View {
        let current = entries.indices.contains(index) ? entries[index] : nil
        switch current {
        case .item(let item)?:
            if let context, item.kind == .login {
                footerHint("↵", "Type into \(context.app)")
                if item.username != nil { footerHint("⌃↵", "Username") }
                if item.password != nil { footerHint("⌥↵", "Password") }
                if item.totp != nil { footerHint("⌘↵", "Code") }
                Text("Hold ⇧ to submit")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                footerHint("↵", "Open")
                if item.password != nil { footerHint("⌘↵", "Copy password") }
                if item.totp != nil { footerHint("⌥↵", "Copy code") }
                if item.host != nil { footerHint("⇧↵", "Open website") }
            }
            footerHint("→", "More")
        case .generated?:
            footerHint("↵", "Copy")
            footerHint("⌘↵", "Save as login")
            footerHint("⌘R", "New")
        case .command?:
            footerHint("↵", actionsFor != nil ? "Run" : "Open")
            if actionsFor != nil { footerHint("←", "Back") }
        case .ssh(let choice)?:
            footerHint("↵", choice.title)
        case nil:
            EmptyView()
        }
    }

    private func sectionLabel(_ title: String, first: Bool) -> some View {
        Text(verbatim: title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.top, first ? 4 : 10).padding(.bottom, 2)
    }

    private func footerHint(_ keys: String, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Keycap(keys: keys)
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    // MARK: Keys

    private func move(_ delta: Int) {
        let count = entries.count
        guard count > 0 else { return }
        index = (index + delta + count) % count
    }

    /// ⌘1–⌘9 run that result; ⌘R makes a new generated value.
    private func commandKey(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers == .command else { return .ignored }
        if press.characters == "r", generateRequest != nil { regenerate(); return .handled }
        if let n = Int(press.characters), (1...9).contains(n), n <= entries.count {
            index = n - 1
            run([])
            return .handled
        }
        return .ignored
    }

    /// → / Tab on an item: its actions. False when the highlighted entry isn't an item.
    private func openActions() -> Bool {
        guard actionsFor == nil, entries.indices.contains(index), case .item(let item) = entries[index] else { return false }
        withAnimation(.snappy(duration: 0.2)) { actionsFor = item }
        index = 0
        return true
    }

    private func closeActions() {
        guard let item = actionsFor else { return }
        withAnimation(.snappy(duration: 0.2)) { actionsFor = nil }
        index = entries.firstIndex { if case .item(let i) = $0 { i.id == item.id } else { false } } ?? 0
    }

    private func regenerate() { generated = generateRequest?.generate() ?? "" }

    // MARK: Running

    private func run(_ modifiers: SwiftUI.EventModifiers) {
        guard entries.indices.contains(index) else { return }
        switch entries[index] {
        case .command(let command):
            // An item's action decides itself when to close (a copy lingers a moment to say so).
            if actionsFor == nil { close() }
            command.run()
        case .ssh(let choice):
            choice.run()
        case .generated:
            let value = generated
            guard !value.isEmpty else { return }
            if modifiers.contains(.command) {
                // ⌘↵: save it in a new login.
                close()
                model.bringToFront()
                model.beginEditing(EditRequest(mode: .create(.login), prefill: EditItemSheet.Prefill(password: value)))
            } else {
                finish(nil, flash: String(localized: "Password copied")) { model.copy(value, label: String(localized: "Password")) }
            }
        case .item(let item):
            // Called from another app: type into it, like KeePass's auto-type (↵ both, ⌃↵ username, ⌥↵ password,
            // ⌘↵ code; ⇧ also presses Return). Without Accessibility yet, the password is copied instead.
            if let context, item.kind == .login, item.username != nil || item.password != nil || item.totp != nil {
                fill(item, into: context, modifiers)
                return
            }
            if modifiers.contains(.shift), let url = websiteURL(item) {
                finish(item, flash: nil) { NSWorkspace.shared.open(url) }
            } else if modifiers.contains(.option), let totp = item.totp {
                finish(item, flash: String(localized: "Code copied")) { model.copy(totp.code(), label: String(localized: "Code")) }
            } else if modifiers.contains(.command), item.password != nil {
                finish(item, flash: String(localized: "Password copied")) { model.copyPassword(item) }
            } else {
                finish(item, flash: nil) { model.showItem(item.id) }
            }
        }
    }

    /// Runs an item's action, then closes; a copy says so in the footer for a moment first. An item that asks for the
    /// master password first closes at once (the question comes up in the window).
    private func finish(_ item: VaultItem?, flash label: String?, _ work: @escaping () -> Void) {
        if let item { PaletteRecents.note(item.id) }
        if let item, !model.isRepromptPassed(item) {
            close()
            model.guarded(item, work)
            return
        }
        work()
        guard let label else { close(); return }
        flashThenClose(label)
    }

    /// Says what was copied in the footer, then closes — unless the palette has been opened again meanwhile.
    private func flashThenClose(_ label: String) {
        flash = label
        let opening = model.quickSearchNonce
        Task {
            try? await Task.sleep(for: .milliseconds(550))
            if model.quickSearchNonce == opening { close() }
        }
    }

    private func fill(_ item: VaultItem, into context: ForegroundContext, _ modifiers: SwiftUI.EventModifiers) {
        let submit = modifiers.contains(.shift)
        let steps: () -> [AutoType.Step] = {
            var steps: [AutoType.Step]
            if modifiers.contains(.control) {
                steps = item.username.map { [.text($0)] } ?? []
            } else if modifiers.contains(.option) {
                steps = item.password.map { [.text($0)] } ?? []
            } else if modifiers.contains(.command) {
                steps = item.totp.map { [.text($0.code())] } ?? []
            } else {
                steps = [item.username.map(AutoType.Step.text), item.username != nil && item.password != nil ? .tab : nil,
                         item.password.map(AutoType.Step.text)].compactMap { $0 }
            }
            if submit, !steps.isEmpty { steps.append(.enter) }
            return steps
        }
        guard !steps().isEmpty else { return }
        PaletteRecents.note(item.id)
        close()
        model.guarded(item) {
            let fallback = modifiers.contains(.control) ? item.username.map { ($0, String(localized: "Username")) }
                : item.password.map { ($0, String(localized: "Password")) }
            model.autoType(steps(), into: context, fallback: fallback.map { (value: $0.0, label: $0.1) })
        }
    }

    private func websiteURL(_ item: VaultItem) -> URL? {
        guard let address = item.uri ?? item.host, !address.isEmpty else { return nil }
        return URL(string: address.contains("://") ? address : "https://" + address)
    }

    /// Everything that can be done with one item, for its type: fill, copy each part, open, edit, favorite, trash.
    private func itemActions(_ item: VaultItem) -> [PaletteCommand] {
        var list: [PaletteCommand] = []
        func copy(_ id: String, _ title: String, _ symbol: String, shortcut: String? = nil, label: String, _ value: @escaping () -> String) {
            list.append(PaletteCommand(id: id, title: title, symbol: symbol, shortcut: shortcut) {
                finish(item, flash: String(localized: "\(label) copied")) { model.copy(value(), label: label) }
            })
        }
        if let context, item.kind == .login, item.username != nil || item.password != nil {
            list.append(PaletteCommand(id: "fill", title: String(localized: "Fill into \(context.app)"), symbol: "keyboard", shortcut: "↵") {
                fill(item, into: context, [])
            })
            list.append(PaletteCommand(id: "fill-submit", title: String(localized: "Fill and Submit"), symbol: "return", shortcut: "⇧↵") {
                fill(item, into: context, .shift)
            })
        }
        if let username = item.username, !username.isEmpty, item.kind == .login {
            copy("username", String(localized: "Copy Username"), "person", label: String(localized: "Username")) { username }
        }
        if item.password?.isEmpty == false {
            list.append(PaletteCommand(id: "password", title: String(localized: "Copy Password"), symbol: "key", shortcut: "⌘↵") {
                finish(item, flash: String(localized: "Password copied")) { model.copyPassword(item) }
            })
        }
        if let totp = item.totp {
            copy("code", String(localized: "Copy One-Time Code"), "clock", shortcut: "⌥↵", label: String(localized: "Code")) { totp.code() }
        }
        for field in item.fields where !field.value.isEmpty {
            copy("field-" + field.label, String(localized: "Copy \(field.label)"), field.secret ? "lock" : "doc.on.doc", label: field.label) { field.value }
        }
        if let notes = item.notes, !notes.isEmpty {
            copy("notes", String(localized: "Copy Notes"), "note.text", label: String(localized: "Notes")) { notes }
        }
        if let url = websiteURL(item) {
            list.append(PaletteCommand(id: "open-site", title: String(localized: "Open Website"), symbol: "safari", shortcut: "⇧↵") {
                finish(item, flash: nil) { NSWorkspace.shared.open(url) }
            })
            list.append(PaletteCommand(id: "copy-site", title: String(localized: "Copy Website"), symbol: "link") {
                PaletteRecents.note(item.id)
                model.copyPlain(url.absoluteString)
                flashThenClose(String(localized: "Website copied"))
            })
        }
        if item.password?.isEmpty == false {
            list.append(PaletteCommand(id: "large-type", title: String(localized: "Show Password in Large Type"), symbol: "textformat.size") {
                PaletteRecents.note(item.id); close(); model.showLargeType(item)
            })
        }
        list.append(PaletteCommand(id: "show", title: String(localized: "Open in Vault"), symbol: "macwindow", shortcut: context == nil ? "↵" : nil) {
            finish(item, flash: nil) { model.showItem(item.id) }
        })
        list.append(PaletteCommand(id: "edit", title: String(localized: "Edit"), symbol: "pencil") {
            PaletteRecents.note(item.id); close()
            model.bringToFront()
            model.guarded(item) { model.beginEditing(EditRequest(mode: .edit(item))) }
        })
        list.append(PaletteCommand(id: "favorite", title: item.favorite ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites"),
                                   symbol: item.favorite ? "star.slash" : "star") {
            close(); Task { await model.toggleFavorite(item) }
        })
        list.append(PaletteCommand(id: "trash", title: String(localized: "Move to Trash…"), symbol: "trash") {
            close(); model.bringToFront(); model.confirmTrash(item)
        })
        return list
    }

    @MainActor
    static func commands(model: AppModel, close: @escaping () -> Void) -> [PaletteCommand] {
        func create(_ kind: AppModel.NewItemKind) { model.bringToFront(); model.beginEditing(EditRequest(mode: .create(kind))) }
        func go(_ section: SidebarSelection) { model.bringToFront(); model.requestedSection = section }
        var list: [PaletteCommand] = []
        if model.isUnlocked {
            list += [
                PaletteCommand(id: "new-login", title: String(localized: "New Login"), symbol: "key", shortcut: "⌘N",
                               keywords: ["add", "password", "create"]) { create(.login) },
                PaletteCommand(id: "new-note", title: String(localized: "New Secure Note"), symbol: "note.text", shortcut: "⇧⌘N",
                               keywords: ["add", "create"]) { create(.secureNote) },
                PaletteCommand(id: "new-card", title: String(localized: "New Card"), symbol: "creditcard", keywords: ["add", "credit"]) { create(.card) },
                PaletteCommand(id: "new-identity", title: String(localized: "New Identity"), symbol: "person.crop.rectangle",
                               keywords: ["add", "address"]) { create(.identity) },
                PaletteCommand(id: "new-ssh", title: String(localized: "New SSH Key"), symbol: "terminal", keywords: ["add", "ed25519"]) { create(.sshKey) },
                PaletteCommand(id: "new-folder", title: String(localized: "New Folder…"), symbol: "folder.badge.plus", shortcut: "⌥⌘N") {
                    model.bringToFront(); model.promptNewFolder()
                },
                PaletteCommand(id: "new-send", title: String(localized: "New Send"), symbol: "paperplane", keywords: ["share", "link"]) {
                    model.bringToFront(); model.requestedSection = .sends; model.composingSend = true
                },
                PaletteCommand(id: "generator", title: String(localized: "Generator"), symbol: "dice", shortcut: "⌘G",
                               keywords: ["random", "generate", "password", "passphrase", "username"]) { model.bringToFront(); model.showingGenerator = true },
                PaletteCommand(id: "codes", title: String(localized: "One-Time Codes"), symbol: "clock.badge.checkmark",
                               keywords: ["totp", "2fa", "otp", "authenticator"]) { go(.codes) },
                PaletteCommand(id: "watchtower", title: String(localized: "Watchtower"), symbol: "checkmark.shield",
                               keywords: ["weak", "reused", "breach", "security"]) { go(.watchtower) },
                PaletteCommand(id: "sync", title: String(localized: "Sync Now"), symbol: "arrow.triangle.2.circlepath", keywords: ["refresh"]) {
                    Task { try? await model.refresh() }
                },
                PaletteCommand(id: "import", title: String(localized: "Import…"), symbol: "square.and.arrow.down", shortcut: "⇧⌘I",
                               keywords: ["csv", "json", "chrome", "safari", "firefox", "bitwarden"]) { model.beginImport() },
                PaletteCommand(id: "export", title: String(localized: "Export Vault…"), symbol: "square.and.arrow.up", shortcut: "⇧⌘E",
                               keywords: ["backup", "csv", "json"]) { model.beginExport() },
                PaletteCommand(id: "lock", title: String(localized: "Lock Vault"), symbol: "lock", shortcut: "⇧⌘L") { model.lock(animated: true) },
            ]
            // Places in the vault: its sections, Send, and every folder.
            let places: [(VaultSection, String)] = [
                (.all, String(localized: "All Items")), (.favorites, String(localized: "Favorites")), (.logins, String(localized: "Logins")),
                (.passkeys, String(localized: "Passkeys")), (.cards, String(localized: "Cards")), (.identities, String(localized: "Identities")),
                (.notes, String(localized: "Secure Notes")), (.sshKeys, String(localized: "SSH Keys")), (.archive, String(localized: "Archive")),
                (.trash, String(localized: "Trash")),
            ]
            for (section, name) in places {
                list.append(PaletteCommand(id: "go-\(section)", title: String(localized: "Go to \(name)"), symbol: section.symbol,
                                           keywords: ["show", "open", "view"]) { go(.section(section)) })
            }
            list.append(PaletteCommand(id: "go-sends", title: String(localized: "Go to Send"), symbol: "paperplane", keywords: ["show", "open"]) { go(.sends) })
            for folder in model.folders {
                list.append(PaletteCommand(id: "go-folder-\(folder.id)", title: String(localized: "Go to folder \(folder.name)"), symbol: "folder",
                                           keywords: ["show", "open"]) { go(.folder(folder.name)) })
            }
            // Accounts: focus one, lock or unlock one, add another.
            if model.accounts.count > 1 {
                if model.accountFocus != nil {
                    list.append(PaletteCommand(id: "account-all", title: String(localized: "Show All Accounts"), symbol: "person.2",
                                               keywords: ["switch", "account"]) { model.bringToFront(); model.accountFocus = nil })
                }
                for account in model.accounts {
                    let open = model.isUnlocked(account.id)
                    if model.focusedAccountID != account.id {
                        list.append(PaletteCommand(id: "account-focus-\(account.id)", title: String(localized: "Switch to \(account.email)"),
                                                   symbol: "person.crop.circle", keywords: ["account", "show"]) {
                            model.bringToFront(); model.accountFocus = account.id
                        })
                    }
                    if open, model.sessions.count > 1 {
                        list.append(PaletteCommand(id: "account-lock-\(account.id)", title: String(localized: "Lock \(account.email)"),
                                                   symbol: "lock", keywords: ["account"]) { model.lock(account.id) })
                    } else if !open {
                        list.append(PaletteCommand(id: "account-unlock-\(account.id)", title: String(localized: "Unlock \(account.email)"),
                                                   symbol: "lock.open", keywords: ["account"]) {
                            model.bringToFront(); model.accountFocus = account.id
                        })
                    }
                }
            }
            list.append(PaletteCommand(id: "add-account", title: String(localized: "Add Account…"), symbol: "person.badge.plus",
                                       keywords: ["login", "sign in", "account"]) { model.bringToFront(); model.beginAddAccount() })
        }
        list.append(PaletteCommand(id: "help", title: String(localized: "Triwarden Help"), symbol: "questionmark.circle", shortcut: "⌘?",
                                   keywords: ["help", "guide", "docs"]) { model.showHelp() })
        list.append(PaletteCommand(id: "shortcuts", title: String(localized: "Keyboard Shortcuts"), symbol: "keyboard", shortcut: "⌃⇧/",
                                   keywords: ["keys", "help", "cheat sheet", "hotkeys"]) {
            model.showingShortcuts = true
        })
        list.append(PaletteCommand(id: "settings", title: String(localized: "Settings…"), symbol: "gearshape", shortcut: "⌘,",
                                   keywords: ["preferences"]) {
            model.showSettings()
        })
        return list
    }
}

/// A scope typed into the query (`#Work`, `@me@example.com`, `card:`), shown as a chip; ✕ takes it out again.
private struct ScopeChip: View {
    let scope: PaletteQuery.Scope
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: scope.symbol).font(.system(size: 10, weight: .semibold))
            Text(verbatim: scope.label).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .help(Text("Remove"))
            .accessibilityLabel(Text("Remove \(scope.label)"))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8).frame(height: 24)
        .frame(maxWidth: 180)
        .background(Color.primary.opacity(0.07), in: .capsule)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// The vault is locked: unlock it here (master password, PIN or Touch ID) and the search goes on.
private struct PaletteUnlock: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var password = ""
    @State private var usePassword = false
    @FocusState private var focused: Bool

    private var hasPIN: Bool { model.unlockTarget.map { model.isPINEnabled($0.id) } ?? false }
    private var pinMode: Bool { hasPIN && !usePassword }

    var body: some View {
        if let account = model.unlockTarget {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    AccountAvatar(account: account, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Unlock to search").font(.system(size: 13, weight: .semibold))
                        Text(verbatim: "\(account.email) · \(account.serverSummary)")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if model.touchIDEnabled {
                        Button { Task { await model.unlockWithTouchID() } } label: {
                            Label("Touch ID", systemImage: "touchid").font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 10).frame(height: 28)
                                .background(Color.primary.opacity(0.07), in: .capsule)
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
                UnlockCapsuleField(pinMode: pinMode, password: $password, focused: $focused.wrappedBinding, submit: submit)
                HStack(spacing: 8) {
                    if let message = model.errorMessage {
                        Text(verbatim: message)
                            .foregroundStyle(scheme == .dark ? Color(red: 1, green: 0.55, blue: 0.55) : Color(red: 0.8, green: 0.2, blue: 0.2))
                    } else if model.isBusy {
                        Text("Unlocking…").foregroundStyle(.secondary)
                    } else {
                        Text("Press Return to unlock").foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if hasPIN {
                        Button(pinMode ? "Use master password" : "Use PIN") {
                            usePassword.toggle(); password = ""; model.errorMessage = nil; focused = true
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            }
            .padding(12)
            .onAppear { focused = true }
            .onChange(of: model.errorMessage) { _, message in if message != nil { password = "" } }
        } else {
            HStack {
                Label("Sign in to Triwarden to search your vault", systemImage: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                Button("Open Triwarden") { model.bringToFront() }
            }
            .padding(12)
        }
    }

    private func submit() {
        guard !password.isEmpty, !model.isBusy else { return }
        let typed = password
        Task { if pinMode { await model.unlockWithPIN(typed) } else { await model.unlock(password: typed) } }
    }
}

/// `gen 24`, `passphrase`: the value itself, ready to copy (or to save in a new login).
private struct GeneratedLine: View {
    let request: PaletteGenerate
    let value: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "dice").font(.system(size: 14)).foregroundStyle(selected ? Color.primary : .secondary).frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: value).font(.system(size: 14, weight: .medium, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    .contentTransition(.numericText())
                Text(verbatim: request.title).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .modifier(RowHighlight(selected: selected))
        .animation(.snappy(duration: 0.2), value: value)
    }
}

/// Spotlight-style selection: a soft neutral wash, no border, no colour slab.
private struct RowHighlight: ViewModifier {
    let selected: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.background {
            if selected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(scheme == .dark ? 0.10 : 0.06))
            }
        }
    }
}

/// A small keycap, used for shortcuts and the hint bar.
struct Keycap: View {
    let keys: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(verbatim: keys)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .lineLimit(1).fixedSize()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5).frame(minWidth: 20, minHeight: 18)
            .background(Color.primary.opacity(scheme == .dark ? 0.10 : 0.05), in: .rect(cornerRadius: 5, style: .continuous))
    }
}

/// One way to answer a waiting SSH signature. The first row carries who asked and which key.
struct SSHPaletteChoice: Identifiable {
    let id: String
    let prompt: SSHPrompt
    let title: LocalizedStringKey
    let symbol: String
    /// The asking app, the tool, and the key. Only the recommended choice shows them.
    let showsIdentity: Bool
    let run: () -> Void
}

/// The asking app on the first choice; the other choices stay short and line up under its name.
private struct SSHPaletteLine: View {
    let choice: SSHPaletteChoice
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            if choice.showsIdentity {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(choice.prompt.displayName) wants to sign")
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    Text("via \(choice.prompt.via) · \(choice.prompt.keyName)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if choice.prompt.appPath == nil, let path = choice.prompt.path {
                        Text(verbatim: path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            } else {
                Image(systemName: choice.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Color.primary : .secondary)
                    .frame(width: 32, height: 32)
                Text(choice.title)
                    .font(.system(size: 14))
            }
            Spacer(minLength: 8)
            if choice.showsIdentity {
                Text(choice.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? Color.primary : .secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Color.primary.opacity(0.08), in: .capsule)
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: choice.showsIdentity ? 56 : 36)
        .modifier(RowHighlight(selected: selected))
    }

    @ViewBuilder private var icon: some View {
        if let path = choice.prompt.appPath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .frame(width: 32, height: 32)
        } else {
            Image(systemName: "terminal")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 8, style: .continuous))
        }
    }
}

/// A login row; when highlighted it shows its live code (what the keys do is in the footer). With several accounts
/// open, the account's letters; a password Watchtower flags carries its tag.
private struct ItemLine: View {
    @Environment(AppModel.self) private var model
    let item: VaultItem
    let selected: Bool
    /// The typed text, marked in the name and username.
    var highlight = ""

    var body: some View {
        // The code and its ring sit at the row's centre, beside both the name and the hints below it.
        HStack(alignment: .center, spacing: 12) {
            // Icon, text and code all centre on the whole row (hints included).
            ItemIcon(item: item, size: 32)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(Highlight.marked(item.name, highlight)).font(.system(size: 14, weight: .medium)).lineLimit(1)
                        AccountTag(accountId: item.accountId)
                        if let issue = item.passwordIssue(breaches: model.breachCounts), issue != .insecure {
                            HStack(spacing: 3) {
                                Image(systemName: issue.rowSymbol).font(.system(size: 8, weight: .bold))
                                Text(issue.shortLabel).font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundStyle(issue.tint)
                            .padding(.horizontal, 5).frame(height: 16)
                            .background(issue.tint.opacity(0.14), in: .capsule)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text(issue.rowLabel))
                        }
                    }
                    Text(Highlight.marked(item.username ?? item.host ?? "", highlight))
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if selected, let totp = item.totp {
                HStack(spacing: 12) { // on the app's shared clock
                    LiveOTPCode(totp: totp, size: 17)
                    LiveCountdownRing(totp: totp, size: 30)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .modifier(RowHighlight(selected: selected))
    }
}

private struct CommandLine: View {
    let command: PaletteCommand
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: command.symbol)
                .font(.system(size: 14))
                .foregroundStyle(selected ? Color.primary : .secondary)
                .frame(width: 32)
            Text(command.title).font(.system(size: 14))
            Spacer()
            if let shortcut = command.shortcut { Keycap(keys: shortcut) }
        }
        .padding(.horizontal, 10).frame(height: 36)
        .modifier(RowHighlight(selected: selected))
    }
}

/// Where the palette was called from: the app's icon, and the page's site once the browser has said.
private struct ContextChip: View {
    let context: ForegroundContext

    var body: some View {
        HStack(spacing: 6) {
            if let icon = NSRunningApplication(processIdentifier: context.pid)?.icon {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            }
            Text(verbatim: context.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 10).frame(height: 26)
        .background(Color.primary.opacity(0.06), in: .capsule)
        .animation(.snappy(duration: 0.2), value: context.host)
        .help(Text(verbatim: context.host.map { "\(context.app) · \($0)" } ?? context.app))
    }
}
