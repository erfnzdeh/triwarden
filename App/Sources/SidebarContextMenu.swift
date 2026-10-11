import AppKit
import SwiftUI

/// Sidebar context actions use a quiet target fill instead of SwiftUI's heavy context-preview outline.
/// The native outline still owns navigation, selection, keyboard focus and drag/drop.
struct SidebarContextAction: Identifiable {
    let title: String
    let symbol: String
    var destructive = false
    var separatorBefore = false
    let run: () -> Void

    var id: String { title }
}

extension View {
    func sidebarContextMenu(_ actions: [SidebarContextAction]) -> some View {
        overlay { SidebarMenuSurface(actions: actions) }
            .accessibilityActions {
                ForEach(actions) { action in
                    Button(action.title, action: action.run)
                }
            }
    }
}

private struct SidebarMenuSurface: NSViewRepresentable {
    let actions: [SidebarContextAction]

    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ view: Surface, context: Context) { view.actions = actions }

    final class Surface: NSView, NSMenuDelegate {
        var actions: [SidebarContextAction] = []
        private var showingMenu = false

        // Let ordinary clicks, disclosure, scrolling and drops reach the existing sidebar row.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(convert(point, from: superview)), let event = NSApp.currentEvent,
                  event.type == .rightMouseDown ||
                    (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) else { return nil }
            return self
        }

        override func rightMouseDown(with event: NSEvent) { openMenu(with: event) }
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { openMenu(with: event) }
        }

        private func openMenu(with event: NSEvent) {
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.delegate = self
            for (index, action) in actions.enumerated() {
                if action.separatorBefore { menu.addItem(.separator()) }
                let item = NSMenuItem(title: action.title, action: #selector(runAction(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
                if action.destructive {
                    item.attributedTitle = NSAttributedString(string: action.title,
                                                             attributes: [.foregroundColor: NSColor.systemRed])
                }
                menu.addItem(item)
            }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        @objc private func runAction(_ sender: NSMenuItem) {
            guard actions.indices.contains(sender.tag) else { return }
            actions[sender.tag].run()
        }

        func menuWillOpen(_ menu: NSMenu) { showingMenu = true; needsDisplay = true }
        func menuDidClose(_ menu: NSMenu) { showingMenu = false; needsDisplay = true }

        override func draw(_ dirtyRect: NSRect) {
            guard showingMenu else { return }
            let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            NSColor.labelColor.withAlphaComponent(contrast ? 0.16 : 0.07).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: -4, dy: -3), xRadius: 8, yRadius: 8).fill()
        }
    }
}
