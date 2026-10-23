import Foundation
import Security

/// Read-only setup guidance. Launch authentication remains in SecretsPeerVerifier.
public struct TerminalHelperInstallation: Sendable {
    public enum State: Sendable { case missingSource, invalidSignature, missingLink, wrongLink, occupied, installed }
    public static let destination = URL(fileURLWithPath: "/usr/local/bin/tw")
    public static let repairLink = "Install this app's tw from Tools > Terminal Helper Setup."
    public static let repairSignature = "Reinstall a signed Triwarden app to repair its signature before you use Tools > Terminal Helper Setup."
    public let source: URL
    public let destination: URL
    public let state: State

    public var instruction: String {
        switch state {
        case .missingSource: "Reinstall a signed Triwarden app to restore the missing helper."
        case .invalidSignature: Self.repairSignature
        case .missingLink, .wrongLink: Self.repairLink
        case .occupied: "Move the existing file or folder from \(destination.path) before you install tw."
        case .installed: "This location uses the helper from this app."
        }
    }

    public var installCommand: String? {
        guard [.missingLink, .wrongLink, .installed].contains(state) else { return nil }
        let quote = SavedToolCommands.shellQuote
        let target = quote(destination.path)
        // Refuse a regular file or directory. Replace only a symlink, including a dangling link.
        return "(test ! -e \(target) || test -L \(target)) && sudo mkdir -p \(quote(destination.deletingLastPathComponent().path)) && sudo ln -sfn \(quote(source.path)) \(target)"
    }

    public static func inspect(appURL: URL, destination: URL = Self.destination) -> Self {
        inspect(appURL: appURL, destination: destination, signatureIsValid: validSignature)
    }

    static func inspect(appURL: URL, destination: URL, signatureIsValid: (URL) -> Bool) -> Self {
        let source = appURL.appendingPathComponent("Contents/MacOS/tw")
        let fm = FileManager.default
        let state: State
        if !fm.isExecutableFile(atPath: source.path) { state = .missingSource }
        else if !signatureIsValid(appURL) { state = .invalidSignature }
        else if let link = try? fm.destinationOfSymbolicLink(atPath: destination.path) {
            let linked = URL(fileURLWithPath: link, relativeTo: destination.deletingLastPathComponent()).standardizedFileURL
            state = linked.resolvingSymlinksInPath() == source.resolvingSymlinksInPath() ? .installed : .wrongLink
        } else { state = fm.fileExists(atPath: destination.path) ? .occupied : .missingLink }
        return Self(source: source, destination: destination, state: state)
    }

    private static func validSignature(_ app: URL) -> Bool {
        var bundle: SecStaticCode?
        var helper: SecStaticCode?
        let strict = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &bundle) == errSecSuccess, let bundle,
              SecStaticCodeCheckValidity(bundle, strict, nil) == errSecSuccess,
              SecStaticCodeCreateWithPath(app.appendingPathComponent("Contents/MacOS/tw") as CFURL, [], &helper) == errSecSuccess,
              let helper, SecStaticCodeCheckValidity(helper, [], nil) == errSecSuccess else { return false }
        var appInfo: CFDictionary?
        var helperInfo: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(bundle, flags, &appInfo) == errSecSuccess,
              SecCodeCopySigningInformation(helper, flags, &helperInfo) == errSecSuccess,
              let appTeam = (appInfo as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              let helperTeam = (helperInfo as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String else { return false }
        return appTeam == helperTeam
    }
}
