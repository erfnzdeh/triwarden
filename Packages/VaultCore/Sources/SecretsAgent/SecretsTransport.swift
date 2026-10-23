import Darwin
import Foundation
import Security
import SSHAgent

public struct SecretsRunRequest: Codable, Sendable {
    public let nonce: UUID
    public let profile: SecretsProfile
    public let revision: String
    public let launch: LaunchIdentity
    public init(profile: SecretsProfile, revision: String, launch: LaunchIdentity, nonce: UUID = UUID()) {
        self.nonce = nonce; self.profile = profile; self.revision = revision; self.launch = launch
    }
}

public struct SecretsRunResponse: Codable, Sendable {
    public let nonce: UUID
    public let revision: String
    public let value: String?
    public let values: [String: String]?
    public let error: String?
    public init(nonce: UUID, revision: String, value: String? = nil, values: [String: String]? = nil, error: String? = nil) {
        self.nonce = nonce; self.revision = revision; self.value = value; self.error = error
        self.values = values
    }
    public func validatedValue(for request: SecretsRunRequest) throws -> String {
        guard request.profile.bindings.count == 1 else { throw SecretsFailure("This launch requires multiple credentials.") }
        return try validatedValues(for: request)[request.profile.variable]!
    }
    public func validatedValues(for request: SecretsRunRequest) throws -> [String: String] {
        guard nonce == request.nonce, revision == request.revision else {
            throw SecretsFailure("The launch response does not match this request.")
        }
        if let error { throw SecretsFailure(error) }
        let resolved: [String: String]
        if let values, value == nil { resolved = values }
        else if let value, values == nil, request.profile.bindings.count == 1 { resolved = [request.profile.variable: value] }
        else { throw SecretsFailure("The credential response is missing or ambiguous. No command was started.") }
        guard Set(resolved.keys) == Set(request.profile.bindings.map(\.variable)) else {
            throw SecretsFailure("The response does not contain exactly the approved credentials. No command was started.")
        }
        _ = try LaunchPolicy.environment(parent: [:], values: resolved)
        return resolved
    }
}

/// Match an OS-provided audit token to the exact signed executable shipped alongside us.
/// PID-only and path-only fallback are deliberately unsupported, including in source builds.
public enum SecretsPeerVerifier {
    @discardableResult
    public static func validate(fd: Int32, expectedExecutable: URL) throws -> Data {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
              length == MemoryLayout<audit_token_t>.size else { throw SecretsFailure("Couldn't authenticate the local connection.") }
        let data = withUnsafeBytes(of: token) { Data($0) }
        // audit token layout: auid, euid, egid, ruid, rgid, pid, asid, pidversion.
        guard token.val.1 == geteuid() else { throw SecretsFailure("The connection belongs to another user.") }
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: data] as CFDictionary, [], &guest) == errSecSuccess,
              let guest, SecCodeCheckValidity(guest, [], nil) == errSecSuccess else {
            throw SecretsFailure(TerminalHelperInstallation.repairSignature)
        }
        var expected: SecStaticCode?
        let expectedURL = expectedExecutable.resolvingSymlinksInPath()
        guard SecStaticCodeCreateWithPath(expectedURL as CFURL, [], &expected) == errSecSuccess,
              let expected, SecStaticCodeCheckValidity(expected, [], nil) == errSecSuccess else {
            throw SecretsFailure(TerminalHelperInstallation.repairSignature)
        }
        // Anchor both peers to our running identity. Matching a replacement helper against
        // itself on disk is insufficient: the app's sealed bundle and signer must also agree.
        var own: SecCode?
        var ownStatic: SecStaticCode?
        var ownInfo: CFDictionary?
        guard SecCodeCopySelf([], &own) == errSecSuccess, let own,
              SecCodeCheckValidity(own, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(own, [], &ownStatic) == errSecSuccess, let ownStatic,
              SecCodeCopySigningInformation(ownStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &ownInfo) == errSecSuccess,
              let ownSigning = ownInfo as? [String: Any] else {
            throw SecretsFailure(TerminalHelperInstallation.repairSignature)
        }
        let bundle = expectedURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if bundle.pathExtension == "app" {
            var sealedBundle: SecStaticCode?
            let strict = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode)
            guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &sealedBundle) == errSecSuccess,
                  let sealedBundle, SecStaticCodeCheckValidity(sealedBundle, strict, nil) == errSecSuccess else {
                throw SecretsFailure(TerminalHelperInstallation.repairSignature)
            }
        }
        var guestStatic: SecStaticCode?
        guard SecCodeCopyStaticCode(guest, [], &guestStatic) == errSecSuccess, let guestStatic else {
            throw SecretsFailure(TerminalHelperInstallation.repairSignature)
        }
        var dynamicInfo: CFDictionary?
        var staticInfo: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(guestStatic, flags, &dynamicInfo) == errSecSuccess,
              SecCodeCopySigningInformation(expected, flags, &staticInfo) == errSecSuccess,
              let actual = dynamicInfo as? [String: Any], let wanted = staticInfo as? [String: Any],
              let actualHash = actual[kSecCodeInfoUnique as String] as? Data,
              let expectedHash = wanted[kSecCodeInfoUnique as String] as? Data,
              actualHash == expectedHash,
              wanted[kSecCodeInfoTeamIdentifier as String] as? String == ownSigning[kSecCodeInfoTeamIdentifier as String] as? String,
              let actualPath = actual[kSecCodeInfoMainExecutable as String] as? URL,
              actualPath.resolvingSymlinksInPath() == expectedURL,
              actual[kSecCodeInfoIdentifier as String] as? String == wanted[kSecCodeInfoIdentifier as String] as? String,
              actual[kSecCodeInfoTeamIdentifier as String] as? String == wanted[kSecCodeInfoTeamIdentifier as String] as? String else {
            throw SecretsFailure(TerminalHelperInstallation.repairLink)
        }
        return data
    }
}

