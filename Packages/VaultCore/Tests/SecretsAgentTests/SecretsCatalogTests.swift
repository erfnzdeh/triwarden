import Foundation
import Testing
@testable import SecretsAgent

struct SecretsCatalogTests {
    func profile(_ name: String = "first") -> SecretsProfile {
        var p = SecretsAgentTests().profile(); p.name = name; return p
    }

    @Test func namedToolsSaveAndRemoveIndependently() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SecretsProfileStore(directory: root)
        try store.save(profile())
        let firstRevision = try store.revision()
        try store.save(profile("second"))
        #expect(try store.loadAll().count == 2)
        #expect(try store.load(named: "first") == profile())
        #expect(try store.revision() != firstRevision)
        #expect(throws: (any Error).self) { try store.requireApprovedRevision(firstRevision) }
        #expect(throws: (any Error).self) { try store.load() }
        #expect(throws: (any Error).self) { try store.load(named: "unknown") }
        try store.remove(named: "first")
        #expect(try store.load() == profile("second"))
        try store.remove(named: "second")
        #expect(try store.loadAll().isEmpty)
    }

    @Test func legacyFileMigratesWithoutChangingItsPinOrOverwritingAnotherTool() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SecretsProfileStore(directory: root), original = profile()
        try JSONEncoder().encode(original).write(to: store.fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.fileURL.path)
        try store.requireApprovedRevision(original.revision())
        try store.save(profile("new"))
        #expect(try store.load(named: "first") == original)
        #expect(try store.load(named: "new").name == "new")
        #expect(!String(decoding: try JSONEncoder().encode(original), as: UTF8.self).contains("additionalBindings"))
    }

    @Test func multiKeyRevisionAndVariableValidationCoverEveryBinding() throws {
        var p = profile()
        let before = try p.revision()
        p.additionalBindings = [.init(accountID: "another-account", itemID: "second-key", field: .hidden("api-key"), variable: "SECOND_KEY")]
        try p.validate()
        #expect(p.bindings.count == 2)
        #expect(try p.revision() != before)
        p.additionalBindings?[0].variable = "API_KEY"
        #expect(throws: (any Error).self) { try p.validate() }
        p.additionalBindings?[0].variable = "NODE_OPTIONS"
        #expect(throws: (any Error).self) { try p.validate() }
    }

    @Test func multiValueResponseMustMatchAllApprovedVariables() throws {
        var p = profile()
        p.additionalBindings = [.init(accountID: "account", itemID: "second", field: .hidden("api-key"), variable: "SECOND_KEY")]
        let request = SecretsRunRequest(profile: p, revision: try p.revision(), launch: try .capture(p))
        let values = ["API_KEY": "first-dummy", "SECOND_KEY": "second-dummy"]
        let response = SecretsRunResponse(nonce: request.nonce, revision: request.revision, values: values)
        #expect(try response.validatedValues(for: request) == values)
        for bad in [["API_KEY": "partial"], values.merging(["UNAPPROVED_KEY": "extra"]) { $1 }, ["API_KEY": "ok", "SECOND_KEY": ""]] {
            #expect(throws: (any Error).self) {
                try SecretsRunResponse(nonce: request.nonce, revision: request.revision, values: bad).validatedValues(for: request)
            }
        }
        #expect(throws: (any Error).self) {
            try SecretsRunResponse(nonce: request.nonce, revision: request.revision, value: "legacy-partial").validatedValues(for: request)
        }
        let env = try LaunchPolicy.environment(parent: ["UNRELATED_KEY": "old", "NODE_OPTIONS": "evil"], values: values)
        #expect(env["API_KEY"] == "first-dummy" && env["SECOND_KEY"] == "second-dummy")
        #expect(env["UNRELATED_KEY"] == nil && env["NODE_OPTIONS"] == nil)
        #expect(throws: (any Error).self) {
            try LaunchPolicy.environment(parent: [:], values: ["API_KEY": String(repeating: "a", count: 32_768), "SECOND_KEY": "b"])
        }
    }

    @Test func malformedCatalogAndDuplicateNamesFailClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SecretsProfileStore(directory: root)
        try store.save(profile())
        let encoded = String(decoding: try JSONEncoder().encode(profile()), as: UTF8.self)
        for json in ["{\"version\":1,\"profiles\":[\(encoded),\(encoded)]}", "{\"version\":99,\"profiles\":[]}"] {
            try Data(json.utf8).write(to: store.fileURL)
            #expect(throws: (any Error).self) { try store.loadAll() }
        }
    }

    @Test func refreshingOneToolDoesNotEvictAnotherToolsGrant() throws {
        var grants = SecretsGrantStore()
        let base = try SecretsGrantTests().binding()
        func scope(_ name: String) -> SecretsGrantBinding {
            .init(caller: base.caller, helper: base.helper, revision: base.revision,
                  credentialFingerprint: base.credentialFingerprint, launch: base.launch, tool: name)
        }
        let first = scope("first"), second = scope("second")
        grants.grant(.untilLock, for: first)
        #expect(grants.allowed(second) == nil)
        grants.grant(.tenMinutes, for: second)
        grants.retain(revision: base.revision, credentialFingerprint: "rotated", launch: base.launch, tool: "first")
        #expect(grants.allowed(first) == nil)
        #expect(grants.allowed(second) == .tenMinutes)
        #expect(grants.activeGrants().map(\.tool) == ["second"])
    }

    @Test func pinUsesTheReviewedSnapshotRatherThanRereadingWritableFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SecretsProfileStore(directory: root)
        try store.save(profile())
        try store.save(profile("second"))
        let snapshot = try store.loadAll()
        var malicious = profile("second"); malicious.arguments = ["unreviewed"]
        try store.save(malicious)
        let intendedPin = try store.save(profile(), basedOn: snapshot)
        #expect(try store.load(named: "second") == profile("second"))
        #expect(intendedPin == (try SecretsProfileStore.revision(of: snapshot)))
        #expect(intendedPin == (try store.revision()))
        try store.save(malicious)
        #expect(throws: (any Error).self) { try store.requireApprovedRevision(intendedPin) }
    }

    @Test func explicitResetRecoversCorruptCatalogWithoutImportingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SecretsProfileStore(directory: root)
        try store.save(profile())
        try Data("invalid json".utf8).write(to: store.fileURL)
        #expect(throws: (any Error).self) { try store.loadAll() }
        let emptyPin = try store.clear()
        #expect(try store.loadAll().isEmpty)
        try store.requireApprovedRevision(emptyPin)
    }

    @Test func boundsLimitTheNumberOfToolsAndBindings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SecretsProfileStore(directory: root)
        let full = (0..<64).map { profile("tool-\($0)") }
        try store.save(full[0], basedOn: full)
        #expect(try store.loadAll().count == 64)
        #expect(throws: (any Error).self) { try store.save(profile("extra")) }
        var p = profile()
        p.additionalBindings = (1..<16).map { .init(accountID: "account", itemID: "key-\($0)", field: .password, variable: "KEY_\($0)") }
        try p.validate()
        p.additionalBindings?.append(.init(accountID: "account", itemID: "extra", field: .password, variable: "EXTRA_KEY"))
        #expect(throws: (any Error).self) { try p.validate() }
    }
}
