import Darwin
import Foundation
import Security

public enum SecretsGrantDuration: String, CaseIterable, Sendable {
    case once, tenMinutes, untilLock
}

/// Kernel-observed immediate parent of an authenticated CLI, not a client-supplied app name.
public struct SecretsCallerIdentity: Equatable, Sendable {
    public let pid: Int32
    public let uid: UInt32
    let startedSeconds: UInt64
    let startedMicros: UInt64
    let codeHash: Data
    public let path: String
    public var label: String { URL(fileURLWithPath: path).lastPathComponent + " (PID \(pid))" }
    public init(pid: Int32, uid: UInt32, startedSeconds: UInt64, startedMicros: UInt64, codeHash: Data, path: String) {
        self.pid = pid; self.uid = uid; self.startedSeconds = startedSeconds; self.startedMicros = startedMicros
        self.codeHash = codeHash; self.path = path
    }

    /// Call only with the audit token of a verified socket peer; SecretsPeer.caller performs
    /// that verification on both sides of this inspection. Failure permits only a single launch.
    static func capture(auditToken: Data) -> Self? {
        guard auditToken.count == MemoryLayout<audit_token_t>.size else { return nil }
        var token = audit_token_t()
        _ = withUnsafeMutableBytes(of: &token) { auditToken.copyBytes(to: $0) }
        guard token.val.1 == geteuid(), token.val.5 > 1, token.val.5 <= UInt32(Int32.max),
              let child = process(Int32(token.val.5)), child.pbi_ppid > 1, child.pbi_ppid <= UInt32(Int32.max),
              let before = process(Int32(child.pbi_ppid)) else { return nil }
        let pid = Int32(before.pbi_pid)
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &guest) == errSecSuccess,
              let guest, SecCodeCheckValidity(guest, [], nil) == errSecSuccess else { return nil }
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopyStaticCode(guest, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let signing = info as? [String: Any], let hash = signing[kSecCodeInfoUnique as String] as? Data,
              let path = signing[kSecCodeInfoMainExecutable as String] as? URL,
              let after = process(pid), sameProcess(before, after),
              let childAfter = process(Int32(token.val.5)), sameProcess(child, childAfter),
              childAfter.pbi_ppid == child.pbi_ppid,
              SecCodeCheckValidity(guest, [], nil) == errSecSuccess else { return nil }
        return Self(pid: pid, uid: before.pbi_uid, startedSeconds: before.pbi_start_tvsec,
                    startedMicros: before.pbi_start_tvusec, codeHash: hash, path: path.resolvingSymlinksInPath().path)
    }

    private static func process(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              info.pbi_pid == UInt32(pid), info.pbi_uid == geteuid() else { return nil }
        return info
    }

    private static func sameProcess(_ lhs: proc_bsdinfo, _ rhs: proc_bsdinfo) -> Bool {
        lhs.pbi_pid == rhs.pbi_pid && lhs.pbi_uid == rhs.pbi_uid &&
        lhs.pbi_start_tvsec == rhs.pbi_start_tvsec && lhs.pbi_start_tvusec == rhs.pbi_start_tvusec
    }
}

public struct SecretsGrantBinding: Equatable, Sendable {
    public let tool: String
    public let caller: SecretsCallerIdentity
    public let helper: String
    public let revision: String
    public let credentialFingerprint: String
    public let launch: LaunchIdentity
    public init(caller: SecretsCallerIdentity, helper: String, revision: String, credentialFingerprint: String, launch: LaunchIdentity, tool: String = "") {
        self.caller = caller; self.helper = helper; self.revision = revision
        self.credentialFingerprint = credentialFingerprint; self.launch = launch
        self.tool = tool
    }
}

/// Safe presentation state: no credential, fingerprint or reusable authorization binding.
public struct SecretsActiveGrant: Identifiable, Sendable {
    public let id: UUID
    public let tool: String
    public let caller: SecretsCallerIdentity
    public let duration: SecretsGrantDuration
    public let deadline: ContinuousClock.Instant?
}

/// Memory-only, reference/fingerprint state. No credential values or persistent trust.
public struct SecretsGrantStore {
    private struct Entry {
        let id = UUID()
        let binding: SecretsGrantBinding
        let duration: SecretsGrantDuration
        let deadline: ContinuousClock.Instant?
        func active(_ now: ContinuousClock.Instant) -> Bool { deadline.map { now < $0 } ?? true }
    }
    private var entries: [Entry] = []
    public init() {}
    public func allowed(_ binding: SecretsGrantBinding, now: ContinuousClock.Instant = .now) -> SecretsGrantDuration? {
        entries.first { $0.binding == binding && $0.active(now) }?.duration
    }
    public func activeCount(now: ContinuousClock.Instant = .now) -> Int { entries.filter { $0.active(now) }.count }
    public func activeGrants(now: ContinuousClock.Instant = .now) -> [SecretsActiveGrant] {
        entries.filter { $0.active(now) }.map {
            SecretsActiveGrant(id: $0.id, tool: $0.binding.tool, caller: $0.binding.caller, duration: $0.duration, deadline: $0.deadline)
        }
    }
    public mutating func revoke(_ id: UUID) { entries.removeAll { $0.id == id } }
    public mutating func retain(revision: String, credentialFingerprint: String, launch: LaunchIdentity, tool: String = "") {
        entries.removeAll { $0.binding.tool == tool && ($0.binding.revision != revision || $0.binding.credentialFingerprint != credentialFingerprint || $0.binding.launch != launch) }
    }
    public mutating func grant(_ duration: SecretsGrantDuration, for binding: SecretsGrantBinding, now: ContinuousClock.Instant = .now) {
        entries.removeAll { $0.binding == binding || !$0.active(now) }
        guard duration != .once else { return }
        if entries.count >= 32 { entries.removeFirst() }
        entries.append(Entry(binding: binding, duration: duration, deadline: duration == .tenMinutes ? now.advanced(by: .seconds(600)) : nil))
    }
    public mutating func reset() { entries.removeAll() }
}
