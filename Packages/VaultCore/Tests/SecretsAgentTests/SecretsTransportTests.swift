import Darwin
import Foundation
import Testing
@testable import SecretsAgent

struct SecretsTransportTests {
    @Test func missingAuditPeerFailsClosed() {
        #expect(throws: (any Error).self) { try SecretsPeerVerifier.validate(fd: -1, expectedExecutable: URL(fileURLWithPath: "/usr/bin/true")) }
    }

    @Test func socketPeerCannotPretendToBeAnotherExecutable() throws {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }
        #expect(throws: (any Error).self) { try SecretsPeerVerifier.validate(fd: pair[0], expectedExecutable: URL(fileURLWithPath: "/usr/bin/true")) }
    }

    @Test func requestRevisionAndNonceMustMatchResponse() throws {
        let p = SecretsAgentTests().profile()
        let request = SecretsRunRequest(profile: p, revision: try p.revision(), launch: try .capture(p))
        let wrong = SecretsRunResponse(nonce: UUID(), revision: request.revision, value: "canary")
        #expect(throws: (any Error).self) { try wrong.validatedValue(for: request) }
        let stale = SecretsRunResponse(nonce: request.nonce, revision: "stale", value: "canary")
        #expect(throws: (any Error).self) { try stale.validatedValue(for: request) }
        let right = SecretsRunResponse(nonce: request.nonce, revision: request.revision, value: "canary")
        #expect(try right.validatedValue(for: request) == "canary")
    }
}
