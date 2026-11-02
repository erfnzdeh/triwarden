import AuthenticationServices
import TriCrypto
import Foundation

/// Tells macOS which domains/usernames we can fill, so QuickType suggests them. Only identifiers are
/// shared with the system — never passwords; those come from the extension after unlock.
enum AutoFillIdentities {
    struct PasskeyReference: Codable, Hashable {
        var accountID: String
        var itemID: String
    }

    /// Off during self-tests so test data never reaches the system's AutoFill store.
    nonisolated(unsafe) static var isEnabled = true

    private static var passkeyIndexURL: URL { AccountStore.metadataURL("autofill-passkeys.json") }

    /// Versioned because existing identity stores contain the legacy bare item id. Both forms remain readable.
    static func passkeyRecordIdentifier(accountID: String, itemID: String) -> String {
        "tw1:\(accountID):\(itemID)"
    }

    static func parsePasskeyRecordIdentifier(_ value: String?) -> PasskeyReference? {
        guard let value else { return nil }
        let parts = value.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "tw1", !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        return PasskeyReference(accountID: String(parts[1]), itemID: String(parts[2]))
    }

    /// The one account that owns the matching named credentials. Nil keeps the chooser for missing, stale or ambiguous data.
    static func preferredAccountID(for credentialIDs: [Data]) -> String? {
        guard !credentialIDs.isEmpty,
              let data = try? Data(contentsOf: passkeyIndexURL),
              let index = try? JSONDecoder().decode([String: [PasskeyReference]].self, from: data) else { return nil }
        return preferredAccountID(for: credentialIDs, index: index)
    }

    static func preferredAccountID(for credentialIDs: [Data], index: [String: [PasskeyReference]]) -> String? {
        guard !credentialIDs.isEmpty else { return nil }
        let references = credentialIDs.flatMap { index[$0.base64EncodedString()] ?? [] }
        let accounts = Set(references.map(\.accountID))
        return accounts.count == 1 ? accounts.first : nil
    }

    /// `equivalents`: a login is also suggested on the domains that share its sign-in (google.com → youtube.com).
    static func publish(_ items: [VaultItem], equivalents: EquivalentDomains = .none) {
        guard isEnabled else { return }
        let identities = identities(for: items, equivalents: equivalents)
        Task { await replaceSystemIdentities(with: identities) }
    }

    /// Extensions can be terminated as soon as they complete their request. Await the identity-store update there so
    /// a newly saved passkey is available to the very next Safari / system AutoFill request.
    static func publishAndWait(_ items: [VaultItem], equivalents: EquivalentDomains = .none) async {
        guard isEnabled else { return }
        let identities = identities(for: items, equivalents: equivalents)
        await replaceSystemIdentities(with: identities)
    }

    private static func identities(for items: [VaultItem], equivalents: EquivalentDomains) -> [any ASCredentialIdentity] {
        let logins = items.filter { !$0.isDeleted && !$0.isArchived && $0.kind == .login }
        var identities: [any ASCredentialIdentity] = logins.flatMap { item -> [any ASCredentialIdentity] in
            guard item.password != nil else { return [] }
            var sites = Set<String>()
            for host in item.hosts {
                sites.insert(host)
                for related in equivalents.related(to: host) where !EquivalentDomains.within(host, related) {
                    sites.insert(related)
                }
            }
            return sites.sorted().map { site in
                ASPasswordCredentialIdentity(serviceIdentifier: ASCredentialServiceIdentifier(identifier: site, type: .domain),
                                             user: item.username ?? "", recordIdentifier: item.id)
            }
        }
        identities += logins.compactMap { item in
            guard let host = item.hosts.first, item.totp != nil else { return nil }
            return ASOneTimeCodeCredentialIdentity(serviceIdentifier: ASCredentialServiceIdentifier(identifier: host, type: .domain),
                                                   label: item.name, recordIdentifier: item.id)
        }
        var passkeyIndex: [String: [PasskeyReference]] = [:]
        identities += logins.flatMap { item in
            item.passkeys.compactMap { pk -> ASPasskeyCredentialIdentity? in
                guard let id = pk.rawId else { return nil }
                let reference = PasskeyReference(accountID: item.accountId, itemID: item.id)
                passkeyIndex[id.base64EncodedString(), default: []].append(reference)
                return ASPasskeyCredentialIdentity(relyingPartyIdentifier: pk.rpId, userName: pk.userName ?? item.username ?? "",
                                                   credentialID: id, userHandle: pk.rawUserHandle ?? Data(),
                                                   recordIdentifier: passkeyRecordIdentifier(accountID: item.accountId, itemID: item.id))
            }
        }
        if let data = try? JSONEncoder().encode(passkeyIndex) { try? data.write(to: passkeyIndexURL, options: .atomic) }
        return identities
    }

    private static func replaceSystemIdentities(with identities: [any ASCredentialIdentity]) async {
        let store = ASCredentialIdentityStore.shared
        guard await store.state().isEnabled else { return }
        try? await store.replaceCredentialIdentities(identities)
    }

    static func clear() {
        guard isEnabled else { return }
        try? FileManager.default.removeItem(at: passkeyIndexURL)
        Task { try? await ASCredentialIdentityStore.shared.removeAllCredentialIdentities() }
    }
}
