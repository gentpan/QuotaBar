import XCTest
@testable import QuotaCore

final class PaceVerdictTests: XCTestCase {
    private func pace(used: Double, elapsedFraction: Double, window: Double = 5 * 3600) -> WindowPace {
        let elapsed = window * elapsedFraction
        let rate = used / elapsed
        return WindowPace(
            expectedPercent: elapsedFraction * 100,
            actualPercent: used,
            secondsToExhaustion: rate > 0 ? (100 - used) / rate : nil,
            secondsToReset: window - elapsed)
    }

    /// openusage's examples: half used halfway is on the limit, so over;
    /// half used a quarter in is well over; a little used late is ahead.
    func testVerdictFollowsTheProjection() {
        XCTAssertEqual(pace(used: 20, elapsedFraction: 0.5).verdict, .ahead)
        XCTAssertEqual(pace(used: 47, elapsedFraction: 0.5).verdict, .close)
        XCTAssertEqual(pace(used: 50, elapsedFraction: 0.25).verdict, .over)
        XCTAssertEqual(pace(used: 100, elapsedFraction: 0.9).verdict, .spent)
        XCTAssertNil(pace(used: 0, elapsedFraction: 0.5).verdict, "nothing used has no rate to project")
    }

    func testProjectionTickAndRunOut() {
        let p = pace(used: 50, elapsedFraction: 0.25)
        XCTAssertEqual(p.projectedPercent, 200, accuracy: 0.001)
        XCTAssertEqual(p.tickFraction, 0.25, accuracy: 0.001)
        XCTAssertNotNil(p.runOutSeconds)
        XCTAssertNil(pace(used: 20, elapsedFraction: 0.5).runOutSeconds)
    }
}

final class ExperiencePrefsTests: XCTestCase {
    func testUnknownValuesFallBackOneByOne() throws {
        let json = #"{"resetTimeFormat":"sundial","alwaysShowPace":true,"currency":"cny","islandChart":"ring","paceAlerts":{"willRunOut":true},"hotkey":{"keyCode":12,"modifiers":2048,"display":"⌥Q"}}"#
        let prefs = try JSONDecoder().decode(ExperiencePrefs.self, from: Data(json.utf8))
        XCTAssertEqual(prefs.resetTimeFormat, .countdown)
        XCTAssertTrue(prefs.alwaysShowPace)
        XCTAssertEqual(prefs.currency, "CNY")
        XCTAssertEqual(prefs.islandChart, .ring)
        XCTAssertTrue(prefs.paceAlerts.willRunOut)
        XCTAssertFalse(prefs.paceAlerts.almostOut)
        XCTAssertEqual(prefs.hotkey?.display, "⌥Q")
    }

