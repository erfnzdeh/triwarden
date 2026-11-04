import Foundation

/// User-facing name and website derived from an allowed browser's front tab.
struct BrowserLoginPrefill: Equatable {
    let name: String
    let uri: String

    init?(isBrowser: Bool, host: String?, pageURL: URL?) {
        guard isBrowser, let host, !host.isEmpty else { return nil }
        name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        uri = pageURL?.absoluteString ?? "https://" + host
    }
}
