import Foundation

/// Main-actor request admission and cancellation cooldown, independent of the scoped grant store.
public struct RunGate {
    private var pending: UUID?
    private var cancelled = false
    private var cooldown: ContinuousClock.Instant?
    public init() {}
    public mutating func begin(_ id: UUID) throws {
        guard pending == nil else { throw SecretsFailure("Another launch is awaiting approval. Finish it before trying again.") }
        guard cooldown.map({ $0 <= .now }) ?? true else {
            throw SecretsFailure("A launch was just denied or cancelled. Wait 10 seconds before requesting again.")
        }
        pending = id; cancelled = false
    }
    public func allows(_ id: UUID) -> Bool { pending == id && !cancelled }
    public mutating func cancel() {
        guard pending != nil else { return }
        cancelled = true; cooldown = .now.advanced(by: .seconds(10))
    }
    public mutating func finish(_ id: UUID) {
        guard pending == id else { return }
        pending = nil
    }
}
