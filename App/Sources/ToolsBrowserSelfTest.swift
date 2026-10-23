#if DEBUG
import Foundation
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
        print("Tools browser self-test: \(failed) failure(s)")
        exit(failed == 0 ? 0 : 1)
    }
}
#endif
