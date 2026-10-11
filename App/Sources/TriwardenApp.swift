import SwiftUI
import TipKit
import UserNotifications
import VaultwardenAPI

@main
struct TriwardenApp: App {
    @State private var model = AppModel()
    @AppStorage(Pref.appearance) private var appearance = AppearanceSetting.system
    @AppStorage(Pref.showMenuBar) private var showMenuBar = true
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    init() {
        Pref.register()
        // Tips (the vault search's, once): not in renders, self-tests or benchmarks, which must look the same every run.
        if !CommandLine.arguments.contains(where: { $0 == "--snapshot" || $0.hasPrefix("--selftest") || $0.hasPrefix("--bench") }),
           !Bench.on {
            try? Tips.configure()
        }
        // One window with its own toolbar: no system tab bar (and no View › Show Tab Bar to turn it on).
        NSWindow.allowsAutomaticWindowTabbing = false
        #if DEBUG
        Bench.runUnlockIfRequested()
        Snapshot.runIfRequested()
        SelfTest.runIfRequested()
        CloudSelfTest.runIfRequested()
        // `--demo`: open straight into the vault with demo items, for UI review. `--demo-full`: a lived-in vault of
        // 200+ items in folders, for screenshots.
        let full = CommandLine.arguments.contains("--demo-full")
        if full || CommandLine.arguments.contains("--demo") {
            let demo = AppModel()
            demo.items = full ? DemoVault.items : Snapshot.demoItems
            if full {
                demo.folders = DemoVault.folders
                demo.organizations = DemoVault.organizations
                IconStore.shared.fallbackEnvironment = .bitwardenUS // real site icons, from Bitwarden's public service
            }
            // An in-memory account only: demo/UI-test runs never show or touch the real saved accounts.
            demo.setPreviewAccounts([SavedAccount(id: "demo", email: "alex@example.com", serverKind: "selfHosted",
                                                  serverURL: "https://vault.home.arpa", kdf: .pbkdf2(iterations: 600_000),
                                                  protectedUserKey: "")])
            demo.previewUnlocked = true
            demo.phase = .vault
            _model = State(initialValue: demo)
            DemoShots.runIfRequested(demo)
        }
        #endif
    }

    private let services = ServicesProvider()

    var body: some Scene {
        // One vault window: reopening (menu bar, palette, Dock, opening the app again) brings this one back.
        Window("Triwarden", id: AppModel.mainWindowID) {
            // No window-wide tint: a tint colours menu icons, and a highlighted row would then hide its own icon.
            // System controls take the neutral global accent (ControlAccent); the app's switches set their own.
            RootView()
                .environment(model)
                .preferredColorScheme(appearance.scheme)
                .onAppear { appDelegate.model = model; Bench.markAfterCommit("first-frame") }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.appDidBecomeActive()
                }
                .onAppear {
                    NSApp.servicesProvider = services
                    NSUpdateDynamicServices()
                    model.startAutoLock()
                    CaptureShield.start()
                }
                // Soft pastel wash from the Liquid design under every screen.
                .containerBackground(for: .window) { WindowBackdrop() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 720)

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarContent()
                .environment(model)
        } label: {
            Image(nsImage: MenuBarGlyph.image(pending: model.sshAgent.pendingCount > 0))
                .opacity(model.isUnlocked ? 1 : 0.55)
        }
        .menuBarExtraStyle(.window)

