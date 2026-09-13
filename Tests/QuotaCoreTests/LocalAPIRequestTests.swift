import XCTest
@testable import QuotaCore

final class LocalAPIRequestTests: XCTestCase {
    private func request(_ headers: String...) -> String {
        (["GET /v1/limits HTTP/1.1"] + headers).joined(separator: "\r\n") + "\r\n\r\n"
    }

    func testLocalToolsAreAnswered() {
        XCTAssertTrue(LocalAPIRequest.isAllowed(request("Host: 127.0.0.1:6736", "User-Agent: curl/8.7.1"), port: 6736))
        XCTAssertTrue(LocalAPIRequest.isAllowed(request("Host: localhost:6736"), port: 6736))
        XCTAssertTrue(LocalAPIRequest.isAllowed(request(), port: 6736), "no Host: a hand-rolled local client")
    }

    /// DNS rebinding: the page's own name resolves to 127.0.0.1, but the
    /// browser still says whose page it is.
    func testARebindingPageIsRefused() {
        XCTAssertFalse(LocalAPIRequest.isAllowed(request("Host: evil.example:6736"), port: 6736))
        XCTAssertFalse(LocalAPIRequest.isAllowed(request("Host: 127.0.0.1:6736", "Origin: https://evil.example"), port: 6736))
        XCTAssertFalse(LocalAPIRequest.isAllowed(request("Host: 127.0.0.1:9999"), port: 6736))
    }

    func testALocalPageIsAnswered() {
        XCTAssertTrue(LocalAPIRequest.isAllowed(request("Host: 127.0.0.1:6736", "Origin: http://localhost:3000"), port: 6736))
    }
}
