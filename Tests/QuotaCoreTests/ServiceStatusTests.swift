import XCTest
@testable import QuotaCore

final class ServiceStatusTests: XCTestCase {
    private let page = URL(string: "https://status.example.com")!

    override func setUp() { L10n.override = .en }
    override func tearDown() { L10n.override = .system }

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

    /// The headline is the page's English; Chinese says it with the level.
    func testHeadlineInChinese() throws {
        L10n.override = .zhHans
        let data = Data("""
        {"status":{"indicator":"minor","description":"Minor Service Outage"},"incidents":[]}
        """.utf8)
        XCTAssertEqual(try StatusPages.parse(data, page: page).description, "轻微故障")
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

    /// The strip on a closed row is the provider's own service, not the
    /// page's first entry.
    func testPrimaryComponentIsTheServiceNotTheFirstEntry() {
        func c(_ name: String) -> ServiceComponent { ServiceComponent(id: name, name: name, level: .operational) }
        XCTAssertEqual(
            StatusPages.primaryComponent(for: .claude, in: [c("Claude for Government"), c("claude.ai"), c("Claude Code")])?.name,
            "Claude Code")
        XCTAssertEqual(
            StatusPages.primaryComponent(for: .deepseek, in: [c("网页对话服务 (Web Chat Service)"), c("API 服务 (API Service)")])?.name,
            "API 服务 (API Service)")
        // Exact before loose: "api.manus.im" also contains the name.
        XCTAssertEqual(StatusPages.primaryComponent(for: .manus, in: [c("api.manus.im"), c("manus.im")])?.name, "manus.im")
        XCTAssertEqual(StatusPages.primaryComponent(for: .codex, in: [c("Login"), c("CLI"), c("Codex API")])?.name, "CLI")
        // A page that renamed everything still answers with something.
        XCTAssertEqual(StatusPages.primaryComponent(for: .cursor, in: [c("Everything")])?.name, "Everything")
        XCTAssertNil(StatusPages.primaryComponent(for: .gemini, in: []))
    }

    // MARK: Focus on the coding services

    /// What the owner saw: Claude's page at "minor" for days over a Cowork
    /// incident while Claude Code was fine. The badge follows Claude Code
    /// and the API; the Cowork incident waits in the opened row.
    private let claudePage = """
    {"status":{"indicator":"minor","description":"Minor Service Outage"},
     "incidents":[{"name":"Degraded functionality for Claude Cowork on Windows","status":"identified",
                   "components":[{"id":"cw","name":"Claude Cowork"}]}],
     "components":[
       {"id":"ai","name":"claude.ai","status":"operational","group":false,"showcase":true},
       {"id":"api","name":"Claude API (api.anthropic.com)","status":"operational","group":false,"showcase":true},
       {"id":"cc","name":"Claude Code","status":"operational","group":false,"showcase":true},
       {"id":"cw","name":"Claude Cowork","status":"partial_outage","group":false,"showcase":true}]}
    """

    func testAnIncidentElsewhereLeavesTheCodingBadgeGreen() throws {
        let status = try StatusPages.parse(
            Data(claudePage.utf8), page: page,
            focus: StatusPages.focusComponentNames(for: .claude), keywords: StatusPages.focusKeywords(for: .claude))
        XCTAssertEqual(status.level, .operational)
        XCTAssertEqual(status.focus, ["Claude Code", "Claude API (api.anthropic.com)"])
        XCTAssertEqual(status.elsewhere, ["Degraded functionality for Claude Cowork on Windows"])
        XCTAssertEqual(status.components.count, 4, "every component is still listed")
    }

    func testWithoutAFocusTheBadgeIsThePagesOwn() throws {
        let status = try StatusPages.parse(Data(claudePage.utf8), page: page)
        XCTAssertEqual(status.level, .minor)
        XCTAssertTrue(status.focus.isEmpty)
        XCTAssertEqual(status.description, "Degraded functionality for Claude Cowork on Windows")
    }

    func testAFocusComponentsOwnBandIsTheBadge() throws {
        let json = claudePage.replacingOccurrences(
            of: #""name":"Claude Code","status":"operational""#,
            with: #""name":"Claude Code","status":"degraded_performance""#)
        let status = try StatusPages.parse(Data(json.utf8), page: page, focus: ["Claude Code", "Claude API"])
        XCTAssertEqual(status.level, .minor)
    }

    /// An incident touching the focus counts even before the page moves the
    /// component's band, and its name is the sentence.
    func testAnIncidentOnTheFocusIsAtLeastMinor() throws {
        let json = claudePage.replacingOccurrences(
            of: #""components":[{"id":"cw","name":"Claude Cowork"}]"#,
            with: #""components":[{"id":"cc","name":"Claude Code"}]"#)
        let status = try StatusPages.parse(Data(json.utf8), page: page, focus: ["Claude Code", "Claude API"])
        XCTAssertEqual(status.level, .minor)
        XCTAssertEqual(status.description, "Degraded functionality for Claude Cowork on Windows")
        XCTAssertTrue(status.elsewhere.isEmpty)
    }

    /// OpenAI's feed lists no components on its incidents: the name decides.
    func testAnIncidentWithoutComponentsIsJudgedByItsName() throws {
        let json = """
        {"status":{"indicator":"minor","description":"x"},
         "incidents":[{"name":"Elevated errors for Codex CLI","status":"investigating","components":[]},
                      {"name":"ChatGPT Work turns are failing","status":"investigating"}],
         "components":[{"id":"cli","name":"CLI","status":"operational"},
                       {"id":"w","name":"ChatGPT Work","status":"degraded_performance"}]}
        """
        let status = try StatusPages.parse(
            Data(json.utf8), page: page,
            focus: StatusPages.focusComponentNames(for: .codex), keywords: StatusPages.focusKeywords(for: .codex))
        XCTAssertEqual(status.level, .minor)
        XCTAssertEqual(status.description, "Elevated errors for Codex CLI")
        XCTAssertEqual(status.elsewhere, ["ChatGPT Work turns are failing"])
    }

    /// OpenAI's summary omits the CLI; the full component list supplies it,
    /// and only the focus components are added from there.
    func testFocusComponentsMissingFromTheSummaryComeFromTheFullList() throws {
        let summary = """
        {"status":{"indicator":"none","description":"x"},"incidents":[],
         "components":[{"id":"web","name":"Codex Web","status":"operational"}]}
        """
        let all = """
        {"components":[{"id":"web","name":"Codex Web","status":"operational"},
                       {"id":"cli","name":"CLI","status":"degraded_performance"},
                       {"id":"sora","name":"Sora","status":"major_outage"}]}
        """
        let status = try StatusPages.parse(
            Data(summary.utf8), page: page, focus: StatusPages.focusComponentNames(for: .codex),
            allComponents: Data(all.utf8))
        XCTAssertEqual(status.components.map(\.name), ["Codex Web", "CLI"])
        XCTAssertEqual(status.focus, ["CLI", "Codex Web"])
        XCTAssertEqual(status.level, .minor)
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
            [.codex, .claude, .cursor, .kimi, .minimax, .gemini, .manus, .deepseek, .moonshot, .copilot, .windsurf])
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
