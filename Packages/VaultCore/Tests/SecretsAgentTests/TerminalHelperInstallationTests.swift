import Foundation
import Testing
@testable import SecretsAgent

struct TerminalHelperInstallationTests {
    @Test func copiedCommandQuotesPathsAndRefusesANewRegularFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("App ' $(id) `id`.app")
        let source = app.appendingPathComponent("Contents/MacOS/tw")
        let destination = root.appendingPathComponent("bin/tw")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)
        let installation = TerminalHelperInstallation.inspect(appURL: app, destination: destination, signatureIsValid: { _ in true })
        let command = try #require(installation.installCommand).replacingOccurrences(of: "sudo ", with: "")
        func run() throws -> Int32 {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            try process.run(); process.waitUntilExit()
            return process.terminationStatus
        }
        #expect(try run() == 0)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path) == source.path)
        try FileManager.default.removeItem(at: destination)
        try Data("do not replace".utf8).write(to: destination)
        #expect(try run() != 0)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "do not replace")
    }

    @Test func setupDistinguishesMissingWrongUnsignedAndOccupiedLocations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Tri ' $HOME `id`.app")
        let source = app.appendingPathComponent("Contents/MacOS/tw")
        let destination = root.appendingPathComponent("tw")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        func inspect(_ signed: Bool = true) -> TerminalHelperInstallation {
            TerminalHelperInstallation.inspect(appURL: app, destination: destination, signatureIsValid: { _ in signed })
        }
        #expect(inspect().state == .missingSource)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)
        #expect(inspect(false).state == .invalidSignature)
        #expect(TerminalHelperInstallation.inspect(appURL: app, destination: destination).state == .invalidSignature)
        #expect(inspect().state == .missingLink)
        #expect(inspect().installCommand?.contains(SavedToolCommands.shellQuote(source.path)) == true)
        try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: "/missing/other/tw")
        #expect(inspect().state == .wrongLink)
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
        #expect(inspect().state == .installed)
        try FileManager.default.removeItem(at: destination)
        try Data("keep this file".utf8).write(to: destination)
        #expect(inspect().state == .occupied)
        #expect(inspect().installCommand == nil)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "keep this file")
        #expect(inspect(false).installCommand == nil)
    }
}
