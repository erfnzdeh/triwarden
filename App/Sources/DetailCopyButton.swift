import SwiftUI

/// A visible copy action. Secret fields use the same guard and clipboard expiry as password tiles.
struct DetailCopyButton: View {
    @Environment(AppModel.self) private var model
    let value: String
    let label: String
    var guardedItem: VaultItem? = nil
    var plain = false
    @State private var armed: Int?
    @State private var copied = false
    @State private var plainCopies = 0
    @State private var hovering = false

    var body: some View {
        Button(action: copy) {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                .labelStyle(.iconOnly)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 32, height: 32)
                .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering || copied ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .background(Color.primary.opacity(hovering ? 0.06 : 0), in: .rect(cornerRadius: 8))
        .onHover { hovering = $0 }
        .accessibilityLabel(Text("Copy \(label)"))
        .accessibilityValue(copied ? Text("Copied") : Text(""))
        .help(copied ? Text("Copied") : Text("Copy \(label)"))
        .disabled(value.isEmpty)
        .copyTick(armed: $armed, copied: $copied)
        .task(id: plainCopies) {
            guard plainCopies > 0 else { return }
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            copied = false
        }
        .onChange(of: value) {
            armed = nil
            copied = false
            plainCopies = 0
        }
    }

    private func copy() {
        if plain {
            model.copyPlain(value)
            copied = true
            plainCopies += 1
        } else {
            armed = model.copyCount
            if let guardedItem {
                model.guarded(guardedItem) { model.copy(value, label: label) }
            } else {
                model.copy(value, label: label)
            }
        }
    }
}
