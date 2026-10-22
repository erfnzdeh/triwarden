import Foundation
import Testing
@testable import SecretsAgent

struct SecretsAgentTests {
    func profile() -> SecretsProfile {
        SecretsProfile(name: "dev", accountID: "account", itemID: "item", field: .hidden("api-key"),
                       variable: "API_KEY", executable: "/usr/bin/true", arguments: [], directory: "/tmp")
    }

    @Test func profileContainsReferencesAndRevisionCoversScope() throws {
        let original = profile()
        try original.validate()
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(SecretsProfile.self, from: data) == original)
        var changed = original
        changed.arguments = ["--different"]
        #expect(try changed.revision() != original.revision())
        changed = original
        changed.field = .hidden("other")
        #expect(try changed.revision() != original.revision())
    }

    @Test func blocksRuntimeControlBindings() {
        for name in ["PATH", "DYLD_INSERT_LIBRARIES", "LD_PRELOAD", "NODE_OPTIONS", "NODE_PATH", "PYTHONPATH", "PYTHONHOME", "BASH_ENV", "ENV", "ZDOTDIR", "HOME", "SHELLOPTS", "RUBYOPT", "PERL5OPT", "JAVA_TOOL_OPTIONS", "bad-name", "1KEY"] {
            var p = profile(); p.variable = name
            #expect(throws: (any Error).self) { try p.validate() }
        }
    }

    @Test func environmentDoesNotInheritOtherKeysOrLoaderControls() throws {
        let env = try LaunchPolicy.environment(parent: ["HOME": "/tmp/home", "TERM": "xterm", "OTHER_SECRET": "old", "API_KEY": "old", "NODE_OPTIONS": "evil", "PATH": "/evil"], variable: "API_KEY", value: "canary")
        #expect(env["API_KEY"] == "canary")
        #expect(env["OTHER_SECRET"] == nil)
        #expect(env["NODE_OPTIONS"] == nil)
        #expect(env["PATH"] == LaunchPolicy.searchPath)
        #expect(env["TERM"] == "xterm")
        #expect(throws: (any Error).self) { try LaunchPolicy.environment(parent: [:], variable: "API_KEY", value: "bad\0value") }
    }

    @Test func fieldResolutionIsExactAndAmbiguityFails() throws {
        let fields = [SecretField(name: "api-key", value: "canary", hidden: true)]
        #expect(try SecretSelector.hidden("api-key").resolve(password: nil, fields: fields) == "canary")
        #expect(throws: (any Error).self) { try SecretSelector.hidden("API-KEY").resolve(password: nil, fields: fields) }
        #expect(throws: (any Error).self) { try SecretSelector.hidden("api-key").resolve(password: nil, fields: fields + fields) }
        #expect(throws: (any Error).self) { try SecretSelector.hidden("api-key").resolve(password: nil, fields: [.init(name: "api-key", value: "canary", hidden: false)]) }
    }

    @Test func targetReplacementIsDetected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("tool")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
        var p = profile(); p.executable = target.path; p.directory = root.path
        let before = try LaunchIdentity.capture(p)
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: target)
        #expect(throws: (any Error).self) { try before.verify(p) }
    }

    @Test func launchPathsRetainTheirPhysicalPrivatePrefix() throws {
        let root = URL(fileURLWithPath: "/private/tmp/tw-path-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("tool")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
        var p = profile(); p.executable = target.path
        let identity = try LaunchIdentity.capture(p)
        #expect(identity.directory == "/private/tmp")
        #expect(identity.executable.path == target.path)
    }

    @Test func profileStoreRoundTripAndPrivatePermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SecretsProfileStore(directory: root)
        try store.save(profile())
        #expect(try store.load() == profile())
        let attrs = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func commandOverridesAndControlCharactersAreRejected() throws {
        #expect(try RunArguments.parse(["--profile", "dev"]) == "dev")
        #expect(throws: (any Error).self) { try RunArguments.parse(["--profile", "dev", "--", "/bin/echo"]) }
        var p = profile(); p.arguments = ["hidden\ncommand"]
        #expect(throws: (any Error).self) { try p.validate() }
    }

    @Test func oldProfilesKeepTheirEncodingAndRevisionWithoutAToolTitle() throws {
        let original = profile()
        let data = try JSONEncoder().encode(original)
        #expect(!String(decoding: data, as: UTF8.self).contains("displayName"))
        let restored = try JSONDecoder().decode(SecretsProfile.self, from: data)
        #expect(restored.title == restored.name)
        #expect(try restored.revision() == original.revision())
    }

    @Test func userFacingToolNamesSupportUnicodeAndRequireNewApproval() throws {
        var p = profile()
        let original = try p.revision()
        p.displayName = "我的文件助理"
        try p.validate()
        #expect(p.title == "我的文件助理")
        #expect(try p.revision() != original)
        p.displayName = "hidden\ncommand"
        #expect(throws: (any Error).self) { try p.validate() }
    }
}

extension SecretsAgentTests {
    @Test func execRejectsChangedExecutableBeforeReplacingProcess() throws {
        var p = profile()
        let identity = try LaunchIdentity.capture(p)
        p.executable = "/usr/bin/false"
        #expect(throws: (any Error).self) { try SecretsExec.replace(profile: p, identity: identity, environment: [:]) }
    }
}

extension SecretsAgentTests {
    @Test func profileEditsRequireNewNativeApproval() throws {
        let approved = profile()
        let revision = try approved.revision()
        try approved.requireApprovedRevision(revision)
        var changed = approved
        changed.arguments = ["-c", "different command"]
        #expect(throws: (any Error).self) { try changed.requireApprovedRevision(revision) }
        #expect(throws: (any Error).self) { try approved.requireApprovedRevision(nil) }
    }
}
