import AppKit
import SwiftUI

extension View {
    /// Right-click and the context-menu key use a native menu. Rows use the same neutral colours as the toolbar menus.
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

    final class Surface: NSView, NSMenuDelegate {
        var entries: [ActionMenuEntry] = []
        var keyboardTarget = false
        var scheme: ColorScheme = .light
        private var showingMenu = false
        private var highlighted: NSMenuItem?
        private var keyMonitor: Any?

        // Stay out of SwiftUI's hover hit-testing; observe only context-menu events in our bounds.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .rightMouseDown, .leftMouseDown]) { [weak self] event in
                guard let self else { return event }
                // A custom row does not send the item action. Return while the menu is open runs the highlighted row.
                if self.showingMenu {
                    guard event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76,
                          let row = self.highlighted?.view as? ActionMenuRow,
                          row.entry.enabled, !row.entry.heading, row.entry.children.isEmpty else { return event }
                    row.activate()
                    return nil
                }
                guard event.window === self.window, self.window?.attachedSheet == nil,
                      !self.isHiddenOrHasHiddenAncestor else { return event }
                if event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) {
                    let point = self.convert(event.locationInWindow, from: nil)
                    guard self.visibleRect.contains(point), !self.entries.isEmpty,
                          self.isPreferredTarget(at: event.locationInWindow) else { return event }
                    self.open(with: event)
                    return nil
                }
                guard event.type == .keyDown, self.keyboardTarget,
                      event.keyCode == 110 || (event.keyCode == 109 && event.modifierFlags.contains(.shift)),
                      !(self.window?.firstResponder is NSTextView), !(self.window?.firstResponder is NSTextField) else { return event }
                self.open(at: NSPoint(x: self.bounds.minX, y: self.bounds.maxY))
                return nil
            }
        }

        /// SwiftUI can leave a full-pane background surface over smaller list and sidebar rows.
        /// Pick the smallest visible surface below the pointer, so the clicked row owns its menu.
        private func isPreferredTarget(at point: NSPoint) -> Bool {
            guard let root = window?.contentView else { return false }
            let candidates = Self.surfaces(in: root).enumerated().compactMap { index, surface -> (Surface, CGFloat, Int)? in
                guard !surface.entries.isEmpty, let rect = surface.visibleFrameInWindow,
                      rect.contains(point) else { return nil }
                return (surface, rect.width * rect.height, index)
            }
            let preferred = candidates.min { left, right in
                if abs(left.1 - right.1) > 0.5 { return left.1 < right.1 }
                return left.2 > right.2
            }?.0
            return preferred === self
        }

        private var visibleFrameInWindow: NSRect? {
            guard window != nil, !isHiddenOrHasHiddenAncestor else { return nil }
            let clipped = bounds.intersection(visibleRect)
            guard !clipped.isEmpty else { return nil }
            return convert(clipped, to: nil)
        }

        private static func surfaces(in view: NSView) -> [Surface] {
            (view as? Surface).map { [$0] } ?? view.subviews.flatMap(surfaces)
        }

        private func makeMenu(_ entries: [ActionMenuEntry]) -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.delegate = self
            menu.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            for entry in entries {
                if entry.separatorBefore { menu.addItem(.separator()) }
                if entry.heading {
                    let item = NSMenuItem()
                    item.view = ActionMenuRow(entry: entry, scheme: scheme)
                    item.isEnabled = false
                    menu.addItem(item)
                    continue
                }
                let item = NSMenuItem()
                item.view = ActionMenuRow(entry: entry, scheme: scheme)
                item.isEnabled = entry.enabled
                if !entry.children.isEmpty { item.submenu = makeMenu(entry.children) }
                menu.addItem(item)
            }
            return menu
        }

        private func open(with event: NSEvent) {
            let menu = makeMenu(entries)
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        private func open(at point: NSPoint) {
            let menu = makeMenu(entries)
            menu.popUp(positioning: nil, at: point, in: self)
        }

        func menuWillOpen(_ menu: NSMenu) { showingMenu = true; needsDisplay = true }
        func menuDidClose(_ menu: NSMenu) {
            // Closing a submenu leaves the menu it came from open.
            guard menu.supermenu == nil else { return }
            showingMenu = false
            highlighted = nil
            needsDisplay = true
        }
        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            highlighted = item
            menu.items.forEach { $0.view?.needsDisplay = true }
        }

        func stop() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        }

        override func draw(_ dirtyRect: NSRect) {
            guard showingMenu else { return }
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
    }
}

