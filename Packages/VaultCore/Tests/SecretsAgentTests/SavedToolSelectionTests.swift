import Darwin
import Foundation
import Testing
@testable import SecretsAgent

struct SavedToolSelectionTests {
    private func tool(_ id: String, folder: String = "/tmp/project", enabled: Bool = true) -> SecretsProfile {
        .init(name: id, accountID: "private-account", itemID: "private-item", field: .hidden("private-field"),
              variable: "PRIVATE_KEY", executable: "/usr/bin/true", arguments: ["must-not-print"],
              directory: folder, enabled: enabled, displayName: "Shared assistant")
    }

    @Test func menuDisambiguatesNamesAndOmitsBindings() throws {
        let a = tool("tool-a"), b = tool("tool-b"), c = tool("tool-c", folder: "/tmp/other", enabled: false)
        let menu = try SavedToolSelection(profiles: [b, a, c])
        #expect(menu.profiles.map(\.name) == ["tool-c", "tool-a", "tool-b"])
        #expect(menu.text.contains("(paused)"))
        #expect(menu.text.contains("/tmp/project · tool-a"))
        #expect(menu.text.contains("/tmp/project · tool-b"))
        #expect(menu.text.contains("/tmp/other"))
        for forbidden in ["private-account", "private-item", "private-field", "PRIVATE_KEY", "must-not-print", "/usr/bin/true"] {
            #expect(!menu.text.contains(forbidden))
        }
        #expect(try menu.select("2")?.name == "tool-a")
        #expect(try menu.select("3")?.name == "tool-b")
        #expect(throws: (any Error).self) { try menu.select("1") }
    }

    @Test func selectionRequiresANumberAndNeverDefaultsToATool() throws {
        let menu = try SavedToolSelection(profiles: [tool("tool-a")])
        for input in ["", " ", "q", "Q"] { #expect(try menu.select(input) == nil) }
        for input in ["0", "2", "-1", "Shared assistant", "1; id", String(repeating: "1", count: 100)] {
            #expect(throws: (any Error).self) { try menu.select(input) }
        }
        #expect(throws: (any Error).self) { try SavedToolSelection(profiles: []) }
        #expect(throws: (any Error).self) { try SavedToolSelection(profiles: [tool("tool-a"), tool("tool-a")]) }
    }

    @Test func redirectedInputCannotSelectOrStartATool() throws {
        let input = Pipe(), output = Pipe()
        #expect(throws: (any Error).self) {
            try TerminalToolSelection.choose(profiles: [tool("tool-a")],
                input: input.fileHandleForReading.fileDescriptor, output: output.fileHandleForWriting.fileDescriptor)
        }
    }

    @Test func terminalSelectionPreservesInputForTheTarget() throws {
        var master: Int32 = -1, slave: Int32 = -1
        #expect(openpty(&master, &slave, nil, nil, nil) == 0)
        defer { close(master); close(slave) }
        let input = Data("0\n1\ninput-for-target\n".utf8)
        #expect(input.withUnsafeBytes { Darwin.write(master, $0.baseAddress!, $0.count) } == input.count)
        let selected = try TerminalToolSelection.choose(profiles: [tool("tool-a")], input: slave, output: slave)
        #expect(selected?.name == "tool-a")
        var remaining = [UInt8](repeating: 0, count: 128)
        let count = Darwin.read(slave, &remaining, remaining.count)
        #expect(count > 0)
        #expect(String(decoding: remaining.prefix(max(0, count)), as: UTF8.self) == "input-for-target\n")
    }

    @Test func terminalBlankQuitAndEOFCancel() throws {
        for input in [Data("\n".utf8), Data("q\n".utf8), Data([4])] {
            var master: Int32 = -1, slave: Int32 = -1
            #expect(openpty(&master, &slave, nil, nil, nil) == 0)
            defer { close(master); close(slave) }
            #expect(input.withUnsafeBytes { Darwin.write(master, $0.baseAddress!, $0.count) } == input.count)
            #expect(try TerminalToolSelection.choose(profiles: [tool("tool-a")], input: slave, output: slave) == nil)
        }
    }
}
