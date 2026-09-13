import XCTest
@testable import QuotaCore

final class BudgetCheckTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    private func day(_ text: String) -> Date {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: text)!
    }

    private func spend(_ date: String, _ usd: Double) -> DailyCost {
        DailyCost(day: calendar.startOfDay(for: day(date + " 12:00")), usd: usd, tokens: 0, billableTokens: 0)
    }

    func testWarnsAtEightyAndSaysOverOnce() {
        let budget = SpendBudget(daily: 100, currency: "USD")
        let now = day("2026-09-13 18:00")
        let at85 = BudgetCheck.alerts(budget: budget, daily: [spend("2026-09-13", 85)], rate: nil, notified: [], now: now, calendar: calendar)
        XCTAssertEqual(at85.map(\.level), [80])
        let notified = at85.map(\.key)
        XCTAssertTrue(BudgetCheck.alerts(budget: budget, daily: [spend("2026-09-13", 90)], rate: nil, notified: notified, now: now, calendar: calendar).isEmpty)
        let over = BudgetCheck.alerts(budget: budget, daily: [spend("2026-09-13", 120)], rate: nil, notified: notified, now: now, calendar: calendar)
        XCTAssertEqual(over.map(\.level), [100])
        XCTAssertTrue(BudgetCheck.alerts(budget: budget, daily: [spend("2026-09-13", 150)], rate: nil, notified: notified + over.map(\.key), now: now, calendar: calendar).isEmpty)
    }

    /// The month counts from the 1st, in the budget's currency.
    func testTheMonthCountsFromTheFirstInItsOwnCurrency() {
        let budget = SpendBudget(monthly: 7000, currency: "CNY")
        let daily = [spend("2026-08-31", 500), spend("2026-09-01", 400), spend("2026-09-12", 600)]
        let alerts = BudgetCheck.alerts(budget: budget, daily: daily, rate: 7.1, notified: [], now: day("2026-09-13 09:00"), calendar: calendar)
        XCTAssertEqual(alerts.first?.period, .month)
        XCTAssertEqual(alerts.first?.level, 100)
        XCTAssertEqual(alerts.first?.spent ?? 0, 7100, accuracy: 0.01)
        XCTAssertTrue(BudgetCheck.alerts(budget: budget, daily: daily, rate: nil, notified: [], now: day("2026-09-13 09:00"), calendar: calendar).isEmpty,
                      "no exchange rate yet: wait")
    }

    func testANewDayStartsAgain() {
        let budget = SpendBudget(daily: 100)
        let yesterday = BudgetCheck.alerts(budget: budget, daily: [spend("2026-09-12", 130)], rate: nil, notified: [], now: day("2026-09-12 20:00"), calendar: calendar)
        let today = BudgetCheck.alerts(budget: budget, daily: [spend("2026-09-12", 130), spend("2026-09-13", 110)], rate: nil,
                                       notified: yesterday.map(\.key), now: day("2026-09-13 20:00"), calendar: calendar)
        XCTAssertEqual(today.map(\.level), [100])
    }
}

final class WeeklyDigestTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    private func at(_ text: String) -> Date {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: text)!
    }

    /// 2026-09-14 is a Monday: before nine nothing, after nine last week.
    func testDueAfterNineOnMonday() {
        XCTAssertNil(WeeklyDigest.dueWeek(now: at("2026-09-14 08:30"), lastSent: "", calendar: calendar))
        let due = WeeklyDigest.dueWeek(now: at("2026-09-14 09:30"), lastSent: "", calendar: calendar)
        XCTAssertEqual(due?.key, "2026-W37")
        XCTAssertEqual(due.map { calendar.component(.day, from: $0.start) }, 7)
        XCTAssertEqual(due.map { calendar.component(.day, from: $0.end) }, 13)
        XCTAssertNil(WeeklyDigest.dueWeek(now: at("2026-09-16 10:00"), lastSent: "2026-W37", calendar: calendar))
    }
}