/// One native-menu row, drawn with the toolbar menu's colours: a neutral wash, red only for destructive actions.
private final class ActionMenuRow: NSView {
    let entry: ActionMenuEntry
    let scheme: ColorScheme

    init(entry: ActionMenuEntry, scheme: ColorScheme) {
        self.entry = entry
        self.scheme = scheme
        super.init(frame: NSRect(x: 0, y: 0, width: 268, height: entry.heading ? 22 : 28))
        toolTip = entry.title
        setAccessibilityLabel(entry.title)
    }

    required init?(coder: NSCoder) { nil }

    /// Menu items with a custom view never send their action. The row runs it after the menu has closed,
    /// so a click can present a sheet or change SwiftUI state.
    override func mouseUp(with event: NSEvent) { activate() }

    func activate() {
        guard entry.enabled, !entry.heading, entry.children.isEmpty else { return }
        let run = entry.run
        var menu = enclosingMenuItem?.menu
        while let parent = menu?.supermenu { menu = parent }
        menu?.cancelTracking()
        // The menu tracks in event-tracking mode. Default mode runs only once that loop has ended.
        RunLoop.main.perform(inModes: [.default]) { run() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = enclosingMenuItem?.isHighlighted == true && entry.enabled && !entry.heading
        if highlighted {
            let wash = scheme == .dark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.10)
            wash.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 8, yRadius: 8).fill()
        }
        if entry.heading {
            draw(entry.title, at: NSPoint(x: 12, y: 4), size: 11, weight: .semibold, color: .secondaryLabelColor)
            return
        }
        let color: NSColor = entry.destructive ? .systemRed : (highlighted ? .labelColor : .secondaryLabelColor)
        let titleColor: NSColor = entry.destructive ? .systemRed : .labelColor
        if !entry.symbol.isEmpty, let icon = Self.symbol(entry.symbol, tint: color) {
            let box = NSRect(x: 10, y: (bounds.height - 16) / 2, width: 16, height: 16)
            icon.draw(in: box, from: .zero, operation: .sourceOver, fraction: entry.enabled ? 1 : 0.4)
        }
        let trailing: String
        if !entry.children.isEmpty { trailing = "›" }
        else if entry.checked { trailing = "✓" }
        else { trailing = entry.shortcut }
        let reserved = trailing.isEmpty ? 12.0 : Double((trailing as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width) + 24
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        // A line is drawn from the top of the rect it is given, so an 18 pt rect under a 15.3 pt line left every
        // title sitting about 2 pt high and the symbol, centred on the row, looked low by that much. Give the title
        // exactly one line's height, then drop it a point below the row's middle: a cap-height-centred baseline puts
        // the glyphs' bounding box on the middle, but their ink sits high in that box (no descenders in most menu
        // words, and the crossbars and bowls of lower-case letters carry more weight than the caps), so measured by
        // where the eye sees the mass, a point lower is what reads as level with the symbol.
        let titleFont = NSFont.systemFont(ofSize: 13)
        let line = titleFont.ascender - titleFont.descender + titleFont.leading
        let baseline = bounds.midY - titleFont.capHeight / 2 + 1
        NSAttributedString(string: entry.title, attributes: [
            .font: titleFont,
            .foregroundColor: titleColor.withAlphaComponent(entry.enabled ? 1 : 0.4),
            .paragraphStyle: paragraph,
        ]).draw(in: NSRect(x: 34, y: baseline + titleFont.descender - titleFont.leading,
                           width: max(0, bounds.width - 34 - reserved), height: line))
        guard !trailing.isEmpty else { return }
        let text = NSAttributedString(string: trailing, attributes: [
            .font: NSFont.systemFont(ofSize: entry.children.isEmpty && !entry.checked ? 12 : 13, weight: entry.children.isEmpty ? .regular : .semibold),
            .foregroundColor: color,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.width - size.width - 12, y: (bounds.height - size.height) / 2))
    }

    /// `sourceIn` only shows a symbol where the row is already painted, so unhighlighted icons vanished.
    private static func symbol(_ name: String, tint: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return nil }
        let side: CGFloat = 16
        let painted = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            tint.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        painted.isTemplate = false
        return painted
    }

    private func draw(_ string: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ]).draw(at: point)
    }
}
