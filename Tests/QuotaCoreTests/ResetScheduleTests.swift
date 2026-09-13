import XCTest
@testable import QuotaCore

final class ResetScheduleTests: XCTestCase {
    func testGroupsTheWeekByDayEarliestFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 10))!
        func at(_ day: Int, _ hour: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))! }
        let claude = UsageSnapshot(planName: nil, account: nil, windows: [
            UsageWindow(title: "5h", usedPercent: 44, resetsAt: at(13, 11), windowSeconds: 18_000),
            UsageWindow(title: "Week", usedPercent: 57, resetsAt: at(14, 5), windowSeconds: 604_800),
        ])
        let codex = UsageSnapshot(planName: nil, account: nil, windows: [
            UsageWindow(title: "Week", usedPercent: 19, resetsAt: at(19, 20), windowSeconds: 604_800),
            UsageWindow(title: "Past", usedPercent: 90, resetsAt: at(13, 9)),
            UsageWindow(title: "Far", usedPercent: 5, resetsAt: at(25, 9)),
        ])
        let days = ResetSchedule.upcoming([(.claude, claude), (.codex, codex)], now: now, calendar: calendar)
        XCTAssertEqual(days.count, 3)
        XCTAssertEqual(days.map { $0.entries.map(\.window.title) }, [["5h"], ["Week"], ["Week"]])
        XCTAssertEqual(days.last?.entries.first?.provider, .codex)
    }
}
