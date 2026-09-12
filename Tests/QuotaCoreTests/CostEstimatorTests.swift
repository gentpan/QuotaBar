import XCTest
@testable import QuotaCore

/// The estimator reads real CLI session logs, so these tests build a throwaway
/// log tree per case and point the estimator at it.
final class CostEstimatorTests: XCTestCase {
    private var root: URL!
    private var claudeRoot: URL!
    private var codexRoot: URL!
    private var paths: CostPaths!

    /// Fixed clock so "this month" and "today" are deterministic.
    private let now = ISO8601DateFormatter().date(from: "2026-08-26T12:00:00Z")!

    /// The estimator buckets by the *local* calendar (that is what "this month"
    /// means to the user) while logs are stamped in UTC, so boundary fixtures
    /// are derived from the calendar rather than written as UTC literals.
    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private var localDayStart: Date {
        Calendar.current.startOfDay(for: now)
    }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-cost-\(UUID().uuidString)")
        claudeRoot = root.appendingPathComponent("claude/projects")
        codexRoot = root.appendingPathComponent("codex/sessions")
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        paths = CostPaths(claudeProjects: claudeRoot, codexSessions: codexRoot)
        CostEstimator.resetCache()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        CostEstimator.resetCache()
    }

    // MARK: Fixtures

    private func writeClaude(_ name: String, lines: [String]) throws {
        try lines.joined(separator: "\n")
            .write(to: claudeRoot.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func claudeLine(
        messageID: String,
        requestID: String,
        model: String = "claude-opus-5",
        timestamp: String = "2026-08-26T10:00:00.000Z",
        input: Int = 0,
        output: Int = 0,
        write5m: Int = 0,
        write1h: Int = 0,
        read: Int = 0) -> String
    {
        """
        {"type":"assistant","requestId":"\(requestID)","timestamp":"\(timestamp)",\
        "message":{"id":"\(messageID)","model":"\(model)","usage":{\
        "input_tokens":\(input),"output_tokens":\(output),\
        "cache_creation_input_tokens":\(write5m + write1h),\
        "cache_read_input_tokens":\(read),\
        "cache_creation":{"ephemeral_5m_input_tokens":\(write5m),"ephemeral_1h_input_tokens":\(write1h)}}}}
        """
    }

    private func writeCodex(_ name: String, lines: [String]) throws {
        try lines.joined(separator: "\n")
            .write(to: codexRoot.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func codexLine(
        timestamp: String = "2026-08-26T10:00:00.000Z",
        input: Int,
        cached: Int,
        output: Int) -> String
    {
        """
        {"type":"event_msg","timestamp":"\(timestamp)","payload":{"type":"token_count",\
        "info":{"last_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),\
        "cache_write_input_tokens":0,"output_tokens":\(output)}}}}
        """
    }

    // MARK: Deduplication

    func testSameAssistantTurnInTwoFilesIsBilledOnce() throws {
        let line = claudeLine(messageID: "msg_1", requestID: "req_1", output: 1_000_000)
        try writeClaude("a.jsonl", lines: [line])
        // Resuming a conversation replays prior turns into a new session file.
        try writeClaude("b.jsonl", lines: [line])

        let summary = CostEstimator.summary(paths: paths, now: now)

        // 1M output tokens on Opus = $25.00, counted exactly once.
        XCTAssertEqual(summary.windowUSD, 25.0, accuracy: 0.0001)
        XCTAssertEqual(summary.windowTokens, 1_000_000)
        XCTAssertEqual(summary.deduplicated, 1)
    }

    func testDistinctTurnsAreBothBilled() throws {
        try writeClaude("a.jsonl", lines: [
            claudeLine(messageID: "msg_1", requestID: "req_1", output: 1_000_000),
            claudeLine(messageID: "msg_2", requestID: "req_2", output: 1_000_000),
        ])

        let summary = CostEstimator.summary(paths: paths, now: now)

        XCTAssertEqual(summary.windowUSD, 50.0, accuracy: 0.0001)
        XCTAssertEqual(summary.deduplicated, 0)
    }

    // MARK: Cache tiers

    func testOneHourCacheWriteCostsMoreThanFiveMinute() throws {
        try writeClaude("a.jsonl", lines: [
            claudeLine(messageID: "m5", requestID: "r5", write5m: 1_000_000),
        ])
        let fiveMinute = CostEstimator.summary(paths: paths, now: now).windowUSD

        CostEstimator.resetCache()
        try writeClaude("a.jsonl", lines: [
            claudeLine(messageID: "m1", requestID: "r1", write1h: 1_000_000),
        ])
        let oneHour = CostEstimator.summary(paths: paths, now: now).windowUSD

        // Opus: 5m write = $6.25/M, 1h write = $10.00/M.
        XCTAssertEqual(fiveMinute, 6.25, accuracy: 0.0001)
        XCTAssertEqual(oneHour, 10.0, accuracy: 0.0001)
    }

    func testFlatCacheCreationFallsBackToFiveMinuteRate() throws {
        // Older log format: no `cache_creation` breakdown at all.
        let line = """
        {"type":"assistant","requestId":"r","timestamp":"2026-08-26T10:00:00.000Z",\
        "message":{"id":"m","model":"claude-opus-5","usage":{\
        "input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":1000000,\
        "cache_read_input_tokens":0}}}
        """
        try writeClaude("a.jsonl", lines: [line])

        XCTAssertEqual(CostEstimator.summary(paths: paths, now: now).windowUSD, 6.25, accuracy: 0.0001)
    }

    // MARK: Codex cached-input handling

    func testCodexCachedInputIsNotBilledTwice() throws {
        // 1M input of which 1M was cached: the fresh-input charge must be zero.
        try writeCodex("rollout-1.jsonl", lines: [
            codexLine(input: 1_000_000, cached: 1_000_000, output: 0),
        ])

        let summary = CostEstimator.summary(paths: paths, now: now)

        // gpt-5-codex cache read = $0.125/M. Billing the input again would give $1.375.
        XCTAssertEqual(summary.windowUSD, 0.125, accuracy: 0.0001)
    }

    func testCodexFreshInputIsBilledAtInputRate() throws {
        try writeCodex("rollout-1.jsonl", lines: [
            codexLine(input: 1_000_000, cached: 0, output: 0),
        ])

        XCTAssertEqual(CostEstimator.summary(paths: paths, now: now).windowUSD, 1.25, accuracy: 0.0001)
    }

    // MARK: Time boundaries

    func testEventsOutsideTheLookbackWindowAreExcluded() throws {
        try writeClaude("a.jsonl", lines: [
            claudeLine(
                messageID: "old", requestID: "old",
                timestamp: iso(localDayStart.addingTimeInterval(-40 * 86_400)), output: 1_000_000),
            claudeLine(
                messageID: "new", requestID: "new",
                timestamp: iso(localDayStart.addingTimeInterval(-2 * 86_400)), output: 1_000_000),
        ])

        let summary = CostEstimator.summary(paths: paths, lookbackDays: 31, now: now)

        XCTAssertEqual(summary.windowUSD, 25.0, accuracy: 0.0001)
    }

    func testTodayIsASubsetOfTheMonth() throws {
        try writeClaude("a.jsonl", lines: [
            claudeLine(
                messageID: "earlier", requestID: "e",
                timestamp: iso(localDayStart.addingTimeInterval(-3600)), output: 1_000_000),
            claudeLine(
                messageID: "today", requestID: "t",
                timestamp: iso(localDayStart.addingTimeInterval(3600)), output: 1_000_000),
        ])

        let summary = CostEstimator.summary(paths: paths, now: now)

        XCTAssertEqual(summary.windowUSD, 50.0, accuracy: 0.0001)
        XCTAssertEqual(summary.todayUSD, 25.0, accuracy: 0.0001)
        XCTAssertEqual(summary.todayTokens, 1_000_000)
    }

    // MARK: Archive-derived figures

    /// The app now shows spend and the year from the archive instead of
    /// rescanning the logs. On the same logs the two must agree: totals,
    /// today and yesterday, per CLI, per model, tokens with and without cache,
    /// and the ledger's days.
    func testArchiveDerivedFiguresMatchAScanOfTheLogs() throws {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: localDayStart)!.addingTimeInterval(3600)
        let lastWeek = calendar.date(byAdding: .day, value: -6, to: localDayStart)!.addingTimeInterval(7200)
        let todayStamp = iso(localDayStart.addingTimeInterval(3600))
        try writeClaude("a.jsonl", lines: [
            claudeLine(messageID: "m1", requestID: "r1", timestamp: todayStamp, input: 1_000, output: 20_000, write5m: 3_000, read: 40_000),
            claudeLine(messageID: "m2", requestID: "r2", model: "claude-sonnet-5", timestamp: iso(yesterday), input: 500, output: 9_000, read: 7_000),
            claudeLine(messageID: "m3", requestID: "r3", timestamp: iso(lastWeek), output: 50_000),
        ])
        // The same turn replayed in a second session file is counted once.
        try writeClaude("b.jsonl", lines: [
            claudeLine(messageID: "m1", requestID: "r1", timestamp: todayStamp, input: 1_000, output: 20_000, write5m: 3_000, read: 40_000),
        ])
        try writeCodex("rollout-1.jsonl", lines: [
            codexLine(timestamp: todayStamp, input: 90_000, cached: 60_000, output: 4_000),
            codexLine(timestamp: iso(lastWeek), input: 10_000, cached: 0, output: 1_000),
        ])

        let scanned = CostEstimator.summary(paths: paths, now: now)
        var archive = UsageArchive()
        archive.merge(CostEstimator.archiveRecords(paths: paths, since: .distantPast), scannedAt: now, full: true)
        let derived = archive.costSummary(now: now)

        XCTAssertEqual(derived.windowUSD, scanned.windowUSD, accuracy: 0.000_001)
        XCTAssertEqual(derived.windowTokens, scanned.windowTokens)
        XCTAssertEqual(derived.todayUSD, scanned.todayUSD, accuracy: 0.000_001)
        XCTAssertEqual(derived.todayTokens, scanned.todayTokens)
        XCTAssertEqual(derived.topModel, scanned.topModel)
        for period in SpendPeriod.allCases {
            let a = derived.spend(period), b = scanned.spend(period)
            XCTAssertEqual(a.usd, b.usd, accuracy: 0.000_001, "\(period)")
            XCTAssertEqual(a.tokens, b.tokens, "\(period)")
            XCTAssertEqual(a.billableTokens, b.billableTokens, "\(period)")
            XCTAssertEqual(a.tokensBySource, b.tokensBySource, "\(period)")
            XCTAssertEqual(Set(a.models.map(\.model)), Set(b.models.map(\.model)), "\(period)")
        }
        XCTAssertEqual(derived.daily.map(\.tokens), scanned.daily.map(\.tokens))

        let scannedLedger = CostEstimator.ledger(paths: paths, now: now)
        let derivedLedger = archive.ledger(now: now)
        XCTAssertEqual(derivedLedger.days.count, scannedLedger.days.count)
        XCTAssertEqual(derivedLedger.days.map(\.tokens), scannedLedger.days.map(\.tokens))
        XCTAssertEqual(derivedLedger.total(.source(.codexCLI)), scannedLedger.total(.source(.codexCLI)))
        XCTAssertEqual(derivedLedger.models().map(\.model), scannedLedger.models().map(\.model))
    }

    /// A log that keeps growing must not pile up parses in memory: the cache
    /// holds one parse per file, and forgets files the scan no longer reaches.
    func testTheParseCacheKeepsOneEntryPerFile() throws {
        try writeClaude("a.jsonl", lines: [claudeLine(messageID: "m1", requestID: "r1", output: 1_000)])
        _ = CostEstimator.archiveRecords(paths: paths, since: .distantPast)
        try writeClaude("a.jsonl", lines: [
            claudeLine(messageID: "m1", requestID: "r1", output: 1_000),
            claudeLine(messageID: "m2", requestID: "r2", output: 2_000),
        ])
        let records = CostEstimator.archiveRecords(paths: paths, since: .distantPast)
        let tokens = records.values.flatMap { $0.values.flatMap { $0.values } }.reduce(0) { $0 + $1.output }
        XCTAssertEqual(tokens, 3_000, "the grown file is read afresh, not served from the old parse")
        XCTAssertEqual(CostEstimator.cachedFileCount, 1)
        try FileManager.default.removeItem(at: claudeRoot.appendingPathComponent("a.jsonl"))
        _ = CostEstimator.archiveRecords(paths: paths, since: .distantPast)
        XCTAssertEqual(CostEstimator.cachedFileCount, 0, "a deleted file is let go")
    }

    // MARK: Attribution

    func testSpendIsAttributedPerCLI() throws {
        try writeClaude("a.jsonl", lines: [
            claudeLine(messageID: "m", requestID: "r", output: 1_000_000),
        ])
        try writeCodex("rollout-1.jsonl", lines: [
            codexLine(input: 1_000_000, cached: 0, output: 0),
        ])

        let summary = CostEstimator.summary(paths: paths, now: now)

        XCTAssertEqual(summary.windowBySource[.claudeCode] ?? 0, 25.0, accuracy: 0.0001)
        XCTAssertEqual(summary.windowBySource[.codexCLI] ?? 0, 1.25, accuracy: 0.0001)
        XCTAssertEqual(summary.windowUSD, 26.25, accuracy: 0.0001)
    }

    func testEmptyTreeProducesNoData() {
        let summary = CostEstimator.summary(paths: paths, lookbackDays: 31, now: now)

        XCTAssertFalse(summary.hasData)
        XCTAssertEqual(summary.windowUSD, 0)
        XCTAssertEqual(summary.todayUSD, 0)
        XCTAssertNil(summary.topModel)
        XCTAssertTrue(summary.windowBySource.isEmpty)
        // The day slots are still present and all zero — the chart needs a
        // continuous axis, so "no data" is 31 empty days, not an empty array.
        XCTAssertEqual(summary.daily.count, 31)
        XCTAssertTrue(summary.daily.allSatisfy { $0.usd == 0 && $0.tokens == 0 })
    }
}

// MARK: - Pricing table

final class PricingTests: XCTestCase {
    /// These pin the *built-in fallback* table, which is only consulted when
    /// the published catalog has no entry. They therefore assert against a
    /// catalog that is deliberately empty — reading the real one would make
    /// the result depend on whatever prices were fetched on this machine, and
    /// on prices that legitimately change.
    func testBuiltInTableIsUsedWhenTheCatalogHasNothing() {
        let expectations: [(String, Double, Double)] = [
            ("claude-fable-5", 10, 50),
            ("claude-opus-5", 5, 25),
            ("claude-opus-4-8", 5, 25),
            ("claude-sonnet-5", 2, 10),
            ("claude-sonnet-4-6", 3, 15),
            ("claude-haiku-4-5", 1, 5),
        ]
        for (model, input, output) in expectations {
            let rates = Pricing.perMillion(for: model, catalog: Self.emptyCatalog)
            XCTAssertEqual(rates.0, input, accuracy: 0.001, "input rate for \(model)")
            XCTAssertEqual(rates.1, output, accuracy: 0.001, "output rate for \(model)")
        }
    }

    /// Why the catalog exists. The fallback prefix-matches, and a model it has
    /// never seen resolves to whatever prefix happens to hit — `gpt-5.6-sol`
    /// lands on `gpt-5` at $1.25/$10 against a real $4/$20.
    func testTheFallbackIsWrongForUnknownModelsWhichIsWhyTheCatalogWins() {
        let guessed = Pricing.perMillion(for: "gpt-5.6-sol", catalog: Self.emptyCatalog)
        XCTAssertEqual(guessed.0, 1.25, accuracy: 0.001, "prefix-matched onto gpt-5")

        let published = PricingCatalog(cacheURL: Self.seededCatalogURL)
        let exact = Pricing.perMillion(for: "gpt-5.6-sol", catalog: published)
        XCTAssertEqual(exact.0, 4, accuracy: 0.001)
        XCTAssertEqual(exact.1, 20, accuracy: 0.001)
    }

    private static let emptyCatalog = PricingCatalog(
        cacheURL: URL(fileURLWithPath: "/nonexistent/quotabar-tests/pricing.json"))

    private static let seededCatalogURL: URL = {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-seeded-\(UUID().uuidString)")
            .appendingPathComponent("pricing.json")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = """
        {"gpt-5.6-sol": {"input_cost_per_token": 0.000004, "output_cost_per_token": 0.00002}}
        """
        if let table = PricingCatalog.parse(Data(payload.utf8)),
           let encoded = try? JSONEncoder().encode(table) {
            try? encoded.write(to: url)
        }
        return url
    }()

    func testSonnet5IsMatchedBeforeGenericSonnet() {
        // Ordering bug guard: "claude-sonnet-5" contains "sonnet" too.
        XCTAssertEqual(
            Pricing.perMillion(for: "claude-sonnet-5", catalog: Self.emptyCatalog).0,
            2, accuracy: 0.001)
        XCTAssertEqual(
            Pricing.perMillion(for: "claude-sonnet-4-6", catalog: Self.emptyCatalog).0,
            3, accuracy: 0.001)
    }

    func testAnthropicCacheWriteTiers() {
        // 5-minute = 1.25x input, 1-hour = 2x input.
        let opus = Pricing.perMillion(for: "claude-opus-5", catalog: Self.emptyCatalog)
        XCTAssertEqual(opus.2, opus.0 * 1.25, accuracy: 0.001)
        XCTAssertEqual(opus.3, opus.0 * 2.0, accuracy: 0.001)
        XCTAssertEqual(opus.4, opus.0 * 0.1, accuracy: 0.001)
    }

    func testUnknownModelIsPricedNotFree() {
        XCTAssertGreaterThan(
            Pricing.perMillion(for: "some-future-model", catalog: Self.emptyCatalog).0, 0)
    }
}

// MARK: - Daily breakdown

final class DailyCostTests: XCTestCase {
    private var root: URL!
    private var claudeRoot: URL!
    private var paths: CostPaths!
    private let now = ISO8601DateFormatter().date(from: "2026-08-26T12:00:00Z")!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-daily-\(UUID().uuidString)")
        claudeRoot = root.appendingPathComponent("claude/projects")
        let codexRoot = root.appendingPathComponent("codex/sessions")
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        paths = CostPaths(claudeProjects: claudeRoot, codexSessions: codexRoot)
        CostEstimator.resetCache()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        CostEstimator.resetCache()
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// Noon on the local day `offset` days before today, so the event cannot
    /// drift across a day boundary when converted to UTC.
    private func localNoon(daysAgo offset: Int) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now))!
        return calendar.date(byAdding: .hour, value: 12, to: day)!
    }

    private func write(_ lines: [String]) throws {
        try lines.joined(separator: "\n")
            .write(to: claudeRoot.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
    }

    private func line(id: String, at date: Date, model: String = "claude-opus-5", output: Int) -> String {
        """
        {"type":"assistant","requestId":"\(id)","timestamp":"\(iso(date))",\
        "message":{"id":"\(id)","model":"\(model)","usage":{\
        "input_tokens":0,"output_tokens":\(output),"cache_creation_input_tokens":0,\
        "cache_read_input_tokens":0}}}
        """
    }

    func testIdleDaysStillOccupyASlot() throws {
        try write([
            line(id: "a", at: localNoon(daysAgo: 4), output: 1_000_000),
            line(id: "b", at: localNoon(daysAgo: 0), output: 2_000_000),
        ])

        let summary = CostEstimator.summary(paths: paths, lookbackDays: 5, now: now)

        // Five slots for five days — collapsing the three idle days would make
        // an idle stretch read as continuous activity in the chart.
        XCTAssertEqual(summary.daily.count, 5)
        XCTAssertEqual(summary.daily.map(\.usd), [25, 0, 0, 0, 50])
    }

    func testDaysAreOldestFirstAndContiguous() throws {
        try write([line(id: "a", at: localNoon(daysAgo: 0), output: 1_000_000)])

        let days = CostEstimator.summary(paths: paths, lookbackDays: 7, now: now).daily

        XCTAssertEqual(days.count, 7)
        for (earlier, later) in zip(days, days.dropFirst()) {
            XCTAssertEqual(
                Calendar.current.dateComponents([.day], from: earlier.day, to: later.day).day, 1,
                "days must be contiguous")
        }
        XCTAssertEqual(days.last?.day, Calendar.current.startOfDay(for: now))
    }

    func testTodayMatchesTheLastBucket() throws {
        try write([
            line(id: "a", at: localNoon(daysAgo: 2), output: 1_000_000),
            line(id: "b", at: localNoon(daysAgo: 0), output: 4_000_000),
        ])

        let summary = CostEstimator.summary(paths: paths, lookbackDays: 5, now: now)

        XCTAssertEqual(summary.daily.last?.usd ?? 0, summary.todayUSD, accuracy: 0.0001)
        XCTAssertEqual(summary.daily.last?.tokens, summary.todayTokens)
    }

    func testWindowTotalIsTheSumOfDays() throws {
        try write([
            line(id: "a", at: localNoon(daysAgo: 3), output: 1_000_000),
            line(id: "b", at: localNoon(daysAgo: 1), output: 2_000_000),
            line(id: "c", at: localNoon(daysAgo: 0), output: 1_000_000),
        ])

        let summary = CostEstimator.summary(paths: paths, lookbackDays: 5, now: now)

        XCTAssertEqual(summary.windowUSD, summary.daily.reduce(0) { $0 + $1.usd }, accuracy: 0.0001)
        XCTAssertEqual(summary.windowUSD, 100, accuracy: 0.0001)
    }

    func testEventsOlderThanTheWindowAreExcluded() throws {
        try write([
            line(id: "old", at: localNoon(daysAgo: 9), output: 1_000_000),
            line(id: "new", at: localNoon(daysAgo: 1), output: 1_000_000),
        ])

        let summary = CostEstimator.summary(paths: paths, lookbackDays: 5, now: now)

        XCTAssertEqual(summary.windowUSD, 25, accuracy: 0.0001)
        XCTAssertEqual(summary.daily.count, 5)
    }

    func testPeakDayIsTheBusiestOne() throws {
        try write([
            line(id: "a", at: localNoon(daysAgo: 3), output: 1_000_000),
            line(id: "b", at: localNoon(daysAgo: 2), output: 8_000_000),
            line(id: "c", at: localNoon(daysAgo: 0), output: 2_000_000),
        ])

        let peak = CostEstimator.summary(paths: paths, lookbackDays: 5, now: now).peakDay

        XCTAssertEqual(peak?.usd ?? 0, 200, accuracy: 0.0001)
        XCTAssertEqual(peak?.day, Calendar.current.startOfDay(for: localNoon(daysAgo: 2)))
    }

    func testTopModelIsRankedBySpendNotFrequency() throws {
        try write([
            // Three cheap Haiku turns versus one expensive Opus turn.
            line(id: "h1", at: localNoon(daysAgo: 0), model: "claude-haiku-4-5", output: 1_000_000),
            line(id: "h2", at: localNoon(daysAgo: 0), model: "claude-haiku-4-5", output: 1_000_000),
            line(id: "h3", at: localNoon(daysAgo: 0), model: "claude-haiku-4-5", output: 1_000_000),
            line(id: "o1", at: localNoon(daysAgo: 0), model: "claude-opus-5", output: 1_000_000),
        ])

        // Haiku: 3 × $5 = $15. Opus: 1 × $25.
        XCTAssertEqual(
            CostEstimator.summary(paths: paths, lookbackDays: 5, now: now).topModel,
            "claude-opus-5")
    }

    func testRecentDaysTrimsFromTheEnd() throws {
        try write([line(id: "a", at: localNoon(daysAgo: 0), output: 1_000_000)])

        let summary = CostEstimator.summary(paths: paths, lookbackDays: 10, now: now)
        let recent = summary.recentDays(3)

        XCTAssertEqual(recent.count, 3)
        XCTAssertEqual(recent.last?.day, Calendar.current.startOfDay(for: now))
    }

    func testEmptyTreeHasNoPeakAndNoModel() {
        let summary = CostEstimator.summary(paths: paths, lookbackDays: 5, now: now)
        XCTAssertNil(summary.topModel)
        XCTAssertEqual(summary.peakDay?.usd ?? 0, 0)
        XCTAssertFalse(summary.hasData)
    }
}