        Window("Triwarden", id: LicenseReminderView.windowID) {
            LicenseReminderView()
                .environment(model)
                .preferredColorScheme(appearance.scheme)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(appearance.scheme)
        }
        .defaultSize(width: 820, height: 640)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Login") { model.beginEditing(EditRequest(mode: .create(.login))) }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(!model.isUnlocked)
                Button("New Secure Note") { model.beginEditing(EditRequest(mode: .create(.secureNote))) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!model.isUnlocked)
                Menu("New Other Item") {
                    Button("Card") { model.beginEditing(EditRequest(mode: .create(.card))) }
                    Button("Identity") { model.beginEditing(EditRequest(mode: .create(.identity))) }
                    Button("SSH Key") { model.beginEditing(EditRequest(mode: .create(.sshKey))) }
                }
                .disabled(!model.isUnlocked)
                Button("New Folder…") { model.promptNewFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                    .disabled(!model.isUnlocked)
                Divider()
                Button("Add Account…") { model.beginAddAccount() }
                    .disabled(!model.isUnlocked)
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { model.updates.checkForUpdates() }
                    .disabled(!model.updates.canCheck)
                if model.license.isConfigured && !model.license.isRegistered {
                    Button("Buy License…") { model.showSettings(.license) }
                }
            }
            CommandGroup(replacing: .importExport) {
                Button("Import…") { model.beginImport() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(model.sessions.isEmpty)
                Button("Export Vault…") { model.beginExport() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.sessions.isEmpty)
            }
            CommandMenu("Item") {
                let item = model.selectedItem
                Button("Edit") { if let item { model.guarded(item) { model.beginEditing(EditRequest(mode: .edit(item))) } } }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(item == nil || item?.isDeleted == true)
                Divider()
                Button("Copy Username") { if let u = item?.username { model.copy(u, label: String(localized: "Username")) } }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(item?.kind != .login || item?.username == nil)
                Button("Copy Password") { if let item { model.copyPassword(item) } }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                    .disabled(item?.password == nil)
                Button("Copy One-Time Code") { if let item, let t = item.totp { model.guarded(item) { model.copy(t.code(), label: String(localized: "Code")) } } }
                    .keyboardShortcut("c", modifiers: [.command, .control])
                    .disabled(item?.totp == nil)
                Button("Show Password in Large Type") { if let item { model.showLargeType(item) } }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                    .disabled(item?.password == nil)
                Divider()
                Button("Toggle Favorite") { if let item { Task { await model.toggleFavorite(item) } } }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(item == nil || item?.isDeleted == true)
                Button(item?.isArchived == true ? "Unarchive" : "Archive") {
                    if let item { Task { await model.setArchived(item, !item.isArchived) } }
                }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(item == nil || item?.isDeleted == true)
                Button("Move to Trash…") { if let item { model.confirmTrash(item) } }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(item == nil || item?.isDeleted == true)
            }
            CommandGroup(replacing: .help) {
                Button("Triwarden Help") { model.showHelp() }
                    .keyboardShortcut("?", modifiers: .command)
                Divider()
                Button("Command Palette") { model.openPalette() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Keyboard Shortcuts") { model.showShortcuts() }
                    .keyboardShortcut("/", modifiers: [.control, .shift])
            }
            CommandGroup(after: .appSettings) {
                Button("Lock Vault") { model.lock(animated: true) }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(!model.isUnlocked)
            }
        }
    }
}

/// Help › Triwarden Help (⌘?), Command Palette (⌘K) and Keyboard Shortcuts (⌃⇧/).
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The login and lock screens leave like a vault's inner gate: split along the middle, halves retracting up and down.
    private var gate: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .opacity,
                                              removal: .modifier(active: GateSplit(progress: 1), identity: GateSplit(progress: 0)))
    }

    /// Into the vault: the gate's heavy ease. Locking: the gate closing. Elsewhere: smooth, nothing wobbles into place.
    private var phaseAnimation: Animation {
        if model.phase.id == AppModel.Phase.vault.id { return .easeInOut(duration: 0.75) }
        return .smooth(duration: 0.45)
    }

    var body: some View {
        @Bindable var model = model
        ZStack {
            switch model.phase {
            case .login, .twoFactor, .deviceVerification, .ssoPassword:
                LoginView()
                    .frame(minWidth: 380, idealWidth: 920, maxWidth: .infinity, minHeight: 560, idealHeight: 640, maxHeight: .infinity)
                    .transition(gate)
                    .zIndex(1) // the gate opens over the vault
            case .locked, .vault:
                // Signed in: the vault is always the window; while locked, the lock lies over it as one layer.
                VaultView(initialSelection: DemoLaunch.item, initialSection: DemoLaunch.section)
                    .frame(minWidth: 380, idealWidth: 1120, minHeight: 520, idealHeight: 720)
                    // No blur or scaling of its own behind the lock (the lock's frosted layer blurs it): a blur would lay
                    // it out under the title bar, and it would jump into place on unlock.
                    // From login it's simply already there under the gate: no fade (a gap would show) and no blur or scale.
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
                    .zIndex(0)
            }
        }
        // The lock lies over the window as an overlay (not a sibling): it reaches under the title bar without
        // stretching the vault's layout there, so nothing moves when it lifts.
        .overlay {
            // The whole vault locked, or one locked account picked while the others are open.
            if model.phase.id == AppModel.Phase.locked.id || model.accountDoor != nil {
                UnlockView()
                    // Appears and leaves at once: when animated, the gate's plates cover it while it does. An account's
                    // door fades in and out (switching to it, or leaving it for all accounts).
                    .transition(reduceMotion || model.accountDoor != nil ? .opacity : .identity)
            }
        }
        // The gate: plates over everything, only while they move (locking and unlocking).
        .overlay {
            if model.gate != nil { GatePlates() }
        }
        .overlay {
            if model.helpScrim {
                HelpScrim { model.dismissHelpPanels() }
            }
        }
        .background { MainWindowAnchor() }
        .onChange(of: model.showingShortcuts) { _, show in
            guard show else { return }
            model.showingShortcuts = false
            model.showShortcuts()
        }
        .animation(phaseAnimation, value: model.phase.id)
        .onAppear {
            model.openSettingsAction = { openSettings() }
            model.openMainWindowAction = { openWindow(id: AppModel.mainWindowID) }
            model.windowDidOpen()
            // Fork-style: an unregistered official build asks now and then at launch, in a window of its own.
            if model.license.takeReminder() {
                Task { try? await Task.sleep(for: .seconds(1)); openWindow(id: LicenseReminderView.windowID) }
            }
        }
        // Every destructive action asks here first.
        .confirmationDialog(model.confirming?.title ?? "", isPresented: Binding(
            get: { model.confirming != nil }, set: { if !$0 { model.confirming = nil } }), presenting: model.confirming) { request in
            Button(request.action, role: .destructive) { Task { await request.run() } }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(request.message)
        }
    }
}

