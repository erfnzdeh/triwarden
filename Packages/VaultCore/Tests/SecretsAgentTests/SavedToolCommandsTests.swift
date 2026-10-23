import Foundation
import Testing
@testable import SecretsAgent

struct SavedToolCommandsTests {
    private func tool(_ id: String = "tool-123", title: String = "My Assistant") -> SecretsProfile {
        .init(name: id, accountID: "private-account", itemID: "private-item", field: .hidden("private-field"),
              variable: "PRIVATE_API_KEY", executable: "/usr/bin/true", arguments: ["private-argument"],
              directory: "/tmp", displayName: title)
    }

    @Test func copyAndAliasUseStableIDsRatherThanDisplayNames() throws {
        let p = tool(title: "My 'Assistant' $(touch /tmp/not-executed)")
        #expect(try SavedToolCommands.launch(p) == "tw run --profile tool-123")
        let alias = try SavedToolCommands.alias(p)
        #expect(alias.hasPrefix("alias tw-my-assistant-touch-tmp-not-executed="))
        #expect(alias.hasSuffix("='tw run --profile tool-123'"))
        #expect(!alias.contains("$("))
        #expect(try SavedToolCommands.alias(tool(title: "文件助理")).hasPrefix("alias tw-tool-123="))
    }

    @Test func shellQuoteRoundTripsWithoutEvaluation() throws {
        let value = "space ' apostrophe $HOME `id` $(id)\nnext line"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s' " + SavedToolCommands.shellQuote(value)]
        let output = Pipe(); process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(String(decoding: data, as: UTF8.self) == value)
    }

    @Test func listingShowsTitlesAndExactCommandsOnly() throws {
        let a = tool("tool-a", title: "Shared assistant")
        var b = tool("tool-b", title: "Shared assistant"); b.enabled = false
        let listing = try SavedToolCommands.list([b, a])
        #expect(listing.contains("Shared assistant\n  tw run --profile tool-a"))
        #expect(listing.contains("Shared assistant (paused)\n  tw run --profile tool-b"))
        for forbidden in ["private-account", "private-item", "private-field", "PRIVATE_API_KEY", "private-argument", "/usr/bin/true"] {
            #expect(!listing.contains(forbidden))
        }
        #expect(try SavedToolCommands.list([a, b]) == listing)
        #expect(try SavedToolCommands.list([]).contains("Open Tools"))
    }

    @Test func invalidMetadataAndUnexpectedArgumentsFail() throws {
        #expect(throws: (any Error).self) { try SavedToolCommands.list([tool(title: "hidden\ncommand")]) }
        #expect(throws: (any Error).self) { try SavedToolCommands.launch(tool("bad; id")) }
        try SavedToolCommands.validateListArguments([])
        try SavedToolCommands.validateListArguments(["list"])
        for args in [["list", "extra"], ["get"], ["--profile", "tool-a"]] {
            #expect(throws: (any Error).self) { try SavedToolCommands.validateListArguments(args) }
        }
    }
}
