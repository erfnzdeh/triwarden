import Darwin
import Foundation
import Testing
@testable import SecretsAgent

struct EnvReferenceFileTests {
    private func tool() -> SecretsProfile {
        .init(name: "tool-env", accountID: "account-A", itemID: "item-1", field: .hidden("api-key"),
              variable: "API_KEY", executable: "/usr/bin/true", arguments: ["do-not-export-arguments"],
              directory: "/tmp", displayName: "Do not export the display name",
              additionalBindings: [.init(accountID: "account-B", itemID: "item-2", field: .password, variable: "SECOND_KEY")])
    }
    private func file(_ lines: String) -> Data { Data(("# triwarden-env: 1\n# tool: tool-env\n" + lines + "\n").utf8) }

    @Test func exportRoundTripsAllBindingsWithoutProgramMetadata() throws {
        let p = tool(), reference = try EnvReferenceFile(profile: tool())
        #expect(reference.text == "# triwarden-env: 1\n# tool: tool-env\nAPI_KEY=triwarden://vault/account-A/item-1/hidden/api-key\nSECOND_KEY=triwarden://vault/account-B/item-2/password\n")
        let parsed = try EnvReferenceFile(data: Data(reference.text.utf8))
        #expect(parsed.toolID == p.name)
        try parsed.validate(against: p)
        for value in [p.executable, p.arguments[0], p.directory, p.title] { #expect(!reference.text.contains(value)) }
    }

    @Test func componentsPreserveCaseUnicodeAndReservedCharacters() throws {
        var p = tool()
        p.accountID = "Account/專案?x#%"
        p.itemID = "ITEM with spaces"
        p.field = .hidden("key=$HOME ' $(id) /🔑")
        let text = try EnvReferenceFile(profile: p).text
        #expect(!text.contains("$(id)"))
        #expect(!text.contains("$HOME"))
        #expect(!text.contains("🔑"))
        try EnvReferenceFile(data: Data(text.utf8)).validate(against: p)
    }

    @Test func supportsQuotesCommentsCRLFAndBindingOrder() throws {
        let data = file("\n# user comment\n SECOND_KEY = 'triwarden://vault/account-B/item-2/password'\nAPI_KEY=\"triwarden://vault/account-A/item-1/hidden/api-key\"")
        let crlf = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\n", with: "\r\n").utf8)
        try EnvReferenceFile(data: crlf).validate(against: tool())
    }

    @Test(arguments: ["sk-secret-must-not-appear", "$(touch /tmp/tw-must-not-run)", "`id`", "${API_KEY}", "", "https://example.com/key"])
    func literalAndShellTextFailWithoutEcho(_ value: String) throws {
        do {
            _ = try EnvReferenceFile(data: file("API_KEY=" + value))
            Issue.record("The parser accepted a literal value or shell text.")
        } catch {
            #expect(!error.localizedDescription.contains("sk-secret-must-not-appear"))
            #expect(!error.localizedDescription.contains("/tmp/tw-must-not-run"))
            #expect(error.localizedDescription.contains("line 3"))
        }
    }

    @Test(arguments: [
        "API_KEY=triwarden://vault/a/i/hidden/key\nAPI_KEY=triwarden://vault/a/j/password",
        "NODE_OPTIONS=triwarden://vault/a/i/password", "export API_KEY=triwarden://vault/a/i/password",
        "API_KEY=triwarden://vault/a/i/hidden/%00", "API_KEY=triwarden://vault/a/i/hidden/%0A",
        "API_KEY=triwarden://vault/a/i/hidden/%ZZ", "API_KEY=triwarden://vault/a/i/password/extra",
        "API_KEY=triwarden://vault//i/password", "API_KEY=triwarden://vault/a/i/other",
        "API_KEY=triwarden://vault/a/i/password # comment", "API_KEY=\"triwarden://vault/a/i/password'"
    ])
    func rejectsAmbiguousOrUnsafeAssignments(_ line: String) {
        #expect(throws: (any Error).self) { try EnvReferenceFile(data: file(line)) }
    }

    @Test(arguments: ["", "# triwarden-env: 1\n# tool: tool-env\n", "# triwarden-env: 2\n# tool: tool-env\nAPI_KEY=triwarden://vault/a/i/password",
        "# triwarden-env: 1\n# tool: tool-env\n# tool: other\nAPI_KEY=triwarden://vault/a/i/password",
        "# tool: tool-env\nAPI_KEY=triwarden://vault/a/i/password",
        "# triwarden-env: 1\n# tool: invalid tool\nAPI_KEY=triwarden://vault/a/i/password"])
    func requiresOneSupportedVersionAndTool(_ text: String) {
        #expect(throws: (any Error).self) { try EnvReferenceFile(data: Data(text.utf8)) }
    }

    @Test func aFileCannotChangeSavedBindingsOrSelectAnotherTool() throws {
        let original = try EnvReferenceFile(profile: tool())
        for change in 0..<6 {
            var p = tool()
            switch change {
            case 0: p.name = "other-tool"
            case 1: p.accountID = "other-account"
            case 2: p.itemID = "other-item"
            case 3: p.field = .password
            case 4: p.variable = "OTHER_KEY"
            default: p.additionalBindings = nil
            }
            #expect(throws: (any Error).self) { try original.validate(against: p) }
        }
        var p = tool(); p.additionalBindings?.append(.init(accountID: "a", itemID: "i", field: .password, variable: "EXTRA_KEY"))
        #expect(throws: (any Error).self) { try original.validate(against: p) }
    }

    @Test func commandChangesStillUseTheCurrentSavedTool() throws {
        let reference = try EnvReferenceFile(profile: tool())
        var p = tool(); p.executable = "/bin/echo"; p.arguments = ["new saved argument"]
        // Only bindings live in the file. The normal app revision check still controls the command.
        try reference.validate(against: p)
    }

    @Test func rejectsInvalidUTF8OversizedFilesAndTooManyBindings() throws {
        #expect(throws: (any Error).self) { try EnvReferenceFile(data: Data([0xFF, 0xFE])) }
        #expect(throws: (any Error).self) { try EnvReferenceFile(data: Data(repeating: 0x20, count: 262_145)) }
        let lines = (0..<17).map { "KEY_\($0)=triwarden://vault/a/i/password" }.joined(separator: "\n")
        #expect(throws: (any Error).self) { try EnvReferenceFile(data: file(lines)) }
    }

    @Test func readsOnlyBoundedRegularFilesWithoutFollowingLinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(".env.triwarden")
        try Data(EnvReferenceFile(profile: tool()).text.utf8).write(to: url)
        try EnvReferenceFile.read(url).validate(against: tool())
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        #expect(throws: (any Error).self) { try EnvReferenceFile.read(link) }
        #expect(throws: (any Error).self) { try EnvReferenceFile.read(directory) }
        let fifo = directory.appendingPathComponent("pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: (any Error).self) { try EnvReferenceFile.read(fifo) }
        try Data(repeating: 0x20, count: 262_145).write(to: url)
        #expect(throws: (any Error).self) { try EnvReferenceFile.read(url) }
    }

    @Test func launchCommandQuotesTheFilePath() throws {
        let url = URL(fileURLWithPath: "/tmp/project ' $(id)/.env.triwarden")
        #expect(try EnvReferenceFile.launchCommand(for: url) == "tw run --env-file " + SavedToolCommands.shellQuote(url.path))
    }

    @Test func strictRunSourceRejectsOverridesAndMixedSelectors() throws {
        #expect(try RunArguments.source(["--profile", "tool-env"]) == .profile("tool-env"))
        #expect(try RunArguments.source(["--env-file", ".env.triwarden"]) == .environmentFile(".env.triwarden"))
        for args in [["--env-file"], ["--env-file", ""], ["--env-file", "--profile"],
                     ["--env-file", "f", "--", "/bin/sh"], ["--profile", "p", "--env-file", "f"], ["f"]] {
            #expect(throws: (any Error).self) { try RunArguments.source(args) }
        }
    }
}
