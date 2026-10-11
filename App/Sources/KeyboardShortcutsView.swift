import SwiftUI

/// Help › Keyboard Shortcuts (⌃⇧/): a searchable two-column list of every key the app answers to, with the modifier
/// symbols (⌘ ⌃ ⇧ ⌥) mapped to Command, Control, Shift and Option. Keys are drawn as keycaps; typed filters as code.
struct KeyboardShortcutsView: View {
    struct Entry: Identifiable {
        enum Kind { case keys, typed }
        /// Keys (`⇧⌘N`), or text to type (`type:card`); alternatives separated by two spaces.
        let keys: String
        let title: LocalizedStringResource
        var kind = Kind.keys
        var id: String { keys + title.key }
    }

    struct Group: Identifiable {
        let title: LocalizedStringResource
        let symbol: String
        let entries: [Entry]
        var id: String { symbol }
    }

    @State private var query = ""
    @State private var selection: String?
    @State private var practiceIDs: Set<String> = []
    @State private var practice = PracticeSession()
    @State private var didAutoFocus = false
    @FocusState private var filterFocused: Bool

    /// What the symbols in the list mean, including the names used on other keyboards.
    struct KeyName: Identifiable {
        let symbol: String
        let name: LocalizedStringResource
        var alias: String?
        var id: String { symbol }
    }

    private static let modifiers: [KeyName] = [
        KeyName(symbol: "⌘", name: "Command", alias: "Cmd"),
        KeyName(symbol: "⌃", name: "Control", alias: "Ctrl"),
        KeyName(symbol: "⇧", name: "Shift"),
        KeyName(symbol: "⌥", name: "Option", alias: "Alt"),
    ]

    /// The system-wide shortcuts, as set in Settings › Shortcuts (empty keys: not set).
    private var everywhere: Group {
        Group(title: "Anywhere on your Mac", symbol: "globe", entries: GlobalAction.allCases.map { action in
            Entry(keys: Shortcut.current(for: action)?.display ?? "", title: action.resource)
        })
    }

    static let window = Group(title: "Vault window", symbol: "macwindow", entries: [
        Entry(keys: "⌘K", title: "Command palette"),
        Entry(keys: "⌘?", title: "Triwarden Help"),
        Entry(keys: "⌃⇧/", title: "Keyboard Shortcuts"),
        Entry(keys: "⌘F", title: "Search the list"),
        Entry(keys: "⌘G", title: "Generator"),
        Entry(keys: "⌘N", title: "New Login"),
        Entry(keys: "⇧⌘N", title: "New Secure Note"),
        Entry(keys: "⌥⌘N", title: "New Folder"),
        Entry(keys: "⌘[", title: "Back (narrow windows)"),
        Entry(keys: "⇧⌘I", title: "Import"),
        Entry(keys: "⇧⌘E", title: "Export Vault"),
        Entry(keys: "⇧⌘L", title: "Lock Vault"),
        Entry(keys: "⌘,", title: "Settings"),
    ])

    static let item = Group(title: "Selected item", symbol: "key", entries: [
        Entry(keys: "⌘E", title: "Edit"),
        Entry(keys: "⇧⌘C", title: "Copy Username"),
        Entry(keys: "⌥⌘C", title: "Copy Password"),
        Entry(keys: "⌃⌘C", title: "Copy One-Time Code"),
        Entry(keys: "⌥⌘T", title: "Show Password in Large Type"),
        Entry(keys: "⌘D", title: "Toggle Favorite"),
        Entry(keys: "⌥⌘A", title: "Archive"),
        Entry(keys: "⌘⌫", title: "Move to Trash"),
        Entry(keys: "↑  ↓", title: "Previous or next item"),
        Entry(keys: "⌘-click  ⇧-click", title: "Pick several items"),
        Entry(keys: "⌘A", title: "Pick all"),
    ])

    static let search = Group(title: "Search and filters", symbol: "line.3.horizontal.decrease.circle", entries: [
        Entry(keys: "type:card", title: "One type of item", kind: .typed),
        Entry(keys: "#Work", title: "A folder and its subfolders", kind: .typed),
        Entry(keys: "is:favorite", title: "Favorites", kind: .typed),
        Entry(keys: "has:otp", title: "Has a one-time code", kind: .typed),
        Entry(keys: "has:passkey", title: "Has a passkey", kind: .typed),
        Entry(keys: "is:weak", title: "Watchtower issues", kind: .typed),
        Entry(keys: "vault:personal", title: "One vault", kind: .typed),
        Entry(keys: "Tab  ↵", title: "Take a suggestion"),
        Entry(keys: "⌫", title: "Take off the last filter"),
        Entry(keys: "Esc", title: "Clear the text, then the filters"),
        Entry(keys: "↓", title: "Into the list"),
    ])

