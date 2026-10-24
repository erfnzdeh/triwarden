#if DEBUG
import Foundation
import Darwin
import SecretsAgent
import SSHAgent
import VaultwardenAPI

/// Synthetic references and dummy values only; never opens a vault, Keychain or agent socket.
enum ToolsPreviewFixture {
    static func keys(_ count: Int = 16) -> [VaultItem] {
        (0..<count).map { i in
            var item = VaultItem(id: "fixture-key-\(i)", accountId: "demo", kind: .note, name: "Development Key \(i)",
                                 username: nil, host: nil, password: nil, totp: nil, notes: nil, favorite: false)
            item.customFields = [CustomField(name: "api-key", value: "dummy-fixture-only", kind: .hidden)]
            return item
        }
    }
    static func profiles(_ count: Int, keys: Int = 16) -> [SecretsProfile] {
        (0..<count).map { i in
            var p = SecretsProfile(name: String(format: "tool-%02d", i), accountID: i % 10 == 5 ? "locked-demo" : "demo",
                itemID: i % 10 == 3 ? "missing-key" : "fixture-key-0", field: .hidden("api-key"), variable: "API_KEY_0",
                executable: "/usr/bin/true", arguments: [], directory: "/Users/alex/Projects/team-\(i % 4)/workspace-\(i)",
                enabled: i % 10 != 2, displayName: i % 10 == 0 ? "Shared assistant" : "Project \(i) assistant")
            p.additionalBindings = keys > 1 ? (1..<keys).map {
                .init(accountID: "demo", itemID: "fixture-key-\($0)", field: .hidden("api-key"), variable: "API_KEY_\($0)")
            } : nil
            return p
        }
    }
}

