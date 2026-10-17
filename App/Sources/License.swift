import AppKit
import CryptoKit
import Foundation
import Observation

/// Paid, but never locked — Fork's model. Every feature works without a license and there's no time limit; an
/// unregistered official build only asks, now and then at launch, whether you'd like to buy one.
///
/// A **License** is a one-time purchase (Lemon Squeezy — cards, Alipay, WeChat Pay, PayPal…). It ends the reminder
/// and covers **one natural person** on every Mac they use (including a company Mac). Not for resale or sharing
/// across people (see `docs/LICENSE-TERMS.md`). Managing work accounts needs a license, regardless of who owns the Mac; an employer may buy and assign one.
///
/// Two kinds of key register:
///
/// - **Receipt keys** (a UUID): Lemon Squeezy generates and emails them. Pressing Activate sends the key — and a
///   random id for this install, never the Mac's name — to Lemon Squeezy's license API once. Nothing is checked
///   again after that: not in the background, not at launch.
/// - **Offline keys**: a small signed note, `<payload>.<signature>` in base64url, the payload JSON
///   `{"n": name, "e": email, "o": order, "d": "yyyy-MM-dd"}`, checked here against the Ed25519 public key in
///   Info.plist (`TWLicensePublicKey`). For buyers who'd rather nothing went online, and a fallback should Lemon
///   Squeezy ever go away. Signed with `make license`; the private key never enters the repo. Extra payload fields
///   (e.g. a former Friends `"t"`) are ignored for compatibility.
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
        case rejected
        case otherProduct
        case unreachable

        var errorDescription: String? {
            switch self {
            case .invalid: String(localized: "This license key isn't valid. Paste the whole key from your receipt.")
            case .rejected: String(localized: "This license key couldn't be activated.")
            case .otherProduct: String(localized: "This license key is for a different product.")
            case .unreachable: String(localized: "Couldn't reach Lemon Squeezy. Check your connection and try again.")
            }
        }
    }

    /// Where "Purchase License" goes (Lemon Squeezy checkout); nil in builds without a store.
    let storeURL: URL?
    /// Where "Learn More" goes (site `/pricing/`). Falls back to `storeURL` when unset.
    let pricingURL: URL?
    private let publicKey: Curve25519.Signing.PublicKey?
    private let productID: Int?
    private(set) var registration: Registration?
    /// The registered key, for showing its last characters.
    private(set) var key: String?

    /// Set when focusing the key field (e.g. "I Have a License Key" or "Focus License Field").
    var wantsKeyEntry = false

    var isConfigured: Bool { storeURL != nil && (publicKey != nil || productID != nil) }
    var isRegistered: Bool { registration != nil }

    /// What the Keychain keeps: the key, and for a receipt key what Lemon Squeezy said about it when it was activated.
    private struct Stored: Codable {
        var key: String
        var registration: Registration?
        /// Kept for Keychain compatibility with builds that stored a Lemon product id; unused for gating.
        var lemonProductID: Int?
    }

    private static let service = "io.github.sinhong2011.triwarden.license"
    private static let firstLaunchKey = "licenseFirstLaunch"
    private static let lastReminderKey = "licenseLastReminder"
    private static let instanceKey = "licenseInstance"
    /// No reminder in the first ~30 days; then at most one a week. No extra reminder after updates.
    private static let grace: TimeInterval = 30 * 86_400
    private static let interval: TimeInterval = 7 * 86_400

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        storeURL = (info["TWStoreURL"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        pricingURL = (info["TWPricingURL"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) } ?? storeURL
        publicKey = (info["TWLicensePublicKey"] as? String).flatMap { Data(base64Encoded: $0) }
            .flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
        productID = (info["TWLemonProductID"] as? String).flatMap { Int($0) }
        if let stored = Keychain.read(service: Self.service).flatMap({ try? JSONDecoder().decode(Stored.self, from: $0) }),
           let registration = verify(stored.key) ?? stored.registration {
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

    /// An offline key is checked here; a receipt key is activated with Lemon Squeezy, once.
    func register(_ rawKey: String) async throws {
        let key = rawKey.filter { !$0.isWhitespace }
        if let registration = verify(key) {
            save(Stored(key: key), registration)
        } else if UUID(uuidString: key) != nil, productID != nil {
            save(Stored(key: key, registration: try await activate(key)), nil)
        } else {
            throw Problem.invalid
        }
    }

    #if DEBUG
    /// Snapshots: show a registration without a key or the Keychain.
    func preview(_ registration: Registration?, key: String? = nil) {
        self.registration = registration
        self.key = key
    }
    #endif

    /// Forgets the key on this Mac. Nothing is sent: receipt keys are sold without an activation limit, so there's no
    /// seat to give back.
    func remove() {
        Keychain.delete(service: Self.service)
        key = nil
        registration = nil
    }

    private func save(_ stored: Stored, _ verified: Registration?) {
        if let data = try? JSONEncoder().encode(stored) { Keychain.write(data, service: Self.service) }
        key = stored.key
        registration = verified ?? stored.registration
    }

    private func verify(_ key: String) -> Registration? {
        let parts = key.split(separator: ".")
        guard let publicKey, parts.count == 2,
              let payload = Data(base64URL: parts[0]), let signature = Data(base64URL: parts[1]),
              publicKey.isValidSignature(signature, for: payload) else { return nil }
        return try? JSONDecoder().decode(Registration.self, from: payload)
    }

    // MARK: Lemon Squeezy license API (receipt keys)

    private struct Activation: Decodable {
        struct Instance: Decodable { let id: String }
        struct Meta: Decodable {
            let orderID: Int?
            let productID: Int?
            let customerName: String?
            let customerEmail: String?
            enum CodingKeys: String, CodingKey {
                case orderID = "order_id", productID = "product_id"
                case customerName = "customer_name", customerEmail = "customer_email"
            }
        }
        let activated: Bool?
        let instance: Instance?
        let meta: Meta?
    }

    private func activate(_ key: String) async throws -> Registration {
        // A random id for this install, kept so registering again reuses it; the Mac's name stays private.
        let defaults = UserDefaults.standard
        let instance = defaults.string(forKey: Self.instanceKey) ?? UUID().uuidString
        defaults.set(instance, forKey: Self.instanceKey)

        var request = URLRequest(url: URL(string: "https://api.lemonsqueezy.com/v1/licenses/activate")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Both values are a UUID: nothing to escape.
        request.httpBody = Data("license_key=\(key)&instance_name=\(instance)".utf8)
        // Errors (unknown key, disabled key) come back as 4xx with the same JSON.
        guard let (data, _) = try? await URLSession(configuration: .ephemeral).data(for: request),
              let response = try? JSONDecoder().decode(Activation.self, from: data) else {
            throw Problem.unreachable
        }
        guard response.activated == true, response.instance != nil else {
            throw Problem.rejected // Lemon Squeezy's own message is English only
        }
        guard response.meta?.productID == productID else { throw Problem.otherProduct }
        return Registration(
            name: response.meta?.customerName ?? "",
            email: response.meta?.customerEmail ?? "",
            order: response.meta?.orderID.map(String.init) ?? "",
            date: Date.now.formatted(.iso8601.year().month().day())
        )
    }
}

private extension Data {
    init?(base64URL text: Substring) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
