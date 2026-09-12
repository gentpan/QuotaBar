import XCTest
@testable import QuotaCore

final class ServiceStatusTests: XCTestCase {
    private let page = URL(string: "https://status.example.com")!

    func testOperational() throws {
        let data = Data("""
        {"page":{"url":"https://status.example.com"},
         "status":{"indicator":"none","description":"All Systems Operational"},
         "incidents":[]}
        """.utf8)
        let status = try StatusPages.parse(data, page: page)
        XCTAssertEqual(status.level, .operational)
        XCTAssertEqual(status.description, "All Systems Operational")
        XCTAssertEqual(status.pageURL, page)
        XCTAssertTrue(status.level.isHealthy)
    }

    func testIncidentNameWins() throws {
        let data = Data("""
        {"status":{"indicator":"minor","description":"Minor Service Outage"},
         "incidents":[{"name":"Elevated errors on Claude Code","status":"investigating"}]}
        """.utf8)
        let status = try StatusPages.parse(data, page: page)
        XCTAssertEqual(status.level, .minor)
        XCTAssertEqual(status.description, "Elevated errors on Claude Code")
        XCTAssertFalse(status.level.isHealthy)
    }

    func testEveryBand() throws {
        for (raw, level) in [("major", ServiceStatusLevel.major), ("critical", .critical), ("maintenance", .maintenance)] {
            let data = Data(#"{"status":{"indicator":"\#(raw)","description":"x"}}"#.utf8)
            XCTAssertEqual(try StatusPages.parse(data, page: page).level, level)
        }
    }

    func testUnknownIndicatorThrows() {
        let data = Data(#"{"status":{"indicator":"weird","description":"x"}}"#.utf8)
        XCTAssertThrowsError(try StatusPages.parse(data, page: page))
        XCTAssertThrowsError(try StatusPages.parse(Data("nope".utf8), page: page))
    }

    func testPagesArePinned() {
        XCTAssertEqual(
            StatusPages.supported,
            [.codex, .claude, .cursor, .kimi, .minimax, .gemini, .manus, .deepseek])
        for id in StatusPages.supported {
            XCTAssertEqual(StatusPages.page(for: id)?.scheme, "https")
        }
        XCTAssertNil(StatusPages.page(for: .grok))
        XCTAssertNil(StatusPages.page(for: .zai))
    }

    func testGoogleCloudOpenIncidentOnGemini() throws {
        let data = Data("""
        [{"end":"2026-01-01T00:00:00+00:00","status_impact":"SERVICE_OUTAGE","external_desc":"old",
          "affected_products":[{"title":"Vertex Gemini API"}]},
         {"end":null,"status_impact":"SERVICE_DISRUPTION","external_desc":"Elevated latency on Gemini 2.5",
          "affected_products":[{"title":"Vertex Gemini API"}]},
         {"end":null,"status_impact":"SERVICE_OUTAGE","external_desc":"Cloud SQL down",
          "affected_products":[{"title":"Cloud SQL"}]}]
        """.utf8)
        let status = try StatusPages.parseGoogleCloud(data, product: "Gemini", page: page)
        XCTAssertEqual(status.level, .minor)
        XCTAssertEqual(status.description, "Elevated latency on Gemini 2.5")
    }

    func testGoogleCloudQuietIsOperational() throws {
        let data = Data(#"[{"end":"2026-01-01T00:00:00+00:00","status_impact":"SERVICE_OUTAGE","affected_products":[{"title":"Vertex Gemini API"}]}]"#.utf8)
        let status = try StatusPages.parseGoogleCloud(data, product: "Gemini", page: page)
        XCTAssertEqual(status.level, .operational)
    }
}