    static let palette = Group(title: "Command palette", symbol: "command", entries: [
        Entry(keys: "↵", title: "Open"),
        Entry(keys: "⌘↵", title: "Copy Password"),
        Entry(keys: "⌥↵", title: "Copy code"),
        Entry(keys: "⇧↵", title: "Open Website"),
        Entry(keys: "→  Tab", title: "All of an item's actions"),
        Entry(keys: ">", title: "Commands only", kind: .typed),
        Entry(keys: "gen 24", title: "A new 24-character password", kind: .typed),
    ])

    static let passwordField = Group(title: "Password field", symbol: "eye", entries: [
        Entry(keys: "⌥⌘R", title: "Reveal password"),
        Entry(keys: "⌥", title: "Reveal while held"),
    ])

    static let otherApp = Group(title: "Over another app", symbol: "rectangle.and.hand.point.up.left", entries: [
        Entry(keys: "↵  ⇧↵", title: "Type username and password / & submit"),
        Entry(keys: "⌃↵  ⇧⌃↵", title: "Type username / & submit"),
        Entry(keys: "⌥↵  ⇧⌥↵", title: "Type password / & submit"),
    ])

    private var catalog: [Group] {
        [Self.window, Self.item, Self.search, Self.palette, Self.otherApp, Self.passwordField, everywhere]
    }

