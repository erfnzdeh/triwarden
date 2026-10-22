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
        let request: SecretsRunRequest
        let credential: String
        let account: String
        let helper: String
        let deadline: ContinuousClock.Instant
        var caller: SecretsCallerIdentity? = nil
    }
    private(set) var profile: SecretsProfile?
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
        try store.save(profile)
        try confirmation.write(profile.revision())
        reset()
        reload()
    }

    private func reload() {
        do {
            profile = try store.load()
            lastError = nil
            guard let profile, profile.enabled else { server?.stop(); server = nil; return }
            try profile.requireApprovedRevision(confirmation.read())
            guard server == nil else { return }
            let server = SecretsServer(socketURL: store.socketURL,
                                       expectedCLI: Bundle.main.bundleURL.appending(path: "Contents/MacOS/tw")) { [weak self] request, peer in
                guard let self else { return }
                await self.handle(request, peer: peer)
            }
            try server.start()
            self.server = server
        } catch {
            // A missing profile is the normal first-run state. Other failures are visible in Settings.
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
              let saved = try? store.load(), saved.enabled, saved == request.profile,
              (try? saved.revision()) == request.revision,
              model?.session(for: saved.accountID) != nil else { return false }
        return (try? saved.requireApprovedRevision(confirmation.read())) != nil
    }

    private func item(for profile: SecretsProfile) throws -> VaultItem {
        guard let model, let session = model.session(for: profile.accountID) else {
            throw SecretsFailure("Unlock the profile's account in Triwarden, then try again.")
        }
        let matches = session.items.filter { $0.id == profile.itemID && !$0.isDeleted && !$0.isArchived && $0.isSupported }
        guard matches.count == 1 else {
            throw SecretsFailure("The saved vault item is missing or unavailable. Select it again in Settings › Secrets.")
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
            guard let saved = try? store.load(), saved.enabled, saved == request.profile,
                  try saved.revision() == request.revision else {
                peer.reply(failure("The profile changed or is disabled. Save it in Settings › Secrets and run the command again."))
                return
            }
            try saved.requireApprovedRevision(confirmation.read())
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
            guard let session = model?.session(for: request.profile.accountID) else {
                throw SecretsFailure("Unlock the profile's account in Triwarden, then try again.")
            }
            // Online required: no silent cache fallback for the initial slice.
            let refresh = Task { try await session.refresh() }
            refreshWork = refresh
            defer { refreshWork = nil }
            do { try await refresh.value }
            catch { throw SecretsFailure("Couldn't refresh the vault online. No credential was supplied; check the account connection and try again.") }
            guard current(request, peer: peer), model?.session(for: session.id) === session else {
                throw SecretsFailure("The request was cancelled, the account locked, or the profile changed.")
            }
            let selected = try item(for: request.profile)
            try request.launch.verify(request.profile)
            let caller = try peer.caller()
            let fingerprint = try credentialFingerprint(selected, profile: request.profile)
            grants.retain(revision: request.revision, credentialFingerprint: fingerprint, launch: request.launch)
            let binding = caller.map {
                SecretsGrantBinding(caller: $0, helper: peer.executable.path, revision: request.revision,
                                    credentialFingerprint: fingerprint, launch: request.launch)
            }
            let cached = binding.flatMap { grants.allowed($0) }
            let choice: SecretsGrantDuration?
            if let cached { choice = cached }
            else {
                pending = Prompt(request: request, credential: Self.display(selected.name), account: Self.display(session.account.email + " · " + session.account.serverSummary), helper: peer.executable.path, deadline: deadline, caller: caller)
                choice = await withCheckedContinuation { continuation in
                    answer = continuation
                    showPanel()
                }
            }
            guard let choice, ContinuousClock.now < deadline, current(request, peer: peer) else {
                throw SecretsFailure("The launch was denied, cancelled, or expired. No command was started.")
            }
            try peer.validate()
            let latest = try item(for: request.profile)
            guard latest.revised == selected.revised, latest.customFields == selected.customFields, latest.password == selected.password else {
                throw SecretsFailure("The credential changed during approval. Run again to review the current item.")
            }
            let value = try request.profile.field.resolve(password: latest.password,
                fields: latest.customFields.map { SecretField(name: $0.name, value: $0.value, hidden: $0.kind == .hidden) })
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
            if peer.reply(.init(nonce: request.nonce, revision: request.revision, value: value)) {
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
        case .once: reason = String(localized: "provide one API credential to the saved development command")
        case .tenMinutes: reason = String(localized: "allow the saved development command to use one API credential for 10 minutes")
        case .untilLock: reason = String(localized: "allow the saved development command to use one API credential until Triwarden locks")
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

    private func credentialFingerprint(_ item: VaultItem, profile: SecretsProfile) throws -> String {
        let value = try profile.field.resolve(password: item.password,
            fields: item.customFields.map { SecretField(name: $0.name, value: $0.value, hidden: $0.kind == .hidden) })
        let data = try JSONEncoder().encode([item.name, String(describing: item.revised), value])
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
