import AppKit
import CryptoKit
import ImageIO
import Observation
import VaultwardenAPI

/// Website icons, fetched from the account's own icon service (Vaultwarden `/icons/…`, or Bitwarden's for
/// official accounts) so domains only go to the provider you already use. The disk cache is encrypted and
/// its file names are keyed hashes, so it doesn't reveal which sites you use.
@MainActor @Observable
final class IconStore {
    /// Decoded bitmap bytes owned by this store; object/allocator overhead is not included.
    let memoryBudget: Int
    @ObservationIgnored private(set) var memoryCost = 0
    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private var costs: [String: Int] = [:]
    @ObservationIgnored private var access: [String: UInt64] = [:]
    @ObservationIgnored private var clock: UInt64 = 0
    @ObservationIgnored private var generation: UInt64 = 0
    private struct Request {
        let id: UUID
        let task: Task<Void, Never>
    }
    @ObservationIgnored private var inflight: [String: Request] = [:]
    @ObservationIgnored private var missing: Set<String> = []
    /// Per icon server: hash of its generic "no icon" placeholder, so we show our own initial instead.
    @ObservationIgnored private var placeholders: [String: Task<Data?, Never>] = [:]
    @ObservationIgnored var makeSession: () -> URLSession = { .shared }
    /// Where icons come from for items without a signed-in account (the full demo vault, for screenshots).
    @ObservationIgnored var fallbackEnvironment: ServerEnvironment?

    private let cacheDir: URL
    private let key: SymmetricKey
    private let iconsEnabled: @MainActor () -> Bool
    private let fetch: @MainActor (URL, URLSession) async throws -> (Data, URLResponse)

    init(memoryBudget: Int = 12 * 1024 * 1024, cacheDir: URL, key: SymmetricKey,
         iconsEnabled: @escaping @MainActor () -> Bool,
         fetch: @escaping @MainActor (URL, URLSession) async throws -> (Data, URLResponse) = { url, session in
             try await session.data(from: url)
         }) {
        self.memoryBudget = max(0, memoryBudget)
        self.cacheDir = cacheDir
        self.key = key
        self.iconsEnabled = iconsEnabled
        self.fetch = fetch
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    func image(for host: String) -> NSImage? {
        guard let image = images[host] else { return nil }
        touch(host)
        return image
    }

    private func touch(_ host: String) {
        clock &+= 1
        access[host] = clock
    }

    private func insert(_ image: NSImage, for host: String) {
        guard let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let cost = bitmap.bytesPerRow * bitmap.height
        guard cost > 0, cost <= memoryBudget else { return }
        while memoryCost + cost > memoryBudget, let oldest = access.min(by: { $0.value < $1.value })?.key {
            memoryCost -= costs.removeValue(forKey: oldest) ?? 0
            access.removeValue(forKey: oldest)
            images.removeValue(forKey: oldest)
        }
        memoryCost -= costs[host] ?? 0
        costs[host] = cost
        memoryCost += cost
        touch(host)
        images[host] = image
    }

    /// A memory miss refills from encrypted disk before trying the icon service.
    func request(host: String, environment: ServerEnvironment?) {
        guard iconsEnabled(), image(for: host) == nil, inflight[host] == nil, !missing.contains(host) else { return }
        if let cached = readCache(host) { insert(cached, for: host); return }
        guard let source = Self.url(for: host, environment: environment) else { return }
        let session = makeSession()
        let placeholder = placeholderHash(for: environment, session: session)
        let epoch = generation, id = UUID()
        let task = Task {
            defer {
                // A late completion must not remove a newer request for the same host.
                if inflight[host]?.id == id { inflight.removeValue(forKey: host) }
            }
            let result = try? await fetch(source, session)
            guard !Task.isCancelled, generation == epoch, inflight[host]?.id == id, iconsEnabled() else { return }
            let placeholderData = await placeholder.value
            guard !Task.isCancelled, generation == epoch, inflight[host]?.id == id, iconsEnabled() else { return }
            guard let (data, response) = result,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = Self.thumbnail(data), image.size.width >= 8,
                  placeholderData != Data(SHA256.hash(data: data)) else {
                missing.insert(host)
                return
            }
            // No suspension between validation and either cache write.
            insert(image, for: host)
            writeCache(host, data)
        }
        inflight[host] = Request(id: id, task: task)
    }

    private func placeholderHash(for environment: ServerEnvironment?, session: URLSession) -> Task<Data?, Never> {
        guard let probe = Self.url(for: "triwarden-no-icon.invalid", environment: environment) else { return Task { nil } }
        let key = probe.host() ?? ""
        if let task = placeholders[key] { return task }
        let task = Task<Data?, Never> {
            guard let (data, _) = try? await fetch(probe, session) else { return nil }
            return Data(SHA256.hash(data: data))
        }
        placeholders[key] = task
        return task
    }

    /// Releases decoded icons and invalidates all pending writes, retaining encrypted disk entries.
    func clearMemory() {
        generation &+= 1
        inflight.values.forEach { $0.task.cancel() }
        inflight = [:]
        placeholders.values.forEach { $0.cancel() }
        placeholders = [:]
        images = [:]
        costs = [:]
        access = [:]
        memoryCost = 0
        clock = 0
        missing = []
    }

    /// Explicitly forget both tiers, e.g. when icons are turned off in Settings.
    func clear() {
        clearMemory()
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    static func url(for host: String, environment: ServerEnvironment?) -> URL? {
        let safe = host.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        guard !safe.isEmpty, let root = environment?.iconsURL else { return nil }
        return root.appending(path: "\(safe)/icon.png")
    }

    private func fileURL(_ host: String) -> URL {
        let name = HMAC<SHA256>.authenticationCode(for: Data(host.utf8), using: key).map { String(format: "%02x", $0) }.joined()
        return cacheDir.appending(path: name)
    }

    private func readCache(_ host: String) -> NSImage? {
        guard let sealed = try? Data(contentsOf: fileURL(host)),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let data = try? AES.GCM.open(box, using: key) else { return nil }
        return Self.thumbnail(data)
    }

    /// The icon decoded at no more than 128 px (it's never drawn larger than ~60 pt), so a site's 512 px favicon
    /// doesn't sit in memory at full size. Kept at its own size when smaller.
    static func thumbnail(_ data: Data, maxPixels: Int = 128) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // Points at 2×, so it stays sharp on Retina.
        return NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
    }

    private func writeCache(_ host: String, _ data: Data) {
        guard let sealed = try? AES.GCM.seal(data, using: key).combined else { return }
        try? sealed.write(to: fileURL(host), options: .atomic)
    }
}
