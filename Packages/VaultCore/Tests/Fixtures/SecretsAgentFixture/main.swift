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
                guard try store.load(named: request.profile.name) == request.profile else { throw SecretsFailure("stale profile") }
                if mode == "caller" {
                    guard let caller = try peer.caller(), caller.pid == getppid() else {
                        throw SecretsFailure("authenticated caller did not match the real fixture parent")
                    }
                }
                if mode == "deny" { throw SecretsFailure("denied by fixture") }
                if mode == "disconnect" { return }
                if mode == "multiple" || mode == "partial" {
                    var values = ["API_KEY": "triwarden-canary", "SECOND_KEY": "second-canary"]
                    if mode == "partial" { values.removeValue(forKey: "SECOND_KEY") }
                    peer.reply(.init(nonce: request.nonce, revision: request.revision, values: values))
                    return
                }
                peer.reply(.init(nonce: request.nonce, revision: request.revision, value: mode == "large" ? String(repeating: "\u{01}", count: 32_768) : "triwarden-canary"))
            } catch { peer.reply(.init(nonce: request.nonce, revision: request.revision, error: error.localizedDescription)) }
        }
        try server.start()
        FileHandle.standardOutput.write(Data("ready\n".utf8))
        Thread.sleep(forTimeInterval: 15)
        server.stop()
    } else if args[0] == "client" || args[0] == "client-env" {
        let p: SecretsProfile
        if args[0] == "client-env" {
            guard args.count == 4 else { exit(64) }
            let file = try EnvReferenceFile.read(URL(fileURLWithPath: args[3]))
            p = try store.load(named: file.toolID)
            try file.validate(against: p)
        } else { p = try args.count > 3 ? store.load(named: args[3]) : store.load() }
        let identity = try LaunchIdentity.capture(p)
        let request = SecretsRunRequest(profile: p, revision: try p.revision(), launch: identity)
        let response = try SecretsClient.request(request, socket: socket, expectedApp: executable)
        let values = try response.validatedValues(for: request)
        guard try store.load(named: p.name) == p else { throw SecretsFailure("profile changed") }
        let env = try LaunchPolicy.environment(parent: ProcessInfo.processInfo.environment, values: values)
        try SecretsExec.replace(profile: p, identity: identity, environment: env)
    } else { exit(64) }
} catch { fail(error) }
