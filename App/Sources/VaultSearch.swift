import SwiftUI
import TipKit
import VaultwardenAPI

// The vault window's search: one field over every vault, plus filters that stay on between launches.
// Filters are typed as tokens (`type:card`, `is:favorite`, `has:otp`, `has:passkey`, `is:weak`, `folder:Work` or `#Work`,
// `vault:personal`) or picked from the filter menu; each shows as a chip under the field, and ⌫ in an empty field
// takes the last one off.

extension VaultItem.Kind {
    init(_ type: SearchFilters.ItemType) {
        switch type {
        case .login: self = .login
        case .card: self = .card
        case .identity: self = .identity
        case .note: self = .note
        case .sshKey: self = .sshKey
        }
    }
}

/// One filter as a chip: the search filters' tokens, plus the vault (which the vault switcher holds).
enum SearchChip: Identifiable, Equatable {
    case filter(SearchToken)
    case vault(AppModel.VaultFilter)

    var id: String {
        switch self {
        case .filter(let token): token.text
        case .vault(let v): "vault:" + (v.raw ?? "all")
        }
    }

    @MainActor func label(_ model: AppModel) -> String {
        switch self {
        case .filter(.type(let t)): VaultItem.Kind(t).paletteLabel
        case .filter(.folder(let path)): path
        case .filter(.vault(let name)): name
        case .filter(.favorites): String(localized: "Favorites")
        case .filter(.hasCode): String(localized: "One-time code")
        case .filter(.hasPasskey): String(localized: "Passkey")
        case .filter(.hasIssue): String(localized: "Watchtower issue")
        case .vault: model.vaultFilterTitle
        }
    }

    var symbol: String {
        switch self {
        case .filter(.type(let t)): VaultItem.Kind(t).paletteSymbol
        case .filter(.folder): "folder"
        case .filter(.vault), .vault(.organization): "building.2"
        case .vault(.several): "square.on.square"
        case .filter(.favorites): "star"
        case .filter(.hasCode): "clock.badge.checkmark"
        case .filter(.hasPasskey): "person.badge.key"
        case .filter(.hasIssue): "exclamationmark.shield"
        case .vault(.all): "square.stack.3d.up"
        case .vault(.personal): "person"
        }
    }
}

extension AppModel {
    /// The chips under the search field: the vault first (when it isn't every vault), then the filters.
    var searchChips: [SearchChip] {
        (vaultFilter == .all ? [] : [.vault(vaultFilter)]) + searchFilters.tokens.map(SearchChip.filter)
    }

    var hasSearchFilters: Bool { vaultFilter != .all || !searchFilters.isEmpty }

    func removeSearchChip(_ chip: SearchChip) {
        switch chip {
        case .filter(let token): searchFilters.remove(token)
        case .vault: vaultFilter = .all
        }
    }

    /// Turns a typed token's filter on; false when it names no folder or vault here (it stays search text).
    func applySearchToken(_ token: SearchToken) -> Bool {
        switch token {
        case .folder(let typed):
            let fold = PaletteQuery.fold
            let names = folders.map(\.name)
            guard let path = names.first(where: { fold($0) == fold(typed) }) ?? names.first(where: { fold($0).hasPrefix(fold(typed)) })
                ?? names.first(where: { fold($0).contains(fold(typed)) }) else { return false }
            searchFilters.folder = path
        case .vault(let typed):
            let v = PaletteQuery.fold(typed)
            if ["all", "any", "every", "everything"].contains(v) {
                vaultFilter = .all
            } else if ["personal", "my", "mine", "me", "own", "private"].contains(v) {
                vaultFilter = .personal
            } else if let org = visibleOrganizations.first(where: { PaletteQuery.fold($0.name) == v })
                        ?? visibleOrganizations.first(where: { PaletteQuery.fold($0.name).hasPrefix(v) }) {
                vaultFilter = .organization(org.id)
            } else {
                return false
            }
        default:
            searchFilters.apply(token)
        }
        return true
    }

