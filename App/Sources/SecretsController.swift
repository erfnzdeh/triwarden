import AppKit
import CryptoKit
import Foundation
import LocalAuthentication
import Observation
import SecretsAgent
import SwiftUI

/// Owns approval, never launches the target. Only the authenticated bundled CLI receives the value.
@MainActor @Observable
final class SecretsController: NSObject, NSWindowDelegate {
    static let approvalTimeout: Duration = .seconds(60)

    struct Prompt {
        struct Credential: Identifiable {
            let name: String
            let account: String
            let field: String
            let variable: String
            var id: String { variable }
        }
        let request: SecretsRunRequest
        let credential: String
        let account: String
        let helper: String
        let deadline: ContinuousClock.Instant
        var caller: SecretsCallerIdentity? = nil
        var credentials: [Credential] = []
    }
    private(set) var profiles: [SecretsProfile] = []
    private(set) var lastError: String?
    private(set) var pending: Prompt?
    private(set) var authenticating = false
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private let store: SecretsProfileStore
    @ObservationIgnored private let configurationAllowed: Bool
    @ObservationIgnored private let confirmation: SecretsProfileConfirmation
    @ObservationIgnored private var server: SecretsServer?
    @ObservationIgnored private var gate = RunGate()
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var answer: CheckedContinuation<SecretsGrantDuration?, Never>?
    @ObservationIgnored private var authentication: LAContext?
    @ObservationIgnored private var refreshWork: Task<Void, any Error>?
    private var grants = SecretsGrantStore()
    @ObservationIgnored private let fingerprintKey = SymmetricKey(size: .bits256)
    var activeGrantCount: Int { grants.activeCount() }
    var activeGrants: [SecretsActiveGrant] { grants.activeGrants() }

    func revokeGrant(_ id: UUID) {
        // Cached requests recheck this store immediately before delivery, including after refresh.
        grants.revoke(id)
    }
    #if DEBUG
    private(set) var lastDeliveryDuration: SecretsGrantDuration?
    // UI fixture configuration only; this never grants access or bypasses authentication.
    var selfTestInitialDuration: SecretsGrantDuration = .once
    #endif

    init(model: AppModel, start: Bool = true, store: SecretsProfileStore = .shared,
         confirmation: SecretsProfileConfirmation = SecretsProfileConfirmation()) {
        self.model = model
        configurationAllowed = start
        self.store = store
        self.confirmation = confirmation
        super.init()
        if start { reload() }
    }

    func save(_ profile: SecretsProfile) throws {
        guard configurationAllowed else { throw SecretsFailure("Saving a Secrets profile is disabled in demo and snapshot mode.") }
        let existing = try store.loadAll()
        // Never bless unreviewed changes to other tools when saving this tool.
        if !existing.isEmpty && !(existing.count == 1 && existing[0].name == profile.name) {
            try store.requireApprovedRevision(confirmation.read(), profiles: existing)
        }
        reset()
        let intendedRevision = try store.save(profile, basedOn: existing)
        try confirm(intendedRevision)
    }

    func remove(_ name: String) throws {
        guard configurationAllowed else { throw SecretsFailure("Removing saved tools is disabled in preview mode.") }
        let existing = try store.loadAll()
        try store.requireApprovedRevision(confirmation.read(), profiles: existing)
        reset()
        let intendedRevision = try store.remove(named: name, basedOn: existing)
        try confirm(intendedRevision)
    }

    func clearSetups() throws {
        guard configurationAllowed else { throw SecretsFailure("Resetting tool settings is disabled in preview mode.") }
        reset()
        let intendedRevision = try store.clear()
        try confirm(intendedRevision)
    }

    private func confirm(_ intendedRevision: String) throws {
        do { try confirmation.write(intendedRevision) }
        catch { reload(); throw error }
        reload()
    }

    private func reload() {
        do {
            profiles = try store.loadAll()
            lastError = nil
            guard !profiles.isEmpty else { server?.stop(); server = nil; return }
            try store.requireApprovedRevision(confirmation.read(), profiles: profiles)
            guard profiles.contains(where: \.enabled) else { server?.stop(); server = nil; return }
            guard server == nil else { return }
            let server = SecretsServer(socketURL: store.socketURL,
                                       expectedCLI: Bundle.main.bundleURL.appending(path: "Contents/MacOS/tw")) { [weak self] request, peer in
                guard let self else { return }
                await self.handle(request, peer: peer)
            }
            try server.start()
            self.server = server
        } catch {
            // Missing settings are normal on first run; other failures appear in Tools.
            if FileManager.default.fileExists(atPath: store.fileURL.path) { lastError = error.localizedDescription }
            server?.stop(); server = nil
        }
    }