    func testABadCurrencyCodeIsDollars() throws {
        let prefs = try JSONDecoder().decode(ExperiencePrefs.self, from: Data(#"{"currency":"¥¥"}"#.utf8))
        XCTAssertEqual(prefs.currency, "USD")
    }

    func testRefreshIsAtLeastFiveMinutes() throws {
        let config = try JSONDecoder().decode(QuotaConfig.self, from: Data(#"{"refreshMinutes":1}"#.utf8))
        XCTAssertEqual(config.refreshMinutes, 5)
        XCTAssertEqual(QuotaConfig.clampRefresh(30), 30)
    }

    func testIslandChartCycles() {
        XCTAssertEqual(IslandChartStyle.spark.next, .bar)
        XCTAssertEqual(IslandChartStyle.bar.next, .ring)
    }
}

final class SnapshotCacheTests: XCTestCase {
    func testSnapshotsRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = UsageSnapshot(
            planName: "Max 20x", account: "a@b.c",
            windows: [UsageWindow(title: "5h", usedPercent: 23, resetsAt: reset, windowSeconds: 18_000),
                      UsageWindow(title: "5h", usedPercent: 40, scope: "Fable")],
            fetchedAt: Date(timeIntervalSince1970: 1_799_990_000),
            resetCredits: ResetCredits(available: 2, applicable: 1))
        SnapshotCache(fileURL: url).store(snapshot, for: .claude)
        let loaded = try XCTUnwrap(SnapshotCache(fileURL: url).snapshot(for: .claude))
        XCTAssertEqual(loaded.planName, "Max 20x")
        XCTAssertEqual(loaded.windows.map(\.id), ["5h", "5h#2"])
        XCTAssertEqual(loaded.windows.first?.resetsAt, reset)
        XCTAssertEqual(loaded.resetCredits, ResetCredits(available: 2, applicable: 1))
        XCTAssertNil(SnapshotCache(fileURL: url).snapshot(for: .codex))
    }
}

final class UsageArchiveTests: XCTestCase {
    private func day(_ offset: Int, from base: Date = Date()) -> String {
        UsageArchive.dayKey(Calendar.current.date(byAdding: .day, value: offset, to: base)!)
    }

    /// A later scan that finds less — the logs were pruned — keeps what the
    /// archive had; one that finds more replaces it.
    func testMergeNeverShrinks() {
        var archive = UsageArchive()
        let key = day(0)
        archive.merge([key: ["claudeCode": ["opus": ArchiveEntry(usd: 5, input: 100, output: 50)]]], scannedAt: Date(), full: true)
        archive.merge([key: ["claudeCode": ["opus": ArchiveEntry(usd: 1, input: 10, output: 5)]]], scannedAt: Date(), full: false)
        XCTAssertEqual(archive.days[key]?["claudeCode"]?["opus"]?.usd, 5)
        archive.merge([key: ["claudeCode": ["opus": ArchiveEntry(usd: 7, input: 140, output: 60)]]], scannedAt: Date(), full: false)
        XCTAssertEqual(archive.days[key]?["claudeCode"]?["opus"]?.usd, 7)
        XCTAssertTrue(archive.fullScanDone)
    }

    func testSummaryCountsEitherWay() {
        var archive = UsageArchive()
        archive.merge([
            day(0): ["claudeCode": ["opus": ArchiveEntry(usd: 5, input: 100, output: 50, cacheRead: 1000)]],
            day(-1): ["codexCLI": ["gpt": ArchiveEntry(usd: 2, input: 30, output: 20)]],
            day(-10): ["codexCLI": ["gpt": ArchiveEntry(usd: 9, input: 1, output: 1)]],
        ], scannedAt: Date(), full: true)
        let week = archive.summary(from: Calendar.current.date(byAdding: .day, value: -6, to: Date())!, to: Date())
        XCTAssertEqual(week.days.count, 7)
        XCTAssertEqual(week.usd, 7, accuracy: 0.001)
        XCTAssertEqual(week.tokens, 1200)
        XCTAssertEqual(week.activeDays, 2)
        XCTAssertEqual(week.sources.first?.source, .claudeCode)
        XCTAssertEqual(week.models.map(\.model), ["opus", "gpt"])
        XCTAssertEqual(week.cumulative(\.usd).last ?? 0, 7, accuracy: 0.001)
        let billable = archive.summary(from: Calendar.current.date(byAdding: .day, value: -6, to: Date())!, to: Date(), counting: .billable)
        XCTAssertEqual(billable.tokens, 200)
        XCTAssertEqual(archive.trend(for: .codexCLI, days: 3).map(\.tokens), [0, 50, 0])
    }

    func testIncrementalCutoffIsTwoDaysBeforeTheLastScan() {
        var archive = UsageArchive()
        XCTAssertNil(archive.incrementalCutoff())
        let scan = Date()
        archive.merge([:], scannedAt: scan, full: true)
        let expected = Calendar.current.date(byAdding: .day, value: -2, to: Calendar.current.startOfDay(for: scan))
        XCTAssertEqual(archive.incrementalCutoff(), expected)
    }
}

final class CurrencyAndTimeTests: XCTestCase {
    func testRatesParse() {
        XCTAssertEqual(CurrencyRates.parse(Data(#"{"result":"success","rates":{"USD":1,"CNY":7.12}}"#.utf8))?["CNY"], 7.12)
        XCTAssertNil(CurrencyRates.parse(Data(#"{"result":"error"}"#.utf8)))
    }

    func testConvertedFigures() {
        XCTAssertEqual(QuotaFormat.converted(32473.211, code: "CNY"), "¥32,473.21")
        XCTAssertEqual(QuotaFormat.converted(1234.6, code: "JPY"), "JP¥1,235")
        XCTAssertEqual(QuotaFormat.money(12.5, code: "USD"), "$12.50")
    }

    func testExactResetTime() {
        let calendar = Calendar.current
        let now = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!
        let later = calendar.date(bySettingHour: 18, minute: 38, second: 0, of: now)!
        let text = QuotaFormat.resetText(to: later, format: .exact, clock: .twentyFourHour, now: now)
        XCTAssertTrue(text.contains("18:38"), text)
        XCTAssertEqual(QuotaFormat.resetText(to: later, format: .countdown, now: now), QuotaFormat.resetLabel(to: later, from: now))
    }

    func testProxyParsing() {
        XCTAssertEqual(ProxySpec("socks5://127.0.0.1:7890")?.kind, .socks5)
        XCTAssertEqual(ProxySpec("http://proxy.local")?.port, 8080)
        XCTAssertNil(ProxySpec("not a proxy"))
        XCTAssertNil(ProxySpec("ftp://x:1"))
    }
}
