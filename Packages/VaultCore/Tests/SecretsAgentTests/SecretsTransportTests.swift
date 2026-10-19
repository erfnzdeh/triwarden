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

extension SecretsTransportTests {
    @Test func extraRequestBytesInvalidateConnection() throws {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }
        let peer = SecretsPeer(fd: pair[0], auditToken: Data(), executable: URL(fileURLWithPath: "/unused"), serverAlive: { true })
        #expect(peer.isConnected)
        var byte: UInt8 = 1
        #expect(write(pair[1], &byte, 1) == 1)
        #expect(!peer.isConnected)
        #expect(!peer.reply(.init(nonce: UUID(), revision: "test", value: "must-not-send")))
    }

    @Test func stoppedServerCannotDeliverCompletedApproval() throws {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }
        let peer = SecretsPeer(fd: pair[0], auditToken: Data(), executable: URL(fileURLWithPath: "/unused"), serverAlive: { false })
        #expect(!peer.reply(.init(nonce: UUID(), revision: "test", value: "must-not-send")))
        var byte: UInt8 = 0
        #expect(recv(pair[1], &byte, 1, MSG_DONTWAIT) < 0)
    }

    @Test func disconnectedClientCannotReceiveCredential() throws {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]) }
        let peer = SecretsPeer(fd: pair[0], auditToken: Data(), executable: URL(fileURLWithPath: "/unused"), serverAlive: { true })
        close(pair[1])
        #expect(!peer.isConnected)
        #expect(!peer.reply(.init(nonce: UUID(), revision: "test", value: "must-not-send")))
    }
}
