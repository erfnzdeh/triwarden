import AppKit
import CryptoKit
import SwiftUI

// Production wiring lives outside the cache so its tests never access the user's Keychain or preferences.
@MainActor
extension IconStore {
    static let shared = IconStore(
        cacheDir: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Icons", directoryHint: .isDirectory),
        key: cacheKey(), iconsEnabled: { enabled }
    )

    static var enabled: Bool { UserDefaults.standard.object(forKey: Pref.showIcons) as? Bool ?? true }

    /// Preserve the existing key, encrypted files, and keyed file names across upgrades.
    private static func cacheKey() -> SymmetricKey {
        let service = "io.github.sinhong2011.triwarden.iconcache"
        if let data = Keychain.read(service: service), data.count == 32 { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256)
        Keychain.write(key.withUnsafeBytes { Data($0) }, service: service)
        return key
    }
}

/// The site's icon when available, otherwise the coloured initial. Cards use the API brand mark (Visa, Mastercard, …).
struct ItemIcon: View {
    @Environment(AppModel.self) private var model
    let item: VaultItem
    let size: CGFloat

    private struct LoadID: Hashable {
        let host: String?
        let cached: Bool
        let unlocked: Bool
    }

    var body: some View {
        let store = IconStore.shared
        let load = LoadID(host: item.host, cached: item.host.flatMap { store.images[$0] } != nil,
                          unlocked: model.isUnlocked && !model.lockClosing)
        Group {
            if item.kind == .card, let brand = item.properties["brand"]?.nilIfEmpty {
                CardBrandIcon(brand: brand, size: size)
                    .transition(.opacity)
            } else if let host = item.host, let image = store.image(for: host) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(size * 0.16)
                    .frame(width: size, height: size)
                    .background(.white, in: .rect(cornerRadius: size * 0.29, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.29, style: .continuous).strokeBorder(.black.opacity(0.08)))
                    .transition(.opacity)
            } else {
                Monogram(name: item.name, size: size)
            }
        }
        .animation(.easeOut(duration: 0.2), value: item.host.flatMap(store.image(for:)) != nil)
        .task(id: load) {
            // A visible row can lose its image to LRU eviction or another account being locked.
            guard load.unlocked, !load.cached, item.kind != .card, let host = load.host else { return }
            store.request(host: host, environment: model.session(for: item.accountId)?.environment ?? store.fallbackEnvironment)
        }
    }
}

/// Credit-card network mark for the vault list and hero avatar. Drawn to match Bitwarden's brand set.
struct CardBrandIcon: View {
    let brand: String
    let size: CGFloat

    private var kind: Kind {
        switch brand.lowercased() {
        case "visa": .visa
        case "mastercard": .mastercard
        case "amex", "american express": .amex
        case "discover": .discover
        case "jcb": .jcb
        case "unionpay", "union pay": .unionPay
        case "diners club", "diners": .diners
        case "maestro": .maestro
        default: .other
        }
    }

    private enum Kind { case visa, mastercard, amex, discover, jcb, unionPay, diners, maestro, other }

    var body: some View {
        Group {
            switch kind {
            case .visa: visa
            case .mastercard: mastercard
            case .amex: amex
            case .discover: discover
            case .jcb: jcb
            case .unionPay: unionPay
            case .diners: diners
            case .maestro: maestro
            case .other: other
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.29, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.29, style: .continuous).strokeBorder(.black.opacity(0.08)))
        .accessibilityHidden(true)
    }

    private var visa: some View {
        ZStack {
            Color(red: 0.10, green: 0.12, blue: 0.44)
            Text("VISA")
                .font(.system(size: size * 0.28, weight: .heavy, design: .rounded))
                .italic()
                .tracking(size * 0.02)
                .foregroundStyle(.white)
        }
    }

    private var mastercard: some View {
        ZStack {
            Color(white: 0.96)
            HStack(spacing: -size * 0.22) {
                Circle().fill(Color(red: 0.92, green: 0.20, blue: 0.14))
                Circle().fill(Color(red: 0.98, green: 0.62, blue: 0.12))
            }
            .frame(width: size * 0.72, height: size * 0.42)
        }
    }

    private var amex: some View {
        ZStack {
            Color(red: 0.00, green: 0.44, blue: 0.81)
            Text("AMEX")
                .font(.system(size: size * 0.24, weight: .bold, design: .rounded))
                .tracking(size * 0.01)
                .foregroundStyle(.white)
        }
    }

    private var discover: some View {
        ZStack {
            Color(white: 0.96)
            VStack(spacing: size * 0.04) {
                Text("DISCOVER")
                    .font(.system(size: size * 0.14, weight: .bold, design: .rounded))
                    .tracking(-0.3)
                    .foregroundStyle(Color(red: 0.15, green: 0.15, blue: 0.18))
                Capsule()
                    .fill(Color(red: 0.96, green: 0.45, blue: 0.10))
                    .frame(width: size * 0.38, height: size * 0.14)
            }
        }
    }

    private var jcb: some View {
        ZStack {
            Color(white: 0.96)
            HStack(spacing: size * 0.04) {
                brandChip("J", Color(red: 0.05, green: 0.35, blue: 0.70))
                brandChip("C", Color(red: 0.10, green: 0.55, blue: 0.30))
                brandChip("B", Color(red: 0.80, green: 0.15, blue: 0.20))
            }
        }
    }

    private var unionPay: some View {
        ZStack {
            Color(white: 0.96)
            HStack(spacing: -size * 0.08) {
                Capsule().fill(Color(red: 0.85, green: 0.15, blue: 0.15)).frame(width: size * 0.28, height: size * 0.42)
                Capsule().fill(Color(red: 0.10, green: 0.35, blue: 0.75)).frame(width: size * 0.28, height: size * 0.42)
                Capsule().fill(Color(red: 0.05, green: 0.55, blue: 0.35)).frame(width: size * 0.28, height: size * 0.42)
            }
        }
    }

    private var diners: some View {
        ZStack {
            Color(red: 0.00, green: 0.36, blue: 0.58)
            ZStack {
                Circle().strokeBorder(.white, lineWidth: size * 0.045).frame(width: size * 0.48, height: size * 0.48)
                Capsule().fill(.white).frame(width: size * 0.14, height: size * 0.36)
            }
        }
    }

    private var maestro: some View {
        ZStack {
            Color(white: 0.96)
            HStack(spacing: -size * 0.22) {
                Circle().fill(Color(red: 0.00, green: 0.40, blue: 0.75))
                Circle().fill(Color(red: 0.85, green: 0.10, blue: 0.30))
            }
            .frame(width: size * 0.72, height: size * 0.42)
        }
    }

    private var other: some View {
        ZStack {
            Color(white: 0.96)
            Image(systemName: "creditcard.fill")
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.45))
        }
    }

    private func brandChip(_ letter: String, _ color: Color) -> some View {
        Text(letter)
            .font(.system(size: size * 0.22, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size * 0.24, height: size * 0.42)
            .background(color, in: .rect(cornerRadius: size * 0.06))
    }
}
