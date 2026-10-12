import Foundation
import Testing
@testable import VaultwardenAPI

@MainActor struct ImportDeliveryTests {
    @Test func stopsAfterAmbiguousFailureWithoutResending() async throws {
        var requests = 0
        do {
            try await ImportDelivery.send([(Data([1]), 5), (Data([2]), 3), (Data([3]), 2)]) { _ in
                requests += 1
                if requests == 2 { throw URLError(.timedOut) }
            }
            Issue.record("Expected failure")
        } catch let error as ImportDeliveryError {
            #expect(requests == 2)
            #expect(error.confirmed == 5)
            #expect(error.uncertain == 3)
            #expect(error.notSent == 2)
        }
    }

    @Test func successfulBatchesAreSentOnceInOrder() async throws {
        var bodies: [Data] = []
        try await ImportDelivery.send([(Data([1]), 5), (Data([2]), 3)]) { bodies.append($0) }
        #expect(bodies == [Data([1]), Data([2])])
    }
}
