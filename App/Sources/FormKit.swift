import SwiftUI

// The app's form language, shared by every "new" and "edit" form (items, Sends, folders): a title with a line of
// help, white cards on the window's wash, labels above soft rounded fields, switches at the row's end, and one
// footer bar with the actions.

/// The form's heading: an icon tile, a title, and what the form is for.
struct FormHeader: View {
    let symbol: String
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 12) {
            // A solid tile in the brand's blue, like the primary buttons: white symbol, a soft light from the top.
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(LinearGradient(colors: [Color.brandFill, Color.brandButton], startPoint: .top, endPoint: .bottom))
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(.white.opacity(scheme == .dark ? 0.18 : 0.35), lineWidth: 0.5))
                        .shadow(color: .black.opacity(scheme == .dark ? 0.3 : 0.1), radius: 2, y: 1)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 20, weight: .bold)).tracking(-0.3)
                if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A group of fields on a card.
struct FormCard<Content: View>: View {
    var title: LocalizedStringKey?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title { Text(title).font(.system(size: 13, weight: .semibold)) }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.panelStrong, in: .rect(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.panelEdge))
    }
}

/// A label above its field, with an optional note under it.
struct FormField<Content: View>: View {
    let label: LocalizedStringKey
    var note: LocalizedStringKey?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            content
            if let note { Text(note).font(.system(size: 11)).foregroundStyle(.tertiary) }
        }
    }
}

