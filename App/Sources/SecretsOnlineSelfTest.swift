#if DEBUG
import AppKit
import Darwin
import Foundation
import SecretsAgent
import SwiftUI
import VaultwardenAPI

/// Uses only the documented disposable dev account and a loopback tunnel. Never bypasses native authentication.
@MainActor
enum SecretsOnlineSelfTest {
    static var requested: Bool {
        CommandLine.arguments.contains("--selftest-secrets-online") || interactive || presentation || envImportOnline
    }
    private static var interactive: Bool { CommandLine.arguments.contains("--selftest-secrets-interactive") || envInteractive }
    private static var envInteractive: Bool { CommandLine.arguments.contains("--selftest-secrets-env-interactive") }
    private static var envImportOnline: Bool { CommandLine.arguments.contains("--selftest-env-import-online") }
    private static var presentation: Bool { CommandLine.arguments.contains("--selftest-secrets-presentation") }

    static func runIfRequested() {
        guard requested else { return }
        guard AccountStore.namespace.hasPrefix("SecretsSelfTest-") else { exit(64) }
        Task { exit(await run()) }
    }

    private static func run() async -> Int32 {
        let identifier = UUID().uuidString
        let fm = FileManager.default
        guard let group = fm.containerURL(forSecurityApplicationGroupIdentifier: AccountStore.appGroup) else { return 1 }
        // Keep the Unix socket below sockaddr_un's path limit. The full UUID marker protects against collisions.
        let root = group.appendingPathComponent("S" + identifier.prefix(8))
        guard mkdir(root.path, 0o700) == 0 else { return 1 }
        let store = SecretsProfileStore(directory: root.appendingPathComponent("p"))
        let confirmation = SecretsProfileConfirmation(service: "io.github.sinhong2011.triwarden.secrets.selftest." + identifier)
        let accounts = group.appendingPathComponent(AccountStore.namespace)
        let keys = ["serverKind", "serverURL", "email", "accountFocus", "vaultFilter"]
        let preferences = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        var children: [Process] = []
        var errorFiles: [Int32: URL] = [:]
        var activeModel: AppModel?
        var created: (id: String, name: String, account: String)?
        var failures = 0
        func check(_ success: Bool, _ message: String) {
            print(success ? "PASS" : "FAIL", message); fflush(stdout)
            if !success { failures += 1 }
        }
        defer {
            for child in children where child.isRunning { child.terminate() }
            try? confirmation.delete()
            try? fm.removeItem(at: root)
            try? fm.removeItem(at: accounts)
            for (key, value) in preferences {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        do {
            try Data(identifier.utf8).write(to: root.appendingPathComponent("test-id"), options: .atomic)
            let model = AppModel(secretsFactory: { model in
                SecretsController(model: model, store: store, confirmation: confirmation)
            })
            activeModel = model
            let controller = model.secrets!
            // Seed a nondefault UI selection to exercise duration reuse. The real
            // approval button and device-owner authentication are still required.
            if interactive && !envInteractive { controller.selfTestInitialDuration = .untilLock }
            let port = ProcessInfo.processInfo.environment["TRIWARDEN_SECRETS_TEST_PORT"] ?? "28880"
            guard let number = UInt16(port), number > 0 else { throw SecretsFailure("Invalid loopback test port.") }
            model.serverKind = .selfHosted
            model.serverURL = "http://127.0.0.1:\(number)"
            model.email = "usagi@chiikawarden.test"
            await model.login(password: "chiikawa-dev-password")
            guard model.isUnlocked, let account = model.sessions.first?.id else {
                throw SecretsFailure("Disposable dev-account login failed. Check the loopback tunnel and seeded dev account.")
            }
            check(true, "real dev-account login, decryption and online sync")
            if let interrupted = ProcessInfo.processInfo.environment["TRIWARDEN_SECRETS_CLEANUP_TEST"] {
                try await cleanupInterrupted(interrupted, group: group, model: model, account: account)
                check(true, "owned interrupted canary and its local confirmation removed")
            }
            if envImportOnline {
                failures += await EnvKeyImportSelfTest.run(model: model, root: root, account: account)
            } else {
            let tag = "triwarden-secrets-canary-" + identifier
            var edit = CipherEdit(name: tag)
            edit.customFields = [CustomField(name: "api-key", value: "triwarden-test-only", kind: .hidden)]
            guard await model.createItem(.secureNote, edit: edit, accountId: account),
                  let itemID = model.items.first(where: { $0.name == tag })?.id else {
                throw SecretsFailure("Couldn't create the uniquely named dummy credential.")
            }
            created = (itemID, tag, account)
            let marker = root.appendingPathComponent("executed")
            var profile = SecretsProfile(name: "canary", accountID: account, itemID: itemID, field: .hidden("api-key"),
                variable: "TRIWARDEN_TEST_KEY", executable: "/bin/sh",
                arguments: ["-c", "test \"${TRIWARDEN_TEST_KEY:-}\" = triwarden-test-only || exit 98; printf received > \"$1\"; exit 37", "canary", marker.path],
                // Process-spawned helpers inherit the App sandbox; use its disposable App Group directory.
                // The unsandboxed terminal /tmp case is covered by the real-process package regression.
                directory: root.path)
            try controller.save(profile)
            guard controller.lastError == nil else { throw SecretsFailure(controller.lastError!) }
            check(true, "enabled native profile starts its isolated socket")
            if envInteractive {
                var copied: URL?, closed = false
                let destination = root.appendingPathComponent(EnvReferenceFile.defaultName)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.title = "Triwarden reference file test"
                window.contentView = NSHostingView(rootView: ReferenceExportAcceptanceHost(profile: profile, destination: destination,
                    onCopy: { copied = $0 }, onClose: { closed = true }).environment(model))
                window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate()
                defer { window.close() }
                print("ACTION: Select Save File in the test window. Keep the proposed name and folder. Select Copy Launch. This test uses one dummy key."); fflush(stdout)
                let deadline = ContinuousClock.now.advanced(by: .seconds(300))
                while copied == nil, !closed, window.isVisible, .now < deadline {
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard let copied, copied.standardizedFileURL == destination.standardizedFileURL else {
                    throw SecretsFailure("Reference export acceptance did not finish. No launch was requested.")
                }
                try EnvReferenceFile.read(copied).validate(against: profile)
                let file = try String(contentsOf: copied, encoding: .utf8)
                check(!file.contains("triwarden-test-only"), "real save panel exports matching references without the dummy key value")
                window.close()
            }

            func diagnostic(_ process: Process) -> String {
                guard let url = errorFiles[process.processIdentifier], let handle = try? FileHandle(forReadingFrom: url) else { return "no CLI error" }
                defer { try? handle.close() }
                return String(decoding: (try? handle.read(upToCount: 4096)) ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            func launch() throws -> Process {
                let process = Process()
                process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/tw")
                process.arguments = [envInteractive ? "--selftest-secrets-run-env" : "--selftest-secrets-run", identifier]
                process.standardOutput = FileHandle.nullDevice
                let errorURL = root.appendingPathComponent("error-" + UUID().uuidString)
                guard fm.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw SecretsFailure("Couldn't create the disposable CLI diagnostic file.")
                }
                let error = try FileHandle(forWritingTo: errorURL)
                defer { try? error.close() }
                process.standardError = error
                try process.run(); children.append(process)
                errorFiles[process.processIdentifier] = errorURL
                return process
            }
            func pending(_ process: Process) async throws {
                let deadline = ContinuousClock.now.advanced(by: .seconds(15))
                while controller.pending == nil, process.isRunning, .now < deadline {
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard controller.pending != nil else { throw SecretsFailure("The bundled CLI did not reach native approval after online refresh. " + diagnostic(process)) }
            }
            func finished(_ process: Process) async throws -> Int32 {
                let deadline = ContinuousClock.now.advanced(by: .seconds(65))
                while process.isRunning, .now < deadline { try await Task.sleep(for: .milliseconds(50)) }
                guard !process.isRunning else { process.terminate(); throw SecretsFailure("CLI did not finish before the test deadline.") }
                return process.terminationStatus
            }
            func noLaunch(_ status: Int32, _ label: String) {
                check(status != 0 && status != 37 && !fm.fileExists(atPath: marker.path) && controller.pending == nil, label)
            }
            if presentation {
                guard let otherApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
                    throw SecretsFailure("The presentation probe needs a running Finder for cooperative focus handoff.")
                }
                let witness = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                                       styleMask: [.titled, .closable], backing: .buffered, defer: false)
                witness.isReleasedWhenClosed = false
                witness.orderOut(nil)
                NSApp.yieldActivation(to: otherApp)
                _ = otherApp.activate()
                try await Task.sleep(for: .milliseconds(500))
                // Activation is cooperative: macOS may leave the user's current app
                // in front instead of Finder. Preserve the actual foreground app.
                guard let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier, foreground != getpid() else {
                    throw SecretsFailure("Presentation check requires another foreground app on an unlocked desktop.")
                }
                let child = try launch(); try await pending(child)
                try await Task.sleep(for: .milliseconds(500))
                let panel = NSApp.windows.first { $0.title == String(localized: "Approve credential access") }
                check(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground && !witness.isVisible,
                      "showing credential approval preserves foreground app and leaves ordinary windows hidden")
                try await Task.sleep(for: .milliseconds(500))
                // A nonactivating panel can be key while AppKit reports isActive; the
                // workspace's foreground application is the observable focus contract.
                check(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,
                      "presentation probe keeps the original foreground application")
                print("PRESENTATION active=\(NSApp.isActive) policy=\(NSApp.activationPolicy().rawValue) panelVisible=\(panel?.isVisible == true) key=\(panel?.isKeyWindow == true) onActiveSpace=\(panel?.isOnActiveSpace == true) unoccluded=\(panel?.occlusionState.contains(.visible) == true) hidesOnDeactivate=\(panel?.hidesOnDeactivate == true) frontmostIsSelf=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid())")
                fflush(stdout)
                check(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground &&
                      panel?.isVisible == true && panel?.isOnActiveSpace == true && panel?.occlusionState.contains(.visible) == true,
                      "approval card remains visible while another app stays in front")
                check(panel?.styleMask.contains(.nonactivatingPanel) == true && panel?.canBecomeMain == false,
                      "credential approval uses an independent nonactivating panel")
                check(panel?.collectionBehavior.contains(.moveToActiveSpace) == true &&
                      panel?.collectionBehavior.contains(.fullScreenAuxiliary) == true,
                      "credential approval follows the active Space and supports fullscreen auxiliary presentation")
                controller.deny()
                noLaunch(try await finished(child), "presentation probe cancels without exec")
            } else if interactive {
                print(envInteractive
                    ? "ACTION: The reference file now selects the saved canary. Keep Allow Once, allow this launch, then complete Touch ID or your Mac password."
                    : "ACTION: The isolated UI fixture preselects Trust Until Lock. Review the canary card, confirm its matching action, then use Touch ID or your Mac password. You may change the duration. No real API key is involved."); fflush(stdout)
                let child = try launch()
                try await pending(child)
                let status = try await finished(child)
                if status != 37 { print("DIAGNOSTIC CLI exit \(status): \(diagnostic(child))"); fflush(stdout) }
                check(status == 37 && (try? String(contentsOf: marker, encoding: .utf8)) == "received", "native approval and device authentication deliver the dummy key to real CLI exec")
                if status == 37 {
                    let duration = controller.lastDeliveryDuration
                    let reusable = duration != nil && duration != .once
                    print("INFO delivered approval duration: \(duration?.rawValue ?? "missing")"); fflush(stdout)
                    check(duration != nil && (controller.activeGrantCount > 0) == reusable,
                          "delivered approval duration matches retained authorization")
                    try fm.removeItem(at: marker)
                    let repeated = try launch()
                    var unexpectedlyPrompted = false
                    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
                    while repeated.isRunning, .now < deadline {
                        if controller.pending != nil {
                            unexpectedlyPrompted = true
                            controller.deny()
                        }
                        try await Task.sleep(for: .milliseconds(25))
                    }
                    let repeatedStatus = try await finished(repeated)
                    if reusable {
                        check(!unexpectedlyPrompted && repeatedStatus == 37 && fm.fileExists(atPath: marker.path),
                              "same authenticated calling process reuses temporary approval without another prompt")
                        if fm.fileExists(atPath: marker.path) { try fm.removeItem(at: marker) }
                        controller.reset()
                        check(controller.activeGrantCount == 0, "explicit revocation removes temporary access")
                        let revoked = try launch(); try await pending(revoked)
                        controller.deny()
                        noLaunch(try await finished(revoked), "revoked access asks again and denial prevents exec")
                    } else {
                        check(unexpectedlyPrompted, "Allow Once requires a new approval")
                        noLaunch(repeatedStatus, "denied repeated launch cannot exec")
                    }
                }
            } else {
                let denied = try launch(); try await pending(denied)
                controller.deny()
                noLaunch(try await finished(denied), "denied native request cannot exec")
                try await Task.sleep(for: .milliseconds(10_200))

                let disconnected = try launch(); try await pending(disconnected)
                disconnected.terminate()
                _ = try await finished(disconnected)
                try await Task.sleep(for: .milliseconds(500))
                noLaunch(disconnected.terminationStatus, "CLI disconnect clears native approval without exec")
                try await Task.sleep(for: .milliseconds(10_200))

                let changed = try launch(); try await pending(changed)
                profile.arguments.append("changed")
                try controller.save(profile)
                noLaunch(try await finished(changed), "native profile save cancels outstanding approval")
                try await Task.sleep(for: .milliseconds(10_200))

                let locked = try launch(); try await pending(locked)
                model.lock(account)
                noLaunch(try await finished(locked), "real account lock cancels native approval without exec")
                await model.unlock(password: "chiikawa-dev-password", accountId: account)
            }
            }
        } catch {
            check(false, error.localizedDescription)
        }
        // Cleanup also runs after a failed assertion, timeout or thrown error, before logging out.
        if let model = activeModel {
            model.secrets.reset()
            for child in children where child.isRunning { child.terminate() }
            if let created {
                if model.session(for: created.account) == nil {
                    await model.unlock(password: "chiikawa-dev-password", accountId: created.account)
                }
                do {
                    guard let session = model.session(for: created.account) else { throw SecretsFailure("Cannot unlock for canary cleanup.") }
                    // unlock() opens the encrypted cache first; its online resume runs in a separate Task.
                    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
                    while session.lastSynced == nil && session.lastSyncError == nil && .now < deadline {
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    try await session.refresh()
                    if let item = model.items.first(where: { $0.id == created.id && $0.name == created.name }) {
                        await model.deleteForever(item)
                    }
                    try await session.refresh()
                    check(!model.items.contains(where: { $0.id == created.id }), "dummy vault item removed and confirmed by online refresh")
                } catch { check(false, "Couldn't remove dummy vault item \(created.name); remove it from the dev account manually.") }
            }
            if var profile = model.secrets.profiles.first(where: { $0.name == "canary" }) {
                profile.enabled = false; try? model.secrets.save(profile)
            }
            for account in model.accounts { model.logOut(account.id) }
        }
        do {
            try confirmation.delete()
            try fm.removeItem(at: root)
            if fm.fileExists(atPath: accounts.path) { try fm.removeItem(at: accounts) }
            check(confirmation.read() == nil && !fm.fileExists(atPath: root.path) && !fm.fileExists(atPath: accounts.path), "isolated local files and Keychain record removed before exit")
        } catch { check(false, "Couldn't clean up isolated local test records.") }
        print("Secrets online self-test: \(failures) failure(s)"); fflush(stdout)
        return failures == 0 ? 0 : 1
    }

    /// Recover only a UUID-marked canary from this diagnostic's disposable account.
    private static func cleanupInterrupted(_ identifier: String, group: URL, model: AppModel, account: String) async throws {
        guard UUID(uuidString: identifier) != nil, let session = model.session(for: account) else {
            throw SecretsFailure("Invalid interrupted test identifier.")
        }
        let root = group.appendingPathComponent("S" + identifier.prefix(8))
        guard (try? String(contentsOf: root.appendingPathComponent("test-id"), encoding: .utf8)) == identifier else {
            throw SecretsFailure("The interrupted test marker does not match.")
        }
        let profiles = try SecretsProfileStore(directory: root.appendingPathComponent("p")).loadAll()
        guard profiles.count == 1, let profile = profiles.first, profile.name == "canary", profile.accountID == account else {
            throw SecretsFailure("The interrupted test profile does not match.")
        }
        try await session.refresh()
        if let item = session.items.first(where: { $0.id == profile.itemID }) {
            guard item.name == "triwarden-secrets-canary-" + identifier,
                  item.customFields.filter({ $0.name == "api-key" }).count == 1,
                  item.customFields.contains(where: { $0.name == "api-key" && $0.kind == .hidden && $0.value == "triwarden-test-only" }) else {
                throw SecretsFailure("The interrupted canary does not match. No item was removed.")
            }
            try await session.deleteForever(item.id)
        }
        try await session.refresh()
        guard !session.items.contains(where: { $0.id == profile.itemID }) else { throw SecretsFailure("Cannot confirm canary removal.") }
        try SecretsProfileConfirmation(service: "io.github.sinhong2011.triwarden.secrets.selftest." + identifier).delete()
        try FileManager.default.removeItem(at: root)
    }
}

private struct ReferenceExportAcceptanceHost: View {
    let profile: SecretsProfile
    let destination: URL
    let onCopy: (URL) -> Void
    let onClose: () -> Void
    @State private var presented = false

    var body: some View {
        Text("Reference file test").frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { WindowBackdrop() }
            .onAppear { presented = true }
            .sheet(isPresented: $presented, onDismiss: onClose) {
                EnvReferenceExport(profile: profile, testDestinationURL: destination, onTestCopy: onCopy)
            }
    }
}
#endif
