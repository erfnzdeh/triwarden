import AppKit
import TriCrypto
import Foundation
import LocalAuthentication
import Observation
import SSHAgent
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
    /// Self-test hook: answer "Save this login?" without showing it.
    var confirmOverride: ((String) -> Bool)?

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

    func reset() { approvedUntil = [:] }

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
            guard model.isUnlocked else { return .failure(Self.locked) }
            guard let url = request.url.flatMap(URL.init(string:)), let host = url.host()?.lowercased(),
                  let password = request.password, !password.isEmpty else { return .failure("Nothing to save.") }
            let username = request.username ?? ""
            let existing = Self.logins(for: host, in: model.items)
                .first { ($0.username ?? "").caseInsensitiveCompare(username) == .orderedSame }
            if let existing {
                guard existing.password != password else { return .success("unchanged") }
                guard confirm(String(localized: "Update the password for “\(existing.name)” (\(username))?")) else { return .success("skipped") }
                return await model.updateItem(existing.id, edit: CipherEdit(password: password)) ? .success("updated") : .failure("Couldn't save.")
            }
            let label = username.isEmpty ? host : "\(username) · \(host)"
            guard confirm(String(localized: "Save this login to Triwarden? \(label)")) else { return .success("skipped") }
            let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            let edit = CipherEdit(name: name, username: username, password: password, uri: "\(url.scheme ?? "https")://\(host)")
            return await model.createItem(.login, edit: edit) ? .success("saved") : .failure("Couldn't save.")
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

    /// "Save this login?" — a real dialog, since a page could otherwise fill the vault with junk.
    private func confirm(_ message: String) -> Bool {
        if let confirmOverride { return confirmOverride(message) }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = String(localized: "Requested by the Triwarden browser extension.")
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        return alert.runModal() == .alertFirstButtonReturn
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
