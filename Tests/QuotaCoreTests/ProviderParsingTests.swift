import XCTest
@testable import QuotaCore

/// Fixtures are real responses recorded from the providers, with account
/// identifiers replaced. They exist to pin the parsers to the shapes the
/// services actually return rather than to the shapes we assumed.
final class CodexParsingTests: XCTestCase {
    /// A Pro account: one 7-day primary window, no secondary, plus a separate
    /// per-model limit and a credits block.
    private let proResponse = """
    {
      "user_id": "user-TEST",
      "account_id": "00000000-0000-0000-0000-000000000000",
      "email": "dev@example.com",
      "plan_type": "pro",
      "rate_limit": {
        "allowed": true,
        "limit_reached": false,
        "primary_window": {
          "used_percent": 35,
          "limit_window_seconds": 604800,
          "reset_after_seconds": 524721,
          "reset_at": 1788285767
        },
        "secondary_window": null
      },
      "additional_rate_limits": [
        {
          "limit_name": "GPT-5.3-Codex-Spark",
          "metered_feature": "codex_bengalfox",
          "rate_limit": {
            "primary_window": {
              "used_percent": 4,
              "limit_window_seconds": 18000,
              "reset_after_seconds": 18000,
              "reset_at": 1787779046
            },
            "secondary_window": {
              "used_percent": 9,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 604800,
              "reset_at": 1788365846
            }
          }
        }
      ],
      "credits": {
        "has_credits": false,
        "unlimited": false,
        "overage_limit_reached": false,
        "balance": "0"
      },
      "spend_control": {"reached": false, "individual_limit": null}
    }
    """

    func testPrimaryWindowIsLabelledFromItsActualLength() throws {
        let snapshot = try CodexProvider.parse(Data(proResponse.utf8))

        // Regression: this window used to be hardcoded as "5-hour window"
        // even though the account reports a 604800s (weekly) window.
        let primary = try XCTUnwrap(snapshot.windows.first)
        XCTAssertEqual(primary.title, WindowTitle.forSeconds(604_800))
        XCTAssertEqual(primary.usedPercent, 35)
        XCTAssertTrue(primary.isActive)
        XCTAssertEqual(primary.resetsAt, Date(timeIntervalSince1970: 1_788_285_767))
    }

    func testAdditionalRateLimitsAreSurfaced() throws {
        let snapshot = try CodexProvider.parse(Data(proResponse.utf8))
        let titles = snapshot.windows.map(\.title)

        XCTAssertTrue(titles.contains { $0.hasPrefix("GPT-5.3-Codex-Spark") },
                      "per-model limits should not be dropped, got \(titles)")
        let spark = snapshot.windows.filter { $0.title.hasPrefix("GPT-5.3-Codex-Spark") }
        XCTAssertEqual(spark.count, 2, "both the 5-hour and weekly Spark windows")
        XCTAssertEqual(spark.map(\.usedPercent), [4, 9])
    }

    func testAccountPrefersEmailOverUUID() throws {
        let snapshot = try CodexProvider.parse(Data(proResponse.utf8))
        XCTAssertEqual(snapshot.account, "dev@example.com")
        XCTAssertEqual(snapshot.planName, "Pro 20x", "plan_type pro is the 20x plan")
    }

    /// The endpoint names the Pro tiers by internal id; the chip should say
    /// which one the account is on.
    func testCodexPlanIdsBecomeTheirTiers() {
        XCTAssertEqual(CodexProvider.planName("prolite"), "Pro 5x")
        XCTAssertEqual(CodexProvider.planName("pro"), "Pro 20x")
        XCTAssertEqual(CodexProvider.planName("PRO"), "Pro 20x")
        XCTAssertEqual(CodexProvider.planName("self_serve_business_prolite"), "Business Premium")
        XCTAssertEqual(CodexProvider.planName("plus"), "Plus")
        XCTAssertEqual(CodexProvider.planName("enterprise_edu"), "Enterprise Edu")
        XCTAssertNil(CodexProvider.planName("  "))
        XCTAssertNil(CodexProvider.planName(nil))
    }

