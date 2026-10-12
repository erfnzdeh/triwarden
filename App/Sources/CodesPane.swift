import TriCrypto
import SwiftUI

/// Sidebar › One-Time Codes: every code, live, click to copy. Tags along the top pick All, Recently Used, or a vault
/// (My vault / each shared vault); favorites are pinned above the rest (the star on a card pins or unpins it); a
/// filter narrows by typing.
///
/// Fast with any number of codes: the grid is lazy (only cards on screen exist), and it never depends on the time —
/// each card's code and ring read the app's one shared clock (`OTPClock`), so a tick refreshes just those small views.
struct CodesPane: View {
    @Environment(AppModel.self) private var model
    @State private var copiedID: String?
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// Which tag is picked: every code, recently copied ones, or one vault.
    @State private var filter: CodesFilter = .all

    private enum CodesFilter: Hashable {
        case all
        case recent
        case vault(String) // "personal" or an organization id
    }

    /// Every live code, narrowed by the typed filter (the tags count from this).
    private var base: [VaultItem] {
        let source = model.sidebarSearchScope.flatMap { scope in
            scope.destination == .codes ? model.items.filter(scope.contains) : nil
        } ?? model.vaultItems
        return source.filter { !$0.isDeleted && !$0.isArchived && $0.totp != nil && AppModel.searchMatches($0, query) }
    }

    private static func vaultKey(_ item: VaultItem) -> String { item.organizationId ?? AppModel.VaultFilter.personalKey }

    /// Recent ids that still have a live code (for the tag's count and the filtered list).
    private var recentCodeIDs: [String] {
        let live = Set(base.map(\.id))
        return PaletteRecents.ids.filter(live.contains)
    }

    /// The period most codes here share (codes renew together, all timed from the same clock), and a code to time the
    /// header's one countdown by. Codes with another period keep a ring of their own.
    private var sharedPeriod: (period: Int, clock: TOTP)? {
        let codes = model.vaultItems.compactMap { $0.isDeleted || $0.isArchived ? nil : $0.totp }
        let counts = Dictionary(grouping: codes, by: \.period)
        guard let best = counts.max(by: { $0.value.count < $1.value.count }), let clock = best.value.first else { return nil }
        return (best.key, clock)
    }

