import AppKit
import SwiftUI

struct WebsiteDetailRow: View {
    let address: String
    let index: Int
    @State private var openHovered = false

    private var url: URL? {
        URL(string: address.contains("://") ? address : "https://" + address)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(index == 0 ? "Website" : "Website \(index + 1)", systemImage: "globe")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    addressText.frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                    actions
                }
                VStack(alignment: .leading, spacing: 10) {
                    addressText
                    actions
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    private var addressText: some View {
        Text(verbatim: address)
            .font(.system(size: 13))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            DetailCopyButton(value: address,
                             label: index == 0 ? String(localized: "Website") : String(localized: "Website \(index + 1)"),
                             plain: true)
            Button {
                if let url { NSWorkspace.shared.open(url) }
            } label: {
                Label("Open", systemImage: "arrow.up.right")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 32, height: 32)
                    .contentShape(.rect(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .foregroundStyle(openHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .background(Color.primary.opacity(openHovered ? 0.06 : 0), in: .rect(cornerRadius: 8))
            .onHover { openHovered = $0 }
            .disabled(url == nil)
            .accessibilityLabel(Text("Open website"))
            .help(Text("Open in your browser"))
        }
        .fixedSize()
    }
}