/// Multi-line text in the same soft, rounded look as `SoftFieldStyle`.
struct SoftEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 90
    var monospaced = false
    /// Shown in the empty editor, like a text field's prompt.
    var prompt: LocalizedStringKey?
    @FocusState private var focused: Bool

    private var font: Font { .system(size: monospaced ? 12 : 13, design: monospaced ? .monospaced : .default) }

    var body: some View {
        TextEditor(text: $text)
            .font(font)
            .scrollContentBackground(.hidden)
            // The system scroller sits inside the box as a grey bar with "Show scroll bars: Always"; it still scrolls.
            .scrollIndicators(.never)
            .focused($focused)
            .overlay(alignment: .topLeading) {
                if let prompt, text.isEmpty {
                    // Lined up with the editor's first line (its text container insets the text by 5pt).
                    Text(prompt).font(font).foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                }
            }
            .padding(8)
            .frame(minHeight: minHeight)
            .background(Color.formInputFill, in: .rect(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(focused ? Color.primary.opacity(0.35) : Color(nsColor: .separatorColor), lineWidth: focused ? 1.5 : 1))
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

/// A choice from a list, drawn as a soft field with a chevron (not the system pop-up button).
struct SoftMenu<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var placeholder: LocalizedStringKey = "Choose"
    var accessibilityLabel: LocalizedStringKey

    var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button {
                    selection = option.0
                } label: {
                    if option.0 == selection {
                        Label { Text(verbatim: option.1) } icon: { Image(systemName: "checkmark") }
                    } else {
                        Text(verbatim: option.1)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                if let current = options.first(where: { $0.0 == selection })?.1 {
                    Text(verbatim: current).foregroundStyle(.primary)
                } else {
                    Text(placeholder).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            .font(.system(size: 13))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Color.formInputFill, in: .rect(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(Text(accessibilityLabel))
    }
}

/// The footer every form ends with: a note on the left, Cancel and the primary action on the right.
struct FormFooter<Note: View>: View {
    let action: LocalizedStringKey
    var busy = false
    var disabled = false
    let cancel: () -> Void
    let submit: () -> Void
    @ViewBuilder var note: Note

    var body: some View {
        HStack(spacing: 10) {
            note
            Spacer()
            Button("Cancel", action: cancel).buttonStyle(.appSecondary).keyboardShortcut(.cancelAction)
            Button(action: submit) {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.small).tint(.white) }
                    Text(action)
                }
            }
            .buttonStyle(.appPrimary).keyboardShortcut(.defaultAction)
            .disabled(disabled || busy)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(alignment: .top) { Divider().opacity(0.5) }
    }
}

extension FormFooter where Note == EmptyView {
    init(action: LocalizedStringKey, busy: Bool = false, disabled: Bool = false, cancel: @escaping () -> Void,
         submit: @escaping () -> Void) {
        self.init(action: action, busy: busy, disabled: disabled, cancel: cancel, submit: submit) { EmptyView() }
    }
}

/// Choosing a folder when folders nest ("Work/Dev"): each level opens as a submenu (a cascader), a parent can be
/// chosen itself from the top of its submenu, and the field shows the path as a breadcrumb. With `create`, the menu
/// ends in "New Folder…" (and "New Subfolder of …" for the chosen one): the field turns into a name field in place,
/// Return makes the folder and picks it, Escape or × goes back to the menu.
struct FolderCascader: View {
    let folders: [Grouping]
    @Binding var selection: String?
    /// Makes a folder from its full path ("Work/Servers") and returns its id; nil when it couldn't.
    var create: ((String) async -> String?)?
    /// Naming a new folder: the path it goes inside ("" for the top level), nil when choosing.
    var newFolderIn: Binding<String?> = .constant(nil)

    @State private var name = ""
    @State private var busy = false
    @FocusState private var nameFocused: Bool

    private var path: String? {
        selection.flatMap { id in folders.first { $0.id == id }?.name }
    }

    var body: some View {
        if let parent = newFolderIn.wrappedValue {
            nameField(in: parent)
        } else {
            menu
        }
    }

    private var menu: some View {
        Menu {
            Button { selection = nil } label: { check(selection == nil, "No Folder") }
            if !folders.isEmpty {
                Divider()
                FolderLevel(nodes: FolderNode.tree(folders), selection: $selection)
            }
            if create != nil {
                Divider()
                Button("New Folder…", systemImage: "folder.badge.plus") { startNaming(in: "") }
                if let path {
                    Button("New Subfolder of “\(leaf(path))”…", systemImage: "folder.badge.plus") { startNaming(in: path) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selection == nil ? "tray" : "folder")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if let path {
                    // Work › Dev: the parents quiet, the folder itself in full.
                    breadcrumb(path, last: Text(verbatim: leaf(path)).foregroundStyle(.primary))
                        .lineLimit(1).truncationMode(.head)
                } else {
                    Text("No Folder").foregroundStyle(.primary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            .fieldChrome(focused: false)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(Text("Folder"))
        .accessibilityValue(Text(verbatim: path ?? String(localized: "No Folder")))
    }

    private func nameField(in parent: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.plus").font(.system(size: 12)).foregroundStyle(.secondary)
                if !parent.isEmpty {
                    breadcrumb(parent + "/", last: Text(verbatim: ""))
                        .lineLimit(1).truncationMode(.head)
                }
                TextField("Folder name", text: $name, prompt: Text(parent.isEmpty ? "e.g. Work/Servers" : "e.g. Servers"))
                    .textFieldStyle(.plain)
                    .focused($nameFocused)
                    .onSubmit(commit)
                    .onExitCommand(perform: stopNaming)
                    .disabled(busy)
                    .frame(minWidth: 140)
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action: commit) {
                        Image(systemName: "return").font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .background(Color.primary.opacity(trimmed.isEmpty ? 0.04 : 0.1), in: .rect(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain).foregroundStyle(trimmed.isEmpty ? .tertiary : .primary)
                    .disabled(trimmed.isEmpty)
                    .help("Create Folder")
                    .accessibilityLabel(Text("Create Folder"))
                    Button(action: stopNaming) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 22, height: 22).contentShape(.rect)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Cancel")
                    .accessibilityLabel(Text("Cancel New Folder"))
                }
            }
            .font(.system(size: 13))
            .fieldChrome(focused: nameFocused)
            Text(parent.isEmpty ? "Return to create and pick it. Use / to nest." : "Return to create and pick it.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .onAppear { nameFocused = true }
        .transition(.opacity)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    private func startNaming(in parent: String) {
        name = ""
        withAnimation(.easeOut(duration: 0.15)) { newFolderIn.wrappedValue = parent }
    }

    private func stopNaming() {
        guard !busy else { return }
        withAnimation(.easeOut(duration: 0.15)) { newFolderIn.wrappedValue = nil }
    }

    private func commit() {
        guard let parent = newFolderIn.wrappedValue, let create, !busy else { return }
        // "Work/ Servers /" → "Work/Servers": no empty or padded parts.
        let parts = trimmed.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return }
        let full = ((parent.isEmpty ? [] : [parent]) + parts).joined(separator: "/")
        // Already there: just pick it rather than make a twin.
        if let existing = folders.first(where: { $0.name.compare(full, options: .caseInsensitive) == .orderedSame }) {
            selection = existing.id
            stopNaming()
            return
        }
        busy = true
        Task {
            let id = await create(full)
            busy = false
            if let id {
                selection = id
                stopNaming()
            } else {
                nameFocused = true
            }
        }
    }

    private func leaf(_ path: String) -> String {
        path.split(separator: "/").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? path
    }

    /// The parents of `path` quietly, each followed by "›", then `last`.
    private func breadcrumb(_ path: String, last: Text) -> Text {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.dropLast().reduce(Text(verbatim: "")) { $0 + Text(verbatim: "\($1) › ").foregroundStyle(.secondary) } + last
    }
}

private extension View {
    /// The soft field look shared by the folder menu and its name field.
    func fieldChrome(focused: Bool) -> some View {
        font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Color.formInputFill, in: .rect(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(focused ? Color.primary.opacity(0.35) : Color(nsColor: .separatorColor), lineWidth: focused ? 1.5 : 1))
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

/// One level of the folder tree: leaves are choices, parents open a submenu.
private struct FolderLevel: View {
    let nodes: [FolderNode]
    @Binding var selection: String?

    var body: some View {
        ForEach(nodes) { node in
            if node.children.isEmpty {
                if let id = node.folderIds.first {
                    Button { selection = id } label: { check(node.folderIds.contains(selection ?? ""), node.name, symbol: "folder") }
                }
            } else {
                Menu {
                    // The parent itself, when it's a real folder (not just a prefix of its children's names).
                    if let id = node.folderIds.first {
                        Button { selection = id } label: { check(node.folderIds.contains(selection ?? ""), node.name, symbol: "folder") }
                        Divider()
                    }
                    FolderLevel(nodes: node.children, selection: $selection)
                } label: {
                    // A tick on the way to the chosen folder.
                    check(contains(node, selection), node.name, symbol: "folder")
                }
            }
        }
    }

    private func contains(_ node: FolderNode, _ id: String?) -> Bool {
        guard let id else { return false }
        return node.folderIds.contains(id) || node.children.contains { contains($0, id) }
    }
}

@ViewBuilder
private func check(_ on: Bool, _ title: LocalizedStringKey) -> some View {
    if on { Label(title, systemImage: "checkmark") } else { Text(title) }
}

@ViewBuilder
private func check(_ on: Bool, _ title: String, symbol: String) -> some View {
    Label { Text(verbatim: title) } icon: { Image(systemName: on ? "checkmark" : symbol) }
}