    func reset() {
        gate.cancel()
        grants.reset()
        refreshWork?.cancel()
        complete(nil)
    }

    private func current(_ request: SecretsRunRequest, peer: SecretsPeer) -> Bool {
        guard gate.allows(request.nonce), peer.isConnected,
              let catalog = try? store.loadAll(),
              let saved = catalog.first(where: { $0.name == request.profile.name }), saved.enabled, saved == request.profile,
              (try? saved.revision()) == request.revision,
              saved.bindings.allSatisfy({ model?.session(for: $0.accountID) != nil }) else { return false }
        return (try? store.requireApprovedRevision(confirmation.read(), profiles: catalog)) != nil
    }

    private func item(for binding: SecretsBinding) throws -> VaultItem {
        guard let model, let session = model.session(for: binding.accountID) else {
            throw SecretsFailure("Unlock the selected key's account in Triwarden, then try again.")
        }
        let matches = session.items.filter { $0.id == binding.itemID && !$0.isDeleted && !$0.isArchived && $0.isSupported }
        guard matches.count == 1 else {
            throw SecretsFailure("A selected key is missing or unavailable. Edit this tool in Tools and select the key again.")
        }
        guard !matches[0].reprompt else {
            throw SecretsFailure("This item requires an additional master-password prompt, which tw run does not yet support. Use a dedicated API credential item with an appropriate policy.")
        }
        return matches[0]
    }

