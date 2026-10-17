import Foundation
import TriCrypto

/// What the palette's query asks for: plain words, plus scopes —
/// `>` (commands only), `#folder`, `@account` and `type:` (`login:`, `card:`, `note:`, `identity:`, `ssh:`).
/// A `#…` or `@…` that names no folder or account stays part of the text, so searching for "@gmail" still works.
struct PaletteQuery: Equatable {
    var text = ""
    var commandsOnly = false
    /// A folder path (as the sidebar shows it).
    var folder: String?
    /// An account id.
    var account: String?
    var kind: VaultItem.Kind?

    /// One scope, as a chip; `token` is the text it was typed as.
    struct Scope: Identifiable, Equatable {
        var id: String { token }
        let label: String
        let symbol: String
        let token: String
    }
    private(set) var scopes: [Scope] = []

    static let kinds: [String: VaultItem.Kind] = [
        "login": .login, "logins": .login, "card": .card, "cards": .card, "note": .note, "notes": .note,
        "identity": .identity, "identities": .identity, "ssh": .sshKey, "key": .sshKey, "keys": .sshKey,
    ]

    init(_ raw: String, folders: [String] = [], accounts: [(id: String, email: String)] = []) {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix(">") {
            commandsOnly = true
            s.removeFirst()
            scopes.append(Scope(label: String(localized: "Commands"), symbol: "command", token: ">"))
        }
        var words: [String] = []
        for token in s.split(separator: " ").map(String.init) {
            let body = String(token.dropFirst())
            if token.count > 1, token.hasPrefix("#"), folder == nil,
               let path = folders.first(where: { Self.fold($0).hasPrefix(Self.fold(body)) })
                ?? folders.first(where: { Self.fold($0).contains(Self.fold(body)) }) {
                folder = path
                scopes.append(Scope(label: path, symbol: "folder", token: token))
            } else if token.count > 1, token.hasPrefix("@"), account == nil,
                      let match = accounts.first(where: { Self.fold($0.email).hasPrefix(Self.fold(body)) })
                        ?? accounts.first(where: { Self.fold($0.email).contains(Self.fold(body)) }) {
                account = match.id
                scopes.append(Scope(label: match.email, symbol: "person.crop.circle", token: token))
            } else if token.count > 1, token.hasSuffix(":"), kind == nil, let k = Self.kinds[token.dropLast().lowercased()] {
                kind = k
                scopes.append(Scope(label: k.paletteLabel, symbol: k.paletteSymbol, token: token))
            } else {
                words.append(token)
            }
        }
        text = words.joined(separator: " ")
    }

    /// Whether an item is inside the scopes (the text is ranked separately).
    func admits(_ item: VaultItem) -> Bool {
        if let kind, item.kind != kind { return false }
        if let account, item.accountId != account { return false }
        if let folder, !(item.folderName == folder || item.folderName?.hasPrefix(folder + "/") == true) { return false }
        return true
    }

    /// Case and accent blind, for matching.
    static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
}

/// Orders items for a query: an exact name, then the name's start, a word's start, the website, anywhere in the name,
/// the username, every word somewhere, and last a loose match ("gthb" → GitHub).
enum PaletteRank {
    static func score(_ item: VaultItem, _ query: String) -> Int? {
        let q = PaletteQuery.fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return 0 }
        let name = PaletteQuery.fold(item.name)
        let host = item.host.map(PaletteQuery.fold) ?? ""
        let user = item.username.map(PaletteQuery.fold) ?? ""
        if name == q { return 1000 }
        if name.hasPrefix(q) { return 900 }
        if words(name).contains(where: { $0.hasPrefix(q) }) { return 800 }
        if host.hasPrefix(q) || host.hasPrefix("www." + q) { return 700 }
        if name.contains(q) { return 600 }
        if host.contains(q) { return 500 }
        if user.hasPrefix(q) { return 450 }
        if user.contains(q) { return 400 }
        let parts = q.split(separator: " ").map(String.init)
        if parts.count > 1, parts.allSatisfy({ name.contains($0) || host.contains($0) || user.contains($0) }) { return 300 }
        if let loose = subsequence(q, in: name) { return 100 + loose }
        return nil
    }

    private static func words(_ s: String) -> [Substring] {
        s.split { !$0.isLetter && !$0.isNumber }
    }

    /// All of `q`'s letters, in order, in `s`: 0–99, tighter matches higher. Needs at least two letters.
    private static func subsequence(_ q: String, in s: String) -> Int? {
        let needle = Array(q.filter { $0 != " " })
        guard needle.count >= 2 else { return nil }
        var i = 0
        var last: Int?
        var gaps = 0
        for (position, c) in s.enumerated() where i < needle.count && c == needle[i] {
            if let last { gaps += position - last - 1 }
            last = position
            i += 1
        }
        guard i == needle.count else { return nil }
        return max(0, 99 - gaps * 6)
    }

    /// Items for a query, best first; recently used and favorites break ties.
    static func rank(_ items: [VaultItem], _ query: String, recents: [String]) -> [VaultItem] {
        let recent = Dictionary(recents.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return items.compactMap { item -> (VaultItem, Int)? in
            guard let s = score(item, query) else { return nil }
            let bonus = (recent[item.id].map { 20 - min($0, 19) } ?? 0) + (item.favorite ? 5 : 0)
            return (item, s + bonus)
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending }
        .map(\.0)
    }
}

