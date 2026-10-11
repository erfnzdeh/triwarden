import SwiftUI

/// Help › Triwarden Help (⌘?): what the app does, one topic at a time. Keyboard Shortcuts is the key list; this is the guide.
struct HelpGuideView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var selection = HelpTopic.all[0].id
    @FocusState private var filterFocused: Bool

    private var shown: [HelpTopic] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return HelpTopic.all }
        return HelpTopic.all.filter {
            String(localized: $0.title).localizedStandardContains(q) || String(localized: $0.body).localizedStandardContains(q)
        }
    }

    private var topic: HelpTopic? {
        shown.first { $0.id == selection } ?? shown.first
    }

    var body: some View {
        HStack(spacing: 0) {
            topics
            Divider().opacity(0.5)
            detail
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 480, idealHeight: 560)
        .background { GlassPanelMaterial() }
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .onAppear { filterFocused = true }
        .background { KeyWindowTextFocus { filterFocused = true } }
        .onExitCommand { NSApp.keyWindow?.close() }
        .background {
            Button("") { NSApp.keyWindow?.close() }.keyboardShortcut("w", modifiers: .command).hidden()
        }
    }

    private var topics: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                TextField("Filter", text: $query, prompt: Text("Find a topic"))
                    .textFieldStyle(.plain)
                    .focused($filterFocused)
                    .onKeyPress(.escape) {
                        if !query.isEmpty { query = ""; return .handled }
                        NSApp.keyWindow?.close()
                        return .handled
                    }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(shown) { topic in
                        topicRow(topic)
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 10)
            }
            .thinScroller()
        }
        .frame(width: 220)
    }

    private func topicRow(_ topic: HelpTopic) -> some View {
        let on = topic.id == (self.topic?.id)
        return Button {
            selection = topic.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: topic.symbol).font(.system(size: 13)).frame(width: 18)
                Text(topic.title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 32)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(on ? Color.primary.opacity(0.1) : .clear)
        }
    }

    @ViewBuilder private var detail: some View {
        if let topic {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label { Text(topic.title) } icon: { Image(systemName: topic.symbol) }
                        .font(.system(size: 20, weight: .semibold))
                    Text(topic.body)
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !topic.keys.isEmpty {
                        HStack(spacing: 14) {
                            ForEach(topic.keys, id: \.self) { KeyCombo(keys: $0) }
                        }
                    }
                    if topic.opensShortcuts {
                        Button("Show Keyboard Shortcuts") { model.showShortcuts() }
                            .buttonStyle(.appPrimarySmall)
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .thinScroller()
        } else {
            ContentUnavailableView("No matching topics", systemImage: "magnifyingglass", description: Text("Try another word."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct HelpTopic: Identifiable {
    let id: String
    let symbol: String
    let title: LocalizedStringResource
    let body: LocalizedStringResource
    var keys: [String] = []
    var opensShortcuts = false

    static let all: [HelpTopic] = [
        HelpTopic(id: "vault", symbol: "key", title: "Your vault",
                  body: "Logins, secure notes, cards, identities and SSH keys, with folders, favorites, Archive and Trash. Shared vaults from an organization sit beside yours. Pick several items with ⌘-click, ⇧-click or ⌘A."),
        HelpTopic(id: "search", symbol: "magnifyingglass", title: "Search",
                  body: "⌘F searches every open vault by name, username or website. Filters stay on between launches. Type one, or choose it from the filter menu. Delete takes the last filter off.",
                  keys: ["⌘F", "type:card", "#Work", "has:otp"]),
        HelpTopic(id: "palette", symbol: "command", title: "Command palette",
                  body: "⌘K finds an item or runs a command from anywhere. Over a browser or another app, Return types that login’s username and password. Control-Return types the username, Option-Return the password. Add Shift to any of those and it submits.",
                  keys: ["⌘K", "↵"]),
        HelpTopic(id: "shortcuts", symbol: "keyboard", title: "Keyboard shortcuts",
                  body: "⌃⇧/ opens every shortcut on one page: the vault, the selected item, search, the palette, and the keys that work in any app. Keys that work anywhere are chosen in Settings › Shortcuts.",
                  keys: ["⌃⇧/"], opensShortcuts: true),
        HelpTopic(id: "autofill", symbol: "person.badge.key", title: "AutoFill",
                  body: "Safari, Chrome and other apps can fill passwords, passkeys and one-time codes. A login saved for one site also fills on the sites it owns, such as a google.com login on youtube.com."),
        HelpTopic(id: "ssh", symbol: "terminal", title: "SSH agent",
                  body: "An SSH key in the vault can sign git commits and SSH sessions. Triwarden asks which app wants the signature. An app you trust is allowed next time without asking, and every answer is kept in a log on this Mac."),
        HelpTopic(id: "watchtower", symbol: "shield", title: "Watchtower",
                  body: "Watchtower marks weak, reused and breached passwords, and logins that still use http. The item list shows each issue. Change on Site opens that site’s own page for changing the password."),
        HelpTopic(id: "lock", symbol: "lock", title: "Lock and unlock",
                  body: "Touch ID or a PIN unlocks the accounts on this Mac. Each account can lock after its own wait, or log out instead of locking. ⇧⌘L locks the vault.",
                  keys: ["⇧⌘L"]),
    ]
}

/// Dims the vault window while Help or Keyboard Shortcuts is open. A click closes them.
struct HelpScrim: View {
    @Environment(\.colorScheme) private var scheme
    var dismiss: () -> Void

    var body: some View {
        Color.black.opacity(scheme == .dark ? 0.46 : 0.28)
            .ignoresSafeArea()
            .contentShape(.rect)
            .onTapGesture(perform: dismiss)
            .accessibilityLabel(Text("Close"))
            .accessibilityAddTraits(.isButton)
            .transition(.opacity)
    }
}

/// Remembers the vault window so Help and Keyboard Shortcuts can center on it.
struct MainWindowAnchor: NSViewRepresentable {
    @Environment(AppModel.self) private var model

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { model.mainWindow = view.window }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let window = view.window { model.mainWindow = window }
    }
}
