import Darwin
import Foundation
import SecretsAgent

// Isolated synthetic transport/exec fixture. Never opens a real vault or the shared profile store.
let args = Array(CommandLine.arguments.dropFirst())
func fail(_ error: any Error) -> Never {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(70)
}
func ownURL() throws -> URL {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else { throw SecretsFailure("fixture path unavailable") }
    return URL(fileURLWithPath: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
}
guard args.count >= 3 else { exit(64) }
do {
    let socket = URL(fileURLWithPath: args[1])
    let store = SecretsProfileStore(directory: URL(fileURLWithPath: args[2]))
    let executable = try ownURL()
    if args[0] == "server" {
        let mode = args.count > 3 ? args[3] : "allow"
        let server = SecretsServer(socketURL: socket, expectedCLI: executable) { request, peer in
            do {
                try peer.validate()
                guard try store.load() == request.profile else { throw SecretsFailure("stale profile") }
                if mode == "deny" { throw SecretsFailure("denied by fixture") }
                if mode == "disconnect" { return }
                peer.reply(.init(nonce: request.nonce, revision: request.revision, value: mode == "large" ? String(repeating: "\u{01}", count: 32_768) : "triwarden-canary"))
            } catch { peer.reply(.init(nonce: request.nonce, revision: request.revision, error: error.localizedDescription)) }
        }
        try server.start()
        FileHandle.standardOutput.write(Data("ready\n".utf8))
        Thread.sleep(forTimeInterval: 15)
        server.stop()
    } else if args[0] == "client" {
        let p = try store.load()
        let identity = try LaunchIdentity.capture(p)
        let request = SecretsRunRequest(profile: p, revision: try p.revision(), launch: identity)
        let response = try SecretsClient.request(request, socket: socket, expectedApp: executable)
        let value = try response.validatedValue(for: request)
        guard try store.load() == p else { throw SecretsFailure("profile changed") }
        let env = try LaunchPolicy.environment(parent: ProcessInfo.processInfo.environment, variable: p.variable, value: value)
        try SecretsExec.replace(profile: p, identity: identity, environment: env)
    } else { exit(64) }
} catch { fail(error) }
