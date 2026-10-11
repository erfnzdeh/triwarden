import AppKit
import AuthenticationServices
import ServiceManagement
import SwiftUI
import SSHAgent
import UniformTypeIdentifiers

/// Settings with a sidebar, like System Settings: sections on the left, the chosen page on the right.
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        // Everyday first, then who and how it's protected, then the keys, the connection, the tools, and about.
        case general, accounts, security, shortcuts, server, developer, license, about
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .accounts: "Accounts"
            case .general: "General"
            case .shortcuts: "Shortcuts"
            case .security: "Security"
            case .developer: "Developer"
            case .server: "Server"
            case .license: "License"
            case .about: "About"
            }
        }
        var symbol: String {
            switch self {
            case .accounts: "person.2"
            case .general: "gearshape"
            case .shortcuts: "keyboard"
            case .security: "lock.shield"
            case .developer: "terminal"
            case .server: "server.rack"
            case .license: "checkmark.seal"
            case .about: "info.circle"
            }
        }
    }

    @Environment(AppModel.self) private var model
    /// The chosen pane's name (an older "account:<id>" means Accounts).
    static let paneKey = "settingsPane"
    @AppStorage(paneKey) private var paneRaw = Pane.general.rawValue

    private var selection: Binding<Pane?> {
        Binding(get: { paneRaw.hasPrefix("account:") ? .accounts : Pane(rawValue: paneRaw) ?? .general },
                set: { paneRaw = ($0 ?? .general).rawValue })
    }

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: selection) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
            // Settings always shows its sidebar, like System Settings: no button to fold it away.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            let pane = selection.wrappedValue ?? .general
            Group {
                switch pane {
                case .accounts: AccountsSettings()
                case .general: GeneralSettings()
                case .shortcuts: ShortcutsSettings()
                case .security: SecuritySettings()
                case .developer: DeveloperSettings()
                case .server: ServerSettings()
                case .license: LicenseSettings()
                case .about: AboutSettings()
                }
            }
            .navigationTitle(pane.title)
            .settingsControlStyles()
        }
        // Opens roomy and resizes freely; forms scroll when the window is shorter than their content.
        .frame(minWidth: 680, idealWidth: 820, maxWidth: .infinity, minHeight: 460, idealHeight: 640, maxHeight: .infinity)
    }
}

extension View {
    /// Settings' controls: buttons in the app's capsule style (explicit styles, like links, still win), switches in the
    /// brand colour when on, and every row's label centred on its control.
    func settingsControlStyles() -> some View {
        buttonStyle(.appSecondarySmall)
            .toggleStyle(.brandSwitch)
            .labeledContentStyle(.centeredRow)
    }
}

// MARK: Accounts

