import CryptoKit
import Darwin
import Foundation

/// Foundation may shorten /private/tmp back to the /tmp symlink. Kernel open/exec checks need the physical path.
private func physicalLaunchPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

public enum LaunchPolicy {
    public static let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    private static let inherited: Set<String> = ["HOME", "USER", "LOGNAME", "TERM", "COLORTERM", "LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES", "TMPDIR", "TZ"]
    private static let forbidden: Set<String> = ["PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "SHELL", "PWD", "OLDPWD", "IFS", "ENV", "BASH_ENV", "SHELLOPTS", "BASHOPTS", "CDPATH", "ZDOTDIR", "NODE_OPTIONS", "NODE_PATH", "PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP", "PYTHONINSPECT", "RUBYOPT", "RUBYLIB", "PERL5OPT", "PERL5LIB", "PERLLIB", "JAVA_TOOL_OPTIONS", "_JAVA_OPTIONS", "JDK_JAVA_OPTIONS", "CLASSPATH", "GIT_CONFIG", "GIT_CONFIG_COUNT", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_SSH", "GIT_SSH_COMMAND", "SSL_CERT_FILE", "SSL_CERT_DIR", "CURL_CA_BUNDLE", "REQUESTS_CA_BUNDLE", "NODE_EXTRA_CA_CERTS", "NODE_TLS_REJECT_UNAUTHORIZED", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"]
    public static func validateVariable(_ name: String) throws {
        let upper = name.uppercased()
        guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,127}$", options: .regularExpression) != nil,
              !forbidden.contains(upper), !inherited.contains(upper),
              !["DYLD_", "LD_", "BASH_FUNC_", "GIT_CONFIG_", "TW_"].contains(where: upper.hasPrefix) else {
            throw SecretsFailure("Choose an API credential variable, not a loader, shell, path, or runtime-control variable.")
        }
    }

    public static func environment(parent: [String: String], variable: String, value: String) throws -> [String: String] {
        try environment(parent: parent, values: [variable: value])
    }

    public static func environment(parent: [String: String], values: [String: String]) throws -> [String: String] {
        for variable in values.keys { try validateVariable(variable) }
        guard !values.isEmpty, values.count <= 16, values.values.allSatisfy({ !$0.isEmpty && !$0.utf8.contains(0) }),
              values.values.reduce(0, { $0 + $1.utf8.count }) <= 32_768 else {
            throw SecretsFailure("The credential cannot be passed as an environment variable.")
        }
        var env = parent.filter { inherited.contains($0.key) && !$0.value.utf8.contains(0) }
        env["PATH"] = searchPath
        env.merge(values) { _, approved in approved }
        return env
    }
}

public struct ExecutableIdentity: Codable, Equatable, Sendable {
    public let path: String
    public let device: Int32
    public let inode: UInt64
    public let size: Int64
    public let mode: UInt16
    public let modifiedSeconds: Int64
    public let modifiedNanos: Int64
    public let changedSeconds: Int64
    public let changedNanos: Int64
    public let digest: String

    public static func capture(_ path: String) throws -> Self {
        guard let canonical = physicalLaunchPath(path) else {
            throw SecretsFailure("Cannot open the saved executable. Correct its path through Tools > Edit Setup.")
        }
        let fd = open(canonical, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SecretsFailure("Cannot open the saved executable. Correct its path through Tools > Edit Setup.") }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              access(canonical, X_OK) == 0, before.st_mode & (S_ISUID | S_ISGID) == 0,
              before.st_size <= 512 * 1024 * 1024 else {
            throw SecretsFailure("Choose a regular executable without set-user/group-ID permissions (maximum 512 MB).")
        }
        var hasher = SHA256()
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        while let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec, before.st_size == after.st_size else {
            throw SecretsFailure("The executable changed while it was being checked. Try again.")
        }
        return Self(path: canonical, device: before.st_dev, inode: before.st_ino, size: before.st_size, mode: before.st_mode,
                    modifiedSeconds: Int64(before.st_mtimespec.tv_sec), modifiedNanos: Int64(before.st_mtimespec.tv_nsec),
                    changedSeconds: Int64(before.st_ctimespec.tv_sec), changedNanos: Int64(before.st_ctimespec.tv_nsec),
                    digest: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

public struct LaunchIdentity: Codable, Equatable, Sendable {
    public let executable: ExecutableIdentity
    public let directory: String
    public let directoryDevice: Int32
    public let directoryInode: UInt64

    public static func capture(_ profile: SecretsProfile) throws -> Self {
        try profile.validate()
        guard let dir = physicalLaunchPath(profile.directory) else { throw SecretsFailure("The saved working directory is missing.") }
        var info = stat()
        guard stat(dir, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw SecretsFailure("The saved working directory is missing.")
        }
        return Self(executable: try .capture(profile.executable), directory: dir, directoryDevice: info.st_dev, directoryInode: info.st_ino)
    }

    public func verify(_ profile: SecretsProfile) throws {
        guard try Self.capture(profile) == self else {
            throw SecretsFailure("The executable or working directory changed after approval. No command was started.")
        }
    }
}
