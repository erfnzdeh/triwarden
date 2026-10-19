import Foundation
import Testing
@testable import SecretsAgent

struct RunGateTests {
    @Test func onlyOnePendingRequestAndNoReplay() throws {
        var gate = RunGate()
        let id = UUID()
        try gate.begin(id)
        #expect(throws: (any Error).self) { try gate.begin(UUID()) }
        #expect(gate.allows(id))
        gate.cancel()
        #expect(!gate.allows(id))
        gate.finish(id)
        #expect(!gate.allows(id))
        #expect(throws: (any Error).self) { try gate.begin(UUID()) }
    }

    @Test func staleCompletionDoesNotClearNewRequest() throws {
        var gate = RunGate()
        let first = UUID(), second = UUID()
        try gate.begin(first)
        gate.finish(first)
        try gate.begin(second)
        gate.finish(first)
        #expect(gate.allows(second))
    }
}
