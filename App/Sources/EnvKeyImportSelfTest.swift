#if DEBUG
import Foundation
import SecretsAgent
import VaultwardenAPI

/// Uses the same importer as the UI with two dummy values in the disposable dev account.
@MainActor enum EnvKeyImportSelfTest {
    static func run(model: AppModel, root: URL, account: String) async -> Int {
        var failures = 0
        func check(_ value: Bool, _ label: String) {
            print(value ? "PASS" : "FAIL", label); fflush(stdout)
            if !value { failures += 1 }
        }
        let project = "triwarden-env-import-" + UUID().uuidString
        let source = root.appendingPathComponent(".env")
        let input = Data("OPENAI_API_KEY=triwarden-import-test-one\nSEARCH_API_KEY='triwarden-import-test-two'\nPORT=3000\nVITE_PUBLIC_KEY=test-public\nNODE_OPTIONS=--require=disabled\n".utf8)
        let flow = EnvKeyImport()
        flow.accountID = account
        do {
            try input.write(to: source, options: .withoutOverwriting)
            flow.open(source); flow.project = project
            check(flow.selected == ["OPENAI_API_KEY", "SEARCH_API_KEY"], "import suggests only the two private dummy keys")
            check(flow.canSave, "masked import review can save the selected keys")
            await flow.save(using: model)
            check(flow.stage == .saved && flow.bindings.count == 2, "encrypted batch returns both exact values through online sync")
            check(flow.file == nil, "confirmed import releases parsed plaintext values")
            check(try Data(contentsOf: source) == input, "import leaves the source file byte-for-byte unchanged")
            let ids = Set(flow.bindings.map(\.itemID))
            check(ids.count == 2 && model.items.filter { ids.contains($0.id) }.allSatisfy(\.isAPIKey),
                  "imported items use the compatible API-key Secure Note format")
            if let first = flow.bindings.first {
                let reference = ToolLaunchReference(accountID: first.accountID, itemID: first.itemID,
                    initialBindings: flow.bindings, suggestedName: flow.project,
                    suggestedDirectory: flow.source?.deletingLastPathComponent().path)
                check(reference.initialBindings.map(\.variable) == ["OPENAI_API_KEY", "SEARCH_API_KEY"] && reference.suggestedDirectory == root.path,
                      "tool setup receives both exact variable names and the project folder")
                let profile = SecretsProfile(name: "import-canary", accountID: first.accountID, itemID: first.itemID,
                    field: first.field, variable: first.variable, executable: "/usr/bin/true", arguments: [], directory: root.path,
                    displayName: project, additionalBindings: Array(flow.bindings.dropFirst()))
                try profile.validate()
                let text = try EnvReferenceFile(profile: profile).text
                check(!text.contains("triwarden-import-test-"), "export after import contains references without dummy values")
            } else { check(false, "tool setup requires confirmed item references") }
            let before = Set(model.items.map(\.id))
            await flow.save(using: model)
            check(Set(model.items.map(\.id)) == before, "completed import cannot send the batch again")
            flow.clearValues()
            flow.open(source)
            check(flow.file != nil, "a new local review can load the source")
            flow.locked()
            check(flow.file == nil && flow.selected.isEmpty && flow.source == nil && !flow.canSave,
                  "account-lock handling clears pending plaintext and selection")
        } catch { check(false, "dummy .env import test did not complete") }

        // Cleanup uses the exact random project prefix and dummy values, never a real item name.
        do {
            guard let session = model.session(for: account) else { throw SecretsFailure("Test account is locked.") }
            try await session.refresh()
            let owned = session.items.filter { item in
                item.name.hasPrefix(project + " · ") && item.isAPIKey &&
                item.customFields.contains { $0.name == "api-key" && ["triwarden-import-test-one", "triwarden-import-test-two"].contains($0.value) }
            }
            for item in owned { try await session.deleteForever(item.id) }
            try await session.refresh()
            check(!session.items.contains { $0.name.hasPrefix(project + " · ") }, "dummy imported items removed and confirmed online")
        } catch { check(false, "remove test items with prefix \(project) from the disposable dev account") }
        return failures
    }
}
#endif