    /// Filters to offer for the word being typed (`type:c` → Cards, `#wo` → Work, `has:` → codes and passkeys), so the
    /// tokens can be learned by typing. Nothing once the word is finished (a space after it) or isn't a token's start.
    func searchSuggestions(for query: String) -> [SearchSuggestion] {
        guard !query.hasSuffix(" "), let last = SearchToken.words(query).last else { return [] }
        let fold = { (s: String) in PaletteQuery.fold(s).replacingOccurrences(of: "\"", with: "") }
        var typed = fold(last)
        if typed.hasPrefix("#") { typed = "folder:" + typed.dropFirst() }
        guard let colon = typed.firstIndex(of: ":") else { return [] }
        let aliases = ["kind": "type", "t": "type", "f": "folder", "in": "vault", "org": "vault", "v": "vault"]
        let key = String(typed[..<colon])
        typed = (aliases[key] ?? key) + typed[colon...]

        var candidates: [SearchToken] = SearchFilters.ItemType.allCases.map(SearchToken.type)
            + [.favorites, .hasCode, .hasPasskey, .hasIssue]
            + folders.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map(SearchToken.folder)
        if !visibleOrganizations.isEmpty {
            candidates += [.vault("personal")] + visibleOrganizations.map { .vault($0.name) }
        }
        let on = Set(searchFilters.tokens)
        return candidates
            .filter { !on.contains($0) && fold($0.text).hasPrefix(typed) }
            .prefix(8)
            .map { token in
                switch token {
                case .vault(let name) where name == "personal":
                    SearchSuggestion(token: token, label: String(localized: "My vault"), symbol: "person")
                default:
                    SearchSuggestion(token: token, label: SearchChip.filter(token).label(self), symbol: SearchChip.filter(token).symbol)
                }
            }
    }

    /// Whether an item matches the typed text: every word in its name, username, website or folder.
    static func searchMatches(_ item: VaultItem, _ query: String) -> Bool {
        let words = query.split(separator: " ")
        guard !words.isEmpty else { return true }
        return words.allSatisfy { word in
            item.name.localizedStandardContains(word)
                || (item.username?.localizedStandardContains(word) ?? false)
                || (item.host?.localizedStandardContains(word) ?? false)
                || item.websites.contains { $0.localizedStandardContains(word) }
        }
    }
}

/// A filter offered while its token is being typed.
struct SearchSuggestion: Identifiable, Equatable {
    let token: SearchToken
    let label: String
    let symbol: String
    var id: String { token.text }
}

/// Shown once, the first time the search is used: filters can be typed, and they stay on. Gone for good once a filter
/// is on or it's closed.
struct SearchFiltersTip: Tip {
    static let searched = Event(id: "vaultSearchFocused")

