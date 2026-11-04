import XCTest

final class BrowserLoginPrefillTests: XCTestCase {
    func testKeepsFullFrontTabURLAndCleansName() throws {
        let prefill = try XCTUnwrap(BrowserLoginPrefill(
            isBrowser: true,
            host: "www.example.com",
            pageURL: URL(string: "https://www.example.com/sign-in?from=app")
        ))

        XCTAssertEqual(prefill.name, "example.com")
        XCTAssertEqual(prefill.uri, "https://www.example.com/sign-in?from=app")
    }

    func testFallsBackToSecureHostURL() throws {
        let prefill = try XCTUnwrap(BrowserLoginPrefill(isBrowser: true, host: "example.com", pageURL: nil))

        XCTAssertEqual(prefill.name, "example.com")
        XCTAssertEqual(prefill.uri, "https://example.com")
    }

    func testRequiresKnownBrowserHost() {
        XCTAssertNil(BrowserLoginPrefill(isBrowser: false, host: "example.com", pageURL: nil))
        XCTAssertNil(BrowserLoginPrefill(isBrowser: true, host: nil, pageURL: nil))
        XCTAssertNil(BrowserLoginPrefill(isBrowser: true, host: "", pageURL: nil))
    }
}