extension Color {
    /// Brand blue, shared with the app icon (Assets: AccentColor, adapts to dark mode).
    static let brand = Color("AccentColor")
    /// What system controls are tinted with — menu highlights and icons, pickers, switches, sliders, the Settings
    /// sidebar: a neutral graphite (Assets: ControlAccent), so no icon or label turns blue. The brand blue is only ever
    /// a fill the app draws on purpose: primary buttons, the vault's selection, header tiles.
    static let controlTint = Color("ControlAccent")
}

extension EnvironmentValues {
    /// True inside the gate's moving halves: animated content holds still there.
    @Entry var gatePassing = false
}

/// The gate: while opening, the screen is drawn as two halves, the top one sliding up and the bottom one down, each
/// casting a shadow from its edge. Closed, it's just the screen. Animatable, so the halves move every frame.
struct GateSplit: ViewModifier, Animatable {
    var progress: CGFloat
    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        if progress <= 0.001 {
            content
        } else {
            GeometryReader { geo in
                let travel = geo.size.height / 2 + 60
                ZStack {
                    half(content, top: true, height: geo.size.height)
                        .offset(y: -progress * travel)
                    half(content, top: false, height: geo.size.height)
                        .offset(y: progress * travel)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func half(_ content: Content, top: Bool, height: CGFloat) -> some View {
        content
            // While the gate moves the door holds still in each half (it's at rest then anyway): its drawing doesn't
            // change, so SwiftUI keeps the rendered layers and only moves them. (No drawingGroup: it can't draw the
            // password field and other AppKit-backed views.)
            .environment(\.gatePassing, true)
            .mask(alignment: top ? .top : .bottom) { Rectangle().frame(height: height / 2) }
            .overlay(alignment: .top) {
                // The gate's edge: a dark seam with a thin highlight inside, so the halves read as heavy plates.
                VStack(spacing: 0) {
                    if !top { Rectangle().fill(.black.opacity(0.22)).frame(height: 2) }
                    Rectangle().fill(.white.opacity(0.4)).frame(height: 1)
                    if top { Rectangle().fill(.black.opacity(0.22)).frame(height: 2) }
                }
                .offset(y: top ? height / 2 - 3 : height / 2)
            }
            .shadow(color: .black.opacity(0.35 * Double(min(progress * 3, 1))), radius: 22, y: top ? 14 : -14)
    }
}


/// Wrapper so @AppStorage can drive preferredColorScheme.
enum AppearanceSetting: String {
    case system, light, dark
    var scheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

/// `--demo` extras for screenshots: `--demo-section codes|generator|watchtower|sends` opens that page,
/// `--demo-item <id>` selects a demo item. Nil in release builds and normal runs.
enum DemoLaunch {
    static var section: SidebarSelection? {
        #if DEBUG
        switch value(after: "--demo-section") {
        case "codes": return .codes
        case "generator": return .generator
        case "watchtower": return .watchtower
        case "sends": return .sends
        default: return nil
        }
        #else
        return nil
        #endif
    }

    static var item: VaultItem.ID? {
        #if DEBUG
        return value(after: "--demo-item")
        #else
        return nil
        #endif
    }

    private static func value(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let at = args.firstIndex(of: flag), at + 1 < args.count else { return nil }
        return args[at + 1]
    }
}

/// Opening Triwarden again (Finder, Spotlight, the Dock) while it waits in the menu bar brings the vault window back.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private let sshNotifications = SSHNotificationBridge()

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows, let model else { return true }
        model.bringToFront()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = sshNotifications
        NotificationCenter.default.addObserver(self, selector: #selector(revealSSHApproval),
                                               name: .sshApprovalReveal, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(revealInbox),
                                               name: .inboxReveal, object: nil)
        // The last window closing: with "Keep running in the menu bar" on, Triwarden leaves the Dock.
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: nil)
    }

    @objc private func revealSSHApproval() {
        model?.sshAgent.reveal()
    }

    @objc private func revealInbox() {
        model?.revealInbox()
    }

    @objc private func windowWillClose(_ note: Notification) {
        model?.windowWillClose(note.object as? NSWindow)
    }
}
