import Darwin
import Foundation
import Testing
@testable import SecretsAgent

struct EnvImportFileTests {
    private func parse(_ text: String) throws -> EnvImportFile { try .init(data: Data(text.utf8)) }

    @Test func readsLiteralAssignmentsWithoutChangingValues() throws {
        let file = try parse("# comment\r\nexport API_KEY = 'one $literal # two'\r\nSECOND_TOKEN=\"three\\n\\\"four\\\"\" # note\r\nPORT=3000\r\n")
        #expect(file.entries.map(\.variable) == ["API_KEY", "SECOND_TOKEN", "PORT"])
        #expect(file.entries[0].value == "one $literal # two")
        #expect(file.entries[1].value == "three\n\"four\"")
        #expect(file.entries[0].suggested && file.entries[1].suggested)
        #expect(!file.entries[2].suggested)
        #expect(file.entries[0].line == 2)
    }

    @Test func preservesHashesAndSpacesInQuotedValues() throws {
        let file = try parse("API_KEY=abc#def\nTOKEN='  value  '\nOTHER_SECRET=unquoted # comment\n")
        #expect(file.entries.map(\.value) == ["abc#def", "  value  ", "unquoted"])
    }

    @Test func publicVariablesAndOrdinarySettingsStartUnselected() throws {
        let file = try parse("VITE_API_KEY=a\nNEXT_PUBLIC_TOKEN=b\nEXPO_PUBLIC_KEY=c\nPUBLIC_SECRET=d\nREACT_APP_KEY=e\nSUPABASE_ANON_KEY=f\nSTRIPE_PUBLISHABLE_KEY=g\nPUBLIC_KEY=h\nBASE_URL=https://example.com\nPORT=3000\nAPI_KEY=private\nDATABASE_URL=postgres://user:password@localhost/db\n")
        #expect(file.entries.filter(\.suggested).map(\.variable) == ["API_KEY", "DATABASE_URL"])
        #expect(file.entries.allSatisfy { $0.problem == nil })
    }

    @Test(arguments: ["API_KEY=$(touch /tmp/never-run)", "API_KEY=`id`", "API_KEY=${OTHER}", "API_KEY=\"$OTHER\"", "API_KEY=abc\\def", "API_KEY=abc;cmd", "API_KEY=\"bad\\q\""])
    func disablesShellSyntaxWithoutExecutingOrEchoingIt(_ line: String) throws {
        let file = try parse(line)
        #expect(file.entries.count == 1)
        #expect(file.entries[0].value == nil)
        #expect(file.entries[0].problem != nil)
        #expect(!file.entries[0].suggested)
        #expect(!String(reflecting: file).contains(line))
        #expect(throws: (any Error).self) { try file.selected(["API_KEY"]) }
    }

    @Test func disablesEmptyReferenceAndProgramControlValues() throws {
        let file = try parse("EMPTY_KEY=\nAPI_KEY=triwarden://vault/a/i/password\nNODE_OPTIONS=--require=evil\nPATH=/evil\nGOOD_TOKEN=ok\n")
        #expect(file.entries.filter { $0.problem == nil }.map(\.variable) == ["GOOD_TOKEN"])
        #expect(throws: (any Error).self) { try file.selected(["PATH"]) }
    }

    @Test(arguments: ["API_KEY=a\nAPI_KEY=b", "export 9BAD=secret", "source ./other", "KEY='unterminated", "KEY=\"unterminated", "KEY='a' trailing", "KEY=\"a\" trailing", "KEY='line\nvalue'", "KEY=a\u{0}b", "KEY=one\rTOKEN=two"])
    func rejectsAmbiguousFilesWithoutEchoingInput(_ input: String) {
        do { _ = try parse(input); Issue.record("Accepted an ambiguous file") }
        catch { #expect(!error.localizedDescription.contains(input)); #expect(!error.localizedDescription.contains("secret")) }
    }

    @Test func rejectsInvalidEncodingSizeAndAssignmentCount() throws {
        #expect(throws: (any Error).self) { try EnvImportFile(data: Data([0xFF])) }
        #expect(throws: (any Error).self) { try EnvImportFile(data: Data(repeating: 32, count: 262_145)) }
        #expect(throws: (any Error).self) { try parse("# no assignments") }
        let many = (0..<257).map { "KEY_\($0)=v" }.joined(separator: "\n")
        #expect(throws: (any Error).self) { try parse(many) }
    }

    @Test func enforcesDeliveryLimitsAndExactSelection() throws {
        let file = try parse((0..<17).map { "KEY_\($0)=v" }.joined(separator: "\n"))
        #expect(throws: (any Error).self) { try file.selected([]) }
        #expect(throws: (any Error).self) { try file.selected(Set(file.entries.map(\.variable))) }
        #expect(throws: (any Error).self) { try file.selected(["MISSING"]) }
        #expect(try file.selected(["KEY_1", "KEY_3"]).map(\.variable) == ["KEY_1", "KEY_3"])
        let large = try parse("API_KEY=" + String(repeating: "a", count: 20_000) + "\nTOKEN=" + String(repeating: "b", count: 20_000))
        #expect(throws: (any Error).self) { try large.selected(["API_KEY", "TOKEN"]) }
        #expect(try large.selected(["API_KEY"]).count == 1)
        #expect(!String(describing: large.entries[0]).contains(String(repeating: "a", count: 10)))
    }

    @Test func readsOnlyRegularBoundedFilesAndKeepsSourceUnchanged() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(".env"), data = Data("API_KEY=test-only\n".utf8)
        try data.write(to: url)
        #expect(try EnvImportFile.read(url).entries[0].value == "test-only")
        #expect(try Data(contentsOf: url) == data)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        #expect(throws: (any Error).self) { try EnvImportFile.read(link) }
        #expect(throws: (any Error).self) { try EnvImportFile.read(directory) }
        let fifo = directory.appendingPathComponent("fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: (any Error).self) { try EnvImportFile.read(fifo) }
    }
}
