import AppKit
import SwiftUI

/// Sidebar context actions use a quiet target fill instead of SwiftUI's heavy context-preview outline.
/// The native outline still owns navigation, selection, keyboard focus and drag/drop.
struct SidebarContextAction: Identifiable {
    let title: String
    let symbol: String
    var destructive = false
    var separatorBefore = false
    var enabled = true
    var children: [SidebarContextAction] = []
    var run: () -> Void = {}

    var accessibleLeaves: [SidebarContextAction] { children.isEmpty ? (enabled ? [self] : []) : children.flatMap(\.accessibleLeaves) }

    var id: String { title }
}

extension View {
    func sidebarContextMenu(_ actions: [SidebarContextAction], selection: SidebarSelection? = nil) -> some View {
        modifier(SidebarContextModifier(actions: actions, selection: selection))
    }
}

private struct SidebarContextModifier: ViewModifier {
    let actions: [SidebarContextAction]
    let selection: SidebarSelection?
    @Environment(\.sidebarCurrent) private var current

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .contentShape(.rect)
            .appContextMenu(actions.map(\.menuEntry), keyboardTarget: selection != nil && selection == current)
    }
}

private extension SidebarContextAction {
    var menuEntry: ActionMenuEntry {
        ActionMenuEntry(title: title, symbol: symbol, enabled: enabled, destructive: destructive,
                        separatorBefore: separatorBefore, children: children.map(\.menuEntry), run: run)
    }
}
