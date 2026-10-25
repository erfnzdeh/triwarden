import AppKit
import CryptoKit
import XCTest
import VaultwardenAPI

@MainActor
final class IconStoreTests: XCTestCase {
    @MainActor private final class Toggle {
        var enabled = true
    }
    private var directories: [URL] = []
    private let environment = ServerEnvironment.bitwardenUS

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }

    override func tearDown() async throws {
        for url in directories { try? FileManager.default.removeItem(at: url) }
        directories = []
    }

    private func png(pixels: Int = 128) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32)!
        rep.bitmapData!.initialize(repeating: 127, count: rep.bytesPerRow * rep.pixelsHigh)
        return rep.representation(using: .png, properties: [:])!
    }

    private func eventually(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(predicate(), file: file, line: line)
    }

    func testLRUBudgetAndEncryptedDiskRefill() async throws {
        let dir = try directory(), key = SymmetricKey(size: .bits256), data = png()
        var downloads = 0
        let store = IconStore(memoryBudget: 2 * 128 * 128 * 4, cacheDir: dir, key: key, iconsEnabled: { true }) { url, _ in
            let placeholder = url.path.contains("triwarden-no-icon.invalid")
            if !placeholder { downloads += 1 }
            return (placeholder ? Data([0]) : data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        for host in ["a.test", "b.test"] {
            store.request(host: host, environment: environment)
            await eventually { store.images[host] != nil }
        }
        XCTAssertNotNil(store.image(for: "a.test")) // a is now most recently used
        store.request(host: "c.test", environment: environment)
        await eventually { store.images["c.test"] != nil }
        XCTAssertNil(store.images["b.test"])
        XCTAssertNotNil(store.images["a.test"])
        XCTAssertLessThanOrEqual(store.memoryCost, store.memoryBudget)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 3)
        for file in files {
            XCTAssertFalse(file.lastPathComponent.contains(".test"))
            let encrypted = try Data(contentsOf: file)
            XCTAssertNotEqual(encrypted, data)
            XCTAssertEqual(try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: key), data)
        }
        store.request(host: "b.test", environment: environment)
        XCTAssertNotNil(store.images["b.test"])
        XCTAssertEqual(downloads, 3, "An evicted entry must refill from disk")
        store.clearMemory()
        XCTAssertTrue(store.images.isEmpty)
        XCTAssertEqual(store.memoryCost, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 3)
        store.request(host: "b.test", environment: environment)
        XCTAssertNotNil(store.image(for: "b.test"))
        XCTAssertEqual(downloads, 3, "A memory miss must refill from encrypted disk without a download")
        store.clear()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 0)
    }

    func testClearRejectsLateTaskAndDoesNotRemoveReplacementRequest() async throws {
        let dir = try directory(), data = png()
        var pending: [CheckedContinuation<(Data, URLResponse), any Error>] = []
        let store = IconStore(cacheDir: dir, key: SymmetricKey(size: .bits256), iconsEnabled: { true }) { url, _ in
            if url.path.contains("triwarden-no-icon.invalid") {
                return (Data([0]), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            // Deliberately ignores cancellation: generation checks must still reject this result.
            return try await withCheckedThrowingContinuation { pending.append($0) }
        }
        store.request(host: "a.test", environment: environment)
        await eventually { pending.count == 1 }
        store.clearMemory()
        store.request(host: "a.test", environment: environment)
        await eventually { pending.count == 2 }
        let response = HTTPURLResponse(url: URL(string: "https://example.test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        pending[0].resume(returning: (data, response))
        // A MainActor round trip allows the old task's completion to run.
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(store.images.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        store.request(host: "a.test", environment: environment)
        XCTAssertEqual(pending.count, 2)
        pending[1].resume(returning: (data, response))
        await eventually { store.images["a.test"] != nil }
        XCTAssertEqual(pending.count, 2)
    }

    func testManyHostsStayWithinBudgetAndClearOnDisable() async throws {
        let data = png()
        let toggle = Toggle()
        let store = IconStore(memoryBudget: 12 * 1024 * 1024, cacheDir: try directory(),
                              key: SymmetricKey(size: .bits256), iconsEnabled: { toggle.enabled }) { url, _ in
            return (url.path.contains("triwarden-no-icon.invalid") ? Data([0]) : data,
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        for i in 0..<1000 {
            let host = "site\(i).test"
            store.request(host: host, environment: environment)
            await eventually { store.images[host] != nil }
            XCTAssertLessThanOrEqual(store.memoryCost, store.memoryBudget)
        }
        print("ICON_BUDGET hosts=1000 unboundedRGBABytes=65536000 retained=\(store.images.count) decodedBytes=\(store.memoryCost) budget=\(store.memoryBudget)")
        XCTAssertLessThan(store.images.count, 1000)
        toggle.enabled = false
        store.clearMemory()
        store.request(host: "site0.test", environment: environment)
        XCTAssertTrue(store.images.isEmpty)
    }

    func testDisableRejectsInFlightResultWithoutWritingDisk() async throws {
        let dir = try directory(), data = png()
        let toggle = Toggle()
        var pending: CheckedContinuation<(Data, URLResponse), any Error>?
        let store = IconStore(cacheDir: dir, key: SymmetricKey(size: .bits256), iconsEnabled: { toggle.enabled }) { url, _ in
            if url.path.contains("triwarden-no-icon.invalid") {
                return (Data([0]), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        store.request(host: "disabled.test", environment: environment)
        await eventually { pending != nil }
        toggle.enabled = false
        let response = HTTPURLResponse(url: URL(string: "https://example.test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        pending?.resume(returning: (data, response))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(store.images.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        toggle.enabled = true
        pending = nil
        store.request(host: "disabled.test", environment: environment)
        await eventually { pending != nil } // disabled result must not poison the negative cache
        pending?.resume(returning: (data, response))
        await eventually { store.images["disabled.test"] != nil }
    }

    func testImageLargerThanBudgetIsNotRetainedButIsSavedOnDisk() async throws {
        let dir = try directory(), data = png()
        let store = IconStore(memoryBudget: 1, cacheDir: dir, key: SymmetricKey(size: .bits256), iconsEnabled: { true }) { url, _ in
            return (url.path.contains("triwarden-no-icon.invalid") ? Data([0]) : data,
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        store.request(host: "oversize.test", environment: environment)
        await eventually { (try? FileManager.default.contentsOfDirectory(atPath: dir.path).count) == 1 }
        XCTAssertTrue(store.images.isEmpty)
        XCTAssertEqual(store.memoryCost, 0)
        store.request(host: "oversize.test", environment: nil)
        XCTAssertTrue(store.images.isEmpty)
        XCTAssertEqual(store.memoryCost, 0)
    }

    func testClearWhileAwaitingPlaceholderRejectsOldGeneration() async throws {
        let dir = try directory(), data = png()
        var placeholders: [CheckedContinuation<(Data, URLResponse), any Error>] = []
        let store = IconStore(cacheDir: dir, key: SymmetricKey(size: .bits256), iconsEnabled: { true }) { url, _ in
            if url.path.contains("triwarden-no-icon.invalid") {
                return try await withCheckedThrowingContinuation { placeholders.append($0) }
            }
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        store.request(host: "waiting.test", environment: environment)
        await eventually { placeholders.count == 1 }
        store.clearMemory()
        store.request(host: "waiting.test", environment: environment)
        await eventually { placeholders.count == 2 }
        let response = HTTPURLResponse(url: URL(string: "https://example.test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        placeholders[0].resume(returning: (Data([0]), response))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(store.images.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        placeholders[1].resume(returning: (Data([0]), response))
        await eventually { store.images["waiting.test"] != nil }
    }

    func testThumbnailDownsamplesBeforeCaching() throws {
        let image = try XCTUnwrap(IconStore.thumbnail(png(pixels: 512)))
        let bitmap = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(bitmap.width, 128)
        XCTAssertEqual(bitmap.height, 128)
    }

    func testThumbnailRejectsUndecodableInput() {
        XCTAssertNil(IconStore.thumbnail(Data([1, 2, 3])))
    }
}