    private func matching(_ group: Group) -> Group? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return group }
        let entries = group.entries.filter {
            String(localized: $0.title).localizedStandardContains(q) || $0.keys.localizedStandardContains(q)
        }
        return entries.isEmpty ? nil : Group(title: group.title, symbol: group.symbol, entries: entries)
    }

    private var visible: [Group] {
        catalog.compactMap(matching)
    }

    private var flatIDs: [String] {
        visible.flatMap { $0.entries.map(\.id) }
    }

    private func step(_ delta: Int) {
        let ids = flatIDs
        guard !ids.isEmpty else { selection = nil; return }
        guard let selection, let index = ids.firstIndex(of: selection) else {
            selection = delta < 0 ? ids.last : ids.first
            return
        }
        let next = min(max(index + delta, 0), ids.count - 1)
        self.selection = ids[next]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                TextField("Filter", text: $query, prompt: Text("Find a shortcut"))
                    .textFieldStyle(.plain)
                    .focused($filterFocused)
                    .onKeyPress(.escape) {
                        if !query.isEmpty || selection != nil {
                            query = ""
                            selection = nil
                            return .handled
                        }
                        NSApp.keyWindow?.close()
                        return .handled
                    }
                    .onKeyPress(.downArrow) { step(1); return .handled }
                    .onKeyPress(.upArrow) { step(-1); return .handled }
            }
            .font(.system(size: 16))
            .padding(.horizontal, 16)
            .frame(height: 50)

            Divider().opacity(0.5)

            ScrollViewReader { proxy in
                ScrollView {
                    if visible.isEmpty {
                        ContentUnavailableView.search(text: query).padding(.top, 48)
                    } else {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(visible) { group in
                                ShortcutSection(group: group, selection: selection, practice: practiceIDs)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 14)
                        .animation(.snappy(duration: 0.2), value: query)
                    }
                }
                .onChange(of: selection) { _, id in
                    guard let id else { return }
                    withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: practiceIDs) { _, ids in
                    guard let id = catalog.lazy.flatMap(\.entries).first(where: { ids.contains($0.id) })?.id else { return }
                    withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .thinScroller()

            Divider().opacity(0.5)
            HStack(spacing: 18) {
                ForEach(Self.modifiers) { key in
                    HStack(spacing: 6) {
                        KeyCap(key: key.symbol)
                        Text(key.name).font(.system(size: 12))
                        if let alias = key.alias {
                            Text(verbatim: alias).font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                    }
                }
                HStack(spacing: 6) {
                    KeyCap(symbol: "cursorarrow.click", label: "Click")
                    Text("Click").font(.system(size: 12))
                }
                Spacer(minLength: 12)
                footerKeys(["↑", "↓"], "Move")
                footerKeys(["Esc"], "Clear")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(minWidth: 860, idealWidth: 960, minHeight: 560, idealHeight: 680)
        .background { GlassPanelMaterial() }
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .onAppear {
            practice.entries = catalog.flatMap(\.entries)
            practice.onMatch = { ids in
                if !query.isEmpty { query = "" }
                practiceIDs = ids
            }
            practice.onBlur = {
                filterFocused = false
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
            practice.start()
        }
        .onDisappear { practice.stop() }
        .background { KeyWindowTextFocus { if !didAutoFocus { didAutoFocus = true; filterFocused = true } } }
        .onChange(of: query) { _, _ in selection = nil }
        .background {
            Button("") { NSApp.keyWindow?.close() }.keyboardShortcut("w", modifiers: .command).hidden()
        }
    }

    private func footerKeys(_ keys: [String], _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { KeyCap(key: $0) }
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// Watches keypresses while Keyboard Shortcuts is key: a real chord highlights every row it matches.
@MainActor
private final class PracticeSession {
    var entries: [KeyboardShortcutsView.Entry] = []
    var onMatch: (Set<String>) -> Void = { _ in }
    var onBlur: () -> Void = {}
    private var token: Any?

    func start() {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { [weak self] event in
            let ours = event.window is KeyGlassWindow && event.window?.title == String(localized: "Keyboard Shortcuts")
            guard ours else { return event }
            if event.type == .leftMouseDown {
                if !Self.clickInSearchField(event) {
                    MainActor.assumeIsolated { self?.onBlur() }
                }
                return event
            }
            guard let input = PracticeInput(event) else { return event }
            let consume = MainActor.assumeIsolated { self?.handle(input) ?? false }
            return consume ? nil : event
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }

    /// The search row is the top 50pt. A click anywhere under it leaves the field.
    private static func clickInSearchField(_ event: NSEvent) -> Bool {
        if let content = event.window?.contentView {
            var view: NSView? = content.hitTest(event.locationInWindow)
            while let current = view {
                if current is NSTextField || current is NSText { return true }
                view = current.superview
            }
        }
        guard let height = event.window?.contentView?.bounds.height else { return false }
        return height - event.locationInWindow.y <= 50
    }

    private func handle(_ input: PracticeInput) -> Bool {
        if input.flagsChanged { return false }
        guard let chord = PracticeChord(input) else { return false }
        if chord.key == "Esc" || chord.key == "↑" || chord.key == "↓" || chord.key == "←" || chord.key == "→" {
            return false
        }
        let ids = Set(entries.compactMap { entry in
            PracticeChord.matches(chord, keys: entry.keys, kind: entry.kind) ? entry.id : nil
        })
        guard !ids.isEmpty else { return false }
        onMatch(ids)
        return chord.command || chord.option || chord.control || chord.key == "↵" || chord.key == "Tab"
    }
}

/// A key-down or flags change, copied off the event so the monitor can hop to the main actor.
private struct PracticeInput: Sendable {
    var flagsChanged: Bool
    var shift: Bool
    var control: Bool
    var option: Bool
    var command: Bool
    var keyCode: UInt16
    var characters: String

    init?(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        flagsChanged = event.type == .flagsChanged
        shift = flags.contains(.shift)
        control = flags.contains(.control)
        option = flags.contains(.option)
        command = flags.contains(.command)
        keyCode = event.keyCode
        characters = event.charactersIgnoringModifiers ?? ""
    }
}

/// One chord, in the same symbols the list uses.
private struct PracticeChord: Equatable {
    var control = false
    var option = false
    var shift = false
    var command = false
    var key = ""

    init(control: Bool = false, option: Bool = false, shift: Bool = false, command: Bool = false, key: String = "") {
        self.control = control
        self.option = option
        self.shift = shift
        self.command = command
        self.key = key
    }

    init?(_ input: PracticeInput) {
        let key: String
        switch input.keyCode {
        case 36, 76: key = "↵"
        case 48: key = "Tab"
        case 49: key = "Space"
        case 51: key = "⌫"
        case 53: key = "Esc"
        case 123: key = "←"
        case 124: key = "→"
        case 125: key = "↓"
        case 126: key = "↑"
        case 33: key = "["
        case 43: key = ","
        case 44: key = "/"
        default:
            key = input.characters.uppercased()
            guard !key.isEmpty else { return nil }
        }
        self.init(control: input.control, option: input.option, shift: input.shift, command: input.command, key: Self.normalize(key))
    }

    static func matches(_ chord: PracticeChord, keys: String, kind: KeyboardShortcutsView.Entry.Kind) -> Bool {
        guard kind == .keys else { return false }
        return keys.components(separatedBy: "  ").contains { combo in
            guard !combo.contains("click"), let parsed = parse(combo) else { return false }
            return parsed == chord
        }
    }

    private static func parse(_ combo: String) -> PracticeChord? {
        var rest = Substring(combo)
        var chord = PracticeChord()
        while let c = rest.first {
            switch c {
            case "⌃": chord.control = true
            case "⌥": chord.option = true
            case "⇧": chord.shift = true
            case "⌘": chord.command = true
            default:
                let key = normalize(String(rest))
                guard !key.isEmpty else { return nil }
                chord.key = key
                return chord
            }
            rest = rest.dropFirst()
        }
        return nil
    }

    private static func normalize(_ key: String) -> String {
        switch key {
        case "↩", "↵", "Return": "↵"
        case "⇥", "Tab": "Tab"
        case "Space", "␣": "Space"
        case "⎋", "Esc": "Esc"
        default: key.count == 1 ? key.uppercased() : key
        }
    }
}

/// A borderless glass window, centered on the vault window and kept above it. SwiftUI's own window puts the title bar back.
@MainActor
final class GlassWindow {
    private let model: AppModel
    private let title: String
    private let size: NSSize
    private let minSize: NSSize
    private let root: () -> AnyView
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private(set) var isShown = false

    init(model: AppModel, title: String, size: NSSize, minSize: NSSize, root: @escaping () -> AnyView) {
        self.model = model
        self.title = title
        self.size = size
        self.minSize = minSize
        self.root = root
    }

    func show() {
        let window = window ?? make()
        self.window = window
        let parent = model.mainWindow
        if let parent {
            if parent.isMiniaturized { parent.deminiaturize(nil) }
            if window.parent !== parent {
                window.parent?.removeChildWindow(window)
                parent.addChildWindow(window, ordered: .above)
            }
        }
        place(over: parent)
        isShown = true
        model.refreshHelpScrim()
        NSApp.activate()
        parent?.orderFront(nil)
        window.makeKeyAndOrderFront(nil)
        // A child of the vault window sometimes refuses key focus. Without it, typing never reaches the search field.
        if !window.isKeyWindow, let parent = window.parent {
            parent.removeChildWindow(window)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func close() { window?.close() }

    /// Screen center of the vault window, kept on that window's screen.
    private func place(over parent: NSWindow?) {
        guard let window else { return }
        guard let parent else { window.center(); return }
        var origin = NSPoint(x: parent.frame.midX - window.frame.width / 2,
                             y: parent.frame.midY - window.frame.height / 2)
        if let screen = parent.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - window.frame.width))
            origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - window.frame.height))
        }
        window.setFrameOrigin(origin)
    }

    private func make() -> NSWindow {
        let window = KeyGlassWindow(contentRect: NSRect(origin: .zero, size: size),
                                    styleMask: [.borderless, .resizable, .fullSizeContentView],
                                    backing: .buffered, defer: false)
        window.title = title
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = minSize
        let host = NSHostingView(rootView: root().environment(model))
        host.safeAreaRegions = []
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = host
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isShown = false
                self.model.refreshHelpScrim()
            }
        }
        return window
    }
}

/// Borderless windows cannot take the keyboard unless a subclass says so. The search field depends on that.
private final class KeyGlassWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// When this window becomes key, move the keyboard into the search field. Focus set at appear is too early: the window is not key yet.
struct KeyWindowTextFocus: NSViewRepresentable {
    var focus: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(focus: focus) }

    func makeNSView(context: Context) -> FocusWatcher {
        let view = FocusWatcher()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: FocusWatcher, context: Context) {
        context.coordinator.focus = focus
        nsView.coordinator = context.coordinator
    }

    final class Coordinator {
        var focus: () -> Void
        init(focus: @escaping () -> Void) { self.focus = focus }
    }
}

