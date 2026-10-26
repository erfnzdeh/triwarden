import AppKit
import TriCrypto
import Foundation
import LocalAuthentication
import Observation
import SSHAgent
import UserNotifications
import VaultwardenAPI

/// Answers the `tw` command over a socket in the App Group container. Anything that reveals vault
/// data needs the vault unlocked plus an approval (Touch ID or the Mac password) naming the program.
@MainActor @Observable
final class CLIBridge {
    static var defaultSocket: URL {
        (FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AccountStore.appGroup)
            ?? FileManager.default.temporaryDirectory).appending(path: CLISocket.name)
    }

    /// Where the bundled tool lives, for the install command.
    static var toolPath: String { Bundle.main.bundleURL.appending(path: "Contents/MacOS/tw").path }

    private(set) var isRunning = false
    private(set) var lastError: String?
    private var server: FramedSocketServer?
    private var approvedUntil: [String: Date] = [:]
    private weak var model: AppModel?
    /// Self-test hook: skip the Touch ID prompt.
    var approveOverride: ((String) -> Bool)?

    /// Logins the browser extension saw you submit, newest last. They wait in the bell, the menu bar panel and a
    /// banner for Save or Not Now; nothing is written until you answer. Kept in memory only and dropped on lock.
    private(set) var pendingSaves: [PendingLoginSave] = []
    /// Site + username pairs you said Not Now to. They stay quiet until the vault locks.
    private var declinedSaves: Set<String> = []
    /// A save arrived since the vault window was last brought forward: bringing it forward opens the bell.
    var revealSavesOnActivate = false

    /// Runs while the command line or the browser extension is turned on.
    func refreshRunning() {
        let wanted = UserDefaults.standard.bool(forKey: Pref.cli) || UserDefaults.standard.bool(forKey: Pref.browser)
        if wanted { start() } else { stop() }
    }

    init(model: AppModel) { self.model = model }

    func start(at socket: URL = defaultSocket) {
        guard server == nil else { return }
        let server = FramedSocketServer(socketURL: socket) { [weak self] request, peer in
            let response: CLIResponse
            if let decoded = try? JSONDecoder().decode(CLIRequest.self, from: request) {
                response = await self?.handle(decoded, peer: peer) ?? .failure("Triwarden is quitting.")
            } else {
                response = .failure("Unreadable request — is tw from the same version as the app?")
            }
            return (try? JSONEncoder().encode(response)) ?? Data()
        }
        do {
            try server.start()
            self.server = server
            isRunning = true
            lastError = nil
        } catch {
            lastError = String(localized: "Couldn't start the command-line bridge: \(String(describing: error))")
        }
    }

    func stop() {
        server?.stop()
        server = nil
        isRunning = false
    }

    func reset() {
        approvedUntil = [:]
        LoginSaveNotifier.withdraw(pendingSaves.map(\.id))
        pendingSaves = []
        declinedSaves = []
        revealSavesOnActivate = false
    }

    // MARK: Saving from the browser

    enum SaveDecision: Equatable {
        /// Already in the vault as typed.
        case unchanged
        /// Not worth asking: no username on a site that already has logins, so it is most likely a "confirm your
        /// password" step (GitHub's sudo mode and the like), and there is no telling which login it belongs to.
        case ignore
        case add
        case update(existingID: String, name: String)
    }

    /// What a submitted login means for the vault.
    static func decide(host: String, username: String, password: String, items: [VaultItem]) -> SaveDecision {
        let siteLogins = Self.logins(for: host, in: items)
        guard !username.isEmpty else {
            if siteLogins.contains(where: { $0.password == password }) { return .unchanged }
            return siteLogins.isEmpty ? .add : .ignore
        }
        guard let existing = siteLogins.first(where: { ($0.username ?? "").caseInsensitiveCompare(username) == .orderedSame }) else {
            return .add
        }
        return existing.password == password ? .unchanged : .update(existingID: existing.id, name: existing.name)
    }

    /// Queues a submitted login for you to answer later, without taking the screen. Returns what happened.
    func queueSave(host: String, scheme: String, username: String, password: String, items: [VaultItem]) -> String {
        let existing: (id: String, name: String)?
        switch Self.decide(host: host, username: username, password: password, items: items) {
        case .unchanged: return "unchanged"
        case .ignore: return "ignored"
        case .add: existing = nil
        case .update(let id, let name): existing = (id, name)
        }
        let key = PendingLoginSave.key(host: host, username: username)
        guard !declinedSaves.contains(key) else { return "skipped" }
        // One entry per site and username: a retry after a typo replaces the first attempt instead of piling up.
        let replaced = pendingSaves.filter { $0.key == key }
        if let same = replaced.first, same.password == password, same.existingID == existing?.id { return "pending" }
        pendingSaves.removeAll { $0.key == key }
        LoginSaveNotifier.withdraw(replaced.map(\.id))
        let pending = PendingLoginSave(host: host, scheme: scheme, username: username, password: password,
                                       existingID: existing?.id, existingName: existing?.name)
        pendingSaves.append(pending)
        if pendingSaves.count > Self.maxPendingSaves {
            let dropped = pendingSaves.prefix(pendingSaves.count - Self.maxPendingSaves)
            LoginSaveNotifier.withdraw(dropped.map(\.id))
            pendingSaves.removeFirst(dropped.count)
        }
        revealSavesOnActivate = true
        LoginSaveNotifier.post(pending)
        return "pending"
    }

    private static let maxPendingSaves = 8

    /// Save (or update) a waiting login, or put it away with Not Now. False when it couldn't be written.
    @discardableResult
    func answerSave(_ id: String, save: Bool) async -> Bool {
        guard let index = pendingSaves.firstIndex(where: { $0.id == id }) else { return false }
        let pending = pendingSaves.remove(at: index)
        LoginSaveNotifier.withdraw([pending.id])
        if pendingSaves.isEmpty { revealSavesOnActivate = false }
        guard save else {
            declinedSaves.insert(pending.key)
            return true
        }
        guard let model, model.isUnlocked else { return false }
        let written: Bool
        // The login it would update may have gone since: then it is a new login after all.
        if let existingID = pending.existingID,
           model.items.contains(where: { $0.id == existingID && !$0.isDeleted && !$0.isArchived }) {
            written = await model.updateItem(existingID, edit: CipherEdit(password: pending.password))
        } else {
            let name = pending.host.hasPrefix("www.") ? String(pending.host.dropFirst(4)) : pending.host
            let edit = CipherEdit(name: name, username: pending.username, password: pending.password,
                                  uri: "\(pending.scheme)://\(pending.host)")
            written = await model.createItem(.login, edit: edit)
        }
        // Offline or refused: keep it in the bell to try again, unless the vault locked meanwhile.
        if !written, model.isUnlocked, !pendingSaves.contains(where: { $0.key == pending.key }) {
            pendingSaves.append(pending)
        }
        return written
    }

    private func handle(_ request: CLIRequest, peer: FramedSocketServer.Peer) async -> CLIResponse {
        guard let model else { return .failure("Triwarden is quitting.") }
        let browserCommand = [.match, .fill, .save].contains(request.command)
        let enabled = UserDefaults.standard.bool(forKey: browserCommand ? Pref.browser : Pref.cli) || approveOverride != nil
        guard enabled else {
            return .failure(browserCommand ? "Turn on the browser extension in Triwarden › Settings › Developer."
                                           : "Turn on “Answer the tw command” in Triwarden › Settings › Developer.")
        }
        switch request.command {
        case .match:
            // Names/usernames only, for the page's site, and only for our own extension/host binaries.
            guard Self.isOwnBinary(peer) else { return .failure("Unknown client.") }
            guard model.isUnlocked else { return .failure(Self.locked) }
            guard let host = request.url.flatMap(URL.init(string:))?.host()?.lowercased() else { return .list([]) }
            return .list(Self.logins(for: host, in: model.items).map {
                CLIResponse.Row(id: $0.id, name: $0.name, detail: $0.username ?? "")
            })
        case .fill:
            guard model.isUnlocked else { return .failure(Self.locked) }
            guard let item = model.items.first(where: { $0.id == request.query && !$0.isDeleted && !$0.isArchived }) else {
                return .failure("That login is no longer in your vault.")
            }
            let host = request.url.flatMap(URL.init(string:))?.host() ?? ""
            // Only fill a login on the site it belongs to.
            guard Self.logins(for: host.lowercased(), in: [item]).count == 1 else { return .failure("“\(item.name)” isn't for \(host).") }
            guard await approve(String(localized: "fill “\(item.name)” on \(host)"), peer: peer) else { return .failure(Self.denied) }
            return .credentials(username: item.username, password: item.password, totp: item.totp?.code())
        case .save:
            guard Self.isOwnBinary(peer) else { return .failure("Unknown client.") }
            guard model.isUnlocked else { return .failure(Self.locked) }
            guard let url = request.url.flatMap(URL.init(string:)), let host = url.host()?.lowercased(),
                  let password = request.password, !password.isEmpty else { return .failure("Nothing to save.") }
            let username = (request.username ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(queueSave(host: host, scheme: url.scheme ?? "https", username: username, password: password,
                                      items: model.items))
        case .status:
            return .success(model.isUnlocked
                ? "unlocked · \(model.sessions.count) account(s) · \(model.items.filter { !$0.isDeleted && !$0.isArchived }.count) items"
                : "locked")
        case .generate:
            var generator = PasswordGenerator.saved
            if let length = request.length { generator.length = min(max(length, 8), 128) }
            return .success(generator.generate())
        case .lock:
            model.lock()
            return .success("locked")
        case .list:
            guard model.isUnlocked else { return .failure(Self.locked) }
            guard await approve(String(localized: "list your vault items"), peer: peer) else { return .failure(Self.denied) }
            let q = request.query ?? ""
            let rows = model.items.filter { !$0.isDeleted && !$0.isArchived && (q.isEmpty || Self.matches($0, q)) }.map {
                CLIResponse.Row(id: $0.id, name: $0.name, detail: $0.username ?? $0.host ?? "")
            }
            return .list(rows)
        case .get, .code:
            guard model.isUnlocked else { return .failure(Self.locked) }
            let item: VaultItem
            switch Self.resolve(request.query ?? "", in: model.items) {
            case .success(let found): item = found
            case .failure(let message): return .failure(message.text)
            }
            let field = request.command == .code ? "totp" : (request.field ?? "password").lowercased()
            guard let value = Self.value(field, of: item) else {
                return .failure("“\(item.name)” has no \(field == "totp" ? "one-time code" : field).")
            }
            let what = field == "totp" ? String(localized: "the one-time code") : field
            guard await approve(String(localized: "read \(what) of “\(item.name)”"), peer: peer) else { return .failure(Self.denied) }
            return .success(value)
        }
    }

    static let locked = "The vault is locked. Unlock Triwarden first."
    static let denied = "Not approved."

    private func approve(_ action: String, peer: FramedSocketServer.Peer) async -> Bool {
        let grant = peer.processName
        if let until = approvedUntil[grant], until > .now { return true }
        let allowed: Bool
        if let approveOverride {
            allowed = approveOverride(action)
        } else {
            let context = LAContext()
            context.localizedCancelTitle = String(localized: "Deny")
            let reason = String(localized: "allow “\(peer.processName)” to \(action)")
            allowed = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
        }
        let window = UserDefaults.standard.integer(forKey: Pref.cliApprovalSeconds)
        if allowed, window > 0 { approvedUntil[grant] = .now.addingTimeInterval(TimeInterval(window)) }
        if allowed { model?.noteActivity() }
        return allowed
    }

    /// Our Safari extension and the bundled `tw` (Chrome's native-messaging host) live inside the app.
    static func isOwnBinary(_ peer: FramedSocketServer.Peer) -> Bool {
        guard let path = peer.path else { return false }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(Bundle.main.bundleURL.resolvingSymlinksInPath().path + "/")
    }

    /// Logins for `host`: same host or a subdomain/parent of it.
    static func logins(for host: String, in items: [VaultItem]) -> [VaultItem] {
        guard !host.isEmpty else { return [] }
        return items.filter { item in
            guard !item.isDeleted, !item.isArchived, item.kind == .login, item.password != nil else { return false }
            return item.hosts.contains { h in h == host || host.hasSuffix("." + h) || h.hasSuffix("." + host) }
        }
    }

    // MARK: Lookup

    struct Message: Error { let text: String }

    static func matches(_ item: VaultItem, _ q: String) -> Bool {
        item.name.localizedCaseInsensitiveContains(q) || (item.username?.localizedCaseInsensitiveContains(q) ?? false)
            || (item.host?.localizedCaseInsensitiveContains(q) ?? false)
            || item.websites.contains { $0.localizedCaseInsensitiveContains(q) }
    }

    /// Id, then exact name, then a unique partial match.
    static func resolve(_ query: String, in items: [VaultItem]) -> Result<VaultItem, Message> {
        let live = items.filter { !$0.isDeleted && !$0.isArchived }
        if let byID = live.first(where: { $0.id == query }) { return .success(byID) }
        let exact = live.filter { $0.name.caseInsensitiveCompare(query) == .orderedSame }
        if exact.count == 1 { return .success(exact[0]) }
        let partial = exact.isEmpty ? live.filter { matches($0, query) } : exact
        switch partial.count {
        case 1: return .success(partial[0])
        case 0: return .failure(Message(text: "No item matches “\(query)”."))
        default:
            let names = partial.prefix(5).map { "\($0.name) (\($0.id))" }.joined(separator: ", ")
            return .failure(Message(text: "“\(query)” matches \(partial.count) items: \(names). Use the id or a more exact name."))
        }
    }

    static func value(_ field: String, of item: VaultItem) -> String? {
        switch field {
        case "password": return item.password
        case "username": return item.username
        case "uri", "url": return item.uri
        case "notes": return item.notes
        case "totp", "code": return item.totp?.code()
        default:
            return item.customFields.first { $0.name.caseInsensitiveCompare(field) == .orderedSame }?.value
                ?? item.properties.first { $0.key.caseInsensitiveCompare(field) == .orderedSame }?.value
        }
    }
}

