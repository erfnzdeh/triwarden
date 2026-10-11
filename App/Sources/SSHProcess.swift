import AppKit
import Darwin
import Foundation
import SSHAgent

enum SSHProcess {
    static func node(_ pid: pid_t) -> ProcessNode? {
        var info = proc_bsdshortinfo()
        let size = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info)))
        guard size == Int32(MemoryLayout.size(ofValue: info)) else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let n = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return 0 }
            return base.withMemoryRebound(to: CChar.self, capacity: ptr.count) { proc_pidpath(pid, $0, UInt32(ptr.count)) }
        }
        let path: String? = n > 0 ? String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self) : nil
        return ProcessNode(pid: Int32(bitPattern: info.pbsi_pid), parent: Int32(bitPattern: info.pbsi_ppid), path: path)
    }

    /// Bundle id and Team ID for a signed process. Unsigned or unreadable processes contribute nothing.
    static func signature(of pid: pid_t) -> (bundleID: String?, teamID: String?) {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return (nil, nil) }
        return (dict[kSecCodeInfoIdentifier as String] as? String, dict[kSecCodeInfoTeamIdentifier as String] as? String)
    }

    static func requester(for peer: SSHAgentServer.Peer) -> SSHRequester {
        var who = SSHRequesterResolver.resolve(pid: peer.pid, peerPath: peer.path, peerName: peer.processName, lookup: node)
        if let appPath = who.appPath {
            let signing = who.appPID.map { signature(of: $0) }
            let bundleID = Bundle(url: URL(fileURLWithPath: appPath))?.bundleIdentifier ?? signing?.bundleID
            who.trustKey = SSHTrustKey.make(bundleID: bundleID, teamID: signing?.teamID,
                                            appPath: appPath, peerPath: who.peerPath, peerName: who.via)
            who.displayName = bundleDisplayName(appPath) ?? who.displayName
        }
        return who
    }

    /// The bundle's own name. A helper process's localized name is the long "Cursor Helper (Plugin): …" label.
    private static func bundleDisplayName(_ appPath: String) -> String? {
        let url = URL(fileURLWithPath: appPath)
        let info = Bundle(url: url)?.infoDictionary
        let named = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String)
        if let named, !named.isEmpty, named.range(of: "helper", options: .caseInsensitive) == nil { return named }
        let folder = url.deletingPathExtension().lastPathComponent
        return folder.isEmpty ? nil : folder
    }
}
