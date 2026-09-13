import XCTest
@testable import QuotaCore

final class CardWindowsTests: XCTestCase {
    private func window(_ title: String, _ seconds: Int?, scope: String? = nil, used: Double? = 10) -> UsageWindow {
        UsageWindow(title: scope.map { "\(title) · \($0)" } ?? title, usedPercent: used, windowSeconds: seconds, scope: scope)
    }

    private func ids(_ windows: [UsageWindow]) -> [String] { windows.map(\.title) }

    /// Pro has no 5-hour limit: the week alone; Spark's limits are folded.
    func testCodexProShowsTheWeekOnly() {
        let snapshot = UsageSnapshot(planName: "Pro 20x", account: nil, windows: [
            window("Week", 604_800),
            window("5h", 18_000, scope: "GPT-5.3-Codex-Spark"),
            window("Week", 604_800, scope: "GPT-5.3-Codex-Spark"),
        ])
        XCTAssertEqual(ids(snapshot.upFrontWindows(for: .codex)), ["Week"])
    }

    func testCodexPlusShowsTheFiveHourAndTheWeek() {
        let snapshot = UsageSnapshot(planName: "Plus", account: nil, windows: [
            window("5h", 18_000),
            window("Week", 604_800),
            window("5h", 18_000, scope: "GPT-5.3-Codex-Spark"),
        ])
        XCTAssertEqual(ids(snapshot.upFrontWindows(for: .codex)), ["5h", "Week"])
    }

    func testClaudeShowsTheFiveHourTheWeekAndFable() {
        let snapshot = UsageSnapshot(planName: "Max 20x", account: nil, windows: [
            window("5h", 18_000),
            window("Week", 604_800),
            window("Week", 604_800, scope: "Fable"),
        ])
        XCTAssertEqual(ids(snapshot.upFrontWindows(for: .claude)), ["5h", "Week", "Week · Fable"])
    }

    /// The window the owner picked for the ring is marked on the card, so it
    /// is never folded away.
    func testThePickedWindowIsAlwaysUpFront() {
        let spark = window("Week", 604_800, scope: "GPT-5.3-Codex-Spark")
        let snapshot = UsageSnapshot(planName: "Pro 20x", account: nil, windows: [window("Week", 604_800), spark])
        XCTAssertEqual(ids(snapshot.upFrontWindows(for: .codex, picked: spark.id)), ["Week", "Week · GPT-5.3-Codex-Spark"])
    }

    /// Everyone else keeps two: Cursor's plan and its named-model limit.
    func testOtherProvidersKeepTheTwoMostUseful() {
        let snapshot = UsageSnapshot(planName: nil, account: nil, windows: [
            window("Monthly", nil, used: 93),
            window("Named models", nil, scope: "Named models", used: 99.8),
            window("Grok Bot", 604_800, scope: "Grok Bot", used: 15),
        ])
        XCTAssertEqual(snapshot.upFrontWindows(for: .cursor).count, 2)
    }

    /// Chosen from the card's menu: Spark's week up front, the plan's week folded.
    func testTheOwnersChoiceWins() {
        let week = window("Week", 604_800)
        let spark = window("Week", 604_800, scope: "GPT-5.3-Codex-Spark")
        let snapshot = UsageSnapshot(planName: "Pro 20x", account: nil, windows: [week, spark])
        XCTAssertEqual(ids(snapshot.upFrontWindows(for: .codex, shown: [spark.id])), ["Week · GPT-5.3-Codex-Spark"])
    }

    /// Window ids are titles: after a language switch the saved choice
    /// matches nothing, and the card falls back to its own choice.
    func testAChoiceThatMatchesNothingFallsBack() {
        let snapshot = UsageSnapshot(planName: "Pro 20x", account: nil, windows: [window("周窗口", 604_800)])
        XCTAssertEqual(ids(snapshot.upFrontWindows(for: .codex, shown: ["Week"])), ["周窗口"])
    }

    func testTheChoiceSurvivesCoding() throws {
        var prefs = ExperiencePrefs()
        prefs.cardWindows["codex"] = ["周窗口"]
        let back = try JSONDecoder().decode(ExperiencePrefs.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(back.cardWindows["codex"], ["周窗口"])
        let odd = try JSONDecoder().decode(ExperiencePrefs.self, from: Data(#"{"cardWindows":7}"#.utf8))
        XCTAssertTrue(odd.cardWindows.isEmpty)
    }
}

final class WindowRenameTests: XCTestCase {
    private func window(_ title: String, _ seconds: Int?, scope: String? = nil) -> UsageWindow {
        UsageWindow(title: title, usedPercent: 10, windowSeconds: seconds, scope: scope)
    }

    func testClaudeInChinesePairsWithClaudeInEnglish() {
        let zh = [window("5 小时窗口", 18_000), window("周窗口", 604_800), window("周窗口 · Fable", 604_800, scope: "Fable")]
        let en = [window("5-hour window", 18_000), window("Weekly window", 604_800), window("Weekly window · Fable", 604_800, scope: "Fable")]
        XCTAssertEqual(WindowRename.pairs(from: zh, to: en), [
            "5 小时窗口": "5-hour window",
            "周窗口": "Weekly window",
            "周窗口 · Fable": "Weekly window · Fable",
        ])
    }

    /// Two model-scoped weeks either side, in the same order: paired in order.
    /// A window only one reading has is left alone.
    func testPairsInOrderAndSkipsWhatDoesNotMatch() {
        let zh = [window("月度套餐", nil), window("指定模型", nil, scope: "指定模型"), window("Grok Bot", 604_800, scope: "Grok Bot")]
        let en = [window("Monthly plan", nil), window("Named models", nil, scope: "Named models")]
        XCTAssertEqual(WindowRename.pairs(from: zh, to: en), ["月度套餐": "Monthly plan", "指定模型": "Named models"])
    }
}
