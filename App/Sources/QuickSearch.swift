import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: Global hotkey

/// A key + modifiers, stored in Carbon terms (what RegisterEventHotKey wants) with a display string.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var key: String

    /// ⇧⌘Space by default: free in macOS and most apps (a global ⌘K would take ⌘K from every app). In Triwarden's
    /// own window ⌘K opens the palette too.
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

    init(model: AppModel) { self.model = model }

    func toggle() {
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
        panel.appearance = switch Pref.colorScheme {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        default: nil
        }
        // Over the vault window when it's in front, else high on the screen.
        if NSApp.isActive, let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && $0 != panel }) {
            let f = window.frame
            panel.setFrameTopLeftPoint(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - 40))
        } else if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - f.height * 0.14))
        }
        closing?.cancel(); closing = nil
        panel.ignoresMouseEvents = false
        // Over another app the panel takes the keyboard without activating Triwarden (it's a non-activating panel,
        // like Spotlight): activating would be slower and would bring the vault window forward too.
        if fromOwnWindow { NSApp.activate() }
        panel.makeKeyAndOrderFront(nil)
        model.quickSearchNonce += 1 // resets query and focuses the field
    }

    /// Returns once the panel is gone (now, if it isn't closing).
    func waitUntilClosed() async { await closing?.value }

    /// The palette shrinks back to the top and fades (see CommandPalette), then the panel hides.
    func close() {
        guard let panel, panel.isVisible, closing == nil else { return }
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
        let panel = QuickSearchPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 660),
                                     styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                                     backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        // Above menu bar extras (status-bar level) so it never opens underneath one, like Spotlight.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false // the palette draws its own soft shadow
        panel.isMovableByWindowBackground = true
        // Not hidesOnDeactivate: that hides it at once. Losing key to another window, the desktop, or another app
        // closes it through close(), so it plays its way out. The system Fill a password sheet is the exception:
        // choosing Triwarden… or Passwords… on the master-password field opens that sheet, and the palette stays.
        panel.hidesOnDeactivate = false
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.notePaletteResignKey() }
        }
        panel.contentView = NSHostingView(rootView: CommandPalette(close: { [weak self] in self?.close() })
            .environment(model))
        return panel
    }

    /// The palette lost the keyboard. Close, unless the system password sheet is what took it.
    private func notePaletteResignKey() {
        guard let panel, panel.isVisible, !panel.isKeyWindow, closing == nil, !holdingForFill else { return }
        if let key = NSApp.keyWindow, key != panel {
            close()
            return
        }
        if Self.passwordFillOnScreen() {
            holdWhilePasswordFillIsUp()
            return
        }
        if Self.anotherAppTookFocus() {
            close()
            return
        }
        resignWatch?.cancel()
        resignWatch = Task { @MainActor in
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                guard let panel = self.panel, panel.isVisible, !panel.isKeyWindow, closing == nil else { return }
                if Self.passwordFillOnScreen() {
                    holdWhilePasswordFillIsUp()
                    return
                }
                if Self.anotherAppTookFocus() {
                    close()
                    return
                }
            }
            guard let panel = self.panel, panel.isVisible, !panel.isKeyWindow, closing == nil, !holdingForFill else { return }
            close()
        }
    }

    /// Stay visible under Fill a password. When that sheet closes, take the keyboard back.
    private func holdWhilePasswordFillIsUp() {
        guard !holdingForFill else { return }
        holdingForFill = true
        resignWatch?.cancel()
        // This panel sits above the menu bar. Drop it so the system sheet can cover it instead of the other way around.
        panel?.level = .normal
        Task { @MainActor in
            while Self.passwordFillOnScreen() {
                try? await Task.sleep(for: .milliseconds(200))
            }
            holdingForFill = false
            guard let panel, panel.isVisible, closing == nil else { return }
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            if Self.anotherAppTookFocus() {
                close()
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
    private static func passwordFillOnScreen() -> Bool {
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
