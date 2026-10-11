import AppKit
import SwiftUI

/// Where the user was when they called the palette or opened the menu bar panel: the app, and, when they have
/// turned it on, the site of a browser's front tab. The palette and the panel put that site's (or app's) logins first.
struct ForegroundContext: Equatable {
    let app: String
    let bundleID: String
    let pid: pid_t
    /// The front tab's host, once the browser has answered (nil for other apps, or if the user declined).
    var host: String?

    var isBrowser: Bool { Self.browsers[bundleID] != nil }

    /// Browsers whose front tab we can ask for, and how (see `pageURL`). Each needs its bundle ID in the
    /// `temporary-exception.apple-events` entitlement; macOS asks the user once per browser.
    static let browsers: [String: Kind] = [
        "com.apple.Safari": .safari, "com.apple.SafariTechnologyPreview": .safari,
        "com.google.Chrome": .chromium, "com.google.Chrome.beta": .chromium, "com.google.Chrome.canary": .chromium,
        "com.brave.Browser": .chromium, "com.microsoft.edgemac": .chromium, "company.thebrowser.Browser": .chromium,
        "company.thebrowser.dia": .chromium, "com.vivaldi.Vivaldi": .chromium, "org.chromium.Chromium": .chromium,
        "com.operasoftware.Opera": .chromium,
    ]
    enum Kind { case safari, chromium }

    init(app: String, bundleID: String, pid: pid_t, host: String?) {
        self.app = app; self.bundleID = bundleID; self.pid = pid; self.host = host
    }

    init(_ app: NSRunningApplication) {
        self.app = app.localizedName ?? ""
        bundleID = app.bundleIdentifier ?? ""
        pid = app.processIdentifier
    }

    /// The front tab's address, asked over Apple Events off the main thread (the first time, macOS shows its
    /// permission prompt and this waits for the answer). nil when there's no window or the user said no.
    static func pageURL(bundleID: String) async -> URL? {
        guard let kind = browsers[bundleID] else { return nil }
        let source = switch kind {
        case .safari: "tell application id \"\(bundleID)\" to return URL of front document"
        case .chromium: "tell application id \"\(bundleID)\" to return URL of active tab of front window"
        }
        let text = await Task.detached(priority: .userInitiated) { () -> String? in
            var error: NSDictionary?
            return NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
        }.value
        guard let text, let url = URL(string: text), ["http", "https"].contains(url.scheme ?? "") else { return nil }
        return url
    }

    /// The vault's items for this context: logins for the site (equivalent domains count), or for another app,
    /// items named after it ("Discord" in Discord).
    @MainActor func items(in model: AppModel) -> [VaultItem] {
        let live = model.items.filter { !$0.isDeleted && !$0.isArchived && $0.kind == .login }
        if let host {
            let equivalents = model.equivalentDomains
            return Array(live.filter { item in
                return item.hosts.contains { equivalents.matches(itemHost: $0, site: host) }
            }.prefix(6))
        }
        guard !isBrowser, app.count >= 3 else { return [] }
        let name = app.lowercased()
        return Array(live.filter { item in
            item.name.lowercased().contains(name) || (item.host?.lowercased().contains(name.replacingOccurrences(of: " ", with: "")) ?? false)
        }.prefix(6))
    }

    /// What the palette and the panel call it: "github.com" for a page, else the app's name.
    var label: String { host ?? app }
}

