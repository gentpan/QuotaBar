import XCTest
@testable import QuotaCore

final class ResetCreditNoticeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func reading(_ available: Int?) -> UsageSnapshot {
        UsageSnapshot(windows: [], resetCredits: available.map { ResetCredits(available: $0) })
    }

    func testAResetGivenSinceTheReadingBefore() {
        let notices = ResetCreditCheck.notices(
            provider: .codex, previous: reading(1), current: ResetCredits(available: 3), notified: [], now: now)
        XCTAssertEqual(notices.map(\.kind), [.given(2)])
        XCTAssertEqual(notices.first?.available, 3)
    }

    /// Before the count was kept at zero a reading carried none at all.
    func testAReadingWithoutACountHadNoneToSpend() {
        let notices = ResetCreditCheck.notices(
            provider: .codex, previous: reading(nil), current: ResetCredits(available: 1), notified: [], now: now)
        XCTAssertEqual(notices.map(\.kind), [.given(1)])
    }

    func testTheFirstReadingEverSetsTheBaseline() {
        XCTAssertTrue(ResetCreditCheck.notices(
            provider: .codex, previous: nil, current: ResetCredits(available: 3), notified: [], now: now).isEmpty)
    }

    func testSpendingOneSaysNothing() {
        XCTAssertTrue(ResetCreditCheck.notices(
            provider: .codex, previous: reading(3), current: ResetCredits(available: 2), notified: [], now: now).isEmpty)
    }

    /// Within a day of running out, once per credit; a credit further off,
    /// or one that never expires, waits.
    func testAReminderComesADayBeforeAndOnce() {
        let credits = ResetCredits(available: 3, credits: [
            ResetCredit(id: "soon", title: "Full reset (Weekly + 5 hr)", expiresAt: now.addingTimeInterval(20 * 3600)),
            ResetCredit(id: "later", expiresAt: now.addingTimeInterval(3 * 86_400)),
            ResetCredit(id: "never"),
        ])
        let first = ResetCreditCheck.notices(provider: .codex, previous: reading(3), current: credits, notified: [], now: now)
        XCTAssertEqual(first.map(\.key), ["codex|expiring|soon"])
        guard case let .expiring(credit)? = first.first?.kind else { return XCTFail("\(first)") }
        XCTAssertEqual(credit.title, "Full reset (Weekly + 5 hr)")

        let again = ResetCreditCheck.notices(
            provider: .codex, previous: reading(3), current: credits, notified: first.map(\.key), now: now.addingTimeInterval(3600))
        XCTAssertTrue(again.isEmpty)
    }

    func testTheSwitchSurvivesCoding() throws {
        var prefs = ExperiencePrefs()
        XCTAssertTrue(prefs.resetCreditNotify, "on unless turned off")
        prefs.resetCreditNotify = false
        prefs.resetCreditNotified = ["codex|expiring|soon"]
        let back = try JSONDecoder().decode(ExperiencePrefs.self, from: JSONEncoder().encode(prefs))
        XCTAssertFalse(back.resetCreditNotify)
        XCTAssertEqual(back.resetCreditNotified, ["codex|expiring|soon"])
    }
}
