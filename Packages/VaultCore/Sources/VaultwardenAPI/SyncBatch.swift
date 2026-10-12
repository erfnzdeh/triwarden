/// Sync independent accounts even when one server fails. Report the first failure after all accounts are attempted.
public enum SyncBatch {
    @MainActor public static func run<Account>(_ accounts: [Account],
                                              sync: @MainActor (Account) async throws -> Void) async throws {
        var firstError: (any Error)?
        for account in accounts {
            do { try await sync(account) } catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }
}