extension AppModel {
    /// Remembers the app the user was last in (anything but us), so the palette and the panel know where they
    /// were called from even after Triwarden comes forward.
    func trackForegroundApps() {
        lastOtherApp = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0 }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                                          queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app != .current else { return }
            MainActor.assumeIsolated { self?.lastOtherApp = app }
        }
    }

    /// Notes where the user is (the front app, or the last one before Triwarden). A browser's front tab is
    /// asked only after the person turns on matching. Call it before Triwarden takes focus.
    func captureForeground() {
        guard !foregroundPinned else { return }
        let front = NSWorkspace.shared.frontmostApplication
        guard let app = (front == .current ? lastOtherApp : front), !app.isTerminated else { foreground = nil; return }
        var context = ForegroundContext(app)
        guard context.isBrowser else { foreground = context; return }
        context.host = foreground?.bundleID == context.bundleID && foreground?.pid == context.pid ? foreground?.host : nil
        foreground = context
        readFrontTab()
    }

    /// Turns front-tab matching on or off. On asks the browser already in front; off forgets the address and
    /// keeps the reminder from coming back.
    func setMatchFrontTab(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Pref.matchFrontTab)
        if on {
            readFrontTab()
        } else {
            UserDefaults.standard.set(true, forKey: Pref.matchFrontTabDismissed)
            foreground?.host = nil
        }
    }

    func dismissFrontTabPrompt() {
        UserDefaults.standard.set(true, forKey: Pref.matchFrontTabDismissed)
    }

    /// The front tab's host, when matching is on. This is the call that makes macOS show its Automation prompt.
    private func readFrontTab() {
        guard UserDefaults.standard.bool(forKey: Pref.matchFrontTab), let context = foreground, context.isBrowser else { return }
        Task {
            let host = await ForegroundContext.pageURL(bundleID: context.bundleID)?.host()?.lowercased()
            guard foreground?.pid == context.pid else { return }
            foreground?.host = host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        }
    }

    /// The global "fill" shortcut: types the one login for the page or app you're in. With several (or none),
    /// or while locked, the palette opens instead, already showing them.
    func fillForeground() {
        guard isUnlocked else { openPalette(); return }
        captureForeground()
        Task {
            if UserDefaults.standard.bool(forKey: Pref.matchFrontTab),
               let context = foreground, context.isBrowser, context.host == nil {
                // Wait (briefly) for the browser to say which page it's on.
                for _ in 0..<20 where foreground?.host == nil && foreground?.pid == context.pid {
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            guard let context = foreground else { openPalette(); return }
            let logins = context.items(in: self).filter { $0.password != nil }
            guard logins.count == 1, let item = logins.first else { openPalette(); return }
            fillLogin(item, into: context)
        }
    }

    /// Types a login into the app (or page) it's for: username, Tab, password, and Return when `submit`.
    /// Without Accessibility for the helper yet, the password is copied instead.
    func fillLogin(_ item: VaultItem, into context: ForegroundContext, submit: Bool = false) {
        var steps: [AutoType.Step] = [item.username.map(AutoType.Step.text), item.username != nil && item.password != nil ? .tab : nil,
                                      item.password.map(AutoType.Step.text)].compactMap { $0 }
        guard !steps.isEmpty else { return }
        if submit { steps.append(.enter) }
        guarded(item) {
            self.autoType(steps, into: context, fallback: item.password.map { (value: $0, label: String(localized: "Password")) })
        }
    }

    /// Hands focus back to the app the palette was called from (after copying something for it).
    func returnToForeground() {
        guard let foreground, let app = NSRunningApplication(processIdentifier: foreground.pid) else { return }
        app.activate()
    }
}

/// Shown over a browser while front-tab matching is still off, so the Automation prompt is a choice.
struct FrontTabMatchPrompt: View {
    var horizontalPadding: CGFloat = 0
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.matchFrontTab) private var enabled = false
    @AppStorage(Pref.matchFrontTabDismissed) private var dismissed = false

    private var appName: String? {
        guard model.isUnlocked, !enabled, !dismissed, let context = model.foreground, context.isBrowser else { return nil }
        return context.app
    }

    var body: some View {
        if let appName {
            VStack(alignment: .leading, spacing: 8) {
                Text("Match \(appName)'s front tab?")
                    .font(.system(size: 13, weight: .semibold))
                Text("Triwarden can read the address of \(appName)'s front tab so that site's logins come first. macOS will ask to let Triwarden control the browser. Automation can reach documents and perform actions; Triwarden only asks for the front tab's http or https address. It does not read the page or change the browser.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Turn On") { model.setMatchFrontTab(true) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Not Now") { model.dismissFrontTabPrompt() }
                        .controlSize(.small)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, horizontalPadding == 0 ? 0 : 8)
        }
    }
}