    func testZeroBalanceWithoutCreditsIsHidden() throws {
        let snapshot = try CodexProvider.parse(Data(proResponse.utf8))
        XCTAssertFalse(snapshot.windows.contains { $0.title == L10n.t("Credits", "额度点数") })
    }

    func testCreditBalanceIsShownWhenPresent() throws {
        let response = """
        {"plan_type":"plus","rate_limit":null,
         "credits":{"has_credits":true,"unlimited":false,"balance":"$12.40"}}
        """
        let snapshot = try CodexProvider.parse(Data(response.utf8))
        let credits = try XCTUnwrap(snapshot.windows.first { $0.title == L10n.t("Credits", "额度点数") })
        XCTAssertEqual(credits.detail, "$12.40")
    }

    func testHeadlineIsTheHighestWindow() throws {
        let snapshot = try CodexProvider.parse(Data(proResponse.utf8))
        XCTAssertEqual(snapshot.headlinePercent, 35)
    }

    func testWindowIDsStayUniqueAcrossRepeatedTitles() throws {
        let snapshot = try CodexProvider.parse(Data(proResponse.utf8))
        let ids = snapshot.windows.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate ids break ForEach rendering")
    }

    func testGarbageResponseIsRejected() {
        XCTAssertThrowsError(try CodexProvider.parse(Data("not json".utf8)))
    }
}

final class ClaudeParsingTests: XCTestCase {
    /// Real shape: `limits` carries per-model weekly caps that the legacy
    /// `five_hour` / `seven_day` fields do not express.
    private let response = """
    {
      "five_hour": {"utilization": 13.0, "resets_at": "2026-08-26T18:09:59.565722+00:00",
                    "limit_dollars": null, "used_dollars": null},
      "seven_day": {"utilization": 12.0, "resets_at": "2026-08-30T20:59:59.565738+00:00",
                    "limit_dollars": null, "used_dollars": null},
      "seven_day_opus": null,
      "extra_usage": {"is_enabled": false, "monthly_limit": null, "used_credits": null,
                      "utilization": null, "spend_limit_reached": false},
      "limits": [
        {"kind": "session", "group": "session", "percent": 13, "severity": "normal",
         "resets_at": "2026-08-26T18:09:59.565722+00:00", "scope": null, "is_active": true},
        {"kind": "weekly_all", "group": "weekly", "percent": 12, "severity": "normal",
         "resets_at": "2026-08-30T20:59:59.565738+00:00", "scope": null, "is_active": false},
        {"kind": "weekly_scoped", "group": "weekly", "percent": 10, "severity": "normal",
         "resets_at": "2026-08-30T20:59:59.565928+00:00",
         "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null},
         "is_active": false}
      ]
    }
    """

