import XCTest
@testable import QuotaCore

/// Grok Bot's weekly allowance comes from a second dashboard endpoint, so the
/// summary parse is pinned with and without it.
final class CursorGrokBotTests: XCTestCase {
    private let summary = Data("""
    {"membershipType":"pro","billingCycleEnd":"2026-10-01T00:00:00.000Z",
     "individualUsage":{"plan":{"totalPercentUsed":42,"apiPercentUsed":60,"limit":2000,"used":840}}}
    """.utf8)

    func testIncludedAllowanceBecomesAWeeklyRow() throws {
        let sand = Data("""
        {"currentPeriodStart":"2026-09-09T21:00:00.000Z","nextResetTimestampUtc":"2026-09-16T21:00:00.000Z",
         "usagePercent":2,"hasAvailableUsage":true,"hasNonZeroIncludedLimit":true}
        """.utf8)
        let snapshot = try CursorProvider.parse(summary, account: "dev@example.com", sand: sand)
        let bot = try XCTUnwrap(snapshot.windows.first { $0.title == "Grok Bot" })
        XCTAssertEqual(bot.usedPercent, 2)
        XCTAssertEqual(bot.scope, "Grok Bot")
        XCTAssertEqual(bot.windowSeconds, 7 * 86_400)
        XCTAssertEqual(bot.resetsAt, Dates.parseISO("2026-09-16T21:00:00.000Z"))
        // Last, after the plan rows: it is the least important number.
        XCTAssertEqual(snapshot.windows.last?.title, "Grok Bot")
        XCTAssertEqual(snapshot.account, "dev@example.com")
    }

    func testNoIncludedAllowanceMeansNoRow() throws {
        let sand = Data("""
        {"currentPeriodStart":null,"nextResetTimestampUtc":null,"usagePercent":0,
         "hasAvailableUsage":false,"hasNonZeroIncludedLimit":false}
        """.utf8)
        let snapshot = try CursorProvider.parse(summary, sand: sand)
        XCTAssertFalse(snapshot.windows.contains { $0.title == "Grok Bot" })
        XCTAssertEqual(snapshot.windows.count, 2)
    }

    func testGarbageFromTheSecondEndpointIsIgnored() throws {
        let snapshot = try CursorProvider.parse(summary, sand: Data("<html>".utf8))
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(try CursorProvider.parse(summary).windows.count, 2)
    }
}
