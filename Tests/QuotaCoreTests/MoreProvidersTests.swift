import XCTest
@testable import QuotaCore

/// Payload shapes after CodexBar's recorded responses for the same services,
/// and, for Copilot, the live endpoint's reply on the owner's account.
final class MoreProvidersTests: XCTestCase {
    private func json(_ text: String) -> Data { Data(text.utf8) }

    func testAlibabaCodingPlanWindowsFromTheNestedGateway() throws {
        let inner = #"{"codingPlanInstanceInfos":[{"planName":"Pro","codingPlanQuotaInfo":{"per5HourUsedQuota":120,"per5HourTotalQuota":1200,"per5HourQuotaNextRefreshTime":1800000000000,"perWeekUsedQuota":900,"perWeekTotalQuota":9000,"perBillMonthUsedQuota":9000,"perBillMonthTotalQuota":90000}}]}"#
        let body = try JSONSerialization.data(withJSONObject: ["data": ["successResponse": inner]])
        let snapshot = try AlibabaCodingPlanProvider.parse(body)
        XCTAssertEqual(snapshot.planName, "Pro")
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [10, 10, 10])
        XCTAssertEqual(snapshot.windows.first?.resetsAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(snapshot.windows.map(\.windowSeconds), [18_000, 604_800, 2_592_000])
    }

