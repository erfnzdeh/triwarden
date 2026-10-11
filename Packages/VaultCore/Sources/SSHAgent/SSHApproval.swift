import Foundation

public struct ProcessNode: Equatable, Sendable {
    public var pid: Int32
    public var parent: Int32
    public var path: String?
    public init(pid: Int32, parent: Int32, path: String?) {
        self.pid = pid
        self.parent = parent
        self.path = path
    }
}

public struct SSHRequester: Equatable, Sendable {
    public var displayName: String
    public var via: String
    public var peerPath: String?
    public var appPath: String?
    public var appPID: Int32?
    public var trustKey: String
    public init(displayName: String, via: String, peerPath: String?, appPath: String?, appPID: Int32?, trustKey: String) {
        self.displayName = displayName
        self.via = via
        self.peerPath = peerPath
        self.appPath = appPath
        self.appPID = appPID
        self.trustKey = trustKey
    }
}

public enum SSHRequesterResolver {
    /// The first `.app` bundle walking from `pid` toward its parents, at most eight steps.
    /// Pid 0 and 1 stop the walk. A display name is the bundle's file name, or the peer name.
    public static func resolve(pid: Int32, peerPath: String?, peerName: String, lookup: (Int32) -> ProcessNode?) -> SSHRequester {
        var current = pid
        var appPath: String?
        var appPID: Int32?
        for _ in 0..<8 where current > 1 {
            guard let node = lookup(current) else { break }
            if let path = node.path, let bundle = hostBundle(in: path) {
                appPath = bundle
                appPID = node.pid
                break
            }
            current = node.parent
        }
        let trustKey = appPath.map { "path:\($0)" } ?? peerPath.map { "path:\($0)" } ?? "name:\(peerName)"
        let displayName = appPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? peerName
        return SSHRequester(displayName: displayName, via: peerName, peerPath: peerPath, appPath: appPath, appPID: appPID, trustKey: trustKey)
    }

    /// The outermost `.app` that is not a helper. Cursor's plugin host lives inside
    /// `Cursor Helper (Plugin).app`, which itself lives inside `Cursor.app`.
    static func hostBundle(in path: String) -> String? {
        var built = ""
        var helper: String?
        for component in path.split(separator: "/") where !component.isEmpty {
            built += "/\(component)"
            guard component.hasSuffix(".app") else { continue }
            if component.range(of: "helper", options: .caseInsensitive) == nil { return built }
            helper = helper ?? built
        }
        return helper
    }
}

public enum SSHTrustKey {
    /// A signed bundle beats a path. An unsigned bundle keeps its own path so a copied app cannot inherit a grant.
    public static func make(bundleID: String?, teamID: String?, appPath: String?, peerPath: String?, peerName: String) -> String {
        if let bundleID, let teamID, !bundleID.isEmpty, !teamID.isEmpty {
            return "bundle:\(bundleID):\(teamID)"
        }
        if let appPath { return "path:\(appPath)" }
        if let peerPath { return "path:\(peerPath)" }
        return "name:\(peerName)"
    }
}

public struct SSHTrust: Equatable, Sendable, Identifiable {
    public var id: String { "\(trustKey)|\(keyID)" }
    public var trustKey: String
    public var keyID: String
    public var displayName: String
    public var keyName: String
    /// Nil lasts until `reset` (the vault locking).
    public var until: Date?
    public init(trustKey: String, keyID: String, displayName: String, keyName: String, until: Date?) {
        self.trustKey = trustKey
        self.keyID = keyID
        self.displayName = displayName
        self.keyName = keyName
        self.until = until
    }
}

public struct SSHTrustStore {
    public private(set) var entries: [SSHTrust] = []
    public init() {}

    public func allows(trustKey: String, keyID: String, now: Date) -> SSHTrust? {
        entries.first { $0.trustKey == trustKey && $0.keyID == keyID && ($0.until.map { $0 > now } ?? true) }
    }

    public var untilLock: [SSHTrust] { entries.filter { $0.until == nil } }

    public mutating func grant(_ trust: SSHTrust) {
        entries.removeAll { $0.id == trust.id }
        entries.append(trust)
    }

    public mutating func revoke(id: String) { entries.removeAll { $0.id == id } }

    public mutating func expire(now: Date) {
        entries.removeAll { $0.until.map { $0 <= now } ?? false }
    }

    public mutating func reset() { entries.removeAll() }
}

public enum SSHChoice: Equatable, Sendable {
    case deny
    case allow(SSHGrant)
    case timedOut
}

public enum SSHGrant: String, Equatable, Sendable {
    case once
    case tenMinutes
    case untilLock
    /// Remember the app. Later signatures are allowed whenever the vault is unlocked, with no further prompt.
    case always
}

public enum SSHApprovalEmphasis {
    /// The first ask in an unlock leads with a short grant. A repeat ask leads with trust until lock.
    public static func leadsWithUntilLock(priorAsks: Int) -> Bool { priorAsks > 0 }
}