@MainActor
enum ToolsBrowserSelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--selftest-tools-browser") else { return }
        var failed = 0
        func check(_ good: Bool, _ label: String) {
            print(good ? "PASS" : "FAIL", label)
            if !good { failed += 1 }
        }
        let keys = ToolsPreviewFixture.keys()
        for count in [0, 1, 10, 64] {
            let index = ToolBrowserIndex(profiles: ToolsPreviewFixture.profiles(count), items: keys, unlocked: ["demo"])
            check(index.results(query: "", filter: .all, order: .ascending).count == count, "\(count)-tool catalog stays complete")
        }
        let index = ToolBrowserIndex(profiles: ToolsPreviewFixture.profiles(64), items: keys, unlocked: ["demo"])
        check(index.entries.allSatisfy { $0.keys.count == 16 }, "all 64 tools retain 16 binding summaries")
        check(index.results(query: "workspace-63", filter: .all, order: .ascending).map(\.id) == ["tool-63"], "search finds a tool by its project folder")
        check(index.results(query: "tool-61", filter: .all, order: .ascending).map(\.id) == ["tool-61"], "search finds an exact shortcut")
        check(index.results(query: "api_key_15", filter: .all, order: .ascending).count == 64, "search includes every environment-variable name")
        check(index.results(query: "development key", filter: .all, order: .ascending).count == 64, "search includes vault key names")
        check(index.results(query: "does-not-exist", filter: .all, order: .ascending).isEmpty, "no-results query returns no unrelated tool")
        check(index.results(query: "", filter: .paused, order: .ascending).allSatisfy { $0.availability == .paused }, "paused filter stays separate from enabled tools")
        check(index.entries.first { $0.id == "tool-03" }?.availability == .needsRepair, "missing key cannot look ready")
        check(index.entries.first { $0.id == "tool-05" }?.availability == .locked, "locked account has a distinct repair state")
        check(index.entries.first { $0.id == "tool-03" }?.keys.first?.repair == .selectKey,
              "missing key offers selection rather than an unlock action")
        check(index.entries.first { $0.id == "tool-05" }?.keys.first?.repair == .unlockAccount,
              "locked key offers account repair before key replacement")
        check(index.entries.first { $0.id == "tool-00" }?.keys.first?.repair == nil,
              "valid key has no repair action")
        check(index.entries.first { $0.id == "tool-00" }?.nextAction == .copyLaunch,
              "ready tool offers launch as its main action")
        check(index.entries.first { $0.id == "tool-03" }?.nextAction == .repairKey("API_KEY_0"),
              "missing key offers repair instead of a launch command")
        check(index.entries.first { $0.id == "tool-05" }?.nextAction == .repairKey("API_KEY_0"),
              "locked account offers repair instead of a launch command")
        check(index.entries.first { $0.id == "tool-02" }?.nextAction == .resume,
              "paused tool offers resume before launch")
        check(ToolBrowserIndex(profiles: ToolsPreviewFixture.profiles(1), items: keys, unlocked: ["demo"], configurationError: true)
            .entries[0].nextAction == .editSetup, "catalog errors never present launch as the main action")
        let knownAccounts = ToolBrowserIndex(profiles: ToolsPreviewFixture.profiles(6), items: keys,
                                            unlocked: ["demo"], configuredAccounts: ["demo"])
        check(knownAccounts.entries.first { $0.id == "tool-05" }?.keys.first?.repair == .addAccount,
              "absent account offers sign-in rather than an unlock action")
        check(knownAccounts.entries.first { $0.id == "tool-05" }?.availability == .needsRepair,
              "absent account does not claim to be merely locked")
        check(index.results(query: "", filter: .attention, order: .ascending).allSatisfy { [.locked, .needsRepair].contains($0.availability) }, "attention includes locked and broken bindings")
        let duplicateNames = index.results(query: "Shared assistant", filter: .all, order: .ascending)
        check(Set(duplicateNames.map(\.id)).count == duplicateNames.count && duplicateNames.count == 7, "duplicate titles retain separate stable identities")
        let sorted = index.results(query: "", filter: .all, order: .ascending)
        let ordered = zip(sorted, sorted.dropFirst()).allSatisfy { $0.profile.title.localizedStandardCompare($1.profile.title) != .orderedDescending }
        check(ordered, "sort uses natural display names rather than internal IDs")
        check(ToolBrowserIndex.selection("tool-63", in: sorted, automatic: true) == "tool-63", "explicit selection survives unrelated list changes")
        check(ToolBrowserIndex.selection("deleted", in: sorted, automatic: true) == sorted.first?.id, "wide layout recovers selection after removal")
        check(ToolBrowserIndex.selection("deleted", in: sorted, automatic: false) == nil, "narrow layout returns to list after removal")
        check(ToolBrowserIndex.selection(nil, in: [], automatic: true) == nil, "empty and no-results states never select a missing row")
        check(ToolBrowserIndex.stepping(nil, by: 1, in: sorted) == sorted.first?.id, "Down enters the first tool without a selection")
        check(ToolBrowserIndex.stepping(nil, by: -1, in: sorted) == sorted.last?.id, "Up enters the last tool without a selection")
        check(ToolBrowserIndex.stepping(sorted[0].id, by: 1, in: sorted) == sorted[1].id, "Down follows the displayed sort order")
        check(ToolBrowserIndex.stepping(sorted.first?.id, by: -1, in: sorted) == sorted.first?.id, "Up stops at the first tool")
        check(ToolBrowserIndex.stepping(sorted.last?.id, by: 1, in: sorted) == sorted.last?.id, "Down stops at the last tool")
        check(ToolBrowserIndex.stepping(nil, by: 1, in: []) == nil, "keyboard navigation is inert for no results")
        var reprompt = keys; reprompt[0].reprompt = true
        let p = ToolsPreviewFixture.profiles(1)
        check(ToolBrowserIndex(profiles: p, items: reprompt, unlocked: ["demo"]).entries[0].availability == .needsRepair, "protected item does not look launch-ready")
        var duplicateFields = keys; duplicateFields[0].customFields.append(duplicateFields[0].customFields[0])
        check(ToolBrowserIndex(profiles: p, items: duplicateFields, unlocked: ["demo"]).entries[0].availability == .needsRepair, "duplicate fields require repair")
        check(ToolBrowserIndex(profiles: p, items: keys + [keys[0]], unlocked: ["demo"]).entries[0].availability == .needsRepair, "ambiguous vault references never pick the first item")
        var other = keys[0]; other.accountId = "another"; other.name = "Separate account key"
        let lookup = ToolBrowserIndex(profiles: p, items: keys + [other], unlocked: ["demo", "another"])
        check(lookup.item(for: .init(accountID: "another", itemID: other.id, field: .hidden("api-key"), variable: "OTHER_KEY"))?.name == "Separate account key", "key lookup is qualified by account")
        let began = ContinuousClock.now
        for _ in 0..<100 {
            _ = index.results(query: "assistant", filter: .all, order: .ascending)
        }
        let elapsed = began.duration(to: .now).components
        print("MEASURE 100 searches over 64 tools / 1024 bindings: \(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15) ms (developer measurement)")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tools-access-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let allowed = root.appendingPathComponent("allowed.json"), log = root.appendingPathComponent("history.json")
            var permissions = SSHAllowlist()
            permissions.add(.init(trustKey: "first", displayName: "First app"))
            permissions.add(.init(trustKey: "second", displayName: "Second app"))
            try permissions.save(to: allowed)
            var history = SSHAccessLog()
            history.append(.init(id: UUID(), date: .now, appName: "Fixture", via: "ssh", path: nil, keyName: "Fake key", outcome: .denied))
            try history.save(to: log)
            let agent = SSHAgentService(logURL: log, allowlistURL: allowed)
            agent.revokeAllowlist(trustKey: "first")
            check(agent.allowlist.entries.map(\.trustKey) == ["second"] && SSHAllowlist.load(from: allowed).entries.map(\.trustKey) == ["second"],
                  "removing a persistent permission updates isolated memory and disk")
            try FileManager.default.removeItem(at: allowed)
            try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
            agent.revokeAllowlist(trustKey: "second")
            check(agent.allowlist.entries.map(\.trustKey) == ["second"], "failed permission persistence keeps the UI honest")
            agent.clearAccessLog()
            check(agent.accessLog.events.isEmpty && !FileManager.default.fileExists(atPath: log.path) && agent.allowlist.entries.count == 1,
                  "clearing SSH history removes only history, never permissions")
            try FileManager.default.removeItem(at: root)
            check(!FileManager.default.fileExists(atPath: root.path), "isolated access diagnostics clean up without a real vault or socket")
        } catch { check(false, "isolated access persistence: \(error.localizedDescription)") }
        try? FileManager.default.removeItem(at: root)
        checkGuideVisibility(check)
        checkSavedToolsCLI(check)
        print("Tools browser self-test: \(failed) failure(s)")
        exit(failed == 0 ? 0 : 1)
    }

    private static func checkGuideVisibility(_ check: (Bool, String) -> Void) {
        let previous = AccountStore.namespace
        AccountStore.namespace = "ToolsGuideSelfTest-" + UUID().uuidString
        defer {
            if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AccountStore.appGroup) {
                try? FileManager.default.removeItem(at: group.appendingPathComponent(AccountStore.namespace))
            }
            AccountStore.namespace = previous
        }
        let model = AppModel()
        model.previewUnlocked = true; model.phase = .vault
        check(!model.showsAPIKeyTools, "new users start without API-key developer pages")
        let hidden = Set(CommandPalette.commands(model: model, close: {}).map(\.id))
        check(hidden.isDisjoint(with: ["new-api-key", "tools-projects", "go-apiKeys", "tools-guide"]),
              "hidden developer pages also leave no API-key palette commands")
        check(!model.showsNavigation(.section(.apiKeys)) && !model.showsNavigation(.toolLaunches) &&
              model.showsNavigation(.section(.notes)) && model.showsNavigation(.access) && model.showsNavigation(.section(.sshKeys)),
              "sidebar visibility hides local API tools and preserves notes and SSH")
        model.beginAPIKey(); model.provideKeyToTool(APIKeyTemplate.fixture); model.showToolGuide()
        check(model.editing == nil && model.toolLaunchReference == nil && !model.showingToolGuide,
              "hidden API-key actions cannot open stale developer forms")
        check(VaultSection.notes.includes(APIKeyTemplate.fixture), "API keys remain ordinary Secure Notes when developer pages are hidden")
        model.showsAPIKeyTools = true
        let shown = Set(CommandPalette.commands(model: model, close: {}).map(\.id))
        check(shown.isSuperset(of: ["new-api-key", "tools-projects", "go-apiKeys", "tools-guide"]),
              "opting in exposes creation, navigation, and the replayable guide")
        check(model.showsNavigation(.section(.apiKeys)) && model.showsNavigation(.toolLaunches),
              "developer sidebar and keyboard navigation use the same visible destinations")
        model.showsAPIKeyTools = false
        check(!CommandPalette.commands(model: model, close: {}).contains { $0.id == "new-api-key" },
              "hiding developer pages updates commands without restarting the app")
    }

    /// The real signed CLI reads only a disposable catalog, with no vault, socket or approval.
    private static func checkSavedToolsCLI(_ check: (Bool, String) -> Void) {
        let installation = TerminalHelperInstallation.inspect(appURL: Bundle.main.bundleURL)
        check(installation.state != .invalidSignature && installation.state != .missingSource,
              "helper setup accepts the signed app and its bundled helper")
        let id = UUID().uuidString
        let root = SecretsProfileStore.shared.directory.deletingLastPathComponent().appendingPathComponent("S" + id.prefix(8))
        do {
            // Never remove a pre-existing directory, even if its random prefix collides.
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            try id.write(to: root.appendingPathComponent("test-id"), atomically: true, encoding: .utf8)
            let store = SecretsProfileStore(directory: root.appendingPathComponent("p"))
            var profiles = ToolsPreviewFixture.profiles(2, keys: 1)
            profiles[0].displayName = "文件助理"
            profiles[0].arguments = ["must-not-appear"]
            profiles[1].enabled = false
            for profile in profiles { try store.save(profile) }
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: CLIBridge.toolPath)
            process.arguments = ["--selftest-secrets-tools", id]
            process.environment = ProcessInfo.processInfo.environment.merging(["TW_SOCKET": "/not-used-by-tool-list"]) { _, new in new }
            process.standardOutput = output; process.standardError = errors
            try process.run()
            let stdout = output.fileHandleForReading.readDataToEndOfFile()
            let stderr = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: stdout, as: UTF8.self)
            check(process.terminationStatus == 0 && stderr.isEmpty, "signed tw lists saved tools without a connection or approval")
            check(text == (try SavedToolCommands.list(profiles)) + "\n", "signed tw prints display names, paused state and exact stable commands")
            check(!text.contains("must-not-appear") && !text.contains("api-key") && !text.contains("dummy-fixture-only"),
                  "signed tw omits bindings, arguments and dummy key values")
            let references = root.appendingPathComponent(".env.triwarden")
            try Data(EnvReferenceFile(profile: profiles[0]).text.utf8).write(to: references)
            func envProbe() throws -> (Int32, String, String) {
                let probe = Process(), out = Pipe(), err = Pipe()
                probe.executableURL = process.executableURL; probe.arguments = ["--selftest-secrets-env", id]
                probe.standardOutput = out; probe.standardError = err
                try probe.run()
                let stdout = out.fileHandleForReading.readDataToEndOfFile()
                let stderr = err.fileHandleForReading.readDataToEndOfFile()
                probe.waitUntilExit()
                return (probe.terminationStatus, String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self))
            }
            let envSelected = try envProbe()
            check(envSelected.0 == 0 && envSelected.1 == "Selected saved tool: " + profiles[0].name + "\n" && envSelected.2.isEmpty,
                  "signed tw selects exact saved bindings from a reference file without IPC")
            var changed = profiles[0]; changed.itemID = "different-item"
            try Data(EnvReferenceFile(profile: changed).text.utf8).write(to: references)
            let envChanged = try envProbe()
            check(envChanged.0 != 0 && envChanged.1.isEmpty && envChanged.2.contains("do not match"),
                  "signed tw rejects changed references before IPC or execution")
            try Data("# triwarden-env: 1\n# tool: \(profiles[0].name)\nAPI_KEY_0=secret-must-not-appear\n".utf8).write(to: references)
            let envLiteral = try envProbe()
            check(envLiteral.0 != 0 && envLiteral.1.isEmpty && !envLiteral.2.contains("secret-must-not-appear"),
                  "signed tw rejects literal values without printing them")
            try Data(EnvReferenceFile(profile: profiles[1]).text.utf8).write(to: references)
            let envPaused = try envProbe()
            check(envPaused.0 != 0 && envPaused.1.isEmpty && envPaused.2.contains("resume"),
                  "signed tw refuses a paused tool selected through a reference file")
            let nonInteractive = Process(), input = Pipe(), nonInteractiveError = Pipe()
            nonInteractive.executableURL = process.executableURL
            nonInteractive.arguments = ["--selftest-secrets-select", id]
            nonInteractive.standardInput = input; nonInteractive.standardOutput = FileHandle.nullDevice
            nonInteractive.standardError = nonInteractiveError
            try nonInteractive.run(); nonInteractive.waitUntilExit()
            let reason = String(decoding: nonInteractiveError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            check(nonInteractive.terminationStatus == 1 && reason.contains("requires a terminal"),
                  "signed tw refuses selection from a pipe without requesting approval")

            profiles[1].enabled = true
            try store.save(profiles[1])
            let menu = try SavedToolSelection(profiles: profiles)
            let selected = try selectionProbe(id: id, input: "2\nq\n")
            check(selected.code == 0 && selected.output == "Selected saved tool: " + menu.profiles[1].name + "\n",
                  "signed tw selects an exact saved ID from a real terminal")
            check(!selected.terminal.contains("must-not-appear") && !selected.terminal.contains("api-key") && !selected.terminal.contains("dummy-fixture-only"),
                  "terminal menu omits arguments, binding fields and values")
            let cancelled = try selectionProbe(id: id, input: "\n")
            check(cancelled.code == 130 && cancelled.output.isEmpty, "signed tw cancels blank selection without a launch")
            var paused = menu.profiles[1]; paused.enabled = false; try store.save(paused)
            let refused = try selectionProbe(id: id, input: "2\nq\n")
            check(refused.code == 130 && refused.output.isEmpty && refused.terminal.contains("This tool is paused"),
                  "signed tw refuses a paused tool without requesting approval")
        } catch { check(false, "isolated saved-tools CLI: \(error.localizedDescription)") }
    }

    private static func selectionProbe(id: String, input: String) throws -> (code: Int32, output: String, terminal: String) {
        var master: Int32 = -1, slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { throw SecretsFailure("Cannot create the test terminal.") }
        defer { close(master); close(slave) }
        let data = Data(input.utf8)
        guard data.withUnsafeBytes({ Darwin.write(master, $0.baseAddress!, $0.count) }) == data.count else {
            throw SecretsFailure("Cannot write the test selection.")
        }
        let child = Process(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: CLIBridge.toolPath)
        child.arguments = ["--selftest-secrets-select", id]
        let tty = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        child.standardInput = tty; child.standardError = tty; child.standardOutput = output
        try child.run()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        var terminal = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(master, &buffer, buffer.count)
            guard count > 0 else { break }
            terminal.append(contentsOf: buffer.prefix(count))
        }
        return (child.terminationStatus, String(decoding: stdout, as: UTF8.self), String(decoding: terminal, as: UTF8.self))
    }
}
#endif
