import SwiftUI

/// Management-page controls share the vault toolbar's height and chrome, without its vault-search token behavior.
struct WorkspaceSearchField: View {
    let prompt: LocalizedStringKey
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var moveToList: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 13)).focused(focused)
                .onKeyPress(.escape) { guard !text.isEmpty else { return .ignored }; text = ""; return .handled }
                .onKeyPress(.downArrow) { guard let moveToList else { return .ignored }; moveToList(); return .handled }
            if !text.isEmpty {
                Button { text = ""; focused.wrappedValue = true } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.tertiary)
                }.buttonStyle(.plain).accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, 12).frame(height: 32)
        .modifier(HeaderChrome(shape: .capsule, hovering: hovering || focused.wrappedValue))
        .contentShape(.capsule).onTapGesture { focused.wrappedValue = true }.onHover { hovering = $0 }
    }
}

struct WorkspaceFilter<Value: Hashable>: View {
    let title: LocalizedStringKey
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        ActionMenu(entries: options.map { option in
            ActionMenuEntry(title: option.1, checked: selection == option.0) { selection = option.0 }
        }) {
            HStack(spacing: 8) {
                Text(verbatim: options.first { $0.0 == selection }?.1 ?? "").font(.system(size: 13)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).frame(height: 32)
            .modifier(HeaderChrome(shape: .capsule)).contentShape(.capsule)
        }.fixedSize().accessibilityLabel(Text(title))
            .accessibilityValue(Text(verbatim: options.first { $0.0 == selection }?.1 ?? ""))
    }
}