    func testAllThreeLimitsAreParsed() throws {
        let snapshot = try ClaudeProvider.parse(Data(response.utf8))

        // Regression: only five_hour and seven_day used to be read, silently
        // dropping the per-model weekly cap.
        XCTAssertEqual(snapshot.windows.count, 3)
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [13, 12, 10])
    }

    func testScopedWeeklyWindowNamesItsModel() throws {
        let snapshot = try ClaudeProvider.parse(Data(response.utf8))
        let scoped = try XCTUnwrap(snapshot.windows.last)
        XCTAssertTrue(scoped.title.contains("Fable"), "got \(scoped.title)")
    }

    func testActiveWindowIsMarked() throws {
        let snapshot = try ClaudeProvider.parse(Data(response.utf8))
        XCTAssertEqual(snapshot.windows.filter(\.isActive).count, 1)
        XCTAssertTrue(snapshot.windows[0].isActive)
    }

    func testResetTimestampsAreParsed() throws {
        let snapshot = try ClaudeProvider.parse(Data(response.utf8))
        XCTAssertNotNil(snapshot.windows[0].resetsAt)
        XCTAssertEqual(
            snapshot.windows[0].resetsAt,
            Dates.parseISO("2026-08-26T18:09:59.565722+00:00"))
    }

    func testFallsBackToLegacyFieldsWhenLimitsIsAbsent() throws {
        let legacy = """
        {"five_hour": {"utilization": 42.0, "resets_at": "2026-08-26T18:09:59Z",
                       "limit_dollars": 20.0, "used_dollars": 8.4},
         "seven_day": {"utilization": 7.0, "resets_at": "2026-08-30T20:59:59Z"}}
        """
        let snapshot = try ClaudeProvider.parse(Data(legacy.utf8))

        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows[0].usedPercent, 42)
        XCTAssertEqual(snapshot.windows[0].detail, "$8.40 / $20.00")
    }

    func testExtraUsageAppearsOnlyWhenEnabled() throws {
        let disabled = try ClaudeProvider.parse(Data(response.utf8))
        XCTAssertFalse(disabled.windows.contains { $0.title == L10n.t("Extra usage", "额外用量") })

        let enabled = """
        {"limits": [{"kind":"session","percent":5,"resets_at":null,"is_active":true}],
         "extra_usage": {"is_enabled": true, "monthly_limit": 50.0, "used_credits": 12.5,
                         "utilization": 25.0, "spend_limit_reached": false}}
        """
        let snapshot = try ClaudeProvider.parse(Data(enabled.utf8))
        let extra = try XCTUnwrap(snapshot.windows.first { $0.title == L10n.t("Extra usage", "额外用量") })
        XCTAssertEqual(extra.usedPercent, 25)
        XCTAssertEqual(extra.detail, "$12.50 / $50.00")
    }

    func testEmptyResponseIsRejected() {
        XCTAssertThrowsError(try ClaudeProvider.parse(Data("{}".utf8))) { error in
            XCTAssertEqual(error as? ProviderError, .badResponse)
        }
    }
}

extension ProviderError: @retroactive Equatable {
    public static func == (lhs: ProviderError, rhs: ProviderError) -> Bool {
        lhs.errorDescription == rhs.errorDescription
    }
}

// MARK: - Local credential readers

