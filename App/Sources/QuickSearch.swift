import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: Global hotkey

/// A key + modifiers, stored in Carbon terms (what RegisterEventHotKey wants) with a display string.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var key: String

    /// ⇧⌘Space by default: free in macOS and most apps (a global ⌘K would take ⌘K from every app). The same key
    /// opens the palette in Triwarden's own window; there is no separate in-app key.
    static let paletteDefault = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey), key: "Space")

    /// Each key on its own, for keycaps: ⌃ ⌥ ⇧ ⌘ then the key.
    var parts: [String] {
        var out: [String] = []
        if modifiers & UInt32(controlKey) != 0 { out.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { out.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { out.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { out.append("⌘") }
        return out + [key]
    }

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }

    /// From a key-down event; nil unless ⌘, ⌥ or ⌃ is held (a bare letter would make typing impossible).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        guard carbon != 0 else { return nil }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        let names: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫",
                                    kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→"]
        let key = names[Int(event.keyCode)] ?? (event.charactersIgnoringModifiers ?? "").uppercased()
        guard !key.isEmpty else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: carbon, key: key)
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.key = key
    }

    /// The shortcut for `action`, or nil when it's off. Unset, the action's default applies.
    static func current(for action: GlobalAction) -> Shortcut? {
        guard let data = UserDefaults.standard.data(forKey: action.defaultsKey) else { return action.defaultShortcut }
        return data.isEmpty ? nil : try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    static func set(_ shortcut: Shortcut?, for action: GlobalAction) {
        let data = shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data() // empty = turned off
        UserDefaults.standard.set(data, forKey: action.defaultsKey)
    }
}

/// What a system-wide shortcut does. Each has its own Carbon hotkey id.
enum GlobalAction: String, CaseIterable, Identifiable {
    case palette, fill, showWindow, generate, lock

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .palette: "Command palette"
        case .fill: "Fill this page or app"
        case .showWindow: "Show Triwarden"
        case .generate: "Copy a new password"
        case .lock: "Lock vault"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .palette: "Search everything, run any command. Over a browser or an app, its logins come first."
        case .fill: "Types the login for the page or app you're in. With more than one (or none), the palette opens."
        case .showWindow: "Brings the vault window forward."
        case .generate: "With your generator settings, straight to the clipboard."
        case .lock: "Locks every account."
        }
    }

    var defaultShortcut: Shortcut? {
        switch self {
        case .palette: .paletteDefault
        case .fill: Shortcut(keyCode: UInt32(kVK_ANSI_Backslash), modifiers: UInt32(cmdKey | optionKey), key: "\\")
        case .showWindow, .generate, .lock: nil
        }
    }

    var hotKeyID: UInt32 { UInt32(Self.allCases.firstIndex(of: self)! + 1) }

    fileprivate var defaultsKey: String { self == .palette ? "paletteShortcut" : "shortcut." + rawValue }
}

/// System-wide shortcuts. Carbon hotkeys work in the sandbox and need no Accessibility permission; one handler
/// serves them all, by id.
@MainActor
final class HotKeys {
    static let shared = HotKeys()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var shortcuts: [UInt32: Shortcut] = [:]
    private var handler: EventHandlerRef?

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            let id = hotKey.id
            MainActor.assumeIsolated { HotKeys.shared.actions[id]?() }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    /// Sets what `action` does and binds its saved shortcut.
    func install(_ action: GlobalAction, perform: @escaping () -> Void) {
        actions[action.hotKeyID] = perform
        bind(Shortcut.current(for: action), to: action)
    }

    /// Binds `shortcut` (nil = none) to `action`; false when another app already owns it (the old one stays).
    @discardableResult
    func bind(_ shortcut: Shortcut?, to action: GlobalAction) -> Bool {
        let id = action.hotKeyID
        let old = shortcuts[id]
        unbind(id)
        guard let shortcut else { return true }
        if register(shortcut, id: id) { return true }
        if let old { _ = register(old, id: id) }
        return false
    }

