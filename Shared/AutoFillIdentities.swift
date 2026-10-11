import AuthenticationServices
import TriCrypto
import Foundation

/// Tells macOS which domains/usernames we can fill, so QuickType suggests them. Only identifiers are
/// shared with the system — never passwords; those come from the extension after unlock.
enum AutoFillIdentities {
    /// Off during self-tests so test data never reaches the system's AutoFill store.
    nonisolated(unsafe) static var isEnabled = true

    /// `equivalents`: a login is also suggested on the domains that share its sign-in (google.com → youtube.com).
    static func publish(_ items: [VaultItem], equivalents: EquivalentDomains = .none) {
        guard isEnabled else { return }
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
        identities += logins.flatMap { item in
            item.passkeys.compactMap { pk -> ASPasskeyCredentialIdentity? in
                guard let id = pk.rawId else { return nil }
                return ASPasskeyCredentialIdentity(relyingPartyIdentifier: pk.rpId, userName: pk.userName ?? item.username ?? "",
                                                   credentialID: id, userHandle: pk.rawUserHandle ?? Data(), recordIdentifier: item.id)
            }
        }
        Task {
            let store = ASCredentialIdentityStore.shared
            guard await store.state().isEnabled else { return }
            try? await store.replaceCredentialIdentities(identities)
        }
    }

    static func clear() {
        guard isEnabled else { return }
        Task { try? await ASCredentialIdentityStore.shared.removeAllCredentialIdentities() }
    }
}