final class FocusWatcher: NSView {
    var coordinator: KeyWindowTextFocus.Coordinator?
    private var observer: NSObjectProtocol?
    private var didFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        guard let window else { return }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.focusOnce() }
        }
        if window.isKeyWindow { focusOnce() }
    }

    /// The field is focused when the window first opens. Later clicks must be able to leave it.
    private func focusOnce() {
        guard !didFocus else { return }
        didFocus = true
        coordinator?.focus()
    }
}

/// The same glass as the command palette: regular material, a light wash, and a hairline.
struct GlassPanelMaterial: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(.regularMaterial)
            .background((dark ? Color.black.opacity(0.15) : Color.white.opacity(0.55)), in: .rect(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.primary.opacity(dark ? 0.14 : 0.08), lineWidth: 0.5))
    }
}

private struct ShortcutSection: View {
    let group: KeyboardShortcutsView.Group
    let selection: String?
    var practice: Set<String> = []

    private let columns = [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label { Text(group.title) } icon: { Image(systemName: group.symbol) }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
                ForEach(group.entries) { entry in
                    ShortcutRow(entry: entry, selected: selection == entry.id, practiced: practice.contains(entry.id))
                        .id(entry.id)
                }
            }
        }
        .transition(.opacity)
    }
}

private struct ShortcutRow: View {
    let entry: KeyboardShortcutsView.Entry
    let selected: Bool
    var practiced = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ShortcutTitle(title: entry.title)
            Spacer(minLength: 8)
            if entry.keys.isEmpty {
                Text("Not set").font(.system(size: 11.5)).foregroundStyle(.tertiary)
            } else if entry.kind == .typed {
                Typed(text: entry.keys)
            } else {
                KeyCombo(keys: entry.keys)
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 32)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(practiced ? Color.primary.opacity(0.16) : (selected ? Color.primary.opacity(0.1) : (hovering ? Color.primary.opacity(0.05) : .clear)))
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering || selected || practiced)
        .accessibilityElement(children: .combine)
    }
}