    /// Lets go of every shortcut (while Settings records a new one) and takes them back.
    func pause() { for id in Array(refs.keys) { if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) } } }
    func resume() { for (id, shortcut) in shortcuts where refs[id] == nil { _ = register(shortcut, id: id) } }

    /// Whether `shortcut` is already bound to a different action of ours.
    func owner(of shortcut: Shortcut) -> GlobalAction? {
        GlobalAction.allCases.first { shortcuts[$0.hotKeyID] == shortcut }
    }

    private func register(_ shortcut: Shortcut, id: UInt32) -> Bool {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: OSType(0x5457_4B59), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        shortcuts[id] = shortcut
        return true
    }

    private func unbind(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        shortcuts[id] = nil
    }
}

// MARK: Panel

/// A floating, borderless panel that can take key focus without activating a full window.
final class QuickSearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class QuickSearchController {
    private var panel: QuickSearchPanel?
    private let model: AppModel
    private var resignObserver: NSObjectProtocol?
    private var closing: Task<Void, Never>?
    /// Waiting to see whether losing the keyboard was the system Fill a password sheet.
    private var resignWatch: Task<Void, Never>?
    /// The palette stays up under that sheet, then takes the keyboard back when the sheet goes.
    private var holdingForFill = false
    private var fillWatch: Task<Void, Never>?
    private var preferredSize: CGSize?
    /// The card's height when the palette opens (the empty query), so the next open centers that card.
    private var openingHeight: CGFloat?
    /// Set by show(): the first fit after it centers the card on this area, if the height turned out different.
    private var openingArea: NSRect?
    /// Where the controller last put the top edge's middle. If the panel's differs at close, the user dragged it.
    private var placedAnchor: NSPoint?
    /// Shrink and grow share one ease. `animator().setFrame` only visibly grows a clear panel.
    private var frameTarget: NSRect?
    private var frameTimer: Timer?

    init(model: AppModel) { self.model = model }

    func toggle() {
        if passwordFillOnScreen() { return }
        if let panel, panel.isVisible, closing == nil { close() } else { show() }
    }

    /// Builds the panel ahead of time, so the first shortcut opens it as fast as every later one.
    func prepare() {
        guard panel == nil else { return }
        let panel = makePanel()
        self.panel = panel
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    func show() {
        // Called from another app: note it (and its page) before we take focus. From our own window there is no
        // detour to return from.
        let fromOwnWindow = NSApp.isActive && NSApp.keyWindow?.canBecomeMain == true
        if fromOwnWindow { model.foreground = nil } else { model.captureForeground() }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Follow the app's Appearance setting, not just the system's.
        panel.appearance = AppearanceSetting.current.nsAppearance
        place(panel)
        closing?.cancel(); closing = nil
        panel.ignoresMouseEvents = false
        // Over another app the panel takes the keyboard without activating Triwarden (it's a non-activating panel,
        // like Spotlight): activating would be slower and would bring the vault window forward too.
        if fromOwnWindow { NSApp.activate() }
        panel.makeKeyAndOrderFront(nil)
        model.quickSearchNonce += 1 // resets query and focuses the field
        // If the reset left the card's height unchanged, no fit arrives; don't let the first keystroke recenter it.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.openingArea = nil
        }
    }

    /// Returns once the panel is gone (now, if it isn't closing).
    func waitUntilClosed() async { await closing?.value }