    private func handle(_ request: SecretsRunRequest, peer: SecretsPeer) async {
        func failure(_ message: String) -> SecretsRunResponse { .init(nonce: request.nonce, revision: request.revision, error: message) }
        do {
            try peer.validate()
            try request.profile.validate()
            let catalog = try store.loadAll()
            guard let saved = catalog.first(where: { $0.name == request.profile.name }), saved.enabled, saved == request.profile,
                  try saved.revision() == request.revision else {
                peer.reply(failure("The tool setup changed or is paused. Review it in Tools and run its saved command again."))
                return
            }
            try store.requireApprovedRevision(confirmation.read(), profiles: catalog)
            try gate.begin(request.nonce)
        } catch { peer.reply(failure(error.localizedDescription)); return }
        defer { gate.finish(request.nonce); complete(nil) }
        let deadline = ContinuousClock.now.advanced(by: Self.approvalTimeout)
        let watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                if ContinuousClock.now >= deadline || !self.current(request, peer: peer) {
                    self.reset(); return
                }
            }
        }
        defer { watcher.cancel() }
        do {
            let sessions = try Set(request.profile.bindings.map(\.accountID)).sorted().map { accountID in
                guard let session = model?.session(for: accountID) else {
                    throw SecretsFailure("Unlock every selected key's account in Triwarden, then try again.")
                }
                return session
            }
            // Online required: no silent cache fallback for the initial slice.
            let refresh = Task {
                for session in sessions { try Task.checkCancellation(); try await session.refresh() }
            }
            refreshWork = refresh
            defer { refreshWork = nil }
            do { try await refresh.value }
            catch { throw SecretsFailure("Couldn't refresh the vault online. No credential was supplied; check the account connection and try again.") }
            guard current(request, peer: peer), sessions.allSatisfy({ model?.session(for: $0.id) === $0 }) else {
                throw SecretsFailure("The request was cancelled, the account locked, or the profile changed.")
            }
            let selected = try request.profile.bindings.map { try item(for: $0) }
            try request.launch.verify(request.profile)
            let caller = try peer.caller()
            let fingerprint = try credentialFingerprint(selected, profile: request.profile)
            grants.retain(revision: request.revision, credentialFingerprint: fingerprint, launch: request.launch, tool: request.profile.name)
            let binding = caller.map {
                SecretsGrantBinding(caller: $0, helper: peer.executable.path, revision: request.revision,
                                    credentialFingerprint: fingerprint, launch: request.launch, tool: request.profile.name)
            }
            let cached = binding.flatMap { grants.allowed($0) }
            let choice: SecretsGrantDuration?
            if let cached { choice = cached }
            else {
                let credentials = zip(request.profile.bindings, selected).map { binding, item in
                    let account = sessions.first { $0.id == binding.accountID }!.account
                    return Prompt.Credential(name: Self.display(item.name), account: Self.display(account.email + " · " + account.serverSummary),
                                             field: Self.display(binding.field.label), variable: binding.variable)
                }
                pending = Prompt(request: request, credential: credentials[0].name, account: credentials[0].account,
                                 helper: peer.executable.path, deadline: deadline, caller: caller, credentials: credentials)
                choice = await withCheckedContinuation { continuation in
                    answer = continuation
                    showPanel()
                }
            }
            guard let choice, ContinuousClock.now < deadline, current(request, peer: peer) else {
                throw SecretsFailure("The launch was denied, cancelled, or expired. No command was started.")
            }
            try peer.validate()
            let latest = try request.profile.bindings.map { try item(for: $0) }
            guard try credentialFingerprint(latest, profile: request.profile) == fingerprint else {
                throw SecretsFailure("The credential changed during approval. Run again to review the current item.")
            }
            let values = try resolvedValues(latest, profile: request.profile)
            try request.launch.verify(request.profile)
            guard try peer.caller() == caller else { throw SecretsFailure("The calling process changed during approval. Run the command again.") }
            // Cached authorization must still be live at delivery, even if refresh/checks crossed its deadline.
            if let cached, let binding, grants.allowed(binding) != cached {
                throw SecretsFailure("Temporary access expired. Run the command again to approve it.")
            }
            guard current(request, peer: peer), ContinuousClock.now < deadline,
                  cached == nil || binding.map({ grants.allowed($0) == cached }) == true else {
                throw SecretsFailure("The launch was cancelled or temporary access expired before delivery.")
            }
            // Background restarts must not keep an idle vault unlocked indefinitely.
            if cached == nil { model?.noteActivity() }
            // Main actor: lock/reset cannot run between this check and the nonblocking send.
            if peer.reply(.init(nonce: request.nonce, revision: request.revision, values: values)) {
                if cached == nil, let binding { grants.grant(choice, for: binding) }
                #if DEBUG
                lastDeliveryDuration = choice
                #endif
            } else { reset() }
        } catch {
            gate.cancel()
            grants.reset()
            peer.reply(failure(error.localizedDescription))
        }
    }

    func deny() { reset() }

    func allow(_ duration: SecretsGrantDuration = .once) {
        guard let prompt = pending, !authenticating, gate.allows(prompt.request.nonce) else { return }
        guard duration == .once || prompt.caller != nil else { return }
        authenticating = true
        let context = LAContext()
        authentication = context
        context.localizedCancelTitle = String(localized: "Deny")
        let reason: String
        switch duration {
        case .once: reason = String(localized: "provide the selected API credentials to the saved development command once")
        case .tenMinutes: reason = String(localized: "allow the saved development command to use the selected API credentials for 10 minutes")
        case .untilLock: reason = String(localized: "allow the saved development command to use the selected API credentials until Triwarden locks")
        }
        Task { [weak self] in
            let allowed = (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                localizedReason: reason)) == true
            guard let self, self.pending?.request.nonce == prompt.request.nonce else { return }
            if allowed && self.gate.allows(prompt.request.nonce) { self.complete(duration) }
            else { self.reset() }
        }
    }

    private func complete(_ duration: SecretsGrantDuration?) {
        authentication?.invalidate(); authentication = nil
        authenticating = false
        pending = nil
        panel?.orderOut(nil)
        let continuation = answer; answer = nil
        continuation?.resume(returning: duration)
    }

    private func resolvedValues(_ items: [VaultItem], profile: SecretsProfile) throws -> [String: String] {
        guard items.count == profile.bindings.count else { throw SecretsFailure("A selected credential is unavailable.") }
        var values: [String: String] = [:]
        for (binding, item) in zip(profile.bindings, items) {
            values[binding.variable] = try binding.field.resolve(password: item.password,
                fields: item.customFields.map { SecretField(name: $0.name, value: $0.value, hidden: $0.kind == .hidden) })
        }
        _ = try LaunchPolicy.environment(parent: [:], values: values)
        return values
    }

    private func credentialFingerprint(_ items: [VaultItem], profile: SecretsProfile) throws -> String {
        let values = try resolvedValues(items, profile: profile)
        let scope = zip(profile.bindings, items).map { binding, item in
            [binding.variable, item.name, String(describing: item.revised), values[binding.variable]!]
        }
        let data = try JSONEncoder().encode(scope)
        return HMAC<SHA256>.authenticationCode(for: data, using: fingerprintKey).map { String(format: "%02x", $0) }.joined()
    }

    private func showPanel() {
        if panel == nil {
            let height = min(720, max(520, (NSScreen.main?.visibleFrame.height ?? 800) - 80))
            let panel = SecretsAccessPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: height),
                                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = String(localized: "Approve credential access")
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.contentMinSize = NSSize(width: 540, height: 520)
            panel.isReleasedWhenClosed = false
            panel.isFloatingPanel = true
            panel.level = .floating
            // The requester may keep focus; activation is cooperative and isn't guaranteed to succeed.
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.delegate = self
            panel.contentView = NSHostingView(rootView: SecretsApprovalPanelContent(controller: self))
            self.panel = panel
        }
        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { reset() }

    static func display(_ value: String) -> String {
        String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format }.prefix(512))
    }
}

private final class SecretsAccessPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