/// Every account on this Mac; one opens its details in a sheet. Then adding another.
private struct AccountsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var shown: SavedAccount?

    var body: some View {
        Form {
            Section {
                ForEach(model.accounts) { account in
                    Button { shown = account } label: { AccountListRow(account: account) }
                        .buttonStyle(.plain)
                }
            } footer: {
                Text("Each account keeps its own vault, Touch ID, PIN and timeout. Choose one for its details.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Spacer()
                    Button {
                        model.beginAddAccount()
                        model.bringToFront()
                    } label: {
                        Label("Add Account…", systemImage: "plus.circle")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $shown) { account in AccountDetailsSheet(accountId: account.id) }
    }
}

/// An account in the list: avatar, email, where it lives, and whether it's open (with its item count).
private struct AccountListRow: View {
    @Environment(AppModel.self) private var model
    let account: SavedAccount
    @State private var hovering = false

    var body: some View {
        let open = model.isUnlocked(account.id)
        let count = model.items.filter { $0.accountId == account.id && !$0.isDeleted }.count
        HStack(spacing: 12) {
            AccountAvatar(account: account, size: 34, showsLock: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: account.email).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(verbatim: account.serverSummary)
                    Text(verbatim: "·")
                    if open {
                        Text("^[\(count) item](inflect: true)")
                    } else {
                        Text("Locked")
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
        .background(Color.primary.opacity(hovering ? 0.04 : 0).padding(.horizontal, -8).padding(.vertical, -4))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// One account's details, in a sheet over the list: everything that was its own page. Closes by itself if the
/// account is logged out from inside.
struct AccountDetailsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let accountId: String

    var body: some View {
        VStack(spacing: 0) {
            if let account = model.accounts.first(where: { $0.id == accountId }) {
                AccountSettingsPage(account: account)
                    .settingsControlStyles()
            } else {
                Color.clear.onAppear { dismiss() }
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.appPrimary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 480, idealHeight: 620)
    }
}

// MARK: General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.appearance) private var appearance = "system"
    @AppStorage(Pref.fullDoorAnimation) private var fullDoorAnimation = false
    @State private var autoFillOn: Bool?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @AppStorage(Pref.showMenuBar) private var showMenuBar = true
    @AppStorage(Pref.closeToMenuBar) private var closeToMenuBar = false
    @AppStorage(Pref.matchFrontTab) private var matchFrontTab = false

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                Toggle(isOn: $fullDoorAnimation) {
                    Text("Full vault-door animation")
                    Text("The door drifts while it waits, turns its rings into line and comes apart before the gate opens, and builds itself again when you lock. Enabling this increases CPU usage and power consumption.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError {
                    Text(verbatim: loginError).font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text("With Reduce Motion on, the lock screen fades in and out instead of sliding.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show Triwarden in the menu bar", isOn: $showMenuBar)
                    .onChange(of: showMenuBar) { _, on in if !on { closeToMenuBar = false } }
                Toggle("Keep running in the menu bar when the window is closed", isOn: $closeToMenuBar)
                    .disabled(!showMenuBar)
            } header: {
                Text("Menu Bar")
            } footer: {
                Text(showMenuBar
                     ? "With the window closed, Triwarden leaves the Dock and waits in the menu bar. Shortcuts, AutoFill and the command palette keep working."
                     : "Without the menu bar icon, open Triwarden from the Dock, Spotlight or its shortcuts.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Match logins to the open website", isOn: Binding(
                    get: { matchFrontTab },
                    set: { on in
                        matchFrontTab = on
                        model.setMatchFrontTab(on)
                    }))
            } header: {
                Text("Open website")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Off until you turn it on. The menu bar and the command palette can then read the address of the front browser tab and put that site's logins first. Only an http or https address is kept. The page is not read, and nothing in the browser is clicked or changed.")
                    Text("Turning this on does not grant access by itself. The next time the menu bar or command palette opens over a browser, macOS asks to let Triwarden control that browser. The system says this Automation permission can reach documents and data and perform actions there. That describes the permission, which is broader than this request. Triwarden asks one question: the address of the front tab. Each browser asks once. Don't Allow leaves the rest of Triwarden working; that browser's tab is not matched. Turning this off stops the question. To remove a permission already given, use System Settings › Privacy & Security › Automation.")
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("AutoFill") {
                    HStack(spacing: 10) {
                        if let autoFillOn {
                            Label(autoFillOn ? "On" : "Off", systemImage: autoFillOn ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(autoFillOn ? .green : .secondary)
                        }
                        Button(autoFillOn == true ? "Settings…" : "Turn On…") {
                            ASSettingsHelper.openCredentialProviderAppSettings { _ in }
                        }
                    }
                }
            } footer: {
                Text("Fill passwords and verification codes in Safari, Chrome and apps. Turn on Triwarden in System Settings › General › AutoFill & Passwords.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .task {
                autoFillOn = await ASCredentialIdentityStore.shared.state().isEnabled
                if autoFillOn == true { AutoFillIdentities.publish(model.items, equivalents: model.equivalentDomains) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { autoFillOn = await ASCredentialIdentityStore.shared.state().isEnabled }
            }

            Section {
                Toggle("Show website icons", isOn: Binding(
                    get: { IconStore.enabled },
                    set: { on in
                        UserDefaults.standard.set(on, forKey: Pref.showIcons)
                        if !on { IconStore.shared.clear() }
                    }))
            } footer: {
                Text("Icons come from your own server (or Bitwarden for bitwarden.com accounts), so no one else learns which sites you use. Cached icons are encrypted.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LanguagePicker()
            } footer: {
                Text("Triwarden is available in English, 繁體中文, 繁體中文（香港）, 简体中文 and 日本語. The AutoFill panel follows the system's language.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Security

private struct SecuritySettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.autoLockMinutes) private var autoLockMinutes = 15
    @AppStorage(Pref.timeoutAction) private var timeoutAction = "lock"
    @AppStorage(Pref.lockOnSleep) private var lockOnSleep = true
    @AppStorage(Pref.clipboardSeconds) private var clipboardSeconds = 30
    @AppStorage(Pref.codeAfterPassword) private var codeAfterPassword = true
    @AppStorage(Pref.hideFromCapture) private var hideFromCapture = false

    var body: some View {
        Form {
            Section {
                Picker("Lock after inactivity", selection: $autoLockMinutes) {
                    Text("1 minute").tag(1)
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                    Divider()
                    Text("Never").tag(0)
                }
                Picker("When it times out", selection: $timeoutAction) {
                    Text("Lock").tag("lock")
                    Text("Log out").tag("logOut")
                }
                .disabled(autoLockMinutes == 0)
                Toggle("Lock when the Mac sleeps or the screen locks", isOn: $lockOnSleep)
            } header: {
                Text("Vault")
            } footer: {
                Text("Log out removes the account and its saved vault from this Mac; getting back in needs the master password (and two-step login). Each account can set its own timeout on its page.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Clear copied items after", selection: $clipboardSeconds) {
                    Text("10 seconds").tag(10)
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                    Divider()
                    Text("Never").tag(0)
                }
                Toggle("Copy the one-time code after the password is pasted", isOn: $codeAfterPassword)
            } header: {
                Text("Clipboard")
            } footer: {
                Text("Copied secrets are marked as concealed, so clipboard managers skip them. Paste a login's password, and its one-time code is ready to paste next.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Hide Triwarden from screen sharing and screenshots", isOn: $hideFromCapture)
                    .onChange(of: hideFromCapture) { CaptureShield.applyAll() }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Meeting apps, recordings and screenshots show an empty space where Triwarden's windows are, so a password on screen doesn't go out with the call.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: SSH

private struct DeveloperSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.sshAgent) private var enabled = false
    @AppStorage(Pref.cli) private var cliEnabled = false
    @AppStorage(Pref.cliApprovalSeconds) private var cliApprovalSeconds = 0
    @AppStorage(Pref.browser) private var browserEnabled = false

    private var installCommand: String { "sudo ln -sf \"\(CLIBridge.toolPath)\" /usr/local/bin/tw" }

    private var configLine: String { "Host *\n  IdentityAgent \"\(model.sshAgent.socketPath)\"" }

    var body: some View {
        let agent = model.sshAgent!
        Form {
            Section {
                Toggle("Use Triwarden as SSH agent", isOn: $enabled)
                    .onChange(of: enabled) { _, on in
                        if on {
                            agent.start()
                        } else {
                            agent.stop()
                        }
                    }
                if let error = agent.lastError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                }
            } header: {
                Text("SSH agent")
            } footer: {
                Text("SSH key items from unlocked accounts are offered to ssh and git. Each signature asks you, then asks macOS for Touch ID or your Mac login password. Keys never leave the app.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Add to ~/.ssh/config") {
                    Button("Copy") { model.copyPlain(configLine) }
                }
                Text(verbatim: configLine)
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .foregroundStyle(.secondary)
                LabeledContent("Or for one shell") {
                    Button("Copy") { model.copyPlain("export SSH_AUTH_SOCK=\"\(agent.socketPath)\"") }
                }
            } header: {
                Text("SSH setup")
            }

            Section {
                Toggle("Answer the tw command", isOn: $cliEnabled)
                    .onChange(of: cliEnabled) { model.cli.refreshRunning() }
                Picker("Ask before revealing", selection: $cliApprovalSeconds) {
                    Text("Every time").tag(0)
                    Text("Once per minute, per app").tag(60)
                    Text("Once per 10 minutes, per app").tag(600)
                }
                LabeledContent("Install tw") {
                    Button("Copy Command") { model.copyPlain(installCommand) }
                }
                Text(verbatim: installCommand)
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary)
                if let error = model.cli.lastError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                }
            } header: {
                Text("Command line")
            } footer: {
                Text("tw get github · tw code github · tw list · tw generate. Reading anything from the vault needs it unlocked and Touch ID or your Mac password.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Allow the browser extension", isOn: $browserEnabled)
                    .onChange(of: browserEnabled) { model.cli.refreshRunning() }
                LabeledContent("Safari") {
                    Button("Open Safari Extensions") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Safari-Extensions-Settings")!)
                    }
                }
                LabeledContent("Chrome, Edge, Brave") {
                    Button("Show Extension Folder") {
                        let folder = Bundle.main.bundleURL.appending(path: "Contents/PlugIns/TriwardenSafari.appex/Contents/Resources/manifest.json")
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                }
            } header: {
                Text("Browser extension")
            } footer: {
                Text("Safari: turn on Triwarden in Safari › Settings › Extensions. Chromium browsers: load the folder as an unpacked extension, then run tw install-chrome <extension id>. Suggestions show names only; filling asks for Touch ID, saving asks you first.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if agent.allowlist.entries.isEmpty {
                    Text("Choose Always Allow when an app asks to sign. It can sign whenever this vault is unlocked, including after you lock and open it again.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(agent.allowlist.entries) { entry in
                        HStack {
                            Text(verbatim: entry.displayName).font(.system(size: 13))
                            Spacer()
                            Button("Remove") { agent.revokeAllowlist(trustKey: entry.trustKey) }
                        }
                    }
                }
            } header: {
                Text("Always allowed")
            }

            Section {
                if agent.trustedUntilLock.isEmpty {
                    Text("Trust an app from the prompt when it asks to sign. Trust lasts until the vault locks.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(agent.trustedUntilLock) { trust in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: trust.displayName).font(.system(size: 13))
                                Text(verbatim: trust.keyName).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove") { agent.revokeTrust(id: trust.id) }
                        }
                    }
                }
            } header: {
                Text("Trusted until the vault locks")
            }

            Section {
                if agent.accessLog.events.isEmpty {
                    Text("No SSH requests yet.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(agent.accessLog.events) { event in
                        SSHAccessSettingsRow(event: event)
                    }
                    Button("Clear Log") { agent.clearAccessLog() }
                }
            } header: {
                Text("SSH access")
            }
        }
        .formStyle(.grouped)
    }

}

/// One SSH access record in Settings: who asked, which key, how it ended, and how long ago (no seconds).
private struct SSHAccessSettingsRow: View {
    let event: SSHAccessEvent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.16), in: .rect(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: event.appName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text("via \(event.via) · \(event.keyName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(tint.opacity(0.16), in: .capsule)
                Text(verbatim: SSHAccessClock.label(since: event.date))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch event.outcome {
        case .allowedOnce, .allowedForTenMinutes, .allowedUntilLock, .reusedTrust: "checkmark"
        case .allowlisted: "checkmark.seal"
        case .denied: "xmark"
        case .timedOut: "clock"
        case .locked: "lock"
        }
    }

    private var tint: Color {
        switch event.outcome {
        case .allowedOnce, .allowedForTenMinutes, .allowedUntilLock, .allowlisted, .reusedTrust:
            Color(red: 0.35, green: 0.78, blue: 0.55)
        case .denied: Color(red: 0.95, green: 0.45, blue: 0.42)
        case .timedOut: Color(red: 0.95, green: 0.72, blue: 0.38)
        case .locked: .secondary
        }
    }

    private var label: LocalizedStringKey {
        switch event.outcome {
        case .allowedOnce: "Allowed once"
        case .allowedForTenMinutes: "Allowed for 10 minutes"
        case .allowedUntilLock: "Trusted until lock"
        case .allowlisted: "Always allowed"
        case .denied: "Denied"
        case .timedOut: "Timed out"
        case .locked: "Vault locked"
        case .reusedTrust: "Used an existing grant"
        }
    }
}

// MARK: Accounts

/// Everything about one account on one page: who and where; Touch ID and sync on this Mac; and, while it's
/// unlocked, its security (two-step login, master password, fingerprint, devices) and emergency access; then
/// export, lock and log out.
private struct AccountSettingsPage: View {
    @Environment(AppModel.self) private var model
    let account: SavedAccount
    @State private var confirmLogOut = false
    @State private var settingPIN = false

    private var session: AccountSession? { model.session(for: account.id) }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    AccountAvatar(account: account, size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: account.email).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                        Text(verbatim: "\(account.serverSummary) · \(kdf)").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 6) {
                        Circle().fill(session != nil ? Color.green : Color.secondary.opacity(0.6)).frame(width: 7, height: 7)
                        Text(session != nil ? "Unlocked" : "Locked")
                    }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }

            Section {
                Toggle(isOn: Binding(get: { model.isTouchIDEnabled(account.id) }, set: { model.setTouchID($0, for: account.id) })) {
                    Text("Unlock with Touch ID")
                    Text(!AccountStore.isTouchIDAvailable ? "Not available on this Mac."
                         : session != nil || model.isTouchIDEnabled(account.id) ? "One touch opens every account that has it."
                         : "Unlock this account once to turn it on.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(!AccountStore.isTouchIDAvailable || (session == nil && !model.isTouchIDEnabled(account.id)))
                Toggle(isOn: Binding(get: { model.isPINEnabled(account.id) }, set: { on in
                    if on { settingPIN = true } else { model.disablePIN(for: account.id) }
                })) {
                    Text("Unlock with PIN")
                    Text(session != nil || model.isPINEnabled(account.id)
                         ? "A short PIN instead of the master password. Five wrong tries turn it off."
                         : "Unlock this account once to set a PIN.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(session == nil && !model.isPINEnabled(account.id))
                if model.isPINEnabled(account.id) {
                    Toggle(isOn: Binding(get: { !model.isPINPersistent(account.id) },
                                         set: { model.setPINPersistent(!$0, for: account.id) })) {
                        Text("Ask for the master password after a restart")
                        Text("The PIN then works only until Triwarden quits, and is never written to disk.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let session {
                    LabeledContent {
                        HStack(spacing: 8) {
                            if session.isSyncing {
                                ProgressView().controlSize(.small)
                            } else if let synced = session.lastSynced {
                                Text(synced, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                            } else {
                                Text("Offline").foregroundStyle(.secondary)
                            }
                            Button("Sync Now") { Task { try? await session.refresh() } }
                                .disabled(session.isSyncing)
                        }
                    } label: {
                        Text("Last synced")
                    }
                }
            } header: {
                Text("This Mac")
            }

            Section {
                Picker("Lock after inactivity", selection: Binding(
                    get: { model.ownAutoLockMinutes(account.id) ?? -1 },
                    set: { model.setOwnAutoLockMinutes($0 == -1 ? nil : $0, account.id) })) {
                    Text("Default (\(TimeoutLabels.minutes(UserDefaults.standard.integer(forKey: Pref.autoLockMinutes))))").tag(-1)
                    Divider()
                    ForEach([1, 5, 15, 30, 60], id: \.self) { Text(TimeoutLabels.minutes($0)).tag($0) }
                    Divider()
                    Text("Never").tag(0)
                }
                Picker("When it times out", selection: Binding(
                    get: { model.ownTimeoutAction(account.id)?.rawValue ?? "default" },
                    set: { model.setOwnTimeoutAction(AppModel.TimeoutAction(rawValue: $0), account.id) })) {
                    Text("Default (\(TimeoutLabels.action(UserDefaults.standard.string(forKey: Pref.timeoutAction) ?? "lock")))").tag("default")
                    Divider()
                    Text("Lock").tag("lock")
                    Text("Log out").tag("logOut")
                }
                .disabled(model.autoLockMinutes(for: account.id) == 0)
            } header: {
                Text("Timeout")
            } footer: {
                Text("For this account only; Default follows Settings › Security. Log out removes the account and its saved vault from this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let session {
                AccountSecuritySections(session: session).id("security-" + session.id)
                EmergencyAccessSections(session: session).id("emergency-" + session.id)
            } else {
                Section {
                    LabeledContent {
                        Button("Unlock…") { unlockInVault() }
                    } label: {
                        Text("Unlock this account to manage its two-step login, master password, devices and emergency access.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Security")
                }
            }

            Section {
                if session != nil {
                    LabeledContent("Export this account's vault") {
                        Button("Export…") { model.beginExport(accountId: account.id) }
                    }
                    LabeledContent("Lock this account") {
                        Button("Lock") { model.lock(account.id) }
                    }
                }
                LabeledContent {
                    Button("Log Out…", role: .destructive) { confirmLogOut = true }
                } label: {
                    Text("Log out")
                    Text("Removes the account and its saved vault from this Mac. Your data stays on the server.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Account")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $settingPIN) { SetPINSheet(account: account) }
        .confirmationDialog("Log out of \(account.email)?", isPresented: $confirmLogOut) {
            Button("Log Out", role: .destructive) { model.logOut(account.id) }
        } message: {
            Text("This removes the account and its saved vault from this Mac. Your data stays on the server.")
        }
    }

    /// The vault window, on this account (its list asks for the master password or Touch ID).
    private func unlockInVault() {
        model.accountFocus = account.id
        model.bringToFront()
    }

    private var kdf: String {
        switch account.kdf {
        case .pbkdf2: "PBKDF2"
        case .argon2id: "Argon2id"
        }
    }
}


// MARK: Server

private struct ServerSettings: View {
    @Environment(AppModel.self) private var model
    @State private var headers: [CustomHeader] = HeaderStore.load()
    @State private var cas: [Data] = Connection.trustedCAs
    @State private var importing = false
    @State private var importError: String?
    /// A certificate or header about to be removed, waiting for "Are you sure?".
    @State private var removingCA: Int?
    @State private var removingHeader: CustomHeader.ID?
    /// One signed-in server and the version it reported.
    @State private var versions: [ServerVersionRow] = []
    @State private var versionsLoaded = false

    var body: some View {
        Form {
            Section {
                if model.accounts.isEmpty {
                    Text("Sign in to see the server version.").foregroundStyle(.secondary)
                } else if !versionsLoaded {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking server…").foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(versions) { row in
                        LabeledContent {
                            Text(verbatim: row.detail).foregroundStyle(.secondary)
                        } label: {
                            Text(verbatim: row.title)
                        }
                    }
                }
            } header: {
                Text("Version")
            }

            Section {
                if cas.isEmpty {
                    Text("Using the system's trusted certificates.").foregroundStyle(.secondary)
                }
                ForEach(Array(cas.enumerated()), id: \.offset) { index, data in
                    HStack {
                        Image(systemName: "checkmark.seal").foregroundStyle(.green)
                        Text(verbatim: certificateName(data))
                        Spacer()
                        Button(role: .destructive) { removingCA = index } label: { Image(systemName: "minus.circle").accessibilityLabel(Text("Remove")) }
                            .buttonStyle(.borderless)
                            .help(Text("Remove"))
                    }
                }
                HStack {
                    Spacer()
                    Button("Add Certificate…") { importing = true }
                }
                if let importError { Text(verbatim: importError).font(.caption).foregroundStyle(.red) }
            } header: {
                Text("Trusted certificates")
            } footer: {
                Text("Add your own CA if your server uses a private or self-signed certificate (PEM or DER).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach($headers) { $header in
                    HStack {
                        TextField("Name", text: $header.name, prompt: Text(verbatim: "CF-Access-Client-Id"))
                        PasswordField(title: "Value", text: $header.value, look: .plain, prompt: Text("Value"))
                        Button(role: .destructive) {
                            // A blank row just goes; one with something in it asks first.
                            if header.name.isEmpty && header.value.isEmpty { headers.removeAll { $0.id == header.id } } else { removingHeader = header.id }
                        } label: { Image(systemName: "minus.circle").accessibilityLabel(Text("Remove")) }
                            .buttonStyle(.borderless)
                            .help(Text("Remove"))
                    }
                    .labelsHidden()
                }
                HStack {
                    Spacer()
                    Button("Add Header") { headers.append(CustomHeader(name: "", value: "")) }
                }
            } header: {
                Text("Extra request headers")
            } footer: {
                Text("Sent with every request, e.g. Cloudflare Access service tokens. Stored in your Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: model.accounts.map(\.id).joined(separator: ",")) {
            versionsLoaded = false
            await loadVersions()
        }
        .onChange(of: headers) { _, new in HeaderStore.save(new); model.resetClient() }
        .confirmationDialog("Remove this certificate?", isPresented: Binding(
            get: { removingCA != nil }, set: { if !$0 { removingCA = nil } }), presenting: removingCA) { index in
            Button("Remove", role: .destructive) { if cas.indices.contains(index) { cas.remove(at: index); saveCAs() } }
            Button("Cancel", role: .cancel) {}
        } message: { index in
            Text("“\(cas.indices.contains(index) ? certificateName(cas[index]) : "")” is no longer trusted; a server that relies on it stops connecting.")
        }
        .confirmationDialog("Remove this header?", isPresented: Binding(
            get: { removingHeader != nil }, set: { if !$0 { removingHeader = nil } }), presenting: removingHeader) { id in
            Button("Remove", role: .destructive) { headers.removeAll { $0.id == id } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It's no longer sent, and its value is deleted from your Keychain.")
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.x509Certificate, UTType(filenameExtension: "pem") ?? .data, .data]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                guard certificate(from: data) != nil else {
                    importError = String(localized: "That file isn't a certificate.")
                    return
                }
                cas.append(data)
                saveCAs()
                importError = nil
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func saveCAs() {
        Connection.trustedCAs = cas
        model.resetClient()
    }

    /// Asks each signed-in server for its version. `/api/config` needs no password.
    private func loadVersions() async {
        var seen = Set<String>()
        var rows: [ServerVersionRow] = []
        for account in model.accounts {
            guard let environment = account.environment else { continue }
            let key = "\(account.serverKind)|\(account.serverSummary)"
            guard seen.insert(key).inserted else { continue }
            let detail: String
            do {
                let config = try await Connection.makeClient(environment).config()
                let name = [config.productName, config.version].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
                detail = name.isEmpty ? String(localized: "Reachable") : name
            } catch {
                detail = String(localized: "Can't reach this server")
            }
            guard !Task.isCancelled else { return }
            rows.append(ServerVersionRow(id: key, title: account.serverSummary, detail: detail))
        }
        versions = rows
        versionsLoaded = true
    }

    private func certificate(from data: Data) -> SecCertificate? {
        if let c = SecCertificateCreateWithData(nil, data as CFData) { return c }
        let body = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: body).flatMap { SecCertificateCreateWithData(nil, $0 as CFData) }
    }

    private func certificateName(_ data: Data) -> String {
        certificate(from: data).flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? "Certificate"
    }
}

/// A server address and the version string from its public config.
private struct ServerVersionRow: Identifiable {
    let id: String
    let title: String
    let detail: String
}

// MARK: About

private struct AboutSettings: View {
    @Environment(AppModel.self) private var model
    @State private var showingNotices = false
    @State private var copiedVersion = false

    private static let repo = URL(string: "https://github.com/sinhong2011/triwarden")!
    private static let support = URL(string: "mailto:triwarden@protonmail.com")!
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }

    var body: some View {
        @Bindable var updates = model.updates
        Form {
            // Who we are.
            Section {
                VStack(spacing: 8) {
                    Image(nsImage: BrandIcon.image)
                        .resizable().frame(width: 84, height: 84)
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                    Text(verbatim: "Triwarden").font(.system(size: 24, weight: .bold)).tracking(-0.3)
                    Text("A native Mac client for Vaultwarden and Bitwarden.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    Button {
                        model.copyPlain("Triwarden \(version) (\(build)), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
                        withAnimation(.snappy) { copiedVersion = true }
                        Task { try? await Task.sleep(for: .seconds(1.5)); withAnimation(.snappy) { copiedVersion = false } }
                    } label: {
                        HStack(spacing: 6) {
                            Text(verbatim: "\(version) (\(build))").monospacedDigit()
                            Image(systemName: copiedVersion ? "checkmark" : "doc.on.doc").font(.system(size: 10, weight: .semibold))
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(Color.primary.opacity(0.06), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .help(Text("Copy the version, for a bug report"))
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }

            Section {
                LabeledContent {
                    Button("Check Now") { updates.checkForUpdates() }
                        .disabled(!updates.canCheck)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Version \(updates.current)")
                            if !updates.isConfigured {
                                Text("Updates are off in development builds.").font(.caption).foregroundStyle(.secondary)
                            } else if let checked = updates.lastChecked {
                                Text("Last checked \(checked, format: .relative(presentation: .named))").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("Not checked yet").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath.circle").foregroundStyle(.secondary)
                    }
                }
                Toggle("Check for updates automatically", isOn: $updates.automaticallyChecks)
                    .disabled(!updates.isConfigured)
                Toggle("Download and install updates automatically", isOn: $updates.automaticallyDownloads)
                    .disabled(!updates.isConfigured || !updates.automaticallyChecks)
            } header: {
                Text("Updates")
            } footer: {
                Text("Updates come from this project's GitHub releases. Each one is signed; Triwarden checks the signature and Apple's notarization before installing, then relaunches.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                link("What's New in \(version)", "sparkles", Self.repo.appending(path: "releases/tag/v\(version)"))
                link("Source Code", "chevron.left.forwardslash.chevron.right", Self.repo)
                link("Report a Problem", "exclamationmark.bubble", Self.repo.appending(path: "issues/new"))
                Link(destination: Self.support) {
                    HStack {
                        Label("Contact", systemImage: "envelope").labelStyle(SecondaryIconLabelStyle())
                        Spacer()
                        Text(verbatim: "triwarden@protonmail.com")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.primary)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                link("License", "doc.text", URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
                Button { showingNotices = true } label: {
                    row("Acknowledgements", "heart.text.square", trailing: "chevron.right")
                }
                .buttonStyle(.plain)
            } footer: {
                Text("Free software under the GNU General Public License v3.0. Not affiliated with Bitwarden, Inc. or the Vaultwarden project.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingNotices) { NoticesSheet() }
    }

    private func link(_ title: LocalizedStringKey, _ symbol: String, _ url: URL) -> some View {
        Link(destination: url) { row(title, symbol, trailing: "arrow.up.right") }
            .buttonStyle(.plain)
    }

    private func row(_ title: LocalizedStringKey, _ symbol: String, trailing: String) -> some View {
        HStack {
            Label(title, systemImage: symbol).labelStyle(SecondaryIconLabelStyle())
            Spacer()
            Image(systemName: trailing).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
        }
        .foregroundStyle(.primary)
        .contentShape(.rect)
    }
}

/// A label whose icon is quiet (secondary) beside primary text.
private struct SecondaryIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(.secondary).frame(width: 20)
            configuration.title
        }
    }
}

/// The third-party notices bundled with the app (Sparkle, Argon2, EFF wordlist).
private struct NoticesSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let text: String = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Acknowledgements").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.appPrimarySmall).keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                Text(verbatim: text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .frame(width: 620, height: 520)
    }
}

/// Click, then press the new key combination (needs ⌘, ⌥ or ⌃). Esc cancels.
/// Records a system-wide shortcut for one action; ✕ turns it off, ↺ goes back to the default.
private struct ShortcutRecorder: View {
    let action: GlobalAction
    @State private var shortcut: Shortcut?
    @State private var recording = false
    @State private var monitor: Any?
    @State private var problem: String?

    init(action: GlobalAction) {
        self.action = action
        _shortcut = State(initialValue: Shortcut.current(for: action))
    }

    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    /// A field like System Settings' shortcut fields: the keys as keycaps; empty, a dashed "Record Shortcut"; while
    /// recording, a firmer outline. Clear shows on hover; reset and clear are also in its context menu.
    var body: some View {
        let dark = scheme == .dark
        VStack(alignment: .trailing, spacing: 4) {
            Button { recording ? stop() : start() } label: {
                HStack(spacing: 4) {
                    if recording {
                        Text("Type shortcut…").foregroundStyle(.secondary)
                    } else if let shortcut {
                        ForEach(Array(shortcut.parts.enumerated()), id: \.offset) { _, key in
                            Text(verbatim: key)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 5).frame(minWidth: 20, minHeight: 20)
                                .background(Color.primary.opacity(dark ? 0.12 : 0.07), in: .rect(cornerRadius: 5, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(dark ? 0.08 : 0.06)))
                        }
                    } else {
                        Text("Record Shortcut").foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .frame(width: 148, height: 30)
                .background(Color.primary.opacity(recording ? 0.06 : shortcut == nil ? 0 : 0.03),
                            in: .rect(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(recording ? Color.primary.opacity(0.45) : problem != nil ? Color.orange.opacity(0.7)
                                      : Color.primary.opacity(shortcut == nil ? 0.18 : 0.1),
                                      style: StrokeStyle(lineWidth: recording ? 1.5 : 1, dash: shortcut == nil && !recording ? [3, 3] : []))
                }
                .overlay(alignment: .trailing) {
                    if shortcut != nil, hovering, !recording {
                        Button { apply(nil) } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 7)
                        .help(Text("Turn off"))
                        .accessibilityLabel(Text("Turn off"))
                        .transition(.opacity)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
            .animation(.easeOut(duration: 0.15), value: recording)
            .contextMenu {
                if let initial = action.defaultShortcut, shortcut != initial {
                    Button("Reset to \(initial.display)") { apply(initial) }
                }
                if shortcut != nil { Button("Turn off") { apply(nil) } }
            }
            .accessibilityLabel(Text(action.title))
            .accessibilityValue(Text(verbatim: shortcut?.display ?? ""))
            if let problem {
                Text(verbatim: problem).font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        problem = nil
        recording = true
        HotKeys.shared.pause() // or pressing a current shortcut would run it
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil } // Esc
            if let new = Shortcut(event: event) { stop(); apply(new) } else { problem = String(localized: "Include ⌘, ⌥ or ⌃") }
            return nil
        }
    }

    private func stop() {
        if recording { HotKeys.shared.resume() }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func apply(_ new: Shortcut?) {
        if let new, let other = HotKeys.shared.owner(of: new), other != action {
            problem = String(localized: "\(new.display) is already used here")
            return
        }
        guard HotKeys.shared.bind(new, to: action) else {
            problem = new.map { String(localized: "Another app uses \($0.display)") }
            return
        }
        problem = nil
        shortcut = new
        Shortcut.set(new, for: action)
    }
}

// MARK: Shortcuts

/// System-wide shortcuts (set here), and the ones inside the app (changed in System Settings, like any app's).
private struct ShortcutsSettings: View {
    /// The menu commands and their keys, as the app's menus define them.
    private static let inApp: [(LocalizedStringKey, String)] = [
        ("Command Palette", "⌘K"), ("Triwarden Help", "⌘?"), ("Keyboard Shortcuts", "⌃⇧/"),
        ("New Login", "⌘N"), ("New Secure Note", "⇧⌘N"), ("New Folder", "⌥⌘N"),
        ("Edit", "⌘E"), ("Copy Username", "⇧⌘C"), ("Copy Password", "⌥⌘C"), ("Copy One-Time Code", "⌃⌘C"),
        ("Toggle Favorite", "⌘D"), ("Archive", "⌥⌘A"), ("Move to Trash", "⌘⌫"), ("Generator", "⌘G"),
        ("Import", "⇧⌘I"), ("Export Vault", "⇧⌘E"), ("Lock Vault", "⇧⌘L"), ("Settings", "⌘,"),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(GlobalAction.allCases) { action in
                    LabeledContent {
                        ShortcutRecorder(action: action)
                    } label: {
                        Text(action.title)
                        Text(action.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Type into other apps") { AutoTypePermission() }
            } header: {
                Text("Anywhere")
            } footer: {
                Text("Works in every app. Called over a browser or an app, the palette puts its logins first, and ↵ types the username and password in (⌃↵ username, ⌥↵ password, ⇧ & submit). Typing needs Accessibility for “Triwarden Auto-Type”, a small helper inside the app, so Triwarden itself stays sandboxed. ⌘K and ⌘F also open the palette inside the vault window.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(Array(Self.inApp.enumerated()), id: \.offset) { _, entry in
                    LabeledContent(entry.0) { Keycap(keys: entry.1) }
                }
            } header: {
                Text("In Triwarden")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("To change one, add Triwarden in System Settings › Keyboard › Keyboard Shortcuts › App Shortcuts and type the menu item's name exactly.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Keyboard Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The app's own language, chosen here: written to the app's `AppleLanguages` (read at launch), then a relaunch.
private struct LanguagePicker: View {
    /// "" follows the system.
    static let choices: [(code: String, name: String)] = [
        ("", String(localized: "System Default")), ("en", "English"), ("zh-Hant", "繁體中文"),
        ("zh-HK", "繁體中文（香港）"), ("zh-Hans", "简体中文"), ("ja", "日本語"),
    ]

    /// What the app was launched with ("" = the system's choice).
    private static let atLaunch: String = (UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"]
        as? [String])?.first ?? ""

    @State private var chosen = Self.atLaunch

    var body: some View {
        LabeledContent("Language") {
            HStack(spacing: 8) {
                if chosen != Self.atLaunch {
                    Button("Relaunch to Apply") { Self.relaunch() }
                        .buttonStyle(.appPrimarySmall)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
                Picker("Language", selection: $chosen) {
                    ForEach(Self.choices, id: \.code) { Text(verbatim: $0.name).tag($0.code) }
                }
                .labelsHidden()
                .fixedSize()
            }
            .animation(.snappy(duration: 0.2), value: chosen)
        }
        .onChange(of: chosen) { _, code in
            if code.isEmpty {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([code], forKey: "AppleLanguages")
            }
        }
    }

    /// Opens a fresh copy once this one has quit, so the new language loads.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}

/// Whether the auto-type helper may type (Accessibility), with a button to ask macOS for it.
private struct AutoTypePermission: View {
    @State private var allowed: Bool?
    @State private var checked = false

    var body: some View {
        HStack(spacing: 8) {
            switch checked ? allowed : nil {
            case .some(true):
                Label("Allowed", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            case .some(false):
                Button("Allow…") { Task { await AutoType.askPermission() } }
                    .buttonStyle(.appSecondarySmall)
            case nil:
                if checked {
                    Text("Unavailable").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .task { await check() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await check() }
        }
    }

    private func check() async {
        allowed = await AutoType.isAllowed()
        checked = true
    }
}

/// Choose a PIN (twice), and whether it should outlive a restart.
private struct SetPINSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let account: SavedAccount
    @State private var pin = ""
    @State private var again = ""
    @State private var afterRestart = true
    @State private var busy = false
    @State private var error: String?

    private var valid: Bool { pin.count >= 4 && pin == again }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set a PIN").font(.system(size: 17, weight: .semibold))
                Text(verbatim: account.email).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                SecureField("PIN", text: $pin, prompt: Text("At least 4 characters"))
                    .textFieldStyle(SoftFieldStyle())
                SecureField("Again", text: $again, prompt: Text("The same PIN again"))
                    .textFieldStyle(SoftFieldStyle())
                    .onSubmit(submit)
                Toggle("Ask for the master password after a restart", isOn: $afterRestart)
                    .toggleStyle(.trailingSwitch)
                    .font(.system(size: 12))
                    .padding(.top, 4)
            }
            Group {
                if let error {
                    Text(verbatim: error).foregroundStyle(.red)
                } else if !again.isEmpty && pin != again {
                    Text("The two PINs don't match.").foregroundStyle(.orange)
                } else {
                    Text("Five wrong tries turn the PIN off; then the master password unlocks. Anyone who knows the PIN can open this account on this Mac.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.appSecondary)
                    .keyboardShortcut(.cancelAction)
                Button {
                    submit()
                } label: {
                    HStack(spacing: 6) {
                        if busy { ProgressView().controlSize(.small).tint(.white) }
                        Text("Turn On")
                    }
                }
                .buttonStyle(.appPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(!valid || busy)
            }
        }
        .padding(22)
        .frame(width: 380)
    }

    private func submit() {
        guard valid, !busy else { return }
        busy = true
        Task {
            let ok = await model.setPIN(pin, persistent: !afterRestart, for: account.id)
            busy = false
            if ok { dismiss() } else { error = String(localized: "Couldn't set the PIN. Unlock the account and try again.") }
        }
    }
}

/// Words for inactivity timeouts, shared by Security and each account's page.
enum TimeoutLabels {
    static func minutes(_ n: Int) -> String {
        switch n {
        case 0: String(localized: "Never")
        case 60: String(localized: "1 hour")
        case 1: String(localized: "1 minute")
        default: String(localized: "\(n) minutes")
        }
    }
    static func action(_ raw: String) -> String {
        raw == "logOut" ? String(localized: "Log out") : String(localized: "Lock")
    }
}
