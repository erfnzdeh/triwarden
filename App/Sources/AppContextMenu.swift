import AppKit
import SwiftUI

extension View {
    /// Use the same compact material surface for right-click and toolbar actions.
    func appContextMenu(_ entries: [ActionMenuEntry], keyboardTarget: Bool = false) -> some View {
        modifier(AppContextMenuModifier(entries: entries, keyboardTarget: keyboardTarget))
    }
}

private extension ActionMenuEntry {
    var accessibleLeaves: [ActionMenuEntry] {
        children.isEmpty ? (enabled && !heading ? [self] : []) : children.flatMap(\.accessibleLeaves)
    }
}

private struct AppContextMenuModifier: ViewModifier {
    let entries: [ActionMenuEntry]
    let keyboardTarget: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.background { ContextMenuSurface(entries: entries, keyboardTarget: keyboardTarget, scheme: scheme) }
            .accessibilityActions {
                ForEach(Array(entries.flatMap(\.accessibleLeaves).enumerated()), id: \.offset) { _, entry in
                    Button(entry.title, action: entry.run)
                }
            }
    }
}

private struct ContextMenuSurface: NSViewRepresentable {
    let entries: [ActionMenuEntry]
    let keyboardTarget: Bool
    let scheme: ColorScheme

    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ view: Surface, context: Context) {
        view.entries = entries
        view.keyboardTarget = keyboardTarget
        view.scheme = scheme
    }
    static func dismantleNSView(_ view: Surface, coordinator: ()) { view.stop() }

    final class Surface: NSView, NSPopoverDelegate {
        var entries: [ActionMenuEntry] = []
        var keyboardTarget = false
        var scheme: ColorScheme = .light
        private var popover: NSPopover?
        private var keyMonitor: Any?

        // Stay out of SwiftUI's hover hit-testing; observe only context-menu events in our bounds.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .rightMouseDown, .leftMouseDown]) { [weak self] event in
                guard let self, event.window === self.window, self.popover == nil,
                      self.window?.attachedSheet == nil, !self.isHiddenOrHasHiddenAncestor else { return event }
                if event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) {
                    let point = self.convert(event.locationInWindow, from: nil)
                    guard self.visibleRect.contains(point), !self.entries.isEmpty else { return event }
                    self.open(at: point)
                    return nil
                }
                guard event.type == .keyDown, self.keyboardTarget,
                      event.keyCode == 110 || (event.keyCode == 109 && event.modifierFlags.contains(.shift)),
                      !(self.window?.firstResponder is NSTextView), !(self.window?.firstResponder is NSTextField) else { return event }
                self.open(at: NSPoint(x: self.bounds.midX, y: self.bounds.midY))
                return nil
            }
        }

        private func open(at point: NSPoint) {
            guard window != nil, !entries.isEmpty else { return }
            popover?.performClose(nil)
            let panel = NSPopover()
            let content = ActionMenuContents(entries: entries, close: { [weak self] in self?.popover?.performClose(nil) })
                .environment(\.colorScheme, scheme)
            let host = NSHostingController(rootView: content)
            host.sizingOptions = .preferredContentSize
            panel.contentViewController = host
            panel.behavior = .transient
            panel.animates = ActionMenuPresentation.animates
            panel.delegate = self
            popover = panel
            panel.show(relativeTo: NSRect(x: point.x, y: point.y, width: 1, height: 1), of: self, preferredEdge: .maxX)
            needsDisplay = true
        }

        func popoverDidClose(_ notification: Notification) { popover = nil; needsDisplay = true }

        func stop() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
            popover?.performClose(nil)
            popover = nil
        }

        override func draw(_ dirtyRect: NSRect) {
            guard popover?.isShown == true else { return }
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
    }
}
