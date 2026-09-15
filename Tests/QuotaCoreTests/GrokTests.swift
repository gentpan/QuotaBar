import XCTest
@testable import QuotaCore

final class GrokAuthFileTests: XCTestCase {
    private let far = Date(timeIntervalSince1970: 2_000_000_000)   // 2033
    private let now = Date(timeIntervalSince1970: 1_800_000_000)   // 2027

    private func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    func testReadsTheFlatShapeEarlyCLIsWrote() {
        XCTAssertEqual(LocalCredentials.grokToken(in: ["access_token": "flat"], now: now), "flat")
        XCTAssertEqual(LocalCredentials.grokToken(in: ["api_key": "k"], now: now), "k")
    }

    /// grok 1.0.x keys the file by issuer and calls the bearer `key`.
    func testReadsTheIssuerKeyedShape() {
        let root: [String: Any] = [
            "https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828": [
                "key": "eyJ.jwt.here",
                "auth_mode": "oidc",
                "expires_at": iso(far),
                "refresh_token": "never-read",
            ],
        ]
        XCTAssertEqual(LocalCredentials.grokToken(in: root, now: now), "eyJ.jwt.here")
    }

    func testPrefersTheEntryThatLivesLongest() {
        let root: [String: Any] = [
            "a": ["key": "short", "expires_at": iso(now.addingTimeInterval(60))],
            "b": ["key": "long", "expires_at": iso(far)],
        ]
        XCTAssertEqual(LocalCredentials.grokToken(in: root, now: now), "long")
    }

    /// An expired token is still returned — it gets a 401 and the "sign in
    /// again" message, which is the truth; "not configured" would not be.
    func testFallsBackToTheMostRecentlyExpiredToken() {
        let root: [String: Any] = [
            "a": ["key": "older", "expires_at": iso(now.addingTimeInterval(-7200))],
            "b": ["key": "newer", "expires_at": iso(now.addingTimeInterval(-60))],
        ]
        XCTAssertEqual(LocalCredentials.grokToken(in: root, now: now), "newer")
    }

    func testIgnoresEntriesWithoutAKey() {
        let root: [String: Any] = ["x": ["auth_mode": "oidc"], "y": "not a dictionary"]
        XCTAssertNil(LocalCredentials.grokToken(in: root, now: now))
    }

    /// The CLI writes six fractional digits; the parser must not choke on them.
    func testParsesTheCLIsTimestampFormat() {
        XCTAssertNotNil(Dates.parseISO("2026-09-12T04:02:12.532598Z"))
        XCTAssertNotNil(Dates.parseISO("2026-09-16T18:04:26.137506+00:00"))
    }
}

final class GrokBillingTests: XCTestCase {
    /// The live shape, values as observed; strings shortened.
    private let body = """
    {"config":{
      "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",
                       "start":"2026-09-09T18:04:26.137506+00:00",
                       "end":"2026-09-16T18:04:26.137506+00:00"},
      "creditUsagePercent":11.0,
      "onDemandCap":{"val":0},"onDemandUsed":{"val":0},
      "productUsage":[{"product":"GrokImagine","usagePercent":10.0},
                      {"product":"GrokBuild","usagePercent":1.0}],
      "isUnifiedBillingUser":true,
      "billingPeriodStart":"2026-09-09T18:04:26.137506+00:00",
      "billingPeriodEnd":"2026-09-16T18:04:26.137506+00:00"}}
    """

    func testAWeeklyAccountIsLabelledWeekly() throws {
        let snapshot = try GrokProvider.parse(Data(body.utf8))
        let credits = try XCTUnwrap(snapshot.windows.first)
        XCTAssertEqual(credits.usedPercent, 11)
        XCTAssertEqual(credits.windowSeconds, 7 * 86_400, "weekly, not the monthly it used to say")
        XCTAssertNotNil(credits.resetsAt, "the six-digit fraction parses")
        XCTAssertNil(credits.scope)
    }

    func testEachProductBecomesAScopedWindowWithItsOwnId() throws {
        let snapshot = try GrokProvider.parse(Data(body.utf8))
        let scoped = snapshot.windows.filter { $0.scope != nil }
        XCTAssertEqual(scoped.map(\.scope), ["Grok Imagine", "Grok Build"])
        XCTAssertEqual(scoped.map(\.usedPercent), [10, 1])
        XCTAssertEqual(Set(snapshot.windows.map(\.id)).count, snapshot.windows.count, "ids collide in ForEach otherwise")
    }

    /// Only Grok Build used: its bar would repeat the credits' own (issue #2).
    func testAProductHoldingTheWholePoolIsNotShownTwice() throws {
        let only = body
            .replacingOccurrences(of: #""creditUsagePercent":11.0"#, with: #""creditUsagePercent":1.0"#)
            .replacingOccurrences(of: #"{"product":"GrokImagine","usagePercent":10.0},"#, with: "")
        let snapshot = try GrokProvider.parse(Data(only.utf8))
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertNil(snapshot.windows[0].scope)
        XCTAssertEqual(snapshot.windows[0].usedPercent, 1)
    }

    func testAZeroOnDemandCapAddsNoWindow() throws {
        let snapshot = try GrokProvider.parse(Data(body.utf8))
        XCTAssertEqual(snapshot.windows.count, 3)
    }

    func testPeriodLabels() {
        XCTAssertEqual(GrokProvider.periodLabel("USAGE_PERIOD_TYPE_WEEKLY").seconds, 604_800)
        XCTAssertEqual(GrokProvider.periodLabel("USAGE_PERIOD_TYPE_MONTHLY").seconds, 2_592_000)
        XCTAssertEqual(GrokProvider.periodLabel("USAGE_PERIOD_TYPE_DAILY").seconds, 86_400)
        XCTAssertNil(GrokProvider.periodLabel(nil).seconds)
    }

    func testProductNamesGetTheirSpaceBack() {
        XCTAssertEqual(GrokProvider.productName("GrokImagine"), "Grok Imagine")
        XCTAssertEqual(GrokProvider.productName("GrokBuild"), "Grok Build")
        XCTAssertEqual(GrokProvider.productName("Grok"), "Grok")
        XCTAssertEqual(GrokProvider.productName("grok4Fast"), "grok4 Fast")
    }

    func testABodyWithoutConfigIsABadResponse() {
        XCTAssertThrowsError(try GrokProvider.parse(Data(#"{"subscriptionTier":"x"}"#.utf8)))
        XCTAssertThrowsError(try GrokProvider.parse(Data("not json".utf8)))
    }
}
