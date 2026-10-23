import Foundation
import Testing
@testable import SecretsAgent

struct ToolLaunchRecipeTests {
    @Test func recipeChangesPreserveUserNamesAndVariables() {
        #expect(ToolLaunchRecipe.claudeCode.suggestedName(current: "", previous: nil) == "Claude Code")
        #expect(ToolLaunchRecipe.python.suggestedName(current: "Claude Code", previous: .claudeCode) == "Python script")
        #expect(ToolLaunchRecipe.python.suggestedName(current: "My research assistant", previous: .claudeCode) == "My research assistant")
        #expect(ToolLaunchRecipe.claudeCode.suggestedVariable(current: "OPENAI_API_KEY", previous: .python, keyDefault: "OPENAI_API_KEY") == "ANTHROPIC_API_KEY")
        #expect(ToolLaunchRecipe.python.suggestedVariable(current: "ANTHROPIC_API_KEY", previous: .claudeCode, keyDefault: "OPENAI_API_KEY") == "OPENAI_API_KEY")
        #expect(ToolLaunchRecipe.claudeCode.suggestedVariable(current: "MY_CUSTOM_KEY", previous: .python, keyDefault: "OPENAI_API_KEY") == "MY_CUSTOM_KEY")
    }

    @Test func recipesKeepArgumentsSeparateFromShellText() {
        #expect(ToolLaunchRecipe.npm.arguments(script: "", extra: ["--port", "3000"]) == ["run", "dev", "--port", "3000"])
        #expect(ToolLaunchRecipe.python.arguments(script: "/tmp/a ' $HOME.py", extra: ["a b"]) == ["/tmp/a ' $HOME.py", "a b"])
        #expect(ToolLaunchRecipe.claudeCode.arguments(script: "ignored", extra: []) == [])
        #expect(ToolLaunchRecipe.claudeCode.variable == "ANTHROPIC_API_KEY")
        #expect(ToolLaunchRecipe.custom.variable == nil)
    }

    @Test func discoveryUsesFixedLocationsWithoutRunningTheProgram() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent(".local/bin/claude")
        let marker = root.appendingPathComponent("must-not-exist")
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(("#!/bin/sh\ntouch " + SavedToolCommands.shellQuote(marker.path) + "\n").utf8).write(to: local)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: local.path)
        #expect(ToolLaunchRecipe.claudeCode.findExecutable(home: root) == local.path)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(ToolLaunchRecipe.custom.findExecutable(home: root) == nil)
        #expect(!ToolLaunchRecipe.claudeCode.candidates(home: root).contains("./claude"))
    }
}
