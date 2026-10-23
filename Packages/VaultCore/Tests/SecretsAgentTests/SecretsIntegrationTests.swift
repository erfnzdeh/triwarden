import Darwin
import Foundation
import Testing
@testable import SecretsAgent

struct SecretsIntegrationTests {
    private func fixtureURL() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [".build/out/Build/Products/Debug/SecretsAgentFixture", ".build/debug/SecretsAgentFixture", ".build/arm64-apple-macosx/debug/SecretsAgentFixture", ".build/x86_64-apple-macosx/debug/SecretsAgentFixture"]
        return try #require(candidates.map { root.appendingPathComponent($0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    private func run(mode: String, sealedBundle: Bool = false, tamper: Bool = false, directory: String? = nil,
                     referenceFile: Bool = false, staleReference: Bool = false) throws -> (Int32, String) {
        // Short path: sockaddr_un has a small fixed size on macOS.
        let root = URL(fileURLWithPath: "/tmp/tw-test-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var fixture = try fixtureURL()
        if sealedBundle {
            let bundle = root.appendingPathComponent("Fixture.app")
            let macOS = bundle.appendingPathComponent("Contents/MacOS")
            let resources = bundle.appendingPathComponent("Contents/Resources")
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            let target = macOS.appendingPathComponent("SecretsAgentFixture")
            try FileManager.default.copyItem(at: fixture, to: target)
            fixture = target
            let info = ["CFBundleIdentifier": "io.triwarden.test.fixture", "CFBundleExecutable": "SecretsAgentFixture", "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
            try Data("sealed".utf8).write(to: resources.appendingPathComponent("marker"))
            let sign = Process()
            sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            sign.arguments = ["--force", "--sign", "-", bundle.path]
            sign.standardOutput = FileHandle.nullDevice; sign.standardError = FileHandle.nullDevice
            try sign.run(); sign.waitUntilExit()
            #expect(sign.terminationStatus == 0)
        }
        let store = SecretsProfileStore(directory: root.appendingPathComponent("profile"))
        var p = SecretsProfile(name: "test", accountID: "synthetic", itemID: "synthetic", field: .password,
                               variable: "API_KEY", executable: "/bin/sh",
                               arguments: ["-c", "test \"$API_KEY\" = triwarden-canary && test -z \"$OTHER_SECRET\" && test -z \"$NODE_OPTIONS\" || exit 99; exit 37"], directory: directory ?? root.path)
        if mode == "large" { p.arguments = ["-c", "test \"${#API_KEY}\" -eq 32768 || exit 99; exit 37"] }
        if mode == "multiple" || mode == "partial" {
            p.additionalBindings = [.init(accountID: "synthetic", itemID: "second", field: .password, variable: "SECOND_KEY")]
            p.arguments = ["-c", "test \"$API_KEY\" = triwarden-canary && test \"$SECOND_KEY\" = second-canary && test -z \"$OTHER_SECRET\" && test -z \"$NODE_OPTIONS\" || exit 99; exit 37"]
            var unrelated = p; unrelated.name = "unrelated"; unrelated.enabled = false
            try store.save(unrelated)
        }
        try store.save(p)
        let references = root.appendingPathComponent(".env.triwarden")
        if referenceFile {
            var fileProfile = p
            if staleReference { fileProfile.itemID = "not-the-saved-item" }
            try Data(EnvReferenceFile(profile: fileProfile).text.utf8).write(to: references)
        }
        let server = Process(), ready = Pipe(), serverErrors = Pipe()
        server.executableURL = fixture
        server.arguments = ["server", root.appendingPathComponent("s").path, store.directory.path, mode]
        server.standardOutput = ready; server.standardError = serverErrors
        try server.run()
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        let line = try ready.fileHandleForReading.read(upToCount: 6)
        guard line == Data("ready\n".utf8) else {
            throw SecretsFailure("Fixture did not start: " + String(decoding: serverErrors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        if tamper {
            try Data("changed".utf8).write(to: fixture.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/marker"))
        }
        let client = Process(), errors = Pipe(), output = Pipe()
        client.executableURL = fixture
        client.arguments = ["client", root.appendingPathComponent("s").path, store.directory.path, "test"]
        if referenceFile { client.arguments = ["client-env", root.appendingPathComponent("s").path, store.directory.path, references.path] }
        var environment = ProcessInfo.processInfo.environment
        environment["OTHER_SECRET"] = "must-not-inherit"
        environment["NODE_OPTIONS"] = "must-not-inherit"
        client.environment = environment
        client.standardOutput = output; client.standardError = errors
        try client.run()
        client.waitUntilExit()
        #expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
        return (client.terminationStatus, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    @Test func signedPeersDeliverCanaryAndExecPreservesExitCode() throws {
        let (code, error) = try run(mode: "allow")
        #expect(code == 37, Comment(rawValue: error))
        #expect(error.isEmpty)
    }

    @Test func envReferencesDeliverTwoCanariesThroughSignedIPCAndExec() throws {
        let (code, error) = try run(mode: "multiple", referenceFile: true)
        #expect(code == 37, Comment(rawValue: error))
        #expect(error.isEmpty)
    }

    @Test func staleEnvReferencesPreventExecution() throws {
        let (code, error) = try run(mode: "multiple", referenceFile: true, staleReference: true)
        #expect(code == 70)
        #expect(error.contains("do not match"))
        #expect(!error.contains("triwarden-canary"))
    }

    @Test func authenticatedPeerResolvesItsActualSignedParent() throws {
        let (code, error) = try run(mode: "caller")
        #expect(code == 37, Comment(rawValue: error))
        #expect(error.isEmpty)
    }

    @Test func systemTmpWorkingDirectorySupportsActualExec() throws {
        let (code, error) = try run(mode: "allow", directory: "/tmp")
        #expect(code == 37, Comment(rawValue: error))
        #expect(error.isEmpty)
    }

    @Test func deniedRequestDoesNotExecuteTarget() throws {
        let (code, error) = try run(mode: "deny")
        #expect(code == 70)
        #expect(error.contains("denied by fixture"))
        #expect(!error.contains("triwarden-canary"))
    }

    @Test func missingResponseDoesNotExecuteTarget() throws {
        let (code, error) = try run(mode: "disconnect")
        #expect(code == 70)
        #expect(error.contains("closed or timed out"))
    }

    @Test func sealedAdHocBundleAuthenticatesBothPeers() throws {
        let (code, error) = try run(mode: "allow", sealedBundle: true)
        #expect(code == 37, Comment(rawValue: error))
    }

    @Test func modifiedBundleSealRejectsCredentialDelivery() throws {
        let (code, error) = try run(mode: "allow", sealedBundle: true, tamper: true)
        #expect(code == 70)
        #expect(error.contains("not signed correctly") || error.contains("bundle was modified") || error.contains("signature"), Comment(rawValue: error))
    }

    @Test func maximumEscapedValueUsesOneCompleteFrame() throws {
        let (code, error) = try run(mode: "large")
        #expect(code == 37, Comment(rawValue: error))
    }

    @Test func multipleCredentialsReachOnlyTheNamedToolTogether() throws {
        let (code, error) = try run(mode: "multiple")
        #expect(code == 37, Comment(rawValue: error))
        #expect(error.isEmpty)
    }

    @Test func partialCredentialResponseCannotExecuteTarget() throws {
        let (code, error) = try run(mode: "partial")
        #expect(code == 70)
        #expect(error.contains("exactly the approved credentials"))
        #expect(!error.contains("canary"))
    }

}