// MARK: - Chunk boundaries

/// The scanner reads in fixed blocks, so lines land across block boundaries in
/// every real log. Fixture files elsewhere in this suite are a few hundred
/// bytes and never exercise that path.
final class ChunkBoundaryTests: XCTestCase {
    private var root: URL!
    private var claudeRoot: URL!
    private var paths: CostPaths!
    private let now = ISO8601DateFormatter().date(from: "2026-08-26T12:00:00Z")!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-chunk-\(UUID().uuidString)")
        claudeRoot = root.appendingPathComponent("claude/projects")
        let codexRoot = root.appendingPathComponent("codex/sessions")
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        paths = CostPaths(claudeProjects: claudeRoot, codexSessions: codexRoot)
        CostEstimator.resetCache()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        CostEstimator.resetCache()
    }

    /// One billable row worth exactly $25 on Opus (1M output tokens).
    private func billableLine(_ id: String) -> String {
        """
        {"type":"assistant","requestId":"\(id)","timestamp":"2026-08-26T10:00:00.000Z",\
        "message":{"id":"\(id)","model":"claude-opus-5","usage":{\
        "input_tokens":0,"output_tokens":1000000,"cache_creation_input_tokens":0,\
        "cache_read_input_tokens":0}}}
        """
    }

    /// A big line the scanner must skip over without losing its place — this
    /// is what tool output looks like in a real log.
    private func filler(_ bytes: Int) -> String {
        "{\"type\":\"user\",\"padding\":\"" + String(repeating: "x", count: bytes) + "\"}"
    }

    private func write(_ lines: [String]) throws {
        try lines.joined(separator: "\n")
            .write(to: claudeRoot.appendingPathComponent("big.jsonl"), atomically: true, encoding: .utf8)
    }

    func testBillableRowsSurviveAcrossManyChunks() throws {
        // ~24MB of filler around 20 billable rows: several read blocks, with
        // rows landing at unpredictable offsets inside them.
        var lines: [String] = []
        for index in 0..<20 {
            lines.append(filler(1_200_000))
            lines.append(billableLine("msg\(index)"))
        }
        try write(lines)

        let summary = CostEstimator.summary(paths: paths, lookbackDays: 31, now: now)

        XCTAssertEqual(summary.windowUSD, 20 * 25.0, accuracy: 0.0001,
                       "every billable row must be found regardless of where blocks fall")
        XCTAssertEqual(summary.windowTokens, 20 * 1_000_000)
    }

    func testRowSplitExactlyAcrossABoundary() throws {
        // Pad so the next line starts a few bytes before a 4MB boundary and is
        // therefore cut in half by the read.
        let blockSize = 4 << 20
        let padding = blockSize - 40
        try write([filler(padding), billableLine("split"), billableLine("after")])

        let summary = CostEstimator.summary(paths: paths, lookbackDays: 31, now: now)

        XCTAssertEqual(summary.windowUSD, 50.0, accuracy: 0.0001,
                       "a row straddling a block boundary must not be dropped")
    }

    func testOversizedLineIsSkippedWithoutLosingTheNextRow() throws {
        // A single line larger than one read block: it must be discarded, and
        // the scanner must resynchronise on the following newline.
        try write([filler(9 << 20), billableLine("after-huge")])

        let summary = CostEstimator.summary(paths: paths, lookbackDays: 31, now: now)

        XCTAssertEqual(summary.windowUSD, 25.0, accuracy: 0.0001,
                       "the row after an oversized line must still be counted")
    }

    func testFinalRowWithoutTrailingNewline() throws {
        try write([filler(5 << 20), billableLine("last")])

        XCTAssertEqual(
            CostEstimator.summary(paths: paths, lookbackDays: 31, now: now).windowUSD,
            25.0, accuracy: 0.0001,
            "the last line has no newline terminator and must still be read")
    }
}