    var title: Text { Text("Filters that stay on") }
    var message: Text? {
        Text("Type a filter like type:card, has:otp or #Work, or pick one from the filter menu. Filters stay on until you clear them; ⌫ takes the last one off.")
    }
    var image: Image? { Image(systemName: "line.3.horizontal.decrease.circle") }
    var rules: [Rule] { [#Rule(Self.searched) { $0.donations.count >= 1 }] }
}

/// The list's search field: a magnifier, the text, a clear button. Finished tokens leave the text for chips; ⌫ in an
/// empty field removes the last chip; Esc clears the text; ↓ moves into the list.
struct VaultSearchField: View {
    @Environment(AppModel.self) private var model
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    var moveToList: () -> Void = {}
    @State private var hovering = false
    /// The highlighted suggestion.
    @State private var pick = 0
    /// Esc closed the suggestions for this text.
    @State private var dismissedFor: String?

    private var suggestions: [SearchSuggestion] {
        guard focused.wrappedValue, dismissedFor != query else { return [] }
        return model.searchSuggestions(for: query)
    }

    /// Takes a suggestion: its filter goes on, the half-typed word comes out of the text.
    private func accept(_ suggestion: SearchSuggestion) {
        withAnimation(.snappy(duration: 0.25)) { _ = model.applySearchToken(suggestion.token) }
        var words = SearchToken.words(query)
        if !words.isEmpty { words.removeLast() }
        query = words.isEmpty ? "" : words.joined(separator: " ") + " "
        pick = 0
    }

    private var prompt: Text {
        model.vaultFilter == .all && (!model.visibleOrganizations.isEmpty || model.focusedAccountID == nil && model.accounts.count > 1)
            ? Text("Search all vaults") : Text("Search")
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search", text: $query, prompt: prompt)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(focused)
                // Esc: closes the suggestions, then clears the text, then takes the filters off.
                .onKeyPress(.escape) {
                    if !suggestions.isEmpty { dismissedFor = query; return .handled }
                    if !query.isEmpty { query = ""; return .handled }
                    guard model.hasSearchFilters else { return .ignored }
                    withAnimation(.snappy(duration: 0.25)) { model.clearSearchFilters() }
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    let list = suggestions
                    if list.isEmpty { moveToList() } else { pick = min(pick + 1, list.count - 1) }
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard !suggestions.isEmpty else { return .ignored }
                    pick = max(pick - 1, 0)
                    return .handled
                }
                .onKeyPress(.tab) {
                    let list = suggestions
                    guard !list.isEmpty else { return .ignored }
                    accept(list[min(pick, list.count - 1)])
                    return .handled
                }
                .onKeyPress(.return) {
                    let list = suggestions
                    guard !list.isEmpty else { return .ignored }
                    accept(list[min(pick, list.count - 1)])
                    return .handled
                }
                .onKeyPress(.delete) {
                    guard query.isEmpty, let last = model.searchChips.last else { return .ignored }
                    withAnimation(.snappy(duration: 0.25)) { model.removeSearchChip(last) }
                    return .handled
                }
                .onSubmit { promote(finishedOnly: false) }
                .onChange(of: query) { pick = 0; promote(finishedOnly: true) }
            if !query.isEmpty {
                Button { query = ""; focused.wrappedValue = true } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(Text("Clear Search"))
                .accessibilityLabel(Text("Clear Search"))
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .modifier(HeaderChrome(shape: .capsule, hovering: hovering || focused.wrappedValue))
        .contentShape(.capsule)
        .onTapGesture { focused.wrappedValue = true }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: query.isEmpty)
        // Filters offered for the word being typed, in a list hanging under the field.
        .overlay(alignment: .topLeading) {
            let list = suggestions
            if !list.isEmpty {
                SearchSuggestionList(suggestions: list, pick: min(pick, list.count - 1), accept: accept)
                    .offset(y: 38)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .animation(.snappy(duration: 0.18), value: suggestions.isEmpty)
        .onChange(of: focused.wrappedValue) { _, now in if now { SearchFiltersTip.searched.sendDonation() } }
        .help(Text("Search by name, username or website. Filter with type:card, is:favorite, has:otp, has:passkey, is:weak, folder:Work or vault:personal."))
    }

    /// Typed tokens become filters (with a space after them, or on Return).
    private func promote(finishedOnly: Bool) {
        guard query.contains(":") || query.contains("#") else { return }
        var applied = false
        let result = SearchToken.extract(from: query, finishedOnly: finishedOnly) { token in
            let ok = withAnimation(.snappy(duration: 0.25)) { model.applySearchToken(token) }
            applied = applied || ok
            return ok
        }
        if applied, result.text != query { query = result.text.trimmingCharacters(in: .whitespaces).isEmpty ? "" : result.text }
    }
}

/// The suggestions under the search field: each filter with its name and how it's typed. ↑↓ pick, Return or Tab take
/// one, a click too.
struct SearchSuggestionList: View {
    let suggestions: [SearchSuggestion]
    let pick: Int
    let accept: (SearchSuggestion) -> Void
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button { accept(suggestion) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: suggestion.symbol).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary).frame(width: 16)
                        Text(verbatim: suggestion.label).font(.system(size: 13)).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(verbatim: suggestion.token.text).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.horizontal, 9).frame(height: 28)
                    .background(Color.primary.opacity(index == pick ? 0.09 : hovered == suggestion.id ? 0.05 : 0),
                                in: .rect(cornerRadius: 8, style: .continuous))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? suggestion.id : nil }
                .accessibilityLabel(Text("Add filter \(suggestion.label)"))
            }
        }
        .padding(5)
        .frame(width: 260)
        .background(.regularMaterial, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
    }
}

/// The filter menu beside the search field: every filter, a click away. Filled while any is on.
struct SearchFilterMenu: View {
    @Environment(AppModel.self) private var model