/// Keys as keycaps, one cap per key (⇧ ⌘ N); alternatives (two spaces apart) a little further apart, with a thin
/// slash between. "⌘-click" is the command cap plus the clicking cursor.
struct KeyCombo: View {
    let keys: String

    private static let modifiers: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]

    /// One alternative split into caps, and any trailing word ("click").
    private func caps(_ combo: String) -> (caps: [String], word: String?) {
        var caps: [String] = []
        var rest = Substring(combo)
        while let c = rest.first, Self.modifiers.contains(c) { caps.append(String(c)); rest = rest.dropFirst() }
        if rest.hasPrefix("-") { return (caps, String(rest.dropFirst())) }
        if !rest.isEmpty { caps.append(String(rest)) }
        return (caps, nil)
    }

    var body: some View {
        let alternatives = keys.components(separatedBy: "  ")
        HStack(spacing: 6) {
            ForEach(Array(alternatives.enumerated()), id: \.offset) { index, combo in
                if index > 0 { AlternativeSlash() }
                let parts = caps(combo)
                HStack(spacing: 3) {
                    ForEach(Array(parts.caps.enumerated()), id: \.offset) { _, key in KeyCap(key: key) }
                    if let word = parts.word {
                        if word == "click" {
                            KeyCap(symbol: "cursorarrow.click", label: "click")
                        } else {
                            Text(verbatim: word).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .fixedSize()
    }
}

/// The thin divider between two ways to do one thing, on a label and between keycaps.
private struct AlternativeSlash: View {
    var body: some View {
        Text(verbatim: "/")
            .font(.system(size: 11))
            .foregroundStyle(.quaternary)
            .accessibilityHidden(true)
    }
}

/// A shortcut name. " / " is the same thin slash used between alternative keycaps.
private struct ShortcutTitle: View {
    let title: LocalizedStringResource

    var body: some View {
        let parts = String(localized: title).components(separatedBy: " / ")
        HStack(spacing: 6) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 { AlternativeSlash() }
                Text(verbatim: part)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
    }
}

/// One key: a flat chip, the same weight as a keybinding hint. A symbol chip is the same shape with an icon.
struct KeyCap: View {
    var key: String = ""
    var symbol: String?
    var label: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .accessibilityLabel(label ?? symbol)
            } else {
                Text(verbatim: key)
                    .font(.system(size: 11, weight: .medium))
            }
        }
        .foregroundStyle(.primary.opacity(0.9))
        .padding(.horizontal, symbol != nil || key.count > 1 ? 5 : 0)
        .frame(minWidth: 20, minHeight: 20)
        .background {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
        }
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(scheme == .dark ? 0.14 : 0.08)))
    }
}

/// Text you type (a filter, a palette command): code, not keys.
private struct Typed: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(.primary.opacity(0.8))
            .padding(.horizontal, 6).frame(minHeight: 21)
            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 5, style: .continuous))
            .fixedSize()
    }
}

extension GlobalAction {
    /// The title as a resource (for matching the filter as well as showing).
    var resource: LocalizedStringResource {
        switch self {
        case .palette: "Command palette"
        case .fill: "Fill this page or app"
        case .showWindow: "Show Triwarden"
        case .generate: "Copy a new password"
        case .lock: "Lock vault"
        }
    }
}
