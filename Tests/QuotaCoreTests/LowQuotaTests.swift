import XCTest
@testable import QuotaCore

final class LowQuotaTests: XCTestCase {
    func testFlashesFromFifteenPercentLeft() {
        XCTAssertEqual(LowQuota.level(used: 84), AlertLevel.none)
        XCTAssertEqual(LowQuota.level(used: 84.4), AlertLevel.none, "shown as 16% left")
        XCTAssertEqual(LowQuota.level(used: 84.6), .warning, "shown as 15% left")
        XCTAssertEqual(LowQuota.level(used: 85), .warning)
        XCTAssertEqual(LowQuota.level(used: 94), .warning)
    }

    func testRedForTheLastFivePercent() {
        XCTAssertEqual(LowQuota.level(used: 95), .critical)
        XCTAssertEqual(LowQuota.level(used: 100), .critical)
        XCTAssertEqual(LowQuota.level(used: 130), .critical)
    }

    func testNoReadingIsNotLow() {
        XCTAssertEqual(LowQuota.level(used: nil), AlertLevel.none)
        XCTAssertEqual(LowQuota.level(used: [nil, 20]), AlertLevel.none)
    }

    func testMostUrgentReadingWins() {
        XCTAssertEqual(LowQuota.level(used: [10, 88, nil]), .warning)
        XCTAssertEqual(LowQuota.level(used: [88, 97]), .critical)
        XCTAssertEqual(LowQuota.level(used: []), AlertLevel.none)
    }

    /// Independent of the notification thresholds, and of whether they are on.
    func testIgnoresAlertSettings() {
        let off = AlertSettings(enabled: false)
        XCTAssertEqual(off.level(for: 90), AlertLevel.none)
        XCTAssertEqual(LowQuota.level(used: 90), .warning)
    }
}
