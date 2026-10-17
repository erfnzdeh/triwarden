import AppKit
import CryptoKit
import Foundation
import Observation

/// Paid, but never locked — Fork's model. Every feature works without a license and there's no time limit; an
/// unregistered official build only asks, now and then at launch, whether you'd like to buy one.
///
/// A **License** is a one-time purchase through Stripe. Komori validates the payment, signs the license and emails
/// it through Resend. The key covers **one natural person** on every Mac they use (including a company Mac). Not for
/// resale or sharing across people (see `docs/LICENSE-TERMS.md`). Managing work accounts needs a license, regardless
/// of who owns the Mac; an employer may buy and assign one.
///
/// A license key is a small signed note, `<payload>.<signature>` in base64url. Its payload is JSON:
/// `{"n": name, "e": email, "o": order, "d": "yyyy-MM-dd"}`. Triwarden checks it on this Mac against the Ed25519
/// public key in Info.plist (`TWLicensePublicKey`). Registration makes no network request and sends no key or device
/// identifier to Stripe, Komori or another license server. Extra payload fields (e.g. a former Friends `"t"`) are
/// ignored for compatibility.
///
/// An honour system: the source is GPL and anyone may build it without the reminder, which is fine. A build without a
/// store link (forks) never reminds, and Debug builds never do either.
@MainActor @Observable
final class License {
    struct Registration: Codable, Equatable {
        var name: String
        var email: String
        var order: String
        var date: String
        /// Ignored if present (older Friends Club offline keys used `"t":"f"`). Kept so decoding still succeeds.
        var tier: String? = nil

        enum CodingKeys: String, CodingKey {
            case name = "n", email = "e", order = "o", date = "d", tier = "t"
        }
    }

    enum Problem: LocalizedError {
        case invalid

        var errorDescription: String? {
            String(localized: "This license key isn't valid. Paste the whole key from your email.")
        }
    }

    /// Where "Purchase License" goes (Stripe checkout); nil in builds without a store.
    let storeURL: URL?
    /// Where "Learn More" goes (site `/pricing/`). Falls back to `storeURL` when unset.
    let pricingURL: URL?
    private let publicKey: Curve25519.Signing.PublicKey?
    private(set) var registration: Registration?
    /// The registered key, for showing its last characters.
    private(set) var key: String?

    /// Set when focusing the key field (e.g. "I Have a License Key" or "Focus License Field").
    var wantsKeyEntry = false

    var isConfigured: Bool { storeURL != nil && publicKey != nil }
    var isRegistered: Bool { registration != nil }

    /// Keychain storage. Unknown fields from older stored records are ignored when decoding.
    private struct Stored: Codable {
        var key: String
    }

    private static let service = "io.github.sinhong2011.triwarden.license"
    private static let firstLaunchKey = "licenseFirstLaunch"
    private static let lastReminderKey = "licenseLastReminder"
    /// No reminder in the first ~30 days; then at most one a week. No extra reminder after updates.
    private static let grace: TimeInterval = 30 * 86_400
    private static let interval: TimeInterval = 7 * 86_400

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        storeURL = (info["TWStoreURL"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        pricingURL = (info["TWPricingURL"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) } ?? storeURL
        publicKey = (info["TWLicensePublicKey"] as? String).flatMap { Data(base64Encoded: $0) }
            .flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
        if let stored = Keychain.read(service: Self.service).flatMap({ try? JSONDecoder().decode(Stored.self, from: $0) }),
           let registration = verify(stored.key) {
            key = stored.key
            self.registration = registration
        }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.firstLaunchKey) == nil {
            defaults.set(Date.now, forKey: Self.firstLaunchKey)
        }
    }

    /// Whether to show the reminder now (and, if so, note that it was shown).
    func takeReminder(now: Date = .now) -> Bool {
        #if DEBUG
        // `--license-review`: show it now, to review the flow.
        return CommandLine.arguments.contains { $0.hasPrefix("--license-review") } && isConfigured && !isRegistered
        #else
        guard isConfigured, !isRegistered else { return false }
        let defaults = UserDefaults.standard
        let first = defaults.object(forKey: Self.firstLaunchKey) as? Date ?? now
        guard now.timeIntervalSince(first) >= Self.grace else { return false }
        if let last = defaults.object(forKey: Self.lastReminderKey) as? Date,
           now.timeIntervalSince(last) < Self.interval {
            return false
        }
        defaults.set(now, forKey: Self.lastReminderKey)
        return true
        #endif
    }

    func buy() {
        if let storeURL { NSWorkspace.shared.open(storeURL) }
    }

    func openPricing() {
        if let pricingURL { NSWorkspace.shared.open(pricingURL) }
    }

    /// Checks the signed key locally. Registration never contacts a server.
    func register(_ rawKey: String) throws {
        let key = rawKey.filter { !$0.isWhitespace }
        guard let registration = verify(key) else { throw Problem.invalid }
        if let data = try? JSONEncoder().encode(Stored(key: key)) {
            Keychain.write(data, service: Self.service)
        }
        self.key = key
        self.registration = registration
    }

    #if DEBUG
    /// Snapshots: show a registration without a key or the Keychain.
    func preview(_ registration: Registration?, key: String? = nil) {
        self.registration = registration
        self.key = key
    }
    #endif

    /// Forgets the key on this Mac. Nothing is sent because registration is fully local.
    func remove() {
        Keychain.delete(service: Self.service)
        key = nil
        registration = nil
    }

    private func verify(_ key: String) -> Registration? {
        let parts = key.split(separator: ".")
        guard let publicKey, parts.count == 2,
              let payload = Data(base64URL: parts[0]), let signature = Data(base64URL: parts[1]),
              publicKey.isValidSignature(signature, for: payload) else { return nil }
        return try? JSONDecoder().decode(Registration.self, from: payload)
    }
}

private extension Data {
    init?(base64URL text: Substring) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
