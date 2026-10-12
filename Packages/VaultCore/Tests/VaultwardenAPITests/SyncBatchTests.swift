import Testing
@testable import VaultwardenAPI

@MainActor struct SyncBatchTests {
    enum Failure: Error { case expired, offline }

    @Test func attemptsEveryAccountAndPreservesFirstFailure() async {
        var attempted: [Int] = []
        do {
            try await SyncBatch.run([1, 2, 3]) { account in
                attempted.append(account)
                if account == 1 { throw Failure.expired }
                if account == 2 { throw Failure.offline }
            }
            Issue.record("Expected sync failure")
        } catch {
            #expect(error as? Failure == .expired)
            #expect(attempted == [1, 2, 3])
        }
    }

    @Test func successfulSyncCompletesEveryAccount() async throws {
        var attempted: [Int] = []
        try await SyncBatch.run([1, 2]) { attempted.append($0) }
        #expect(attempted == [1, 2])
    }
}