public struct SSHPrompt: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var trustKey: String
    public var displayName: String
    public var via: String
    public var path: String?
    public var appPath: String?
    public var keyID: String
    public var keyName: String
    public var waitingCount: Int
    public init(id: UUID, trustKey: String, displayName: String, via: String, path: String?, keyID: String, keyName: String, appPath: String? = nil, waitingCount: Int = 1) {
        self.id = id
        self.trustKey = trustKey
        self.displayName = displayName
        self.via = via
        self.path = path
        self.appPath = appPath
        self.keyID = keyID
        self.keyName = keyName
        self.waitingCount = waitingCount
    }
}

public actor SSHApprovalQueue {
    public let timeout: TimeInterval = 60
    private struct Waiting {
        var prompt: SSHPrompt
        var shownAt: Date?
        var resume: CheckedContinuation<SSHChoice, Never>
    }
    private var order: [UUID] = []
    private var waiting: [UUID: Waiting] = [:]

    public init() {}

    public func snapshot() -> (current: SSHPrompt?, count: Int) {
        (order.first.flatMap { waiting[$0]?.prompt }, order.count)
    }

    public func ask(_ prompt: SSHPrompt) async -> SSHChoice {
        await withCheckedContinuation { continuation in
            waiting[prompt.id] = Waiting(prompt: prompt, shownAt: order.isEmpty ? .now : nil, resume: continuation)
            order.append(prompt.id)
        }
    }

    /// Another signature for the prompt already on screen. The card can show how many joined.
    public func noteJoined(_ id: UUID) {
        guard var item = waiting[id] else { return }
        item.prompt.waitingCount += 1
        waiting[id] = item
    }

    public func resolveFront(_ choice: SSHChoice) {
        guard let id = order.first, let item = waiting.removeValue(forKey: id) else { return }
        order.removeFirst()
        revealFront()
        // Resuming inline deadlocks: the waiter re-enters this actor before resolveFront returns.
        let resume = item.resume
        Task.detached { resume.resume(returning: choice) }
    }

    /// The vault locked: every prompt still waiting is a denial.
    public func denyAll() {
        while !order.isEmpty { resolveFront(.deny) }
    }

    public func expire(now: Date) {
        guard let id = order.first, let shown = waiting[id]?.shownAt, now.timeIntervalSince(shown) >= timeout else { return }
        resolveFront(.timedOut)
    }

    private func revealFront() {
        guard let id = order.first, var item = waiting[id] else { return }
        item.shownAt = item.shownAt ?? .now
        waiting[id] = item
    }
}

public enum SSHAccessOutcome: String, Codable, Equatable, Sendable {
    case allowedOnce
    case allowedForTenMinutes
    case allowedUntilLock
    case allowlisted
    case denied
    case timedOut
    case locked
    case reusedTrust
}

/// Apps allowed to sign whenever the vault is unlocked. Membership survives lock and quit.
public struct SSHAllowlistEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String { trustKey }
    public var trustKey: String
    public var displayName: String
    public init(trustKey: String, displayName: String) {
        self.trustKey = trustKey
        self.displayName = displayName
    }
}

public struct SSHAllowlist: Codable, Equatable, Sendable {
    public private(set) var entries: [SSHAllowlistEntry] = []
    public init() {}

    public func contains(_ trustKey: String) -> Bool { entries.contains { $0.trustKey == trustKey } }

    public mutating func add(_ entry: SSHAllowlistEntry) {
        entries.removeAll { $0.trustKey == entry.trustKey }
        entries.append(entry)
    }

    public mutating func remove(trustKey: String) { entries.removeAll { $0.trustKey == trustKey } }

    public static func load(from url: URL) -> SSHAllowlist {
        guard let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode(SSHAllowlist.self, from: data) else {
            return SSHAllowlist()
        }
        return list
    }

    public func save(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

public struct SSHAccessEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var date: Date
    public var appName: String
    public var via: String
    public var path: String?
    public var keyName: String
    public var outcome: SSHAccessOutcome
    public var trustKey: String
    public init(id: UUID, date: Date, appName: String, via: String, path: String?, keyName: String, outcome: SSHAccessOutcome, trustKey: String = "") {
        self.id = id
        self.date = date
        self.appName = appName
        self.via = via
        self.path = path
        self.keyName = keyName
        self.outcome = outcome
        self.trustKey = trustKey
    }
}

public struct SSHAccessLog: Codable, Equatable, Sendable {
    public static let capacity = 200
    public private(set) var events: [SSHAccessEvent] = []
    public init() {}

    public mutating func append(_ event: SSHAccessEvent) {
        events.insert(event, at: 0)
        if events.count > Self.capacity { events.removeLast(events.count - Self.capacity) }
    }

    public mutating func clear() { events.removeAll() }

    /// Asks for this trust key at or after `since` (the current unlock), ignoring grants that were reused or refused because the vault was locked.
    public func priorAsks(trustKey: String, since: Date) -> Int {
        events.filter {
            $0.trustKey == trustKey && $0.date >= since && $0.outcome != .reusedTrust && $0.outcome != .locked && $0.outcome != .allowlisted
        }.count
    }

    public static func load(from url: URL) -> SSHAccessLog {
        guard let data = try? Data(contentsOf: url), let log = try? JSONDecoder().decode(SSHAccessLog.self, from: data) else {
            return SSHAccessLog()
        }
        return log
    }

    public func save(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }
}