    func testAlibabaAskingToLogInIsUnauthorized() {
        XCTAssertThrowsError(try AlibabaCodingPlanProvider.parse(json(#"{"code":"ConsoleNeedLogin","message":"need login"}"#))) { error in
            guard case ProviderError.unauthorized = error else { return XCTFail("\(error)") }
        }
    }

    func testArkcliPlanPeriods() throws {
        let data = json(#"{"viewer":{"auth_method":"sso"},"items":[{"product":"coding-plan","subscribed":true,"periods":[{"label":"five_hour","percent":25,"reset_at":"2026-09-13T10:00:00Z"},{"label":"weekly","percent":40}]},{"product":"agent-plan","subscribed":false,"periods":[]}]}"#)
        let snapshot = try VolcengineArkProvider.parse(data)
        XCTAssertEqual(snapshot.planName, "Coding Plan")
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [25, 40])
        XCTAssertEqual(snapshot.windows.map(\.windowSeconds), [18_000, 604_800])
        XCTAssertNotNil(snapshot.windows.first?.resetsAt)
    }

    func testArkcliWithoutASessionIsUnauthorized() {
        XCTAssertThrowsError(try VolcengineArkProvider.parse(json(#"{"viewer":{"auth_method":"none"},"items":[]}"#)))
    }

    func testMoonshotBalance() throws {
        let snapshot = try MoonshotBalanceProvider.parse(json(#"{"code":0,"data":{"available_balance":49.58,"voucher_balance":46.58,"cash_balance":3},"scode":"0x0","status":true}"#), currency: "CNY")
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertTrue(snapshot.windows[0].detail?.contains("49.58") == true)
        XCTAssertNil(snapshot.windows[0].usedPercent)
    }

    /// The documented reply of GET api.deepseek.com/user/balance (issue #1).
    func testDeepSeekBalanceIsReadSnakeCased() throws {
        let snapshot = try DeepSeekProvider.parse(json(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"}]}"#))
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertNil(snapshot.windows[0].usedPercent)
        XCTAssertTrue(snapshot.windows[0].detail?.contains("110.00") == true)
        XCTAssertTrue(snapshot.windows[0].detail?.contains("10.00") == true)
    }

    func testDeepSeekTwoCurrenciesGetTheirOwnWindows() throws {
        let snapshot = try DeepSeekProvider.parse(json(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"5.00","granted_balance":"0.00","topped_up_balance":"5.00"},{"currency":"USD","total_balance":"2.50","granted_balance":"0.00","topped_up_balance":"2.50"}]}"#))
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(Set(snapshot.windows.map(\.id)).count, 2)
        XCTAssertTrue(snapshot.windows[1].detail?.contains("$2.50") == true)
    }

    func testDeepSeekEmptyAccountShowsZero() throws {
        let snapshot = try DeepSeekProvider.parse(json(#"{"is_available":false,"balance_infos":[]}"#))
        XCTAssertEqual(snapshot.windows.count, 1)
    }

    func testDeepSeekUnrelatedReplyIsABadResponse() {
        XCTAssertThrowsError(try DeepSeekProvider.parse(json(#"{"error":{"message":"nope"}}"#)))
    }

    func testCopilotPremiumAndChat() throws {
        let data = json(#"{"login":"octo","copilot_plan":"individual","access_type_sku":"monthly_subscriber","quota_reset_date":"2026-10-01","quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":210,"percent_remaining":70,"unlimited":false},"chat":{"entitlement":0,"remaining":0,"percent_remaining":100,"unlimited":true}}}"#)
        let snapshot = try CopilotProvider.parse(data)
        XCTAssertEqual(snapshot.planName, "Individual")
        XCTAssertEqual(snapshot.account, "octo")
        XCTAssertEqual(snapshot.windows.count, 1, "unlimited chat is not a window")
        XCTAssertEqual(snapshot.windows[0].usedPercent ?? 0, 30, accuracy: 0.001)
        XCTAssertNotNil(snapshot.windows[0].resetsAt)
    }

    /// What the endpoint answered on the owner's lapsed subscription.
    func testCopilotEndedSubscription() throws {
        let snapshot = try CopilotProvider.parse(json(#"{"login":"gentpan","copilot_plan":"individual","access_type_sku":"subscription_ended","chat_enabled":false}"#))
        XCTAssertEqual(snapshot.windows.first?.detail, L10n.t("Subscription ended", "订阅已结束"))
    }

    func testCopilotFreePlan() throws {
        let snapshot = try CopilotProvider.parse(json(#"{"copilot_plan":"free","limited_user_quotas":{"chat":40,"completions":1500},"monthly_quotas":{"chat":50,"completions":2000},"limited_user_reset_date":"2026-10-01"}"#))
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [20, 25])
    }

    func testOpenRouterCreditsAndKey() throws {
        let snapshot = try OpenRouterProvider.parse(
            credits: json(#"{"data":{"total_credits":50,"total_usage":12.5}}"#),
            key: json(#"{"data":{"limit":20,"limit_remaining":15,"usage_daily":1.2,"usage_weekly":4,"usage_monthly":12.5}}"#))
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [25, 25, nil])
        XCTAssertTrue(snapshot.windows[2].detail?.contains("$1.20") == true)
    }

    func testMiMoBalanceAndPlan() throws {
        let snapshot = try MiMoProvider.parse(
            balance: json(#"{"code":0,"data":{"balance":"88.50","currency":"CNY","cashBalance":"80","giftBalance":"8.5"}}"#),
            detail: json(#"{"code":0,"data":{"planCode":"Pro","currentPeriodEnd":"2026-10-01 00:00:00","expired":false}}"#),
            usage: json(#"{"code":0,"data":{"monthUsage":{"percent":0.3,"items":[{"name":"tokens","used":3000000,"limit":10000000,"percent":0.3}]}}}"#))
        XCTAssertEqual(snapshot.planName, "Pro")
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 30)
        XCTAssertTrue(snapshot.windows.last?.detail?.contains("88.50") == true)
    }

    func testMiMoExpiredSessionIsUnauthorized() {
        XCTAssertThrowsError(try MiMoProvider.parse(balance: json(#"{"code":401,"message":"login"}"#), detail: nil, usage: nil))
    }

    func testQoderCredits() throws {
        let snapshot = try QoderProvider.parse(json(#"{"totalQuota":{"quotaSummary":{"usedValue":300,"limitValue":1000,"usagePercentage":30}},"nextResetAt":1800000000}"#))
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 30)
        XCTAssertEqual(snapshot.windows.first?.resetsAt, Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testWindsurfCachedPlan() throws {
        let snapshot = try WindsurfProvider.parse(json(#"{"planName":"Pro","endTimestamp":1800000000000,"usage":{"messages":500,"usedMessages":125},"quotaUsage":{"dailyRemainingPercent":80,"weeklyRemainingPercent":55,"weeklyResetAtUnix":1800000000}}"#))
        XCTAssertEqual(snapshot.planName, "Pro")
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [20, 45, 25])
    }

    func testKiroCredits() throws {
        let snapshot = try KiroProvider.parse(json(#"{"usageBreakdownList":[{"resourceType":"AGENTIC_REQUEST","currentUsageWithPrecision":1,"usageLimitWithPrecision":2},{"resourceType":"CREDIT","currentUsageWithPrecision":250.5,"usageLimitWithPrecision":1000,"nextDateReset":1800000000}]}"#))
        XCTAssertEqual(snapshot.windows.first?.usedPercent ?? 0, 25.05, accuracy: 0.001)
        XCTAssertEqual(snapshot.windows.first?.resetsAt, Date(timeIntervalSince1970: 1_800_000_000))
    }
}