    /// A filter that turns on and off; its token as the subtitle, so the menu teaches how to type it.
    private func toggle(_ title: LocalizedStringKey, _ symbol: String, token: SearchToken, _ on: Bool,
                        _ set: @escaping (Bool) -> Void) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { set(!on) }
        } label: {
            Label { Text(title); Text(verbatim: token.text) } icon: { Image(systemName: on ? "checkmark" : symbol) }
        }
    }

    var body: some View {
        @Bindable var model = model
        let active = model.hasSearchFilters
        Menu {
            Section("Type") {
                Button { withAnimation(.snappy(duration: 0.25)) { model.searchFilters.type = nil } } label: {
                    Label("Any type", systemImage: model.searchFilters.type == nil ? "checkmark" : "square.grid.2x2")
                }
                ForEach(SearchFilters.ItemType.allCases, id: \.self) { type in
                    let kind = VaultItem.Kind(type)
                    Button { withAnimation(.snappy(duration: 0.25)) { model.searchFilters.type = type } } label: {
                        Label { Text(verbatim: kind.paletteLabel); Text(verbatim: SearchToken.type(type).text) } icon: {
                            Image(systemName: model.searchFilters.type == type ? "checkmark" : kind.paletteSymbol)
                        }
                    }
                }
            }
            Section("Show only") {
                toggle("Favorites", "star", token: .favorites, model.searchFilters.favorites) { model.searchFilters.favorites = $0 }
                toggle("Has a one-time code", "clock.badge.checkmark", token: .hasCode, model.searchFilters.hasCode) { model.searchFilters.hasCode = $0 }
                toggle("Has a passkey", "person.badge.key", token: .hasPasskey, model.searchFilters.hasPasskey) { model.searchFilters.hasPasskey = $0 }
                toggle("Watchtower issues", "exclamationmark.shield", token: .hasIssue, model.searchFilters.hasIssue) { model.searchFilters.hasIssue = $0 }
            }
            if !model.folders.isEmpty {
                Menu {
                    Button { withAnimation(.snappy(duration: 0.25)) { model.searchFilters.folder = nil } } label: {
                        Label("Any folder", systemImage: model.searchFilters.folder == nil ? "checkmark" : "folder")
                    }
                    Divider()
                    ForEach(model.folders.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }, id: \.self) { path in
                        Button { withAnimation(.snappy(duration: 0.25)) { model.searchFilters.folder = path } } label: {
                            Label { Text(verbatim: path); Text(verbatim: SearchToken.folder(path).text) } icon: {
                                Image(systemName: model.searchFilters.folder == path ? "checkmark" : "folder")
                            }
                        }
                    }
                } label: {
                    Label("My Folders", systemImage: "folder")
                }
            }
            if !model.visibleOrganizations.isEmpty {
                Menu {
                    vaultChoice(.all, String(localized: "All vaults"), "square.stack.3d.up")
                    Divider()
                    VaultToggles()
                } label: {
                    Label("Vault", systemImage: "square.stack.3d.up")
                }
            }
            Divider()
            Button("Clear Filters", systemImage: "xmark.circle") {
                withAnimation(.snappy(duration: 0.25)) { model.clearSearchFilters() }
            }
            .disabled(!active)
        } label: {
            Image(systemName: active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                .font(.system(size: 13, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 32, height: 32)
                .modifier(HeaderChrome(shape: .circle))
                .contentShape(.circle)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("Filters"))
        .accessibilityLabel(Text("Filters"))
        .accessibilityValue(active ? Text("\(model.searchChips.count) on") : Text("Off"))
    }

    private func vaultChoice(_ filter: AppModel.VaultFilter, _ title: String, _ symbol: String) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { model.vaultFilter = filter }
        } label: {
            Label { Text(verbatim: title) } icon: { Image(systemName: model.vaultFilter == filter ? "checkmark" : symbol) }
        }
    }
}

/// The filters that are on, as chips under the search field; each one's ✕ takes it off, Clear takes them all off.
/// Shown only while a filter is on. Chips pop in and out (the app's snappy spring); with Reduce Motion they fade.
struct SearchFilterBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How many items the filters leave, for the count at the end.
    var resultCount: Int

    private var chipTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.7, anchor: .leading).combined(with: .opacity)
    }

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(model.searchChips) { chip in
                        if case .vault = chip {
                            // The vaults shown: a click opens the picker to change them.
                            VaultChip(label: chip.label(model), symbol: chip.symbol) {
                                withAnimation(.snappy(duration: 0.25)) { model.removeSearchChip(chip) }
                            }
                            .transition(chipTransition)
                        } else {
                            FilterChip(label: chip.label(model), symbol: chip.symbol) {
                                withAnimation(.snappy(duration: 0.25)) { model.removeSearchChip(chip) }
                            }
                            .transition(chipTransition)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
            // More chips than fit: they fade out at the end rather than being cut, and scroll sideways.
            .mask {
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 18)
                }
            }
            Button {
                withAnimation(.snappy(duration: 0.25)) { model.clearSearchFilters() }
            } label: {
                Text("Clear").font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 9).frame(height: 24)
                    .background(Color.primary.opacity(0.07), in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(Text("Clear Filters"))
            .accessibilityLabel(Text("Clear Filters"))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Filters, \(resultCount) items"))
    }
}

/// One filter: its symbol, its name, ✕.
private struct FilterChip: View {
    let label: String
    let symbol: String
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            Text(verbatim: label).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.tail)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .background(Color.primary.opacity(hovering ? 0.1 : 0), in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(Text("Remove"))
            .accessibilityLabel(Text("Remove \(label)"))
        }
        .foregroundStyle(.primary.opacity(0.75))
        .padding(.leading, 8).padding(.trailing, 5).frame(height: 24)
        .frame(maxWidth: 220)
        .background(Color.primary.opacity(0.08), in: .capsule)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }
}

/// The vault chip: like the others, and a click on it opens the vault picker (check vaults on and off, or "Only").
private struct VaultChip: View {
    let label: String
    let symbol: String
    let remove: () -> Void
    @State private var open = false

    var body: some View {
        FilterChip(label: label, symbol: symbol, remove: remove)
            .contentShape(.capsule)
            .onTapGesture { open = true }
            .popover(isPresented: $open, arrowEdge: .bottom) { VaultSwitcherPicker() }
            .help(Text("Change the vaults shown"))
    }
}