/// Valid only during one handler invocation; the server owns the descriptor until it returns.
public struct SecretsPeer: Sendable {
    public let auditToken: Data
    public let executable: URL
    private let fd: Int32
    private let serverAlive: @Sendable () -> Bool
    init(fd: Int32, auditToken: Data, executable: URL, serverAlive: @escaping @Sendable () -> Bool) {
        self.fd = fd; self.auditToken = auditToken; self.executable = executable; self.serverAlive = serverAlive
    }
    public var isConnected: Bool {
        guard serverAlive() else { return false }
        var byte: UInt8 = 0
        let count = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        // Extra bytes mean an unsolicited/replayed request: fail closed rather than queue it.
        return count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)
    }
    /// Called synchronously by the owner of the authorization state, immediately after its
    /// final check. One nonblocking write defines the irreversible delivery boundary.
    /// A partial or failed write is rejected by the client's frame decoder and never retried.
    @discardableResult
    public func reply(_ response: SecretsRunResponse) -> Bool {
        guard isConnected, let bytes = try? JSONEncoder().encode(response), bytes.count <= 262_144 else { return false }
        let n = UInt32(bytes.count)
        let frame = Data([UInt8(n >> 24), UInt8(n >> 16 & 255), UInt8(n >> 8 & 255), UInt8(n & 255)]) + bytes
        return frame.withUnsafeBytes { send(fd, $0.baseAddress, frame.count, MSG_DONTWAIT) == frame.count }
    }

    public func validate() throws {
        guard isConnected, try SecretsPeerVerifier.validate(fd: fd, expectedExecutable: executable) == auditToken else {
            throw SecretsFailure("The requesting CLI disconnected or changed identity.")
        }
    }

    public func caller() throws -> SecretsCallerIdentity? {
        try validate()
        let caller = SecretsCallerIdentity.capture(auditToken: auditToken)
        try validate()
        return caller
    }
}

/// Small, one-request server, independent of general vault-read grants and browser IPC.
public final class SecretsServer: @unchecked Sendable {
    public typealias Handler = @Sendable (SecretsRunRequest, SecretsPeer) async -> Void
    private let socketURL: URL
    private let expectedCLI: URL
    private let handler: Handler
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var connections = 0
    public init(socketURL: URL, expectedCLI: URL, handler: @escaping Handler) {
        self.socketURL = socketURL; self.expectedCLI = expectedCLI; self.handler = handler
    }
    public var isRunning: Bool { lock.withLock { listener >= 0 } }
    public func start() throws {
        guard !isRunning else { return }
        var address = sockaddr_un()
        let path = socketURL.path
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw SecretsFailure("The local socket path is too long.") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SecretsFailure("Couldn't create the local launch socket.") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        unlink(path)
        let bound = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 4) == 0 else {
            close(fd); unlink(path); throw SecretsFailure("Couldn't open the private launch socket.")
        }
        lock.withLock { listener = fd }
        Thread { [weak self] in self?.acceptLoop(fd) }.start()
    }
    public func stop() {
        let fd = lock.withLock { let fd = listener; listener = -1; return fd }
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd); unlink(socketURL.path) }
    }
    deinit { stop() }

    private func acceptLoop(_ fd: Int32) {
        while lock.withLock({ listener == fd }) {
            let client = accept(fd, nil, nil)
            if client < 0 { if errno == EINTR { continue }; return }
            let accepted = lock.withLock { () -> Bool in
                guard listener == fd, connections < 4 else { return false }
                connections += 1; return true
            }
            guard accepted else { close(client); continue }
            Thread { [weak self] in
                defer { close(client) }
                guard let self else { return }
                defer { self.lock.withLock { self.connections -= 1 } }
                self.serve(client)
            }.start()
        }
    }

    private func serve(_ fd: Int32) {
        Self.configure(fd, seconds: 5)
        guard let audit = try? SecretsPeerVerifier.validate(fd: fd, expectedExecutable: expectedCLI),
              let data = FramedSocketServer.readFrame(fd, max: 65_536),
              let request = try? JSONDecoder().decode(SecretsRunRequest.self, from: data) else { return }
        let peer = SecretsPeer(fd: fd, auditToken: audit, executable: expectedCLI, serverAlive: { [weak self] in self?.isRunning == true })
        let done = DispatchSemaphore(value: 0)
        Task.detached { await self.handler(request, peer); done.signal() }
        done.wait()
        // The handler commits its reply synchronously with its final lifecycle check.
        // Never retain a plaintext reply on this thread for a later write.
        // One request, then close; a second request is never accepted.
    }

    static func configure(_ fd: Int32, seconds: Int) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var sendBuffer: Int32 = 512 * 1024
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
}

public enum SecretsClient {
    public static func request(_ request: SecretsRunRequest, socket: URL, expectedApp: URL) throws -> SecretsRunResponse {
        guard let fd = FramedSocketServer.connect(to: socket.path) else {
            throw SecretsFailure("Open Triwarden and unlock the required accounts. Resume the tool in Tools if it is paused.")
        }
        defer { close(fd) }
        SecretsServer.configure(fd, seconds: 90)
        try SecretsPeerVerifier.validate(fd: fd, expectedExecutable: expectedApp)
        let data = try JSONEncoder().encode(request)
        guard data.count <= 65_536, FramedSocketServer.writeFrame(fd, data),
              let response = FramedSocketServer.readFrame(fd, max: 262_144) else {
            throw SecretsFailure("The connection closed or timed out; install the running app's tw through Tools > Terminal Helper Setup.")
        }
        return try JSONDecoder().decode(SecretsRunResponse.self, from: response)
    }
}