    /// The codes the tag shows: by name, or most recently used first under Recently Used.
    private var items: [VaultItem] {
        switch filter {
        case .all:
            return base.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .recent:
            let order = Dictionary(recentCodeIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            return base.filter { order[$0.id] != nil }
                .sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
        case .vault(let key):
            return base.filter { Self.vaultKey($0) == key }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    var body: some View {
        let list = items
        let pinned = list.filter(\.favorite)
        let rest = list.filter { !$0.favorite }
        // The header stays put above the scrolling codes: its countdown ring redraws 15 times a second, and out here
        // that never touches the grid.
        VStack(alignment: .leading, spacing: 0) {
            // Where the vault page's search row is: at the top, 32 pt high, 10 pt above what follows.
            header
                .frame(height: 32)
                .padding(.leading, VaultView.pageInset)
                .padding(.bottom, 10)
            codes(list: list, pinned: pinned, rest: rest)
        }
        .onChange(of: model.wantsCodesSearchFocus, initial: true) { _, wants in
            guard wants else { return }
            model.wantsCodesSearchFocus = false
            query = ""
            filter = .all
            Task { @MainActor in searchFocused = true }
        }
    }

    private func codes(list: [VaultItem], pinned: [VaultItem], rest: [VaultItem]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if list.isEmpty {
                    ContentUnavailableView {
                        Label(emptyTitle, systemImage: emptySymbol)
                    } description: {
                        if query.isEmpty, filter == .recent {
                            Text("Copy a code to see it here.")
                        } else if query.isEmpty {
                            Text("Add a code secret to a login to see it here.")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    if !pinned.isEmpty {
                        sectionTitle("Favorites", symbol: "star.fill", count: pinned.count)
                        grid(pinned)
                        if !rest.isEmpty { sectionTitle("All Codes", symbol: nil, count: rest.count).padding(.top, 6) }
                    }
                    grid(rest)
                }
            }
            .padding(.leading, VaultView.pageInset)
            .padding(.top, 4).padding(.bottom, 24)
            .animation(.snappy(duration: 0.25), value: list.map(\.id))
        }
        .modifier(SideOverflowClip())
        .thinScroller()
    }

    private func grid(_ items: [VaultItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
            ForEach(items) { card($0) }
        }
    }

    private func sectionTitle(_ title: LocalizedStringKey, symbol: String?, count: Int) -> some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.yellow) }
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(count, format: .number).font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(.tertiary)
        }
        .padding(.top, 2)
        .accessibilityAddTraits(.isHeader)
    }

    private var emptyTitle: LocalizedStringKey {
        if !query.isEmpty { "No Results" }
        else if filter == .recent { "No recently used codes" }
        else { "No one-time codes" }
    }
    private var emptySymbol: String {
        if !query.isEmpty { "magnifyingglass" }
        else if filter == .recent { "clock.arrow.circlepath" }
        else { "clock.badge.checkmark" }
    }

    /// The tags (All, Recently Used, My vault, each shared vault) and the filter pill. The page's name is the
    /// sidebar's; this row is for narrowing.
    private var header: some View {
        let list = base
        return HStack(spacing: 8) {
            // One countdown for the page: every code with this period renews when it runs out.
            if let shared = sharedPeriod {
                SharedCountdown(clock: shared.clock)
            }
            // The tags in a plain row (a scroll view up here picks up the toolbar's inset and shifts its contents);
            // with more vaults than fit, the row fades out at its end.
            HStack(spacing: 6) {
                tag(.all, String(localized: "All"), "clock.badge.checkmark", list.count, iconOnly: true)
                tag(.recent, String(localized: "Recently Used"), "clock.arrow.circlepath", recentCodeIDs.count, iconOnly: true)
                if !model.visibleOrganizations.isEmpty {
                    tag(.vault(AppModel.VaultFilter.personalKey), String(localized: "My vault"), "person",
                        list.filter { $0.organizationId == nil }.count, iconOnly: true)
                    ForEach(model.visibleOrganizations) { org in
                        tag(.vault(org.id), org.name, "building.2", list.filter { $0.organizationId == org.id }.count)
                    }
                }
            }
            .fixedSize()
            .padding(.vertical, 4).padding(.horizontal, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .mask {
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 16)
                }
            }
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                TextField("Filter", text: $query, prompt: Text("Filter codes"))
                    .focused($searchFocused)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .onKeyPress(.escape) { guard !query.isEmpty else { return .ignored }; query = ""; return .handled }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Clear Search"))
                }
            }
            .padding(.horizontal, 12).frame(width: 200, height: 32)
            .modifier(HeaderChrome(shape: .capsule))
        }
        .padding(.trailing, 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("One-Time Codes"))
        // A vault that's gone (left, or its account locked): back to every vault.
        .onChange(of: model.visibleOrganizations.map(\.id)) { _, ids in
            if case .vault(let id) = filter, id != AppModel.VaultFilter.personalKey, !ids.contains(id) {
                filter = .all
            }
        }
    }

    /// One tag: picked, a solid blue pill with white text; otherwise soft glass. `iconOnly`: the name shows on hover.
    private func tag(_ value: CodesFilter, _ title: String, _ symbol: String, _ count: Int, iconOnly: Bool = false) -> some View {
        VaultTag(title: title, symbol: symbol, count: count, picked: filter == value, iconOnly: iconOnly) {
            withAnimation(.snappy(duration: 0.25)) { filter = value }
        }
    }

    private func card(_ item: VaultItem) -> some View {
        Group {
            if let totp = item.totp {
                CodeCard(item: item, totp: totp, ownRing: totp.period != sharedPeriod?.period, copied: copiedID == item.id) {
                    model.guarded(item) { model.copy(totp.code(at: .now), label: String(localized: "Code")) }
                    PaletteRecents.note(item.id) // feeds the Recently Used tag
                    withAnimation(.snappy) { copiedID = item.id }
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        if copiedID == item.id { withAnimation(.snappy) { copiedID = nil } }
                    }
                } pin: {
                    Task { await model.toggleFavorite(item) }
                }
                .appContextMenu(model.itemContextActions(item))
            }
        }
    }
}

