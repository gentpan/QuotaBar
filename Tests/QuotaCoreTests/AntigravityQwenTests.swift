import XCTest
@testable import QuotaCore

/// Shapes recorded from CodexBar's fixtures for the same endpoints; the
/// live services have not been exercised from here (Antigravity's token on
/// this Mac had expired, Qwen Cloud has no account), so these pin the
/// parsers, not the wire.
final class AntigravityParsingTests: XCTestCase {
    func testAvailableModelsBecomeScopedWindows() throws {
        let data = Data("""
        {"models":{
          "gemini-3-pro":{"displayName":"Gemini 3 Pro","quotaInfo":{"remainingFraction":0.6,"resetTime":"2026-09-13T00:00:00Z"}},
          "claude-sonnet-4-5":{"label":"Claude Sonnet 4.5","quotaInfo":{"remainingFraction":0.1,"resetTime":"2026-09-13T00:00:00Z"}},
          "gemini-2.5-flash":{"displayName":"Gemini 2.5 Flash"}}}
        """.utf8)
        let snapshot = try AntigravityProvider.parse(models: data, plan: "Google AI Pro")
        XCTAssertEqual(snapshot.windows.map(\.title), ["Claude Sonnet 4.5", "Gemini 3 Pro"])
        XCTAssertEqual(snapshot.windows[0].usedPercent!, 90, accuracy: 0.001)
        XCTAssertEqual(snapshot.windows[1].usedPercent!, 40, accuracy: 0.001)
        XCTAssertEqual(snapshot.windows[0].scope, "Claude Sonnet 4.5")
        XCTAssertEqual(snapshot.planName, "Google AI Pro")
        XCTAssertEqual(snapshot.headlinePercent!, 90, accuracy: 0.001)
        XCTAssertNotNil(snapshot.windows[0].resetsAt)
    }

    func testBucketsKeepTheEmptiestPerModel() throws {
        let data = Data("""
        {"buckets":[
          {"modelId":"gemini-2.5-flash","remainingFraction":0.9,"resetTime":"2026-09-13T00:00:00Z"},
          {"modelId":"gemini-2.5-flash","remainingFraction":0.4,"resetTime":"2026-09-13T00:00:00Z"},
          {"modelId":"gemini-2.5-pro","remainingFraction":0.6,"resetTime":"2026-09-13T00:00:00Z"}]}
        """.utf8)
        let snapshot = try AntigravityProvider.parse(buckets: data)
        XCTAssertEqual(snapshot.windows.map(\.title), ["gemini-2.5-flash", "gemini-2.5-pro"])
        XCTAssertEqual(snapshot.windows[0].usedPercent!, 60, accuracy: 0.001)
    }

    func testNoQuotasIsABadResponse() {
        XCTAssertThrowsError(try AntigravityProvider.parse(models: Data(#"{"models":{}}"#.utf8)))
        XCTAssertThrowsError(try AntigravityProvider.parse(buckets: Data("nope".utf8)))
    }

    func testTokenFileShape() {
        let root: [String: Any] = [
            "token": ["access_token": "ya29.x", "expiry": "2026-09-11T01:49:43.809006+05:00", "token_type": "Bearer"],
            "auth_method": "consumer",
        ]
        let token = LocalCredentials.antigravityToken(in: root)
        XCTAssertEqual(token?.accessToken, "ya29.x")
        XCTAssertNotNil(token?.expiry)
        XCTAssertTrue(token!.isExpired(now: Date(timeIntervalSince1970: 1_800_000_000)))
        XCTAssertFalse(token!.isExpired(now: Date(timeIntervalSince1970: 1_700_000_000)))
        XCTAssertNil(LocalCredentials.antigravityToken(in: ["token": ["expiry": "x"]]))
    }

    func testPythonISOFormatIsParsed() {
        XCTAssertNotNil(LocalCredentials.parseFlexibleISO("2026-09-11T01:49:43.809006+05:00"))
        XCTAssertNotNil(LocalCredentials.parseFlexibleISO("2026-09-11T01:49:43Z"))
        XCTAssertNil(LocalCredentials.parseFlexibleISO(""))
    }
}

final class QwenParsingTests: XCTestCase {
    func testEmbeddedJSONUsageBecomesTwoWindows() throws {
        let inner = #"{"code":0,"data":{"per5HourPercentage":0.03,"per5HourResetTime":1700003600000,"per1WeekPercentage":0.01,"per1WeekResetTime":1700086400000},"success":true}"#
        let payload: [String: Any] = ["data": ["DataV2": ["data": inner]]]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let subscription = Data(#"{"data":{"specCode":"standard","status":"VALID"}}"#.utf8)
        let snapshot = try QwenProvider.parse(data, subscription: subscription)
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows[0].usedPercent!, 3, accuracy: 0.001)
        XCTAssertEqual(snapshot.windows[0].windowSeconds, 18_000)
        XCTAssertEqual(snapshot.windows[0].resetsAt, Date(timeIntervalSince1970: 1_700_003_600))
        XCTAssertEqual(snapshot.windows[1].usedPercent!, 1, accuracy: 0.001)
        XCTAssertEqual(snapshot.windows[1].windowSeconds, 604_800)
        XCTAssertEqual(snapshot.planName, "Standard")
    }

    func testFlatShapeAndPointsAreAccepted() throws {
        let data = Data(#"{"data":{"per5HourPercentage":42,"per1WeekPercentage":0.5}}"#.utf8)
        let snapshot = try QwenProvider.parse(data)
        XCTAssertEqual(snapshot.windows[0].usedPercent!, 42, accuracy: 0.001)
        XCTAssertEqual(snapshot.windows[1].usedPercent!, 50, accuracy: 0.001)
        XCTAssertNil(snapshot.planName)
    }

    func testLoginPageIsUnauthorized() {
        XCTAssertThrowsError(try QwenProvider.parse(Data(#"{"code":"NeedLogin","redirect":"https://login"}"#.utf8))) { error in
            guard case ProviderError.unauthorized = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try QwenProvider.parse(Data(#"{"data":{}}"#.utf8)))
    }

    func testSecTokenIsFoundInThePage() {
        XCTAssertEqual(QwenProvider.secToken(inHTML: #"window.ALIYUN_CONSOLE_CONFIG = {"sec_token":"abc.def"}"#), "abc.def")
        XCTAssertEqual(QwenProvider.secToken(inHTML: "sec_token = 'xyz'"), "xyz")
        XCTAssertNil(QwenProvider.secToken(inHTML: "<html>login</html>"))
    }

    func testCookieHelpers() {
        XCTAssertEqual(QwenProvider.normalizeCookie("Cookie: a=1; cna=zz"), "a=1; cna=zz")
        XCTAssertEqual(QwenProvider.cookieValue("cna", in: "a=1; cna=zz; b=2"), "zz")
        XCTAssertNil(QwenProvider.cookieValue("x", in: "a=1"))
        XCTAssertNil(QwenProvider.normalizeCookie("   "))
    }
}