final class CursorSessionTests: XCTestCase {
    /// A JWT with `sub: "user_ABC"` and `aud: "https://cursor.com"`. Signature
    /// is a placeholder — the reader never verifies it, it only decodes the
    /// user's own already-trusted token.
    private func jwt(sub: String) -> String {
        func b64(_ json: String) -> String {
            Data(json.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = b64(#"{"alg":"HS256","typ":"JWT"}"#)
        let payload = b64("{\"sub\":\"\(sub)\",\"aud\":\"https://cursor.com\",\"type\":\"session\"}")
        return "\(header).\(payload).c2ln"
    }

    func testComposesTheSessionCookieAsSubColonColonToken() throws {
        let token = jwt(sub: "user_01ABC")
        let session = try XCTUnwrap(
            LocalCredentials.makeCursorSession(accessToken: token, email: "dev@example.com"))

        // cursor.com rejects the bare JWT; it wants "sub::JWT".
        XCTAssertEqual(session.sessionCookie, "user_01ABC::\(token)")
        XCTAssertEqual(session.email, "dev@example.com")
    }

    func testBlankEmailBecomesNil() throws {
        let session = try XCTUnwrap(
            LocalCredentials.makeCursorSession(accessToken: jwt(sub: "u1"), email: "  "))
        XCTAssertNil(session.email)
    }

    func testATokenWithoutASubIsRejected() {
        // A JWT whose payload has no `sub` cannot form the cookie.
        let noSub = "\(Data(#"{"alg":"HS256"}"#.utf8).base64EncodedString())."
            + "\(Data(#"{"aud":"x"}"#.utf8).base64EncodedString()).sig"
        XCTAssertNil(LocalCredentials.makeCursorSession(accessToken: noSub, email: nil))
    }

    func testGarbageTokenIsRejected() {
        XCTAssertNil(LocalCredentials.makeCursorSession(accessToken: "not-a-jwt", email: nil))
        XCTAssertNil(LocalCredentials.makeCursorSession(accessToken: "", email: nil))
    }

    func testJWTClaimDecoding() {
        let token = jwt(sub: "user_XYZ")
        XCTAssertEqual(LocalCredentials.jwtClaim(token, "sub"), "user_XYZ")
        XCTAssertEqual(LocalCredentials.jwtClaim(token, "aud"), "https://cursor.com")
        XCTAssertNil(LocalCredentials.jwtClaim(token, "missing"))
    }
}

final class OpenCodeKeyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-oc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The reader walks a fixed pair of home-relative paths, so this test
    /// exercises the parse shape rather than the real location.
    private func parse(_ json: String, slug: String) throws -> String? {
        let url = root.appendingPathComponent("auth.json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = obj[slug] as? [String: Any] else { return nil }
        return entry["key"] as? String
    }

    func testReadsTheKeyForAProviderSlug() throws {
        let json = """
        {"opencode-go":{"type":"api","key":"sk-test-123"},
         "kimi-for-coding":{"type":"api","key":"other"}}
        """
        XCTAssertEqual(try parse(json, slug: "opencode-go"), "sk-test-123")
    }

    func testMissingSlugYieldsNoKey() throws {
        XCTAssertNil(try parse(#"{"other":{"key":"x"}}"#, slug: "opencode-go"))
    }
}

final class OpenCodeGoParsingTests: XCTestCase {
    /// The real response shape, recorded live: windows nested under `usage`,
    /// resets as ISO timestamps.
    private let response = """
    {"usage":{
      "rolling":{"status":"ok","percent":0,"resetsAt":"2026-08-27T02:10:27.918Z"},
      "weekly":{"status":"ok","percent":0,"resetsAt":"2026-08-31T00:00:00.918Z"},
      "monthly":{"status":"ok","percent":84,"resetsAt":"2026-08-31T20:52:39.918Z"}}}
    """

    func testParsesNestedUsageWindows() throws {
        let snapshot = try OpenCodeGoProvider.parse(Data(response.utf8))

        // Regression: the parser looked at the root, not under `usage`, and
        // returned nothing on the live shape.
        XCTAssertEqual(snapshot.windows.count, 3)
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [0, 0, 84])
        XCTAssertEqual(snapshot.headlinePercent, 84)
    }

    func testParsesISOResetTimestamps() throws {
        let snapshot = try OpenCodeGoProvider.parse(Data(response.utf8))
        XCTAssertEqual(snapshot.windows[2].resetsAt, Dates.parseISO("2026-08-31T20:52:39.918Z"))
    }

    func testZeroPercentIsAValueNotAbsence() throws {
        // A window at 0% must still render — it means "nothing used yet",
        // which is different from "no data".
        let snapshot = try OpenCodeGoProvider.parse(Data(response.utf8))
        XCTAssertEqual(snapshot.windows[0].usedPercent, 0)
    }

    func testStillReadsAFlatRootShape() throws {
        // Defensive: an older/flatter response without the `usage` wrapper.
        let flat = """
        {"rolling":{"percent":12},"weekly":{"percent":34},"monthly":{"percent":56}}
        """
        let snapshot = try OpenCodeGoProvider.parse(Data(flat.utf8))
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [12, 34, 56])
    }

    func testEmptyResponseThrows() {
        XCTAssertThrowsError(try OpenCodeGoProvider.parse(Data("{}".utf8)))
    }
}

final class CodexResetCreditsTests: XCTestCase {
    /// Recorded live: one reset credit held, none applicable right now.
    private let response = """
    {"plan_type":"pro","email":"dev@example.com",
     "rate_limit":{"primary_window":{"used_percent":0,"limit_window_seconds":604800,
                                     "reset_at":1788453173}},
     "additional_rate_limits":[{"limit_name":"GPT-5.3-Codex-Spark",
       "rate_limit":{"primary_window":{"used_percent":0,"limit_window_seconds":18000}}}],
     "rate_limit_reset_credits":{"available_count":1,"applicable_available_count":0}}
    """

    func testParsesResetCredits() throws {
        let snapshot = try CodexProvider.parse(Data(response.utf8))
        let credits = try XCTUnwrap(snapshot.resetCredits)

        XCTAssertEqual(credits.available, 1)
        XCTAssertEqual(credits.applicable, 0)
    }

    func testZeroCreditsAreKeptButNotShown() throws {
        let none = """
        {"plan_type":"pro","rate_limit":null,
         "rate_limit_reset_credits":{"available_count":0,"applicable_available_count":0}}
        """
        // Nothing to spend and no history of being given any: no row. The
        // count is kept so the credit list can still say how many came.
        let credits = try XCTUnwrap(try CodexProvider.parse(Data(none.utf8)).resetCredits)
        XCTAssertEqual(credits.available, 0)
        XCTAssertFalse(credits.isShown)
        XCTAssertTrue(ResetCredits(available: 0, totalEarned: 4).isShown, "given some before, all spent")
    }

    /// wham/rate-limit-reset-credits, in the shape the Codex CLI's own tests
    /// record (issue #3): the available credits, soonest deadline first and
    /// the one that never expires last, and how many came in all.
    func testTheCreditListOfTheCreditsStillAvailable() throws {
        let now = Dates.parseISO("2026-09-15T00:00:00Z")!
        let body = """
        {"credits":[
          {"id":"b","reset_type":"codex_rate_limits","status":"available","granted_at":"2026-09-10T00:00:00Z","expires_at":"2026-10-05T22:00:00Z","title":"Full reset (Weekly + 5 hr)"},
          {"id":"a","reset_type":"codex_rate_limits","status":"available","granted_at":"2026-09-01T00:00:00Z","expires_at":"2026-09-20T18:00:00.000Z","title":" "},
          {"id":"c","reset_type":"codex_rate_limits","status":"available","granted_at":"2026-09-11T00:00:00Z","expires_at":null},
          {"id":"d","reset_type":"codex_rate_limits","status":"redeemed","granted_at":"2026-08-01T00:00:00Z","expires_at":"2026-09-30T00:00:00Z"},
          {"id":"e","reset_type":"codex_rate_limits","status":"available","granted_at":"2026-08-01T00:00:00Z","expires_at":"2026-09-14T00:00:00Z"}],
         "available_count":3,"total_earned_count":5,"immediate_reset_purchase_eligible":false,"history_enabled":true}
        """
        let list = try XCTUnwrap(CodexProvider.resetCreditList(Data(body.utf8), now: now))
        XCTAssertEqual(list.totalEarned, 5)
        XCTAssertEqual(list.credits.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(list.credits.map(\.title), [nil, "Full reset (Weekly + 5 hr)", nil])
        XCTAssertEqual(list.credits.first?.grantedAt, Dates.parseISO("2026-09-01T00:00:00Z"))
        let credits = ResetCredits(available: 3, totalEarned: 5, credits: list.credits)
        XCTAssertEqual(credits.upcomingExpirations(now: now), [Dates.parseISO("2026-09-20T18:00:00Z")!, Dates.parseISO("2026-10-05T22:00:00Z")!])

        // The live reply on an account never given one.
        let empty = try XCTUnwrap(CodexProvider.resetCreditList(Data(#"{"credits":[],"available_count":0,"total_earned_count":0,"immediate_reset_purchase_eligible":false,"history_enabled":true}"#.utf8)))
        XCTAssertEqual(empty, CodexProvider.ResetCreditList(credits: [], totalEarned: 0))
        XCTAssertNil(CodexProvider.resetCreditList(Data("<html>".utf8)))
        XCTAssertNil(CodexProvider.resetCreditList(Data(#"{"detail":"Too many requests"}"#.utf8)))
    }

    /// The list answers 429 when polled, so a refresh reuses the last one
    /// until something says it changed.
    func testTheCreditListIsReadAgainOnlyWhenItMayHaveChanged() {
        let cache = CodexProvider.ResetCreditListCache()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let list = CodexProvider.ResetCreditList(credits: [
            ResetCredit(id: "a", expiresAt: now.addingTimeInterval(86_400)),
            ResetCredit(id: "b", expiresAt: nil),
        ], totalEarned: 2)
        XCTAssertNil(cache.reusable(account: "a", available: 2, now: now), "nothing read yet")
        cache.store(list, account: "a", available: 2, now: now)
        XCTAssertEqual(cache.reusable(account: "a", available: 2, now: now.addingTimeInterval(600)), list)
        XCTAssertNil(cache.reusable(account: "a", available: 3, now: now.addingTimeInterval(600)), "a reset was given")
        XCTAssertNil(cache.reusable(account: "b", available: 2, now: now.addingTimeInterval(600)), "another account")
        XCTAssertNil(cache.reusable(account: "a", available: 2, now: now.addingTimeInterval(3700)), "an hour on")
        cache.store(list, account: "a", available: 2, now: now.addingTimeInterval(80_000))
        XCTAssertNil(cache.reusable(account: "a", available: 2, now: now.addingTimeInterval(86_500)), "the first deadline passed")
    }

    func testTheCreditsSurviveTheSnapshotCache() throws {
        let credit = ResetCredit(id: "a", title: "Full reset (Weekly + 5 hr)", grantedAt: Date(timeIntervalSince1970: 1_799_000_000), expiresAt: Date(timeIntervalSince1970: 1_800_000_000))
        let snapshot = UsageSnapshot(windows: [], resetCredits: ResetCredits(available: 1, totalEarned: 3, credits: [credit]))
        let back = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(back.resetCredits, snapshot.resetCredits)
        let old = try JSONDecoder().decode(ResetCredits.self, from: Data(#"{"available":2,"applicable":0}"#.utf8))
        XCTAssertEqual(old, ResetCredits(available: 2, applicable: 0), "a cache written before the list was read")
    }

    func testTheDeadlineListReadsLikeTheResetRows() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let dates = [
            now.addingTimeInterval(18 * 86_400 + 23 * 3600 + 30),
            now.addingTimeInterval(5 * 86_400 + 18 * 3600 + 30),
            now.addingTimeInterval(-60),
        ]
        L10n.override = .en
        defer { L10n.override = .system }
        XCTAssertEqual(QuotaFormat.expiryList(dates, format: .countdown, now: now), "5d 18h · 18d 23h")
        let many = (1...5).map { now.addingTimeInterval(Double($0) * 86_400 + 30) }
        XCTAssertEqual(QuotaFormat.expiryList(many, format: .countdown, now: now), "1d 0h · 2d 0h · 3d 0h · +2 more")
        XCTAssertEqual(
            QuotaFormat.creditLines([
                ResetCredit(title: "Full reset (Weekly + 5 hr)", expiresAt: now.addingTimeInterval(3 * 3600 + 30)),
                ResetCredit(),
            ], format: .countdown, now: now),
            ["Full reset (Weekly + 5 hr) · expires in 3h 0m", "Full reset · does not expire"])
    }

    func testAbsentFieldIsTolerated() throws {
        let none = #"{"plan_type":"pro","rate_limit":null}"#
        XCTAssertNil(try CodexProvider.parse(Data(none.utf8)).resetCredits)
    }

    func testWindowsCarryTheirLengthAndScope() throws {
        let snapshot = try CodexProvider.parse(Data(response.utf8))

        // Badge comes from the reported length, not from parsing the title.
        XCTAssertEqual(snapshot.windows[0].shortLabel, "7d")
        XCTAssertNil(snapshot.windows[0].scope, "the account-wide window has no scope")

        let spark = try XCTUnwrap(snapshot.windows.first { $0.scope != nil })
        XCTAssertEqual(spark.shortLabel, "5h")
        XCTAssertEqual(spark.scope, "GPT-5.3-Codex-Spark")
    }
}

final class CursorParsingTests: XCTestCase {
    /// Recorded live from an account holding bonus credit — the case that
    /// exposed the bug.
    private let response = """
    {"billingCycleStart":"2026-08-21T20:48:13.000Z",
     "billingCycleEnd":"2026-09-21T20:48:13.000Z",
     "membershipType":"pro_plus","limitType":"user","isUnlimited":false,
     "autoModelSelectedDisplayMessage":"You've used 54% of your included total usage",
     "individualUsage":{
       "plan":{"enabled":true,"used":7000,"limit":7000,"remaining":0,
               "breakdown":{"included":7000,"bonus":64240,"total":71240},
               "autoPercentUsed":51.52416666666667,
               "apiPercentUsed":85.55454545454545,
               "totalPercentUsed":54.38167938931298},
       "onDemand":{"enabled":true,"used":0,"limit":20000,"remaining":20000}}}
    """

    func testUsesCursorsOwnPercentageNotUsedOverLimit() throws {
        let snapshot = try CursorProvider.parse(Data(response.utf8))
        let plan = try XCTUnwrap(snapshot.windows.first)

        // Regression: used/limit is 7000/7000 = 100%, because `limit` counts
        // only the included allowance and ignores 64240 of bonus credit.
        // Cursor's own page says 54%.
        XCTAssertEqual(try XCTUnwrap(plan.usedPercent), 54.38, accuracy: 0.01)
        XCTAssertNotEqual(plan.usedPercent, 100)
    }

    func testMoneyIsSizedAgainstTheRealTotal() throws {
        let snapshot = try CursorProvider.parse(Data(response.utf8))
        let plan = try XCTUnwrap(snapshot.windows.first)

        // 54.38% of $712.40, not "$70.00 / $70.00".
        XCTAssertEqual(plan.detail, "$387.42 / $712.40")
    }

    func testNamedModelUsageGetsItsOwnRow() throws {
        let snapshot = try CursorProvider.parse(Data(response.utf8))

        // 86% against a 54% headline: this is the one about to run out, so it
        // must not be buried.
        let api = try XCTUnwrap(snapshot.windows.first { $0.scope != nil })
        XCTAssertEqual(try XCTUnwrap(api.usedPercent), 85.55, accuracy: 0.01)
        XCTAssertEqual(snapshot.headlinePercent ?? 0, 85.55, accuracy: 0.01)
    }

    func testOnDemandIsUnchanged() throws {
        let snapshot = try CursorProvider.parse(Data(response.utf8))
        let onDemand = try XCTUnwrap(snapshot.windows.first { $0.detail == "$0.00 / $200.00" })
        XCTAssertEqual(onDemand.usedPercent, 0)
    }

    func testPlanMetadata() throws {
        let snapshot = try CursorProvider.parse(Data(response.utf8), account: "dev@example.com")
        XCTAssertEqual(snapshot.planName, "Pro_Plus")
        XCTAssertEqual(snapshot.account, "dev@example.com")
        XCTAssertEqual(snapshot.windows.first?.resetsAt,
                       Dates.parseAny("2026-09-21T20:48:13.000Z"))
    }

    func testFallsBackToUsedOverLimitWhenNoPercentagesArePublished() throws {
        // An older shape, or a plan Cursor reports differently.
        let legacy = """
        {"membershipType":"pro","billingCycleEnd":"2026-09-21T20:48:13.000Z",
         "individualUsage":{"plan":{"used":3500,"limit":7000}}}
        """
        let snapshot = try CursorProvider.parse(Data(legacy.utf8))
        let plan = try XCTUnwrap(snapshot.windows.first)

        XCTAssertEqual(plan.usedPercent, 50)
        XCTAssertEqual(plan.detail, "$35.00 / $70.00")
    }

    func testGarbageIsRejected() {
        XCTAssertThrowsError(try CursorProvider.parse(Data("nope".utf8)))
    }
}
