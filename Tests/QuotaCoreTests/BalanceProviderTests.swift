import XCTest
@testable import QuotaCore

/// Prepaid providers: a balance, what it went on, and each key's share.
///
/// The DeepSeek console payloads follow the shapes its usage page reads —
/// `get_user_summary`, `get_api_keys`, `usage/by_api_key/cost` and `/amount` —
/// with made-up figures and names.
final class BalanceProviderTests: XCTestCase {
    private func json(_ text: String) -> Data { Data(text.utf8) }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 18_000)!
        calendar.firstWeekday = 2
        return calendar
    }

    /// Tuesday 15 September 2026, 10:00 at UTC+5.
    private var now: Date { Date(timeIntervalSince1970: 1_789_448_400) }

    private func midnight(_ day: Int) -> Int {
        Int(calendar.date(from: DateComponents(year: 2026, month: 9, day: day))!.timeIntervalSince1970)
    }

    // MARK: DeepSeek credential

    func testAnSKValueIsAnAPIKeyAndAnythingElseAConsoleToken() {
        XCTAssertEqual(DeepSeekProvider.credential(" sk-abc123 \n"), .apiKey("sk-abc123"))
        XCTAssertEqual(DeepSeekProvider.credential("AbCdEf0123"), .consoleToken("AbCdEf0123"))
        XCTAssertEqual(DeepSeekProvider.credential("Bearer AbCdEf0123"), .consoleToken("AbCdEf0123"))
        XCTAssertEqual(DeepSeekProvider.credential(#"{"value":"AbCdEf0123","__version":"0"}"#), .consoleToken("AbCdEf0123"))
    }

    func testAnAPIKeyReadingIsASheetThatSaysHowToSeeKeys() throws {
        let snapshot = try DeepSeekProvider.parse(json(#"{"is_available":false,"balance_infos":[{"currency":"CNY","total_balance":"1.00","granted_balance":"0.00","topped_up_balance":"1.00"}]}"#))
        let sheet = try XCTUnwrap(snapshot.balance)
        XCTAssertEqual(sheet.balances, [AccountBalance(currency: "CNY", total: 1, paid: 1)])
        XCTAssertEqual(sheet.canCallAPI, false)
        XCTAssertNil(sheet.keys)
        XCTAssertNotNil(sheet.keysNote)
        XCTAssertEqual(sheet.representedWindowIDs, snapshot.windows.map(\.id))
    }

    // MARK: DeepSeek console

    private var summary: Data {
        json(#"{"code":0,"msg":"","data":{"biz_code":0,"biz_msg":"","biz_data":{"normal_wallets":[{"currency":"USD","balance":"12.3300000000","token_estimation":"0"},{"currency":"CNY","balance":"100.0000000000","token_estimation":"0"}],"bonus_wallets":[{"currency":"CNY","balance":"7.39","token_estimation":"0"}],"total_costs":[{"currency":"USD","amount":"7.66"},{"currency":"CNY","amount":"592.67"}]}}}"#)
    }

    private var keys: Data {
        json(#"{"code":0,"msg":"","data":{"biz_code":0,"biz_msg":"","biz_data":{"api_keys":[{"created_at":1788000000,"last_use":1789440000,"tracking_id":"t-editor","sensitive_id":"sk-aaaa****1111","name":"Editor"},{"created_at":1788000000,"last_use":0,"tracking_id":"t-idle","sensitive_id":"sk-bbbb****2222","name":"Idle"}]}}}"#)
    }

    private func cost() -> Data {
        // Editor: ¥10 on the 1st (this month, not this week), ¥5 on the 14th
        // (this week), ¥2 today on another model. A deleted key spent $1 today.
        let body: [String: Any] = ["code": 0, "msg": "", "data": ["biz_code": 0, "biz_msg": "", "biz_data": [
            "start": midnight(1), "end": midnight(16), "bucket": 86_400, "models": ["deepseek-chat", "deepseek-v4-pro"],
            "data": [
                ["currency": "CNY", "series": [
                    ["api_key": ["tracking_id": "t-editor", "name": "Editor", "sensitive_id": "sk-aaaa****1111", "valid": true],
                     "model": "deepseek-chat",
                     "buckets": [["time": midnight(1), "cost": "10"], ["time": midnight(14), "cost": "5"], ["time": midnight(15), "cost": "0"]]],
                    ["api_key": ["tracking_id": "t-editor", "name": "Editor", "sensitive_id": "sk-aaaa****1111", "valid": true],
                     "model": "deepseek-v4-pro",
                     "buckets": [["time": midnight(15), "cost": "2"]]],
                    ["api_key": ["tracking_id": "t-idle", "name": "Idle", "sensitive_id": "sk-bbbb****2222", "valid": true],
                     "model": "deepseek-chat",
                     "buckets": [["time": midnight(15), "cost": "0"]]],
                ]],
                ["currency": "USD", "series": [
                    ["api_key": ["tracking_id": "t-gone", "name": "Old", "sensitive_id": "sk-cccc****3333", "valid": false],
                     "model": "deepseek-chat",
                     "buckets": [["time": midnight(15), "cost": "1"]]],
                ]],
            ],
        ]]]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private func amount() -> Data {
        let usage = { (requests: Int, output: Int, hit: Int, miss: Int) -> [String: Int] in
            ["REQUEST": requests, "RESPONSE_TOKEN": output, "PROMPT_CACHE_HIT_TOKEN": hit, "PROMPT_CACHE_MISS_TOKEN": miss]
        }
        let body: [String: Any] = ["code": 0, "msg": "", "data": ["biz_code": 0, "biz_msg": "", "biz_data": [
            "start": midnight(1), "end": midnight(16), "bucket": 86_400,
            "series": [
                ["api_key": ["tracking_id": "t-editor", "name": "Editor", "sensitive_id": "sk-aaaa****1111", "valid": true],
                 "model": "deepseek-chat & deepseek-reasoner",
                 "buckets": [["time": midnight(1), "usage": usage(20, 1000, 500, 500)], ["time": midnight(15), "usage": usage(3, 100, 0, 50)]]],
            ],
        ]]]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private func hourly() -> Data {
        let today = midnight(15)
        let body: [String: Any] = ["code": 0, "msg": "", "data": ["biz_code": 0, "biz_msg": "", "biz_data": [
            "start": today, "end": today + 86_400, "bucket": 3_600,
            "data": [["currency": "CNY", "series": [
                ["api_key": ["tracking_id": "t-editor", "name": "Editor", "sensitive_id": "sk-aaaa****1111", "valid": true],
                 "model": "deepseek-v4-pro",
                 "buckets": [["time": today + 3 * 3_600, "cost": "0.5"], ["time": today + 9 * 3_600, "cost": "1.5"]]],
            ]]],
        ]]]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private var august: UsageBucket {
        UsageBucket(start: Date(timeIntervalSince1970: TimeInterval(midnight(1))).addingTimeInterval(-31 * 86_400), costs: [Money(currency: "CNY", amount: 50)])
    }

    private func console() throws -> UsageSnapshot {
        try DeepSeekProvider.parseConsole(
            summary: summary, keys: keys, cost: cost(), amount: amount(), hourly: hourly(), months: [august],
            range: .init(now: now, calendar: calendar))
    }

    func testTheConsoleReadsBothWalletsWithTheGiftSeparate() throws {
        let sheet = try XCTUnwrap(try console().balance)
        XCTAssertEqual(sheet.balances, [
            AccountBalance(currency: "USD", total: 12.33, paid: 12.33),
            AccountBalance(currency: "CNY", total: 107.39, paid: 100, granted: 7.39),
        ])
    }

    func testAllOfItIsTheConsolesLifetimeTotalNotThisMonth() throws {
        let sheet = try XCTUnwrap(try console().balance)
        XCTAssertEqual(sheet.usage[.all]?.costs, [Money(currency: "USD", amount: 7.66), Money(currency: "CNY", amount: 592.67)])
        XCTAssertEqual(sheet.chart[.all]?.map(\.costTotal), [50])
    }

    func testTheAccountIsToldOverTodaySevenAndThirtyDays() throws {
        let sheet = try XCTUnwrap(try console().balance)
        XCTAssertEqual(sheet.usage[.today]?.costs, [Money(currency: "CNY", amount: 2), Money(currency: "USD", amount: 1)])
        XCTAssertEqual(sheet.usage[.last7]?.costs, [Money(currency: "CNY", amount: 7), Money(currency: "USD", amount: 1)])
        XCTAssertEqual(sheet.usage[.last30]?.costs, [Money(currency: "CNY", amount: 17), Money(currency: "USD", amount: 1)])
        XCTAssertEqual(sheet.usage[.last30]?.requests, 23)
        XCTAssertEqual(sheet.usage[.last30]?.tokens, 2_150)
    }

    func testTheChartsAreHoursForTodayAndDaysForTheWeekAndMonth() throws {
        let sheet = try XCTUnwrap(try console().balance)
        let hours = try XCTUnwrap(sheet.chart[.today])
        XCTAssertEqual(hours.count, 24)
        XCTAssertEqual(hours[9].costTotal, 1.5)
        XCTAssertEqual(hours[3].costTotal, 0.5)
        let days = try XCTUnwrap(sheet.chart[.last30])
        XCTAssertEqual(days.count, 30)
        XCTAssertEqual(days.first?.start, Date(timeIntervalSince1970: TimeInterval(midnight(15))).addingTimeInterval(-29 * 86_400))
        XCTAssertEqual(days[15].costTotal, 10, "1 September")
        XCTAssertEqual(days[15].requests, 20)
        XCTAssertEqual(sheet.chart[.last7]?.count, 7)
        XCTAssertEqual(sheet.chart[.last7]?.last?.costTotal, 3)
    }

    func testEachKeyIsToldOverThePeriodsAndDayByDay() throws {
        let sheet = try XCTUnwrap(try console().balance)
        let editor = try XCTUnwrap(sheet.keys?.first { $0.id == "t-editor" })
        XCTAssertEqual(editor.maskedKey, "sk-aaaa****1111")
        XCTAssertEqual(editor.usage[.today]?.costs, [Money(currency: "CNY", amount: 2)])
        XCTAssertEqual(editor.usage[.last7]?.costs, [Money(currency: "CNY", amount: 7)])
        XCTAssertEqual(editor.usage[.last30]?.costs, [Money(currency: "CNY", amount: 17)])
        XCTAssertEqual(editor.usage[.last30]?.requests, 23)
        XCTAssertEqual(editor.usage[.today]?.tokens, 150)
        XCTAssertNil(editor.usage[.all], "the console has no per-key lifetime total")
        XCTAssertEqual(editor.daily.count, 30)
        XCTAssertEqual(editor.daily[15].costs, [Money(currency: "CNY", amount: 10)])
        XCTAssertTrue(try XCTUnwrap(sheet.keys?.first { $0.id == "t-idle" }).daily.isEmpty)
    }

    func testModelsAreToldPerPeriodBusiestFirst() throws {
        let sheet = try XCTUnwrap(try console().balance)
        let month = try XCTUnwrap(sheet.usage[.last30]?.models)
        XCTAssertEqual(month.map(\.model), ["deepseek-chat", "deepseek-v4-pro", "deepseek-chat & deepseek-reasoner"])
        XCTAssertEqual(month.first?.costs, [Money(currency: "CNY", amount: 15), Money(currency: "USD", amount: 1)])
        // Requests and tokens are reported under the combined model name.
        XCTAssertEqual(month.last?.requests, 23)
        XCTAssertEqual(sheet.usage[.today]?.models.first?.model, "deepseek-v4-pro")
    }

    func testAnIdleKeyIsListedButNotActiveAndADeletedOneOnlyWhileItHasHistory() throws {
        let sheet = try XCTUnwrap(try console().balance)
        XCTAssertEqual(sheet.keys?.map(\.id), ["t-editor", "t-idle", "t-gone"])
        XCTAssertEqual(sheet.keys?.last?.isDisabled, true)
        XCTAssertEqual(sheet.activeKeys(in: .last30).map(\.id), ["t-editor", "t-gone"])
        XCTAssertEqual(sheet.activeKeys(in: .today).map(\.id), ["t-editor", "t-gone"])
    }

    func testAMonthReadAddsUpEveryModelAndTokenType() throws {
        let data = json(#"{"code":0,"msg":"","data":{"biz_code":0,"biz_msg":"","biz_data":[{"currency":"CNY","total":[{"model":"deepseek-chat","usage":[{"type":"PROMPT_TOKEN","amount":"0"},{"type":"PROMPT_CACHE_MISS_TOKEN","amount":"16.37"},{"type":"RESPONSE_TOKEN","amount":"19.49"}]},{"model":"deepseek-v4-pro","usage":[{"type":"PROMPT_CACHE_HIT_TOKEN","amount":"0.88"}]}],"days":[]},{"currency":"USD","total":[],"days":[]}]}}"#)
        let start = Date(timeIntervalSince1970: TimeInterval(midnight(1)))
        let bucket = try XCTUnwrap(DeepSeekProvider.monthBucket(data, start: start))
        XCTAssertEqual(bucket.start, start)
        XCTAssertEqual(bucket.costs.count, 1)
        XCTAssertEqual(bucket.costs.first?.currency, "CNY")
        XCTAssertEqual(bucket.costs.first?.amount ?? 0, 36.74, accuracy: 0.001)
    }

    func testTheRecentRangeIsThirtyDaysEndingTonight() {
        let range = DeepSeekProvider.ConsoleRange(now: now, calendar: calendar)
        XCTAssertEqual(range.end.timeIntervalSince(range.start), 30 * 86_400)
        XCTAssertEqual(range.end.timeIntervalSince(range.today), 86_400)
        XCTAssertEqual(range.month, Date(timeIntervalSince1970: TimeInterval(midnight(1))))
    }

    func testAMissingTokenIsUnauthorized() {
        XCTAssertThrowsError(try DeepSeekProvider.parseConsole(
            summary: json(#"{"code":40002,"msg":"Missing Token","data":null}"#), keys: nil, cost: nil, amount: nil,
            range: .init(now: now, calendar: calendar))) { error in
            guard case ProviderError.unauthorized = error else { return XCTFail("\(error)") }
        }
    }

    func testUsageThatDoesNotAnswerLeavesTheBalanceAndSaysSo() throws {
        let sheet = try XCTUnwrap(try DeepSeekProvider.parseConsole(
            summary: summary, keys: keys, cost: nil, amount: nil,
            range: .init(now: now, calendar: calendar)).balance)
        XCTAssertEqual(sheet.balances.count, 2)
        XCTAssertNotNil(sheet.keysNote)
        XCTAssertEqual(sheet.keys?.count, 2)
        XCTAssertNotNil(sheet.usage[.all], "the lifetime total comes with the wallets")
    }

    // MARK: OpenRouter

    func testAProvisioningKeyListsEveryKeyWithoutReadingCredits() throws {
        let snapshot = try OpenRouterProvider.parse(
            credits: nil, key: nil,
            keys: json(#"{"data":[{"hash":"h1","name":"Agent","label":"sk-or-v1-abc...xyz","disabled":false,"usage":40,"usage_daily":1.5,"usage_weekly":6,"usage_monthly":20},{"hash":"h2","name":"Old","label":"sk-or-v1-def...uvw","disabled":true,"usage":3,"usage_daily":0,"usage_weekly":0,"usage_monthly":0}]}"#))
        let sheet = try XCTUnwrap(snapshot.balance)
        XCTAssertTrue(sheet.balances.isEmpty)
        XCTAssertEqual(sheet.keys?.map(\.name), ["Agent", "Old"])
        XCTAssertEqual(sheet.keys?.first?.maskedKey, "sk-or-v1-abc...xyz")
        XCTAssertEqual(sheet.activeKeys(in: .last30).map(\.id), ["h1"])
        XCTAssertEqual(sheet.usage[.last7]?.costs, [Money(currency: "USD", amount: 6)])
        XCTAssertEqual(sheet.usage[.all]?.costs, [Money(currency: "USD", amount: 43)])
        XCTAssertNil(sheet.keysNote)
    }

    func testAnOrdinaryKeyShowsItselfAndTheCreditsAsABalance() throws {
        let snapshot = try OpenRouterProvider.parse(
            credits: json(#"{"data":{"total_credits":50,"total_usage":12.5}}"#),
            key: json(#"{"data":{"label":"sk-or-v1-abc...xyz","usage":12.5,"usage_daily":1.2,"usage_weekly":4,"usage_monthly":12.5}}"#))
        let sheet = try XCTUnwrap(snapshot.balance)
        XCTAssertEqual(sheet.balances, [AccountBalance(currency: "USD", total: 37.5, paid: 50)])
        XCTAssertEqual(sheet.keys?.count, 1)
        XCTAssertEqual(sheet.usage[.today]?.costs, [Money(currency: "USD", amount: 1.2)])
        XCTAssertEqual(sheet.usage[.all]?.costs, [Money(currency: "USD", amount: 12.5)])
        XCTAssertNotNil(sheet.keysNote)
        // The credits window keeps its figure for the ring; the card draws the sheet.
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 25)
        XCTAssertTrue(sheet.representedWindowIDs.contains(snapshot.windows[0].id))
    }

    // MARK: Others and the cache

    func testMoonshotAndMiMoBalancesAreSheets() throws {
        let moonshot = try MoonshotBalanceProvider.parse(json(#"{"code":0,"data":{"available_balance":49.58,"voucher_balance":46.58,"cash_balance":3}}"#), currency: "CNY")
        XCTAssertEqual(moonshot.balance?.balances, [AccountBalance(currency: "CNY", total: 49.58, paid: 3, granted: 46.58)])
        XCTAssertFalse(moonshot.balance?.hasUsage ?? true, "left for the estimate")
        let mimo = try MiMoProvider.parse(
            balance: json(#"{"code":0,"data":{"balance":"88.50","currency":"CNY","cashBalance":"80","giftBalance":"8.5"}}"#),
            detail: nil,
            usage: json(#"{"code":0,"data":{"monthUsage":{"items":[{"used":3000000,"limit":10000000}]}}}"#))
        XCTAssertEqual(mimo.balance?.balances.first?.granted, 8.5)
        // The Token Plan is an allowance with a ceiling and is not represented.
        XCTAssertEqual(mimo.balance?.representedWindowIDs, [mimo.windows.last!.id])
    }

    func testTheSheetSurvivesTheSnapshotCache() throws {
        let snapshot = try console()
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.balance, snapshot.balance)
        let text = String(decoding: try JSONEncoder().encode(snapshot.balance), as: UTF8.self)
        XCTAssertTrue(text.contains(#""last30""#), "periods encode as object keys")
    }

    // MARK: Usage from the balance

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    func testFallsAreSpendAndRisesAreTopUps() {
        let readings = [
            BalanceReading(date: at(13, 10), totals: ["CNY": 100]),
            BalanceReading(date: at(14, 12), totals: ["CNY": 90]),
            BalanceReading(date: at(15, 9), totals: ["CNY": 120]),
            BalanceReading(date: at(15, 9, 30), totals: ["CNY": 115]),
        ]
        XCTAssertEqual(BalanceEstimate.entries(readings).map(\.cost), [10, 5])
        var sheet = BalanceSheet(balances: [AccountBalance(currency: "CNY", total: 115)])
        BalanceEstimate.apply(to: &sheet, readings: readings, now: now, calendar: calendar)
        XCTAssertTrue(sheet.estimated)
        XCTAssertEqual(sheet.estimatedSince, at(13, 10))
        XCTAssertEqual(sheet.usage[.today]?.costs, [Money(currency: "CNY", amount: 5)])
        XCTAssertEqual(sheet.usage[.last7]?.costs, [Money(currency: "CNY", amount: 15)])
        XCTAssertEqual(sheet.usage[.all]?.costs, [Money(currency: "CNY", amount: 15)])
        XCTAssertEqual(sheet.chart[.last7]?.map(\.costTotal), [0, 0, 0, 0, 0, 10, 5])
        XCTAssertEqual(sheet.chart[.today]?[9].costTotal, 5)
        XCTAssertEqual(sheet.chart[.all]?.count, 1)
    }

    func testAnEstimateNeverReplacesRealUsage() {
        var sheet = BalanceSheet(balances: [AccountBalance(currency: "CNY", total: 1)], keys: [])
        BalanceEstimate.apply(to: &sheet, readings: [BalanceReading(date: at(1, 0), totals: ["CNY": 9]), BalanceReading(date: at(2, 0), totals: ["CNY": 1])], now: now, calendar: calendar)
        XCTAssertFalse(sheet.estimated)
        XCTAssertTrue(sheet.usage.isEmpty)
    }

    func testTheHistoryKeepsAReadingOnlyWhenTheBalanceMoved() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("balance-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = BalanceHistoryStore(fileURL: url)
        store.record(.deepseek, balances: [AccountBalance(currency: "CNY", total: 10)], at: at(1, 0))
        store.record(.deepseek, balances: [AccountBalance(currency: "CNY", total: 10)], at: at(1, 1))
        store.record(.deepseek, balances: [AccountBalance(currency: "CNY", total: 9)], at: at(1, 2))
        XCTAssertEqual(store.readings(for: .deepseek).map(\.date), [at(1, 0), at(1, 2)])
        XCTAssertEqual(BalanceHistoryStore(fileURL: url).readings(for: .deepseek).count, 2, "written to disk")
    }

    // MARK: Low balance

    private let rates: (String) -> Double? = { ["USD": 1, "CNY": 7][$0] }

    func testAnAccountBelowItsFloorSpeaksOncePerDip() {
        let low = BalanceSheet(balances: [AccountBalance(currency: "CNY", total: 14)])
        let floor = BalanceFloor(amount: 20, currency: "CNY")
        let first = LowBalanceCheck.evaluate(sheets: [.deepseek: low], floor: floor, rate: rates, notified: [])
        XCTAssertEqual(first.alerts.map(\.provider), [.deepseek])
        XCTAssertEqual(first.alerts.first?.left, 14)
        let again = LowBalanceCheck.evaluate(sheets: [.deepseek: low], floor: floor, rate: rates, notified: first.low)
        XCTAssertTrue(again.alerts.isEmpty)
        XCTAssertEqual(again.low, ["deepseek"])
        let toppedUp = LowBalanceCheck.evaluate(
            sheets: [.deepseek: BalanceSheet(balances: [AccountBalance(currency: "CNY", total: 200)])],
            floor: floor, rate: rates, notified: again.low)
        XCTAssertTrue(toppedUp.low.isEmpty, "a top-up clears it, so the next dip speaks again")
    }

    func testCurrenciesAreAddedUpInTheFloorsCurrency() {
        // ¥7 + $2 = ¥21, above a ¥20 floor; without a CNY rate only the ¥7 counts.
        let sheet = BalanceSheet(balances: [AccountBalance(currency: "CNY", total: 7), AccountBalance(currency: "USD", total: 2)])
        let floor = BalanceFloor(amount: 20, currency: "CNY")
        XCTAssertTrue(LowBalanceCheck.evaluate(sheets: [.deepseek: sheet], floor: floor, rate: rates, notified: []).alerts.isEmpty)
        let noRate = LowBalanceCheck.evaluate(sheets: [.deepseek: sheet], floor: floor, rate: { $0 == "USD" ? 1 : nil }, notified: [])
        XCTAssertEqual(noRate.alerts.first?.left, 7)
    }

    func testAnAccountThatCannotPaySpeaksEvenAboveTheFloorAndNothingWithoutOne() {
        let sheet = BalanceSheet(balances: [AccountBalance(currency: "USD", total: 50)], canCallAPI: false)
        XCTAssertEqual(LowBalanceCheck.evaluate(sheets: [.moonshot: sheet], floor: BalanceFloor(amount: 1), rate: rates, notified: []).alerts.first?.cannotPay, true)
        XCTAssertTrue(LowBalanceCheck.evaluate(sheets: [.moonshot: sheet], floor: BalanceFloor(), rate: rates, notified: []).alerts.isEmpty)
    }

    func testCompactBalance() {
        XCTAssertEqual(QuotaFormat.amountCompact(107.39, code: "CNY"), "¥107")
        XCTAssertEqual(QuotaFormat.amountCompact(12_345, code: "USD"), "$12.3K")
    }
}
