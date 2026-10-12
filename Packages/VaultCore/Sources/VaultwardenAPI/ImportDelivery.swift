import Foundation

/// A failed request may have reached the server. Never automatically resend an import batch.
public struct ImportDeliveryError: Error, Sendable {
    public let confirmed: Int
    public let uncertain: Int
    public let notSent: Int
}

public enum ImportDelivery {
    /// Bodies are prepared before delivery, so an encryption failure never leaves a partial import.
    @MainActor public static func send(_ batches: [(body: Data, count: Int)],
                                      using deliver: (Data) async throws -> Void) async throws {
        var confirmed = 0
        let total = batches.reduce(0) { $0 + $1.count }
        for batch in batches {
            do { try await deliver(batch.body) } catch {
                throw ImportDeliveryError(confirmed: confirmed, uncertain: batch.count,
                                          notSent: total - confirmed - batch.count)
            }
            confirmed += batch.count
        }
    }
}