    /// The palette shrinks back to the top and fades (see CommandPalette), then the panel hides.
    func close() {
        guard let panel, panel.isVisible, closing == nil else { return }
        rememberDraggedPosition(of: panel)
        resignWatch?.cancel(); resignWatch = nil
        fillWatch?.cancel(); fillWatch = nil
        holdingForFill = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.ignoresMouseEvents = true
        model.quickSearchDismissNonce += 1
        closing = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(110)) // the palette's fade-out (0.1 s), then gone
            guard !Task.isCancelled, let self else { return }
            self.panel?.orderOut(nil)
            self.closing = nil
        }
    }

    private func makePanel() -> QuickSearchPanel {
        let panel = QuickSearchPanel(contentRect: NSRect(x: 0, y: 0, width: 704, height: 660),
                                     styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                                     backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        // Above menu bar extras (status-bar level) so it never opens underneath one, like Spotlight.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true // the native shadow follows the tightly fitted, rounded content
        panel.isMovableByWindowBackground = true
        // Not hidesOnDeactivate: that hides it at once. Losing key to another window, the desktop, or another app
        // closes it through close(), so it plays its way out. The system Fill a password sheet is the exception:
        // choosing Triwarden… or Passwords… on the master-password field opens that sheet, and the palette stays.
        panel.hidesOnDeactivate = false
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.notePaletteResignKey() }
        }
        let hosting = NSHostingView(rootView: CommandPalette(close: { [weak self] in self?.close() },
            sizeChanged: { [weak self] size in self?.resizePanel(to: size) })
            .environment(model)
            .modifier(LiveAppearance())
            .tracksWindowVisibility()) // the palette stays built while it's hidden, its highlighted row too
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 22
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting
        return panel
    }

    /// Fit the window to the visible card. A fixed transparent canvas also gets dimmed by AppKit sheets.
    private func resizePanel(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let firstFit = preferredSize == nil
        preferredSize = size
        guard let panel, panel.attachedSheet == nil, !holdingForFill else { return }
        let frame = panel.frame
        // The first fit after opening is the empty query's card: center that one, and remember its height.
        let opening = openingArea
        if opening != nil { openingArea = nil; openingHeight = size.height }
        guard abs(frame.width - size.width) > 0.5 || abs(frame.height - size.height) > 0.5 else { return }
        // Otherwise keep the top edge (the search field) where it is, so the results grow and shrink below it.
        var rect = if let opening {
            NSRect(x: opening.midX - size.width / 2, y: opening.midY - size.height / 2, width: size.width, height: size.height)
        } else {
            NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height)
        }
        if let bounds = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            rect.origin.x = min(max(rect.origin.x, bounds.minX), max(bounds.minX, bounds.maxX - rect.width))
            rect.origin.y = min(max(rect.origin.y, bounds.minY), max(bounds.minY, bounds.maxY - rect.height))
        }
        // The first measurement just replaces the placeholder. Later changes ease in both directions.
        if opening != nil { placedAnchor = NSPoint(x: rect.midX, y: rect.maxY) }
        let ease = panel.isVisible && !firstFit && opening == nil && Motion.plays && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if ease {
            easeFrame(of: panel, to: rect)
        } else {
            frameTimer?.invalidate()
            frameTimer = nil
            frameTarget = nil
            panel.setFrame(rect, display: true)
            panel.invalidateShadow()
        }
    }

    /// Step toward the latest size. A clear panel shows a shrink only when the frame itself moves each tick.
    private func easeFrame(of panel: NSPanel, to target: NSRect) {
        frameTarget = target
        guard frameTimer == nil else { return }
        frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            let done = MainActor.assumeIsolated { () -> Bool in
                guard let self, let panel = self.panel, let target = self.frameTarget else { return true }
                let current = panel.frame
                let dx = target.minX - current.minX
                let dy = target.minY - current.minY
                let dw = target.width - current.width
                let dh = target.height - current.height
                if abs(dw) < 0.5, abs(dh) < 0.5, abs(dx) < 0.5, abs(dy) < 0.5 {
                    panel.setFrame(target, display: true)
                    panel.invalidateShadow()
                    self.frameTimer = nil
                    self.frameTarget = nil
                    return true
                }
                panel.setFrame(NSRect(x: current.minX + dx * 0.28,
                                      y: current.minY + dy * 0.28,
                                      width: current.width + dw * 0.28,
                                      height: current.height + dh * 0.28), display: true)
                return false
            }
            if done { timer.invalidate() }
        }
    }

    /// Where the palette opens: where the user last dragged it (with Remember position on), otherwise centered on
    /// the screen under the pointer.
    private func place(_ panel: NSPanel) {
        let size = CGSize(width: preferredSize?.width ?? panel.frame.width,
                          height: openingHeight ?? preferredSize?.height ?? panel.frame.height)
        if UserDefaults.standard.bool(forKey: Pref.rememberPalettePosition), let anchor = Self.savedAnchor,
           let screen = NSScreen.screens.first(where: { NSMouseInRect(NSPoint(x: anchor.x, y: anchor.y - 1), $0.visibleFrame, false) }) {
            openingArea = nil
            setFrame(of: panel, NSRect(x: anchor.x - size.width / 2, y: anchor.y - size.height, width: size.width, height: size.height),
                     within: screen.visibleFrame)
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? panel.frame
        openingArea = area
        setFrame(of: panel, NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height),
                 within: area)
    }

    private func setFrame(of panel: NSPanel, _ rect: NSRect, within bounds: NSRect) {
        var rect = rect
        rect.origin.x = min(max(rect.origin.x, bounds.minX), max(bounds.minX, bounds.maxX - rect.width))
        rect.origin.y = min(max(rect.origin.y, bounds.minY), max(bounds.minY, bounds.maxY - rect.height))
        frameTimer?.invalidate(); frameTimer = nil; frameTarget = nil
        panel.setFrame(rect, display: false)
        placedAnchor = NSPoint(x: rect.midX, y: rect.maxY)
    }

    /// The top edge's middle, in screen coordinates: the top stays put while the results change, so that is the spot.
    private static var savedAnchor: NSPoint? {
        guard let value = UserDefaults.standard.string(forKey: Pref.palettePosition) else { return nil }
        let parts = value.split(separator: ",").compactMap { Double($0) }
        return parts.count == 2 ? NSPoint(x: parts[0], y: parts[1]) : nil
    }

    /// Only a drag counts: a palette that was never moved keeps opening on the screen under the pointer.
    private func rememberDraggedPosition(of panel: NSPanel) {
        guard UserDefaults.standard.bool(forKey: Pref.rememberPalettePosition), let placedAnchor else { return }
        let anchor = NSPoint(x: panel.frame.midX, y: panel.frame.maxY)
        guard hypot(anchor.x - placedAnchor.x, anchor.y - placedAnchor.y) > 2 else { return }
        UserDefaults.standard.set("\(anchor.x),\(anchor.y)", forKey: Pref.palettePosition)
    }

    /// AppKit can attach the password sheet before its service has an on-screen window.
    private func passwordFillOnScreen() -> Bool {
        panel?.attachedSheet != nil || Self.passwordFillServiceOnScreen()
    }

    /// Give the system sheet time to attach before treating focus loss as dismissal.
    private func notePaletteResignKey() {
        guard let panel, panel.isVisible, !panel.isKeyWindow, closing == nil, !holdingForFill else { return }
        if passwordFillOnScreen() {
            holdWhilePasswordFillIsUp()
            return
        }
        resignWatch?.cancel()
        resignWatch = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled,
                      let panel = self.panel, panel.isVisible, !panel.isKeyWindow, self.closing == nil else { return }
                if self.passwordFillOnScreen() {
                    self.holdWhilePasswordFillIsUp()
                    return
                }
            }
            self.close()
        }
    }

    /// Keep the parent visible while the sheet owns focus, then restore the same palette without resetting its query.
    private func holdWhilePasswordFillIsUp() {
        guard !holdingForFill else { return }
        holdingForFill = true
        resignWatch?.cancel()
        panel?.level = .normal
        fillWatch?.cancel()
        fillWatch = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.passwordFillOnScreen() {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
            }
            self.holdingForFill = false
            guard let panel = self.panel, panel.isVisible, self.closing == nil else { return }
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            if let size = self.preferredSize { self.resizePanel(to: size) }
            // A nonactivating panel returns to its original foreground app when the sheet closes.
            // That return is expected; only a different app should dismiss the palette.
            let front = NSWorkspace.shared.frontmostApplication
            let returnedToContext = front?.processIdentifier == self.model.foreground?.pid
            if Self.anotherAppTookFocus() && !returnedToContext {
                self.close()
            } else {
                panel.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// A normal app (or the desktop) is in front, rather than the system password sheet.
    private static func anotherAppTookFocus() -> Bool {
        guard !NSApp.isActive else { return false }
        let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        return !id.isEmpty && id != Bundle.main.bundleIdentifier && !passwordFillBundles.contains(id)
    }

    private static let passwordFillBundles: Set<String> = [
        "com.apple.AutoFillPanelService",
        "com.apple.Passwords",
    ]

    /// The Fill a password sheet is on screen. The service process stays running with no window, so a live window counts.
    private static func passwordFillServiceOnScreen() -> Bool {
        let pids = Set(passwordFillBundles.flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).map(\.processIdentifier)
        })
        guard !pids.isEmpty,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        return info.contains { dict in
            guard let pid = (dict[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pids.contains(pid),
                  let bounds = dict[kCGWindowBounds as String] as? NSDictionary,
                  let width = bounds["Width"] as? CGFloat, let height = bounds["Height"] as? CGFloat
            else { return false }
            return width > 80 && height > 80
        }
    }
}
