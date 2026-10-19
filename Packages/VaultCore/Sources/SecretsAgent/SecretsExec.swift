import Darwin
import Foundation

public enum SecretsExec {
    /// Replaces the CLI, retaining its terminal, process group and normal exit/signal semantics.
    /// The caller must have authenticated and authorized the delivery before reaching here.
    public static func replace(profile: SecretsProfile, identity: LaunchIdentity, environment: [String: String]) throws -> Never {
        try identity.verify(profile)
        let directoryFD = open(identity.directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw SecretsFailure("The working directory can no longer be opened.") }
        defer { close(directoryFD) }
        var info = stat()
        guard fstat(directoryFD, &info) == 0, info.st_dev == identity.directoryDevice, info.st_ino == identity.directoryInode else {
            throw SecretsFailure("The working directory changed after approval.")
        }
        let arguments = [identity.executable.path] + profile.arguments
        let entries = environment.keys.sorted().map { "\($0)=\(environment[$0]!)" }
        guard (arguments + entries).allSatisfy({ !$0.utf8.contains(0) }) else { throw SecretsFailure("Invalid launch data.") }
        var argv = arguments.map { strdup($0) } + [nil]
        var envp = entries.map { strdup($0) } + [nil]
        defer {
            argv.dropLast().forEach { free($0) }
            envp.dropLast().forEach { free($0) }
        }
        guard argv.dropLast().allSatisfy({ $0 != nil }), envp.dropLast().allSatisfy({ $0 != nil }) else {
            throw SecretsFailure("Not enough memory to start the command.")
        }
        guard fchdir(directoryFD) == 0 else { throw SecretsFailure("Couldn't enter the saved working directory.") }
        // macOS lacks descriptor-based exec in the public SDK. Recheck immediately before path exec;
        // this detects replacement but cannot eliminate the final race against a same-user writer.
        try identity.verify(profile)
        argv.withUnsafeMutableBufferPointer { args in
            envp.withUnsafeMutableBufferPointer { env in
                _ = execve(identity.executable.path, args.baseAddress!, env.baseAddress!)
            }
        }
        let code = errno
        throw SecretsFailure("Couldn't execute the saved command (OS error \(code)). No credential was written to a file.")
    }
}
