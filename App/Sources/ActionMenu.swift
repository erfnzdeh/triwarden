import AppKit
import SwiftUI

enum ActionMenuPresentation {
    static var animates: Bool { Motion.plays && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// Shared toolbar menus: stable icon columns, independent checkmarks and a translucent neutral selection wash that preserves the material underneath.
struct ActionMenuEntry {
    var title: String
    var symbol: String = ""
    var shortcut: String = ""
    var checked = false
    var enabled = true
    var destructive = false
    var separatorBefore = false
    var heading = false
    var children: [ActionMenuEntry] = []
    var run: () -> Void = {}

    static func heading(_ title: String) -> Self { Self(title: title, enabled: false, heading: true) }
}

struct ActionMenu<Label: View>: View {
    let entries: [ActionMenuEntry]
    @ViewBuilder var label: () -> Label
    @State private var open = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button { open.toggle() } label: { label() }
            .buttonStyle(.plain)
            .background {
                BelowPopover(isPresented: $open) {
                    ActionMenuContents(entries: entries, close: { open = false })
                        .environment(\.colorScheme, scheme)
                }
            }
    }
}

struct ActionMenuContents: View {
    let entries: [ActionMenuEntry]
    let close: () -> Void
    @State private var path: [Int] = []
    @State private var selected: Int?
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme

    private var current: [ActionMenuEntry] {
        path.reduce(entries) { list, index in list.indices.contains(index) ? list[index].children : [] }
    }

    /// The rows' height, worked out from what they are rather than measured. A scroll view has no height of its own,
    /// so a popover sized from its preferred content size kept the height it was first given and drew an empty band
    /// under a short menu. `fixedSize` did not settle it; adding up the rows does.
    private var estimatedHeight: CGFloat {
        current.reduce(0) { total, entry in
            if entry.heading { return total + 20 + (entry.separatorBefore ? 7 : 0) }
            return total + 26 + (entry.separatorBefore ? 7 : 0)
        }
        // The 1 pt spacing between rows, and a heading's own top padding.
        + CGFloat(max(current.count - 1, 0)) + 4
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if !path.isEmpty {
                Button { back() } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.plain).padding(6)
                Divider()
            }
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(current.indices, id: \.self) { index in
                        let entry = current[index]
                        if entry.separatorBefore { Divider().padding(.vertical, 3) }
                        if entry.heading {
                            Text(verbatim: entry.title)
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 10).padding(.top, index == 0 ? 2 : 6).padding(.bottom, 2)
                        } else {
                            Button { activate(index) } label: {
                                // Centred, with no per-row offsets: measured off a render, a symbol's middle and the
                                // cap-height middle of the label beside it land within half a point of each other.
                                // The variation that looks like misalignment is the glyphs themselves — an ascender
                                // or a descender changes a word's bounding box, not its baseline.
                                HStack(alignment: .center, spacing: 8) {
                                    Image(systemName: entry.symbol)
                                        .font(.system(size: 12))
                                        .foregroundStyle(entry.destructive ? Color.red : selected == index ? Color.primary : Color.secondary)
                                        // One box for every symbol, at the label's own line height. SF Symbols come in
                                        // different intrinsic sizes (13 pt for text.alignleft, 15 pt for doc), so
                                        // without a shared box each row's weight differs and the row looks misaligned
                                        // even though every centre is on the same line.
                                        .frame(width: 18, height: 20, alignment: .center)
                                    Text(verbatim: entry.title)
                                        .frame(height: 20, alignment: .center)
                                    Spacer(minLength: 12)
                                    if !entry.shortcut.isEmpty {
                                        Text(verbatim: entry.shortcut).foregroundStyle(entry.destructive ? Color.red : selected == index ? Color.primary : Color.secondary)
                                    }
                                    if !entry.children.isEmpty {
                                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                                    } else {
                                        Image(systemName: "checkmark").opacity(entry.checked ? 1 : 0).frame(width: 12)
                                    }
                                }
                                .font(.system(size: 13))
                                .frame(height: 26)
                                .padding(.horizontal, 10)
                                .foregroundStyle(entry.destructive ? Color.red : Color.primary)
                                .background(selected == index ? (scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.10)) : .clear,
                                            in: .rect(cornerRadius: 8))
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain).disabled(!entry.enabled)
                            .onHover { if $0 && entry.enabled { selected = index } }
                            .accessibilityAddTraits(entry.checked ? .isSelected : [])
                            .id(index)
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            // Exactly the rows' height, so the popover wraps them; a menu longer than 520 pt scrolls instead.
            .frame(height: min(estimatedHeight, 520))
            .onChange(of: selected) { _, index in if let index { proxy.scrollTo(index) } }
            }
        }
        .padding(6).frame(width: 280)
        .focusable().focusEffectDisabled().focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { step(1); return .handled }
        .onKeyPress(.upArrow) { step(-1); return .handled }
        .onKeyPress(.return) { if let selected { activate(selected) }; return .handled }
        .onKeyPress(.rightArrow) {
            if let selected, current.indices.contains(selected), !current[selected].children.isEmpty { activate(selected) }
            return .handled
        }
        .onKeyPress(.leftArrow) { back(); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
    }

    private func step(_ delta: Int) {
        let choices = current.indices.filter { current[$0].enabled && !current[$0].heading }
        guard !choices.isEmpty else { return }
        let start = selected.flatMap { choices.firstIndex(of: $0) } ?? (delta > 0 ? -1 : choices.count)
        selected = choices[min(max(start + delta, 0), choices.count - 1)]
    }

    private func activate(_ index: Int) {
        guard current.indices.contains(index), current[index].enabled else { return }
        let entry = current[index]
        if entry.children.isEmpty { close(); entry.run() }
        else { path.append(index); selected = nil }
    }

    private func back() { if !path.isEmpty { path.removeLast(); selected = nil } }
}
