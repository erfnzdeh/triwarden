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
        content.overlay { SidebarMenuSurface(actions: actions, selected: selection != nil && selection == current) }
            .accessibilityActions {
                ForEach(actions.flatMap(\.accessibleLeaves)) { action in Button(action.title, action: action.run) }
            }
    }
}

private struct SidebarMenuSurface: NSViewRepresentable {
    let actions: [SidebarContextAction]
    let selected: Bool

    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ view: Surface, context: Context) { view.actions = actions; view.selected = selected }
    static func dismantleNSView(_ view: Surface, coordinator: ()) { view.stopMonitoring() }

    final class Surface: NSView, NSMenuDelegate {
        var actions: [SidebarContextAction] = []
        var selected = false
        private var showingMenu = false
        private var handlers: [Int: () -> Void] = [:]
        private var keyMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
            guard window != nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.keyCode == 110 || (event.keyCode == 109 && event.modifierFlags.contains(.shift)),
                      self.selected, !self.showingMenu, event.window === self.window, self.window?.attachedSheet == nil,
                      !(self.window?.firstResponder is NSTextView), !(self.window?.firstResponder is NSTextField) else { return event }
                self.handlers.removeAll()
                let menu = self.makeMenu(self.actions)
                menu.delegate = self
                menu.popUp(positioning: nil, at: NSPoint(x: self.bounds.minX, y: self.bounds.maxY), in: self)
                return nil
            }
        }

        func stopMonitoring() { if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil } }

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

        private func makeMenu(_ actions: [SidebarContextAction]) -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for action in actions {
                if action.separatorBefore { menu.addItem(.separator()) }
                let item = NSMenuItem(title: action.title, action: #selector(runAction(_:)), keyEquivalent: "")
                item.target = self
                item.tag = handlers.count
                handlers[item.tag] = action.run
                item.isEnabled = action.enabled
                item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
                if !action.children.isEmpty { item.submenu = makeMenu(action.children) }
                if action.destructive {
                    item.attributedTitle = NSAttributedString(string: action.title, attributes: [.foregroundColor: NSColor.systemRed])
                }
                menu.addItem(item)
            }
            return menu
        }

        private func openMenu(with event: NSEvent) {
            handlers.removeAll()
            let menu = makeMenu(actions)
            menu.delegate = self
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        @objc private func runAction(_ sender: NSMenuItem) { handlers[sender.tag]?() }

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
