import Foundation
import LocalAuthentication
import Observation
import SSHAgent

/// Serves the unlocked vault's SSH keys to `ssh`, `git` and friends. A signature names the app that asked,
/// then proves the device owner with Touch ID or the Mac login password. A grant can last 15 seconds,
/// 10 minutes, or until the vault locks. An app on the allowlist signs whenever the vault is unlocked.
@MainActor @Observable
final class SSHAgentService {
    /// `~/Library/Group Containers/<group>/agent.sock`. Kept short: a socket path must fit in 104 bytes.
    static var defaultSocket: URL {
        (FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AccountStore.appGroup)
            ?? FileManager.default.temporaryDirectory).appending(path: "agent.sock")
    }

    static var logURL: URL { defaultSocket.deletingLastPathComponent().appending(path: "ssh-access-log.json") }
    static var allowlistURL: URL { defaultSocket.deletingLastPathComponent().appending(path: "ssh-allowlist.json") }

    private(set) var isRunning = false
    private(set) var lastError: String?
    /// Last few uses, newest first, for the menu bar.
    private(set) var recent: [(date: Date, key: String, program: String, allowed: Bool)] = []
    /// The prompt on screen, when a signature is waiting.
    private(set) var pending: SSHPrompt?
    private(set) var pendingCount = 0
    private(set) var accessLog: SSHAccessLog
    /// Apps that may sign whenever the vault is unlocked. Kept across lock and quit.
    private(set) var allowlist: SSHAllowlist
    private(set) var trustedUntilLock: [SSHTrust] = []

    private var server: SSHAgentServer?
    private var parsed: [String: (pem: String, key: SSHPrivateKey)] = [:]
    private var trust = SSHTrustStore()
    private let prompts = SSHApprovalQueue()
    private var inflight: [String: Task<(Bool, SSHChoice), Never>] = [:]
    private var inflightPrompt: [String: UUID] = [:]
    private var sessionStarted = Date()
    private var watching = false
    private var authenticating = false
    private weak var model: AppModel?
    /// Self-test hook: skip the card and Touch ID. Arguments stay (key name, peer process name).
    var approveOverride: ((String, String) -> Bool)?

    init(model: AppModel) {
        self.model = model
        accessLog = SSHAccessLog.load(from: Self.logURL)
        allowlist = SSHAllowlist.load(from: Self.allowlistURL)
    }

    func start(at socket: URL = defaultSocket) {
        guard server == nil else { return }
        let server = SSHAgentServer(
            socketURL: socket,
            identities: { [weak self] in await self?.identities() ?? [] },
            approve: { [weak self] identity, peer in await self?.approve(identity, peer) ?? false })
        do {
            try server.start()
            self.server = server
            isRunning = true
            lastError = nil
            SSHApprovalNotifier.requestPermission()
        } catch SSHAgentServer.Failure.pathTooLong {
            lastError = String(localized: "Couldn't start the SSH agent: the socket path is longer than macOS allows (104 bytes). This happens with very long user names.")
        } catch {
            lastError = String(localized: "Couldn't start the SSH agent: \(String(describing: error))")
        }
    }

    func stop() {
        server?.stop()
        server = nil
        isRunning = false
    }

    var socketPath: String { server?.socketURL.path ?? Self.defaultSocket.path }

    /// The first ask in this unlock leads with Allow Once. A later ask leads with Trust Until Lock.
    var pendingLeadsWithUntilLock: Bool {
        guard let pending else { return false }
        return SSHApprovalEmphasis.leadsWithUntilLock(priorAsks: accessLog.priorAsks(trustKey: pending.trustKey, since: sessionStarted))
    }

    func choose(_ choice: SSHChoice) {
        Task { await prompts.resolveFront(choice) }
    }

    /// The menu bar or a notification tap brings the waiting card back.
    func reveal() {
        guard pending != nil else { return }
        MenuBarOpener.isOpen = false
        MenuBarOpener.open()
    }

    func revokeTrust(id: String) {
        trust.revoke(id: id)
        trustedUntilLock = trust.untilLock
    }

    func clearAccessLog() {
        accessLog.clear()
        try? FileManager.default.removeItem(at: Self.logURL)
        recent = []
    }

    /// Forget approvals and parsed keys (on lock). The access log stays.
    func reset() {
        parsed = [:]
        trust.reset()
        trustedUntilLock = []
        sessionStarted = .now
        Task { await prompts.denyAll() }
    }

    // MARK: Agent callbacks

    /// SSH key items from every unlocked account. Empty while locked.
    private func identities() -> [SSHAgentServer.Identity] {
        guard let model else { return [] }
        return model.items.filter { $0.kind == .sshKey && !$0.isDeleted && !$0.isArchived }.compactMap { item in
            guard let pem = item.properties["privateKey"], !pem.isEmpty else { return nil }
            if let cached = parsed[item.id], cached.pem == pem {
                return SSHAgentServer.Identity(id: item.id, name: item.name, key: cached.key)
            }
            guard let key = try? SSHPrivateKey(pem: pem) else { return nil }
            parsed[item.id] = (pem, key)
            return SSHAgentServer.Identity(id: item.id, name: item.name, key: key)
        }
    }

    private func approve(_ identity: SSHAgentServer.Identity, _ peer: SSHAgentServer.Peer) async -> Bool {
        if let approveOverride {
            let allowed = approveOverride(identity.name, peer.processName)
            recent.insert((.now, identity.name, peer.processName, allowed), at: 0)
            if recent.count > 8 { recent.removeLast() }
            return allowed
        }
        let requester = SSHProcess.requester(for: peer)
        guard model?.isUnlocked == true else {
            record(requester, key: identity.name, outcome: .locked)
            return false
        }
        trust.expire(now: .now)
        trustedUntilLock = trust.untilLock
        if trust.allows(trustKey: requester.trustKey, keyID: identity.id, now: .now) != nil {
            record(requester, key: identity.name, outcome: .reusedTrust)
            model?.noteActivity()
            return true
        }
        if allowlist.contains(requester.trustKey) {
            record(requester, key: identity.name, outcome: .allowlisted)
            model?.noteActivity()
            return true
        }

        let pair = "\(requester.trustKey)|\(identity.id)"
        if let existing = inflight[pair] {
            if let id = inflightPrompt[pair] {
                await prompts.noteJoined(id)
                await refreshPending()
            }
            let (ok, choice) = await existing.value
            record(requester, key: identity.name, outcome: Self.outcome(ok: ok, choice: choice))
            if ok { model?.noteActivity() }
            return ok
        }

        let prompt = SSHPrompt(id: UUID(), trustKey: requester.trustKey, displayName: requester.displayName,
                               via: requester.via, path: requester.peerPath, keyID: identity.id, keyName: identity.name,
                               appPath: requester.appPath)
        let task = Task { @MainActor in
            async let choice = self.prompts.ask(prompt)
            await Task.yield()
            await self.refreshPending()
            SSHApprovalNotifier.arm(prompt)
            let decided = await choice
            SSHApprovalNotifier.cancel(prompt.id)
            let ok = await self.authenticate(decided, requester: requester, identity: identity)
            await self.refreshPending()
            return (ok, decided)
        }
        inflight[pair] = task
        inflightPrompt[pair] = prompt.id
        let (ok, choice) = await task.value
        inflight[pair] = nil
        inflightPrompt[pair] = nil
        record(requester, key: identity.name, outcome: Self.outcome(ok: ok, choice: choice))
        if ok { model?.noteActivity() }
        return ok
    }

    private func authenticate(_ choice: SSHChoice, requester: SSHRequester, identity: SSHAgentServer.Identity) async -> Bool {
        guard case .allow(let grant) = choice else { return false }
        authenticating = true
        defer { authenticating = false }
        let context = LAContext()
        context.localizedCancelTitle = String(localized: "Deny")
        let reason = String(localized: "allow “\(requester.displayName)” to sign with the SSH key “\(identity.name)”")
        let ok = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
        guard ok, model?.isUnlocked == true else { return false }
        if grant == .always {
            var list = allowlist
            list.add(SSHAllowlistEntry(trustKey: requester.trustKey, displayName: requester.displayName))
            allowlist = list
            try? allowlist.save(to: Self.allowlistURL)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: Self.allowlistURL.path)
            return true
        }
        let until: Date? = switch grant {
        case .once: Date.now.addingTimeInterval(15)
        case .tenMinutes: Date.now.addingTimeInterval(600)
        case .untilLock, .always: nil
        }
        trust.grant(SSHTrust(trustKey: requester.trustKey, keyID: identity.id, displayName: requester.displayName,
                             keyName: identity.name, until: until))
        trustedUntilLock = trust.untilLock
        return true
    }

    func revokeAllowlist(trustKey: String) {
        var list = allowlist
        list.remove(trustKey: trustKey)
        allowlist = list
        try? allowlist.save(to: Self.allowlistURL)
    }

    private func refreshPending() async {
        let snap = await prompts.snapshot()
        let previous = pending?.id
        pending = snap.current
        pendingCount = snap.count
        if pending != nil { ensureWatch() }
        if let id = pending?.id, id != previous {
            MenuBarOpener.open()
        }
    }

    private func ensureWatch() {
        guard !watching else { return }
        watching = true
        Task { @MainActor in
            while self.pendingCount > 0 {
                try? await Task.sleep(for: .seconds(1))
                await self.prompts.expire(now: .now)
                await self.refreshPending()
            }
            self.watching = false
        }
    }

    private func record(_ requester: SSHRequester, key: String, outcome: SSHAccessOutcome) {
        let allowed = switch outcome {
        case .allowedOnce, .allowedForTenMinutes, .allowedUntilLock, .allowlisted, .reusedTrust: true
        default: false
        }
        recent.insert((.now, key, requester.displayName, allowed), at: 0)
        if recent.count > 8 { recent.removeLast() }
        accessLog.append(SSHAccessEvent(id: UUID(), date: .now, appName: requester.displayName, via: requester.via,
                                         path: requester.peerPath, keyName: key, outcome: outcome, trustKey: requester.trustKey))
        try? accessLog.save(to: Self.logURL)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: Self.logURL.path)
    }

    private static func outcome(ok: Bool, choice: SSHChoice) -> SSHAccessOutcome {
        if case .timedOut = choice { return .timedOut }
        guard ok else { return .denied }
        switch choice {
        case .allow(.once): return .allowedOnce
        case .allow(.tenMinutes): return .allowedForTenMinutes
        case .allow(.untilLock): return .allowedUntilLock
        case .allow(.always): return .allowlisted
        case .deny, .timedOut: return .denied
        }
    }
}