/// One code. It holds no clock: the code and ring inside read the shared one.
private struct CodeCard: View {
    let item: VaultItem
    let totp: TOTP
    /// A period unlike the page's: its own ring (the header's countdown doesn't apply to it).
    var ownRing = false
    let copied: Bool
    let copy: () -> Void
    let pin: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: copy) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    ItemIcon(item: item, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(verbatim: item.username ?? item.host ?? "").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    // Copy state as an icon: appears on hover, turns to a check once copied.
                    Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(copied ? Color.primary : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                        .opacity(copied || hovering ? 1 : 0)
                        .accessibilityHidden(true)
                    // Pin: a favorite sits above the rest. Always shown once pinned; on hover otherwise.
                    Button(action: pin) {
                        Image(systemName: item.favorite ? "star.fill" : "star")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(item.favorite ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 22, height: 22)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .opacity(item.favorite || hovering ? 1 : 0)
                    .help(item.favorite ? Text("Unpin (remove from Favorites)") : Text("Pin to the top (add to Favorites)"))
                    .accessibilityLabel(item.favorite ? Text("Remove from Favorites") : Text("Add to Favorites"))
                }
                // The code, centred; its middle dot turns orange in the last seconds. A ring only for an odd period,
                // at the edge, so the code stays centred.
                LiveOTPCode(totp: totp, size: 28)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .overlay(alignment: .trailing) {
                        if ownRing { LiveCountdownRing(totp: totp, size: 40, lively: false) }
                    }
            }
            .padding(16)
            .background(Color.panelStrong.opacity(hovering ? 1 : 0.85), in: .rect(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(copied ? Color.brand.opacity(0.6) : Color.panelEdge, lineWidth: copied ? 1.5 : 1))
            .shadow(color: Color(red: 0.12, green: 0.16, blue: 0.35).opacity(hovering ? 0.12 : 0.06), radius: hovering ? 14 : 8, y: 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(verbatim: item.name))
        .accessibilityHint(Text("Copies the code"))
    }
}

/// An unpicked tag's soft glass (the header's chrome); a picked one has its own fill.
private struct TagChrome: ViewModifier {
    let picked: Bool
    func body(content: Content) -> some View {
        if picked { content } else { content.modifier(HeaderChrome(shape: .capsule)) }
    }
}

/// The codes page's one countdown: just the ring; on hover the pill widens smoothly to reveal "New codes" and the tags
/// beside it slide along to make room (glass over glass looked muddled), then it closes back to the ring.
private struct SharedCountdown: View {
    let clock: TOTP
    @State private var hovering = false
    @State private var labelWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            LiveCountdownRing(totp: clock, size: 24, digits: 0.4)
                .padding(4)
            Text("New codes").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { labelWidth = $0 }
                .padding(.trailing, 12)
                .opacity(hovering ? 1 : 0)
        }
        .frame(width: hovering ? 32 + labelWidth + 12 : 32, height: 32, alignment: .leading)
        .modifier(HeaderChrome(shape: .capsule, hovering: hovering))
        .clipShape(.capsule)
        .contentShape(.capsule)
        .onHover { h in withAnimation(.snappy(duration: 0.28, extraBounce: 0)) { hovering = h } }
        .help(Text("Every code below renews when the ring runs out (codes with another period keep their own ring)."))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("New codes"))
    }
}

/// A tag in the codes page's header. With `iconOnly` (All, My vault: their icons say enough) it shows its icon and
/// count, and widens smoothly on hover to reveal its name; shared vaults keep their names, their icons being alike.
private struct VaultTag: View {
    let title: String
    let symbol: String
    let count: Int
    let picked: Bool
    var iconOnly = false
    let action: () -> Void
    @State private var hovering = false
    @State private var titleWidth: CGFloat = 0

    private var showsTitle: Bool { !iconOnly || hovering }
    private var ink: AnyShapeStyle { picked ? AnyShapeStyle(.white) : AnyShapeStyle(.primary.opacity(0.75)) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(verbatim: title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { titleWidth = $0 }
                    .padding(.leading, 6)
                    // Hidden by fading as its room closes (a clip drew it in the wrong appearance's colour).
                    .opacity(showsTitle ? 1 : 0)
                    .frame(width: showsTitle ? titleWidth + 6 : 0, alignment: .leading)
                Text(count, format: .number).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .opacity(picked ? 0.8 : 0.55)
                    .contentTransition(.numericText(value: Double(count)))
                    .padding(.leading, 6)
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 12).frame(height: 32)
            .background {
                // The sidebar selection's blue: made for white text in both appearances (the brand blue is a light sky
                // in dark mode).
                if picked { Capsule().fill(Color.sidebarSelection) }
            }
            .modifier(TagChrome(picked: picked))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { h in
            guard iconOnly else { return }
            withAnimation(.snappy(duration: 0.28, extraBounce: 0)) { hovering = h }
        }
        .help(iconOnly ? Text(verbatim: title) : Text(verbatim: ""))
        .accessibilityLabel(Text(verbatim: "\(title), \(count)"))
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}
