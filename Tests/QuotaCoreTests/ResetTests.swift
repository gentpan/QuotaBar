import XCTest
@testable import QuotaCore

final class ResetDetectorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(_ windows: [UsageWindow]) -> UsageSnapshot {
        UsageSnapshot(planName: nil, account: nil, windows: windows, fetchedAt: now)
    }

    /// The 5-hour window rolled over: its reset time passed and the figure fell.
    func testPassedResetWithADropIsAReset() {
        let before = snapshot([UsageWindow(title: "5h", usedPercent: 94, resetsAt: now.addingTimeInterval(-40), windowSeconds: 18_000)])
        let after = snapshot([UsageWindow(title: "5h", usedPercent: 0, resetsAt: nil, windowSeconds: 18_000)])
        let events = ResetDetector.events(provider: .claude, previous: before, current: after, now: now)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.previousUsed, 94)
        XCTAssertEqual(events.first?.resetAt, now.addingTimeInterval(-40))
        XCTAssertEqual(events.first?.isFresh, true)
        XCTAssertEqual(events.first?.followedHeavyUse, true)
    }

    /// Read a little early, the reset time is still in the future — but it
    /// jumped a whole week ahead, which only a reset does.
    func testResetTimeMovingForwardCountsAsPassed() {
        let before = snapshot([UsageWindow(title: "week", usedPercent: 60, resetsAt: now.addingTimeInterval(300), windowSeconds: 604_800)])
        let after = snapshot([UsageWindow(title: "week", usedPercent: 2, resetsAt: now.addingTimeInterval(604_800), windowSeconds: 604_800)])
        XCTAssertEqual(ResetDetector.events(provider: .codex, previous: before, current: after, now: now).count, 1)
    }

    /// A drop with the same reset time is a top-up or a correction.
    func testDropWithoutTimeRunningOutIsNotAReset() {
        let reset = now.addingTimeInterval(3_600)
        let before = snapshot([UsageWindow(title: "5h", usedPercent: 50, resetsAt: reset, windowSeconds: 18_000)])
        let after = snapshot([UsageWindow(title: "5h", usedPercent: 20, resetsAt: reset, windowSeconds: 18_000)])
        XCTAssertTrue(ResetDetector.events(provider: .claude, previous: before, current: after, now: now).isEmpty)
    }

    /// A window that rolled with almost nothing used is not worth a banner.
    func testSmallDropIsNotAReset() {
        let before = snapshot([UsageWindow(title: "5h", usedPercent: 6, resetsAt: now.addingTimeInterval(-10), windowSeconds: 18_000)])
        let after = snapshot([UsageWindow(title: "5h", usedPercent: 0, windowSeconds: 18_000)])
        XCTAssertTrue(ResetDetector.events(provider: .claude, previous: before, current: after, now: now).isEmpty)
    }

    /// The first reading has nothing to compare with; a window that only
    /// appears in one reading neither.
    func testNoPreviousOrUnmatchedWindow() {
        let after = snapshot([UsageWindow(title: "5h", usedPercent: 0)])
        XCTAssertTrue(ResetDetector.events(provider: .claude, previous: nil, current: after, now: now).isEmpty)
        let before = snapshot([UsageWindow(title: "week", usedPercent: 90, resetsAt: now.addingTimeInterval(-10))])
        XCTAssertTrue(ResetDetector.events(provider: .claude, previous: before, current: after, now: now).isEmpty)
    }

    /// A cached reading replaced hours after its reset: still a reset, but not
    /// news — no banner, no notification.
    func testStaleResetIsNotFresh() {
        let before = snapshot([UsageWindow(title: "5h", usedPercent: 95, resetsAt: now.addingTimeInterval(-3 * 3_600), windowSeconds: 18_000)])
        let after = snapshot([UsageWindow(title: "5h", usedPercent: 0, windowSeconds: 18_000)])
        let event = ResetDetector.events(provider: .claude, previous: before, current: after, now: now).first
        XCTAssertEqual(event?.isFresh, false)
        XCTAssertEqual(event.map { ResetNotifyMode.always.shouldNotify($0) }, false)
    }

    func testNotifyModes() {
        let heavy = ResetEvent(provider: .claude, windowID: "5h", name: "5h", previousUsed: 97, usedNow: 0, resetAt: now, noticedAt: now)
        let light = ResetEvent(provider: .claude, windowID: "5h", name: "5h", previousUsed: 40, usedNow: 0, resetAt: now, noticedAt: now)
        XCTAssertFalse(ResetNotifyMode.off.shouldNotify(heavy))
        XCTAssertTrue(ResetNotifyMode.afterHeavyUse.shouldNotify(heavy))
        XCTAssertFalse(ResetNotifyMode.afterHeavyUse.shouldNotify(light))
        XCTAssertTrue(ResetNotifyMode.always.shouldNotify(light))
    }

    func testNextCheckIsTheEarliestUpcomingResetPlusGrace() {
        let s = snapshot([
            UsageWindow(title: "week", usedPercent: 10, resetsAt: now.addingTimeInterval(86_400)),
            UsageWindow(title: "5h", usedPercent: 10, resetsAt: now.addingTimeInterval(1_200)),
            UsageWindow(title: "old", usedPercent: 10, resetsAt: now.addingTimeInterval(-50)),
        ])
        XCTAssertEqual(ResetDetector.nextCheck(for: s, after: now), now.addingTimeInterval(1_220))
        XCTAssertNil(ResetDetector.nextCheck(for: snapshot([UsageWindow(title: "balance", usedPercent: 10)]), after: now))
    }

    func testPrefsDefaultAndDecodeLeniently() throws {
        let prefs = try JSONDecoder().decode(ExperiencePrefs.self, from: Data(#"{"resetNotify":"nonsense"}"#.utf8))
        XCTAssertTrue(prefs.resetEffects)
        XCTAssertEqual(prefs.resetNotify, .afterHeavyUse)
        let off = try JSONDecoder().decode(ExperiencePrefs.self, from: Data(#"{"resetEffects":false,"resetNotify":"off"}"#.utf8))
        XCTAssertFalse(off.resetEffects)
        XCTAssertEqual(off.resetNotify, .off)
    }
}
