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
                                HStack(spacing: 8) {
                                    Image(systemName: entry.symbol).frame(width: 18)
                                        .foregroundStyle(entry.destructive ? Color.red : selected == index ? Color.primary : Color.secondary)
                                    Text(verbatim: entry.title)
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
                                .padding(.horizontal, 10).frame(height: 26)
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
            .frame(maxHeight: 520).fixedSize(horizontal: false, vertical: true)
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
