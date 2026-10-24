#if DEBUG
import AppKit
import Foundation
import SecretsAgent

/// Actual Data Protection Keychain and native controller configuration checks.
/// Every file and Keychain service is isolated; this never opens or migrates a real credential.
@MainActor
enum SecretsSelfTest {
    static func prepareModelIfRequested() {
        guard CommandLine.arguments.contains("--selftest-secrets") || SecretsOnlineSelfTest.requested else { return }
        AccountStore.namespace = "SecretsSelfTest-" + UUID().uuidString
        AutoFillIdentities.isEnabled = false
    }

    static func runIfRequested() {
        guard CommandLine.arguments.contains("--selftest-secrets") else { return }
        guard AccountStore.namespace.hasPrefix("SecretsSelfTest-") else {
            print("FAIL account storage must be isolated before AppModel construction")
            exit(1)
        }
        Task {
            let identifier = UUID().uuidString
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("SecretsSelfTest-" + identifier)
            let confirmation = SecretsProfileConfirmation(service: "io.github.sinhong2011.triwarden.secrets.selftest." + identifier)
            let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AccountStore.appGroup)
                ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let accounts = base.appendingPathComponent(AccountStore.namespace)
            var failures = runChecks(root: root, accounts: accounts, confirmation: confirmation)
            // runChecks must return normally so its cleanup runs before process termination.
            if !FileManager.default.fileExists(atPath: root.path),
               !FileManager.default.fileExists(atPath: accounts.path), confirmation.read() == nil {
                print("PASS isolated files and Keychain record cleaned before process exit")
            } else {
                print("FAIL self-test cleanup")
                failures += 1
            }
            print("Secrets native self-test: \(failures) failure(s)")
            exit(failures == 0 ? 0 : 1)
        }
    }

    private static func runChecks(root: URL, accounts: URL, confirmation: SecretsProfileConfirmation) -> Int {
        var failures = 0
        func check(_ value: Bool, _ label: String) {
            print(value ? "PASS" : "FAIL", label)
            if !value { failures += 1 }
        }
        let store = SecretsProfileStore(directory: root.appendingPathComponent("profile"))
        defer {
            try? confirmation.delete()
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: accounts)
        }
        do {
            let model = AppModel()
            check(model.accounts.isEmpty && AccountStore.namespace.hasPrefix("SecretsSelfTest-"), "initial account access uses an isolated empty namespace")
            let original = SecretsProfile(name: "selftest", accountID: "synthetic", itemID: "synthetic",
                field: .hidden("api-key"), variable: "API_KEY", executable: "/usr/bin/true", arguments: [], directory: "/tmp", enabled: false)
            check(confirmation.read() == nil, "isolated Keychain service starts empty")
            let native = SecretsController(model: model, store: store, confirmation: confirmation)
            try native.save(original)
            check(try store.load() == original, "native save writes only the isolated profile")
            check(confirmation.read() == (try original.revision()), "native save pins the exact revision in Data Protection Keychain")
            check(native.profiles == [original] && native.lastError == nil, "native configuration reload succeeds")
            let cli = Process()
            cli.executableURL = Bundle.main.bundleURL.appending(path: "Contents/MacOS/tw")
            cli.arguments = ["--selftest-secrets-keychain", confirmation.service]
            cli.standardOutput = FileHandle.nullDevice
            cli.standardError = FileHandle.nullDevice
            try cli.run()
            cli.waitUntilExit()
            check(cli.terminationStatus == 0, "bundled CLI cannot read or overwrite the App's existing profile confirmation")
            check(confirmation.read() == (try original.revision()), "CLI denial leaves the protected revision unchanged")

            for (scope, message) in [("../Secrets", "Expected a self-test UUID."),
                                      (UUID().uuidString, "The isolated self-test marker is missing.")] {
                let probe = Process(), errors = Pipe()
                probe.executableURL = cli.executableURL
                probe.arguments = ["--selftest-secrets-run", scope]
                probe.standardOutput = FileHandle.nullDevice
                probe.standardError = errors
                try probe.run(); probe.waitUntilExit()
                let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                check(probe.terminationStatus == 64 && text.contains(message), "CLI diagnostic rejects unowned scope: " + message)
            }

            let reopened = SecretsController(model: model, store: store, confirmation: confirmation)
            check(reopened.profiles == [original], "new controller retains the saved account, item and field")
            var changed = original
            changed.arguments = ["changed"]
            try store.save(changed)
            do { try changed.requireApprovedRevision(confirmation.read()); check(false, "external edit rejected") }
            catch { check(true, "external edit rejected by protected revision pin") }

            changed.enabled = true
            try store.save(changed)
            let tampered = SecretsController(model: model, store: store, confirmation: confirmation)
            check(tampered.lastError != nil && !FileManager.default.fileExists(atPath: store.socketURL.path),
                  "unconfirmed enabled profile cannot start the native server")
            changed.enabled = false
            try native.save(changed)
            check(confirmation.read() == (try changed.revision()), "native resave updates the same Keychain record")

            var other = original; other.name = "second-tool"
            other.additionalBindings = [.init(accountID: "synthetic", itemID: "second-key", field: .hidden("api-key"), variable: "SECOND_KEY")]
            try native.save(other)
            check(try store.loadAll().count == 2 && store.load(named: changed.name) == changed,
                  "saving another tool preserves the first and its exact binding")
            check(confirmation.read() == (try store.revision()), "Keychain pin covers the complete tool catalog")
            var editedOutside = other; editedOutside.arguments = ["unreviewed"]
            try store.save(editedOutside)
            do { try native.save(changed); check(false, "saving one tool must not approve external changes to another") }
            catch { check(confirmation.read() != (try store.revision()), "unreviewed changes to another tool are never repinned") }
            try store.save(other)
            try native.remove(other.name)
            check(try store.load() == changed && native.profiles.count == 1, "removing one setup preserves the other tool")

            let disabled = SecretsController(model: model, start: false, store: store, confirmation: confirmation)
            do { try disabled.save(original); check(false, "demo cannot save") }
            catch { check(try store.load() == changed, "disabled/demo controller cannot modify the profile") }

            let denied = SecretsProfileConfirmation(service: confirmation.service + ".denied",
                accessGroup: "INVALID.io.github.triwarden.secrets.selftest")
            do { try denied.write("synthetic-revision"); check(false, "unauthorized group rejected") }
            catch { check(denied.read() == nil, "invalid Keychain access group fails closed without fallback") }

            try confirmation.delete()
            check(confirmation.read() == nil, "isolated Keychain record is deleted")
            do { try changed.requireApprovedRevision(confirmation.read()); check(false, "missing pin rejected") }
            catch { check(true, "missing confirmation fails closed") }
        } catch {
            check(false, "native secrets self-test: \(error.localizedDescription)")
        }
        return failures
    }
}
#endif
