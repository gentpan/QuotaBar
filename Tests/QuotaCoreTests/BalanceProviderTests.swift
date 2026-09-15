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

    private func console() throws -> UsageSnapshot {
        try DeepSeekProvider.parseConsole(
            summary: summary, keys: keys, cost: cost(), amount: amount(),
            range: .init(now: now, calendar: calendar))
    }

    func testTheConsoleReadsBothWalletsWithTheGiftSeparate() throws {
        let sheet = try XCTUnwrap(try console().balance)
        XCTAssertEqual(sheet.balances, [
            AccountBalance(currency: "USD", total: 12.33, paid: 12.33),
            AccountBalance(currency: "CNY", total: 107.39, paid: 100, granted: 7.39),
        ])
        XCTAssertEqual(sheet.spend[.month], [Money(currency: "USD", amount: 7.66), Money(currency: "CNY", amount: 592.67)])
    }

    func testEachKeyIsToldOverTodayThisWeekAndThisMonth() throws {
        let sheet = try XCTUnwrap(try console().balance)
        let editor = try XCTUnwrap(sheet.keys?.first { $0.id == "t-editor" })
        XCTAssertEqual(editor.maskedKey, "sk-aaaa****1111")
        XCTAssertEqual(editor.usage[.today]?.costs, [Money(currency: "CNY", amount: 2)])
        XCTAssertEqual(editor.usage[.week]?.costs, [Money(currency: "CNY", amount: 7)])
        XCTAssertEqual(editor.usage[.month]?.costs, [Money(currency: "CNY", amount: 17)])
        XCTAssertEqual(editor.usage[.month]?.requests, 23)
        XCTAssertEqual(editor.usage[.today]?.tokens, 150)
        XCTAssertEqual(editor.usage[.month]?.models.map(\.model), ["deepseek-chat", "deepseek-v4-pro", "deepseek-chat & deepseek-reasoner"])
        XCTAssertEqual(sheet.spend[.today], [Money(currency: "CNY", amount: 2), Money(currency: "USD", amount: 1)])
    }

    func testEachKeyIsAlsoToldDayByDayAcrossTheRange() throws {
        let sheet = try XCTUnwrap(try console().balance)
        let editor = try XCTUnwrap(sheet.keys?.first { $0.id == "t-editor" })
        // 1 to 15 September: the month began before this week.
        XCTAssertEqual(editor.daily.count, 15)
        XCTAssertEqual(editor.daily.first?.costs, [Money(currency: "CNY", amount: 10)])
        XCTAssertEqual(editor.daily.first?.requests, 20)
        XCTAssertEqual(editor.daily[1].costTotal, 0)
        XCTAssertEqual(editor.daily.last?.costs, [Money(currency: "CNY", amount: 2)])
        XCTAssertEqual(editor.daily.last?.tokens, 150)
        XCTAssertTrue(try XCTUnwrap(sheet.keys?.first { $0.id == "t-idle" }).daily.isEmpty)
    }

    func testTheWholeAccountIsAlsoToldPerModel() throws {
        let sheet = try XCTUnwrap(try console().balance)
        let month = try XCTUnwrap(sheet.models[.month])
        XCTAssertEqual(month.first?.model, "deepseek-chat")
        XCTAssertEqual(month.first?.costs, [Money(currency: "CNY", amount: 15), Money(currency: "USD", amount: 1)])
        // Requests and tokens are reported under the combined model name.
        let combined = try XCTUnwrap(month.first { $0.model == "deepseek-chat & deepseek-reasoner" })
        XCTAssertEqual(combined.requests, 23)
        XCTAssertEqual(combined.tokens, 2150)
        XCTAssertEqual(sheet.models[.today]?.map(\.model).first, "deepseek-v4-pro")
    }

    func testAnIdleKeyIsListedButNotActiveAndADeletedOneOnlyWhileItHasHistory() throws {
        let sheet = try XCTUnwrap(try console().balance)
        XCTAssertEqual(sheet.keys?.map(\.id), ["t-editor", "t-idle", "t-gone"])
        XCTAssertEqual(sheet.keys?.last?.isDisabled, true)
        XCTAssertEqual(sheet.activeKeys(in: .month).map(\.id), ["t-editor", "t-gone"])
        XCTAssertEqual(sheet.activeKeys(in: .today).map(\.id), ["t-editor", "t-gone"])
    }

    func testTheRangeStartsAtTheEarlierOfTheMonthAndTheWeek() {
        // Tuesday 1 September: the week began on Monday 31 August.
        let range = DeepSeekProvider.ConsoleRange(now: Date(timeIntervalSince1970: 1_788_238_800), calendar: calendar)
        XCTAssertEqual(range.start, range.week)
        XCTAssertLessThan(range.week, range.month)
        XCTAssertEqual(range.end.timeIntervalSince(range.today), 86_400)
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
        XCTAssertEqual(sheet.activeKeys(in: .month).map(\.id), ["h1"])
        XCTAssertEqual(sheet.spend[.week], [Money(currency: "USD", amount: 6)])
        XCTAssertNil(sheet.keysNote)
    }

    func testAnOrdinaryKeyShowsItselfAndTheCreditsAsABalance() throws {
        let snapshot = try OpenRouterProvider.parse(
            credits: json(#"{"data":{"total_credits":50,"total_usage":12.5}}"#),
            key: json(#"{"data":{"label":"sk-or-v1-abc...xyz","usage_daily":1.2,"usage_weekly":4,"usage_monthly":12.5}}"#))
        let sheet = try XCTUnwrap(snapshot.balance)
        XCTAssertEqual(sheet.balances, [AccountBalance(currency: "USD", total: 37.5, paid: 50)])
        XCTAssertEqual(sheet.keys?.count, 1)
        XCTAssertNotNil(sheet.keysNote)
        // The credits window keeps its figure for the ring; the card draws the sheet.
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 25)
        XCTAssertTrue(sheet.representedWindowIDs.contains(snapshot.windows[0].id))
    }

    // MARK: Others and the cache

    func testMoonshotAndMiMoBalancesAreSheets() throws {
        let moonshot = try MoonshotBalanceProvider.parse(json(#"{"code":0,"data":{"available_balance":49.58,"voucher_balance":46.58,"cash_balance":3}}"#), currency: "CNY")
        XCTAssertEqual(moonshot.balance?.balances, [AccountBalance(currency: "CNY", total: 49.58, paid: 3, granted: 46.58)])
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
        XCTAssertTrue(text.contains(#""month""#), "periods encode as object keys")
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