/// Items run from the palette, most recent first: what it suggests before anything is typed.
/// Only ids are kept (never names or secrets).
enum PaletteRecents {
    private static let key = "paletteRecents"
    static let limit = 12

    static var ids: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    static func note(_ id: String) {
        var list = ids.filter { $0 != id }
        list.insert(id, at: 0)
        UserDefaults.standard.set(Array(list.prefix(limit)), forKey: key)
    }
}

/// `gen`, `gen 24`, `password 16`, `passphrase`, `words 5`: a fresh secret right in the results.
enum PaletteGenerate: Equatable {
    case password(length: Int?)
    case passphrase(words: Int?)

    static func parse(_ text: String) -> PaletteGenerate? {
        let parts = text.lowercased().split(separator: " ").map(String.init)
        guard let head = parts.first, parts.count <= 2 else { return nil }
        let n = parts.count == 2 ? Int(parts[1]) : nil
        if parts.count == 2, n == nil { return nil }
        switch head {
        case "gen", "generate", "pwgen", "pw", "password":
            return .password(length: n.map { min(max($0, PasswordGenerator.lengthRange.lowerBound), PasswordGenerator.lengthRange.upperBound) })
        case "passphrase", "phrase", "words":
            return .passphrase(words: n.map { min(max($0, PassphraseGenerator.wordRange.lowerBound), PassphraseGenerator.wordRange.upperBound) })
        default:
            return nil
        }
    }

    /// A fresh value, with the generator's saved options and the asked-for size.
    func generate() -> String {
        switch self {
        case .password(let length):
            var g = PasswordGenerator.saved
            if let length { g.length = length }
            return g.generate()
        case .passphrase(let words):
            var g = UserDefaults.standard.data(forKey: "passphraseGenerator")
                .flatMap { try? JSONDecoder().decode(PassphraseGenerator.self, from: $0) } ?? PassphraseGenerator()
            if let words { g.words = words }
            return g.generate()
        }
    }

    var title: String {
        switch self {
        case .password: String(localized: "Generated password")
        case .passphrase: String(localized: "Generated passphrase")
        }
    }
}

/// A new login from what was typed: a domain becomes the website (and the name, without "www.").
enum PaletteCreate {
    static func prefill(_ text: String) -> EditItemSheet.Prefill? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let bare = t.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        let looksLikeDomain = !bare.contains(" ") && bare.contains(".") && bare.split(separator: ".").last.map { $0.count >= 2 } == true
        guard looksLikeDomain else { return EditItemSheet.Prefill(name: t) }
        let host = String(bare.split(separator: "/").first ?? Substring(bare))
        let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return EditItemSheet.Prefill(name: name, uri: "https://" + host)
    }
}

extension VaultItem.Kind {
    var paletteLabel: String {
        switch self {
        case .unsupported: String(localized: "Unsupported item")
        case .login: String(localized: "Logins")
        case .note: String(localized: "Secure Notes")
        case .card: String(localized: "Cards")
        case .identity: String(localized: "Identities")
        case .sshKey: String(localized: "SSH Keys")
        }
    }

    var paletteSymbol: String {
        switch self {
        case .unsupported: "questionmark.square"
        case .login: "key"
        case .note: "note.text"
        case .card: "creditcard"
        case .identity: "person.crop.rectangle"
        case .sshKey: "terminal"
        }
    }
}