/// A login the browser extension saw you submit, waiting for Save or Not Now.
struct PendingLoginSave: Identifiable, Equatable, Sendable {
    let id = UUID().uuidString
    let host: String
    let scheme: String
    let username: String
    let password: String
    /// The login whose password this replaces; nil saves a new login.
    let existingID: String?
    let existingName: String?
    let date = Date.now

    var key: String { Self.key(host: host, username: username) }
    static func key(host: String, username: String) -> String { host + "\u{0}" + username.lowercased() }

    var isUpdate: Bool { existingID != nil }
    var title: String {
        if let existingName { return String(localized: "Update the password for “\(existingName)”?") }
        let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return String(localized: "Save the login for \(site)?")
    }
    var detail: String { username.isEmpty ? host : "\(username) · \(host)" }
}

/// The banner for a login waiting to be saved. Save and Not Now answer it right there; a click on the banner opens
/// the bell. It never carries the password.
enum LoginSaveNotifier {
    static let saveCategory = "login-save"
    static let updateCategory = "login-update"
    static let saveAction = "login-save.save"
    static let notNowAction = "login-save.not-now"
    static let userInfoKey = "loginSave"

    /// The banner buttons. Called once at launch.
    static func registerCategories() {
        let notNow = UNNotificationAction(identifier: notNowAction, title: String(localized: "Not Now"), options: [])
        let save = UNNotificationAction(identifier: saveAction, title: String(localized: "Save"), options: [])
        let update = UNNotificationAction(identifier: saveAction, title: String(localized: "Update"), options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: saveCategory, actions: [save, notNow], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: updateCategory, actions: [update, notNow], intentIdentifiers: [], options: []),
        ])
    }

    static func post(_ pending: PendingLoginSave) {
        // The self-tests answer saves directly; they shouldn't ask for notification permission or leave banners.
        guard !CommandLine.arguments.contains(where: { $0.hasPrefix("--selftest") || $0 == "--snapshot" }) else { return }
        let id = pending.id, title = pending.title, isUpdate = pending.isUpdate
        let body = pending.username.isEmpty
            ? String(localized: "From your browser · \(pending.host)")
            : String(localized: "\(pending.username) · from your browser")
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { add(id: id, title: title, body: body, isUpdate: isUpdate, center: center) }
                }
            case .authorized, .provisional:
                add(id: id, title: title, body: body, isUpdate: isUpdate, center: center)
            default:
                break // The bell and the menu bar panel still show it.
            }
        }
    }

    private static func add(id: String, title: String, body: String, isUpdate: Bool, center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = isUpdate ? updateCategory : saveCategory
        content.userInfo = [userInfoKey: id]
        center.add(UNNotificationRequest(identifier: "login-save-" + id, content: content, trigger: nil))
    }

    static func withdraw(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let identifiers = ids.map { "login-save-" + $0 }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}
