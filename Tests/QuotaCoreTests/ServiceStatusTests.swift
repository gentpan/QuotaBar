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

    func testShowcasedComponentsAreListedInOrder() throws {
        let data = Data("""
        {"status":{"indicator":"minor","description":"x"},
         "components":[
           {"id":"g","name":"Group","status":"operational","group":true,"showcase":true},
           {"id":"a","name":"claude.ai","status":"operational","group":false,"showcase":true},
           {"id":"b","name":"Claude Cowork","status":"partial_outage","group":false,"showcase":true},
           {"id":"c","name":"Hidden","status":"major_outage","group":false,"showcase":false}]}
        """.utf8)
        let status = try StatusPages.parse(data, page: page)
        XCTAssertEqual(status.components.map(\.name), ["claude.ai", "Claude Cowork"])
        XCTAssertEqual(status.components.map(\.level), [.operational, .major])
    }

    func testEveryLeafIsListedWhenNothingIsShowcased() throws {
        let data = Data("""
        {"status":{"indicator":"none","description":"x"},
         "components":[
           {"id":"a","name":"API","status":"degraded_performance","group":false,"showcase":false},
           {"id":"g","name":"Group","status":"operational","group":true,"showcase":false}]}
        """.utf8)
        let status = try StatusPages.parse(data, page: page)
        XCTAssertEqual(status.components.map(\.name), ["API"])
        XCTAssertEqual(status.components.first?.level, .minor)
    }

    func testUptimeDaysAreSortedBandedAndGreyDropped() throws {
        let data = Data("""
        {"months":[
          {"name":"August","days":[
            {"color":"#76ad2a","date":"2026-08-30T00:00:00.000Z","events":[],"p":0,"m":0},
            {"color":"#e75f36","date":"2026-08-31T00:00:00.000Z","events":[{"name":"Slow API"}],"p":7082,"m":0},
            {"color":"#EAEAEA","date":"2026-09-01T00:00:00.000Z","events":[],"p":null,"m":null}]},
          {"name":"July","days":[
            {"color":"#e04343","date":"2026-07-31T00:00:00.000Z","events":[{"name":"Down"}],"p":0,"m":6529}]}]}
        """.utf8)
        let days = try StatusPages.parseUptime(data)
        XCTAssertEqual(days.count, 3)
        XCTAssertEqual(days.map(\.level), [.critical, .operational, .major])
        XCTAssertEqual(days[2].events, ["Slow API"])
        // (7082 + 6529) seconds over three days.
        XCTAssertEqual(UptimeDay.uptimePercent(days), 100 - 13_611.0 / (3 * 86_400) * 100, accuracy: 0.001)
        XCTAssertThrowsError(try StatusPages.parseUptime(Data(#"{"months":[]}"#.utf8)))
    }

    func testIncidentIOImpactsBecomeDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-09-12T12:00:00Z")!
        let data = Data("""
        {"incidents":[
          {"name":"Slow images","component_impacts":[
             {"component_id":"img","status":"degraded_performance","start_at":"2026-09-11T22:00:00Z","end_at":"2026-09-12T01:00:00Z"}]},
          {"name":"API down","component_impacts":[
             {"component_id":"api","status":"full_outage","start_at":"2026-09-10T10:00:00Z","end_at":"2026-09-10T11:00:00Z"},
             {"component_id":"img","status":"partial_outage","start_at":"2026-09-10T10:00:00Z","end_at":"2026-09-10T10:30:00Z"}]},
          {"name":"Still open","component_impacts":[
             {"component_id":"api","status":"degraded_performance","start_at":"2026-09-12T11:00:00Z","end_at":null}]}]}
        """.utf8)
        let img = try StatusPages.uptimeFromIncidentIO(data, componentID: "img", days: 4, now: now, calendar: calendar)
        XCTAssertEqual(img.count, 4)
        XCTAssertEqual(img.map(\.level), [.operational, .major, .minor, .minor])
        XCTAssertEqual(img[1].downtimeSeconds, 1800)
        XCTAssertEqual(img[2].downtimeSeconds, 7200)
        XCTAssertEqual(img[3].downtimeSeconds, 3600)
        XCTAssertEqual(img[2].events, ["Slow images"])
        let api = try StatusPages.uptimeFromIncidentIO(data, componentID: "api", days: 4, now: now, calendar: calendar)
        XCTAssertEqual(api.map(\.level), [.operational, .critical, .operational, .minor])
        // The open one runs to now: an hour so far.
        XCTAssertEqual(api[3].downtimeSeconds, 3600)
        XCTAssertNil(StatusPages.incidentIOProxy(for: .claude))
        XCTAssertNotNil(StatusPages.incidentIOProxy(for: .codex))
    }

    func testDayColoursReadByHue() {
        XCTAssertEqual(StatusPages.dayLevel(color: "#76ad2a"), .operational)
        XCTAssertEqual(StatusPages.dayLevel(color: "#2fcc66"), .operational)
        XCTAssertEqual(StatusPages.dayLevel(color: "#d2a92a"), .minor)
        XCTAssertEqual(StatusPages.dayLevel(color: "#f08030"), .major)
        XCTAssertEqual(StatusPages.dayLevel(color: "#e04343"), .critical)
        XCTAssertEqual(StatusPages.dayLevel(color: "#3498db"), .maintenance)
        XCTAssertNil(StatusPages.dayLevel(color: "#EAEAEA"))
        XCTAssertEqual(StatusPages.dayLevel(color: nil), .operational)
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
