import AppKit
import XCTest
@testable import QuotaCore

final class WindowTitleTests: XCTestCase {
    override func setUp() { L10n.override = .en }
    override func tearDown() { L10n.override = .system }

    func testNamedWindows() {
        XCTAssertEqual(WindowTitle.forSeconds(604_800), "Weekly window")
        XCTAssertEqual(WindowTitle.forSeconds(86_400), "Daily window")
        XCTAssertEqual(WindowTitle.forSeconds(2_592_000), "Monthly window")
    }

    func testDerivedWindows() {
        XCTAssertEqual(WindowTitle.forSeconds(18_000), "5-hour window")
        XCTAssertEqual(WindowTitle.forSeconds(3_600), "1-hour window")
        XCTAssertEqual(WindowTitle.forSeconds(1_800), "30-minute window")
        XCTAssertEqual(WindowTitle.forSeconds(432_000), "5-day window")
    }

    func testMinutesMatchSeconds() {
        XCTAssertEqual(WindowTitle.forMinutes(300), WindowTitle.forSeconds(18_000))
        XCTAssertEqual(WindowTitle.forMinutes(10_080), WindowTitle.forSeconds(604_800))
        XCTAssertEqual(WindowTitle.forMinutes(43_200), WindowTitle.forSeconds(2_592_000))
    }

    func testNonPositiveLengthFallsBack() {
        XCTAssertEqual(WindowTitle.forSeconds(0), "Quota")
        XCTAssertEqual(WindowTitle.forSeconds(-1), "Quota")
    }
}

final class QuotaFormatTests: XCTestCase {
    override func setUp() { L10n.override = .en }
    override func tearDown() { L10n.override = .system }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testCountdown() {
        XCTAssertEqual(QuotaFormat.countdown(to: now.addingTimeInterval(45), from: now), "45s")
        XCTAssertEqual(QuotaFormat.countdown(to: now.addingTimeInterval(600), from: now), "10m")
        XCTAssertEqual(QuotaFormat.countdown(to: now.addingTimeInterval(8_100), from: now), "2h 15m")
        XCTAssertEqual(QuotaFormat.countdown(to: now.addingTimeInterval(180_000), from: now), "2d 2h")
    }

    func testResetLabelReadsAsOnePhrase() {
        // Regression: composing "resets in" + countdown produced
        // "resets in now" / "已重置后重置" once the moment had passed.
        XCTAssertEqual(QuotaFormat.resetLabel(to: now.addingTimeInterval(600), from: now),
                       "resets in 10m")
        XCTAssertEqual(QuotaFormat.resetLabel(to: now.addingTimeInterval(-60), from: now),
                       "reset due")
        XCTAssertEqual(QuotaFormat.resetLabel(to: now, from: now), "reset due")

        L10n.override = .zhHans
        XCTAssertEqual(QuotaFormat.resetLabel(to: now.addingTimeInterval(600), from: now),
                       "10 分钟后重置")
        XCTAssertEqual(QuotaFormat.resetLabel(to: now.addingTimeInterval(-60), from: now),
                       "已到重置时间")
        L10n.override = .en
    }

    func testCountdownInThePast() {
        XCTAssertEqual(QuotaFormat.countdown(to: now.addingTimeInterval(-10), from: now), "now")
        XCTAssertEqual(QuotaFormat.countdown(to: now, from: now), "now")
    }

    func testAge() {
        XCTAssertEqual(QuotaFormat.age(of: now, now: now), "just now")
        XCTAssertEqual(QuotaFormat.age(of: now.addingTimeInterval(-300), now: now), "5m ago")
        XCTAssertEqual(QuotaFormat.age(of: now.addingTimeInterval(-7_200), now: now), "2h ago")
        XCTAssertEqual(QuotaFormat.age(of: now.addingTimeInterval(-172_800), now: now), "2d ago")
    }

    func testAgeNeverGoesNegative() {
        // Clock skew between the provider and the Mac must not read "-1m ago".
        XCTAssertEqual(QuotaFormat.age(of: now.addingTimeInterval(60), now: now), "just now")
    }

    func testPercentDropsTrailingZero() {
        XCTAssertEqual(QuotaFormat.percent(35), "35%")
        XCTAssertEqual(QuotaFormat.percent(35.04), "35%")
        XCTAssertEqual(QuotaFormat.percent(35.25), "35.3%")
    }

    func testMoneyAndCompactCounts() {
        XCTAssertEqual(QuotaFormat.dollars(cents: 1_234), "$12.34")
        XCTAssertEqual(QuotaFormat.usd(8.4), "$8.40")
        XCTAssertEqual(QuotaFormat.usd(4557.331), "$4,557.33", "four figures need grouping")
        XCTAssertEqual(QuotaFormat.usd(0), "$0.00")
        XCTAssertEqual(QuotaFormat.usd(1_234_567.89), "$1,234,567.89")
        XCTAssertEqual(QuotaFormat.compact(999), "999")
        XCTAssertEqual(QuotaFormat.compact(12_400), "12k")
        XCTAssertEqual(QuotaFormat.compact(3_400_000), "3.4M")
        // A month of token usage reaches the billions; stopping at M printed
        // things like "51578.9M".
        XCTAssertEqual(QuotaFormat.compact(51_578_900_000), "51.6B")
        XCTAssertEqual(QuotaFormat.compact(1_000_000_000), "1.0B")
        XCTAssertEqual(QuotaFormat.compact(2_500_000_000_000), "2.5T")
    }
}

final class UsageSnapshotTests: XCTestCase {
    func testHeadlineIsTheMaximumPercent() {
        let snapshot = UsageSnapshot(windows: [
            UsageWindow(title: "a", usedPercent: 10),
            UsageWindow(title: "b", usedPercent: 72),
            UsageWindow(title: "c", detail: "no percent"),
        ])
        XCTAssertEqual(snapshot.headlinePercent, 72)
    }

    func testHeadlineIsNilWithoutAnyPercent() {
        let snapshot = UsageSnapshot(windows: [UsageWindow(title: "balance", detail: "$3.00")])
        XCTAssertNil(snapshot.headlinePercent)
    }

    func testPercentsAreClamped() {
        let snapshot = UsageSnapshot(windows: [
            UsageWindow(title: "over", usedPercent: 140),
            UsageWindow(title: "under", usedPercent: -20),
        ])
        XCTAssertEqual(snapshot.windows[0].usedPercent, 100)
        XCTAssertEqual(snapshot.windows[1].usedPercent, 0)
    }

    func testRepeatedTitlesGetUniqueIDs() {
        let snapshot = UsageSnapshot(windows: [
            UsageWindow(title: "Weekly window", usedPercent: 1),
            UsageWindow(title: "Weekly window", usedPercent: 2),
            UsageWindow(title: "Weekly window", usedPercent: 3),
        ])
        XCTAssertEqual(Set(snapshot.windows.map(\.id)).count, 3)
        XCTAssertEqual(snapshot.windows.map(\.title), Array(repeating: "Weekly window", count: 3))
    }
}

final class L10nTests: XCTestCase {
    override func tearDown() { L10n.override = .system }

    func testExplicitOverrideWins() {
        L10n.override = .zhHans
        XCTAssertEqual(L10n.t("Weekly", "每周"), "每周")
        L10n.override = .en
        XCTAssertEqual(L10n.t("Weekly", "每周"), "Weekly")
    }

    func testLanguageIsCodable() throws {
        let encoded = try JSONEncoder().encode(L10n.Language.zhHans)
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "\"zh-Hans\"")
        XCTAssertEqual(try JSONDecoder().decode(L10n.Language.self, from: encoded), .zhHans)
    }

    func testEveryLanguageHasADisplayName() {
        for language in L10n.Language.allCases {
            XCTAssertFalse(language.displayName.isEmpty)
        }
    }
}

final class ProviderRegistryTests: XCTestCase {
    func testEveryProviderIDResolvesToItsOwnProvider() {
        for id in ProviderID.allCases {
            XCTAssertEqual(ProviderRegistry.make(id).id, id)
        }
    }

    func testRegistryCoversEveryID() {
        XCTAssertEqual(ProviderRegistry.all.count, ProviderID.allCases.count)
    }

    func testEveryProviderHasBrandMetadata() {
        for id in ProviderID.allCases {
            XCTAssertFalse(id.displayName.isEmpty)
            XCTAssertEqual(id.accentHex.count, 6, "\(id) accent must be a 6-digit hex")
            XCTAssertNotNil(id.dashboardURL, "\(id) should link to its console")
            XCTAssertFalse(id.setupHint.isEmpty, "\(id) must tell the user how to connect")
        }
    }

    /// A name that is not a real SF Symbol renders as nothing at all, so the
    /// fallback for a provider with no logo PNG is a blank tile — which is the
    /// exact failure the rest of this test exists to prevent. `braces` shipped
    /// for OpenCode Go and does not exist; the symbol is `curlybraces`.
    func testEverySymbolResolves() {
        for id in ProviderID.allCases {
            XCTAssertNotNil(
                NSImage(systemSymbolName: id.symbolName, accessibilityDescription: nil),
                "\(id): '\(id.symbolName)' is not an SF Symbol")
        }
    }

    /// SF Symbols localises a handful of marks — `textformat` draws the word
    /// "格式" under a Chinese locale. A brand fallback must mean the same thing
    /// in both languages the app ships.
    func testNoSymbolIsLocaleDependent() {
        let localised: Set<String> = ["textformat", "textformat.size", "character", "bold", "italic", "underline"]
        for id in ProviderID.allCases {
            XCTAssertFalse(
                localised.contains(id.symbolName),
                "\(id): '\(id.symbolName)' renders differently per language")
        }
    }

    /// The notch strip, the edge dock and the desktop widget all draw on black,
    /// and the strip paints its figure in the provider's own accent. An accent
    /// dark enough to disappear there should fail here — where whoever picked
    /// it can choose a lighter one — rather than be lifted at draw time, which
    /// would ship a colour nobody chose.
    func testEveryAccentIsLegibleOnTheDarkSurfaces() {
        for id in ProviderID.allCases {
            XCTAssertGreaterThanOrEqual(
                QuotaTheme.contrastOnBlack(hex: id.accentHex), 4.5,
                "\(id): \(id.accentHex) is too dark to read on the black surfaces")
        }
    }

    func testAutomaticProvidersHaveNoCredentialField() {
        // These read an existing CLI session; showing a paste box would be wrong.
        for id in [ProviderID.codex, .claude, .gemini] {
            XCTAssertNil(id.credentialHint, "\(id) should not ask for a pasted secret")
        }
    }
}

final class MeterModeTests: XCTestCase {
    override func setUp() { L10n.override = .en }
    override func tearDown() { L10n.override = .system }

    func testRemainingInvertsTheUsedFigure() {
        XCTAssertEqual(MeterMode.remaining.shownPercent(fromUsed: 0), 100)
        XCTAssertEqual(MeterMode.remaining.shownPercent(fromUsed: 34), 66)
        XCTAssertEqual(MeterMode.remaining.shownPercent(fromUsed: 100), 0)
    }

    func testUsedPassesThrough() {
        XCTAssertEqual(MeterMode.used.shownPercent(fromUsed: 34), 34)
    }

    func testOutOfRangeInputIsClampedBeforeInverting() {
        // A provider reporting 120% must not render as -20% remaining.
        XCTAssertEqual(MeterMode.remaining.shownPercent(fromUsed: 120), 0)
        XCTAssertEqual(MeterMode.remaining.shownPercent(fromUsed: -5), 100)
    }

    func testDefaultsToRemaining() {
        // An almost-empty bar reads as "nothing left"; that should mean the
        // quota is nearly gone, not that it is barely touched.
        XCTAssertEqual(QuotaConfig().meterMode, .remaining)
    }

    func testModeIsPersistedAndBackwardCompatible() throws {
        let encoded = try JSONEncoder().encode(QuotaConfig(meterMode: .used))
        XCTAssertEqual(try JSONDecoder().decode(QuotaConfig.self, from: encoded).meterMode, .used)

        // A config file written before this setting existed.
        let older = Data(#"{"enabled":["codex"],"refreshMinutes":5}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(QuotaConfig.self, from: older).meterMode, .remaining)
    }

    func testEveryModeHasADisplayName() {
        for mode in MeterMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty)
        }
    }
}

final class MenuBarStyleTests: XCTestCase {
    override func setUp() { L10n.override = .en }
    override func tearDown() { L10n.override = .system }

    func testEveryStyleIsNamedInBothLanguages() {
        for style in MenuBarStyle.allCases {
            L10n.override = .en
            XCTAssertFalse(style.displayName.isEmpty, "\(style) has no English name")
            L10n.override = .zhHans
            XCTAssertFalse(style.displayName.isEmpty, "\(style) has no Chinese name")
        }
        L10n.override = .en
    }

    func testSteppedStylesDeclareTheirResolution() {
        XCTAssertEqual(MenuBarStyle.grid.steps, 9)
        XCTAssertEqual(MenuBarStyle.segments.steps, 5)
        XCTAssertEqual(MenuBarStyle.columns.steps, 4)
    }

    func testContinuousStylesDeclareNoSteps() {
        for style in [MenuBarStyle.bar, .ring, .percent, .battery, .gauge, .ticks] {
            XCTAssertNil(style.steps, "\(style) should be continuous")
        }
    }

    func testDefaultSeparatesTheHorizons() {
        // Asserted by property, not by name: the default may change, but it
        // must not collapse the two horizons into one figure.
        XCTAssertTrue(
            QuotaConfig().menuBarStyle.showsBothHorizons,
            "the default must not collapse the horizons")
    }

    func testExactlyTheTwoDualStylesSeparateTheHorizons() {
        let dualStyles: Set<MenuBarStyle> = [.dual, .dualBar]
        for style in MenuBarStyle.allCases {
            XCTAssertEqual(
                style.showsBothHorizons, dualStyles.contains(style),
                "\(style) horizon handling")
        }
    }

    func testDualBarIsContinuousAndDualCellsIsStepped() {
        XCTAssertNil(MenuBarStyle.dualBar.steps, "bars read as a proportion")
        XCTAssertEqual(MenuBarStyle.dual.steps, 5, "cells are countable")
    }

    func testAllStylesRoundTripThroughConfig() throws {
        for style in MenuBarStyle.allCases {
            let encoded = try JSONEncoder().encode(QuotaConfig(menuBarStyle: style))
            XCTAssertEqual(
                try JSONDecoder().decode(QuotaConfig.self, from: encoded).menuBarStyle,
                style)
        }
    }

    func testAnExistingPreferenceIsNotOverriddenByTheNewDefault() throws {
        // Someone who already picked "bar" keeps it; only fresh installs get
        // the new default.
        let existing = Data(#"{"enabled":["codex"],"menuBarStyle":"bar"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(QuotaConfig.self, from: existing).menuBarStyle, .bar)
    }

    func testUnknownStyleFromAFutureVersionFallsBack() throws {
        let future = Data(#"{"enabled":["codex"],"menuBarStyle":"hologram"}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(QuotaConfig.self, from: future).menuBarStyle,
            QuotaConfig().menuBarStyle)
    }
}

final class WindowBadgeTests: XCTestCase {
    override func setUp() { L10n.override = .en }
    override func tearDown() { L10n.override = .system }

    func testShortLabels() {
        XCTAssertEqual(WindowTitle.short(18_000), "5h")
        XCTAssertEqual(WindowTitle.short(604_800), "7d")
        XCTAssertEqual(WindowTitle.short(2_592_000), "30d")
        XCTAssertEqual(WindowTitle.short(3_600), "1h")
        XCTAssertEqual(WindowTitle.short(1_800), "30m")
    }

    func testShortLabelPrefersTheLargerUnit() {
        // 86400s is a day, not "24h".
        XCTAssertEqual(WindowTitle.short(86_400), "1d")
    }

    func testNoBadgeForAnUnknownLength() {
        XCTAssertNil(WindowTitle.short(0))
        XCTAssertNil(WindowTitle.short(-1))
    }

    func testWindowExposesItsBadge() {
        let window = UsageWindow(title: "x", usedPercent: 10, windowSeconds: 604_800)
        XCTAssertEqual(window.shortLabel, "7d")
    }

    func testWindowWithoutALengthHasNoBadge() {
        // Balance and billing-cycle rows have no fixed window.
        XCTAssertNil(UsageWindow(title: "Balance", detail: "$3.00").shortLabel)
    }
}

final class ResetCreditsTests: XCTestCase {
    func testCarriesBothCounts() {
        let credits = ResetCredits(available: 3, applicable: 1)
        XCTAssertEqual(credits.available, 3)
        XCTAssertEqual(credits.applicable, 1)
    }

    func testApplicableIsOptional() {
        XCTAssertNil(ResetCredits(available: 2).applicable)
    }
}

final class MeterReadingTests: XCTestCase {
    private func window(_ percent: Double, seconds: Int?) -> UsageWindow {
        UsageWindow(title: "w", usedPercent: percent, windowSeconds: seconds)
    }

    func testWindowsUnderADayAreShortHorizon() {
        XCTAssertEqual(window(1, seconds: 18_000).horizon, .short)   // 5h
        XCTAssertEqual(window(1, seconds: 3_600).horizon, .short)    // 1h
        XCTAssertEqual(window(1, seconds: 86_399).horizon, .short)
    }

    func testADayOrMoreIsLongHorizon() {
        XCTAssertEqual(window(1, seconds: 86_400).horizon, .long)
        XCTAssertEqual(window(1, seconds: 604_800).horizon, .long)   // 7d
        XCTAssertEqual(window(1, seconds: 2_592_000).horizon, .long) // 30d
    }

    func testWindowsWithoutALengthCountAsLong() {
        // Billing cycles and balances are about running out over a period,
        // not about being throttled in the next few minutes.
        XCTAssertEqual(window(1, seconds: nil).horizon, .long)
    }

    func testTakesTheHighestPerHorizonAcrossProviders() {
        let a = UsageSnapshot(windows: [window(25, seconds: 18_000), window(39, seconds: 604_800)])
        let b = UsageSnapshot(windows: [window(4, seconds: 18_000), window(84, seconds: 2_592_000)])

        let reading = MeterReading.across([a, b])

        XCTAssertEqual(reading.short, 25)
        XCTAssertEqual(reading.long, 84)
    }

    func testHeadlineIsWhicheverHorizonIsCloserToItsLimit() {
        XCTAssertEqual(MeterReading(short: 25, long: 84).headline, 84)
        XCTAssertEqual(MeterReading(short: 90, long: 12).headline, 90)
    }

    func testAPlanWithOnlyOneHorizon() {
        // A Codex Pro account reports a 7-day window and no 5-hour one; the
        // glyph must fall back to a single meter rather than draw an empty row.
        let snapshot = UsageSnapshot(windows: [window(36, seconds: 604_800)])
        let reading = MeterReading.across([snapshot])

        XCTAssertNil(reading.short)
        XCTAssertEqual(reading.long, 36)
        XCTAssertFalse(reading.hasBothHorizons)
        XCTAssertEqual(reading.headline, 36)
    }

    func testWindowsWithoutAPercentAreIgnored() {
        let snapshot = UsageSnapshot(windows: [
            UsageWindow(title: "balance", detail: "$3.00"),
            window(42, seconds: 604_800),
        ])
        let reading = MeterReading.across([snapshot])

        XCTAssertNil(reading.short)
        XCTAssertEqual(reading.long, 42)
    }

    func testNoDataAtAll() {
        let reading = MeterReading.across([])
        XCTAssertNil(reading.headline)
        XCTAssertFalse(reading.hasBothHorizons)
    }
}

final class WindowPaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A 7-day window that resets `hoursLeft` from now, sitting at `used`%.
    private func window(used: Double, hoursLeft: Double, lengthDays: Double = 7) -> UsageWindow {
        UsageWindow(
            title: "w",
            usedPercent: used,
            resetsAt: now.addingTimeInterval(hoursLeft * 3600),
            windowSeconds: Int(lengthDays * 86_400))
    }

    func testEvenConsumptionIsOnPace() throws {
        // Half the window elapsed, half consumed.
        let pace = try XCTUnwrap(window(used: 50, hoursLeft: 84).pace(now: now))

        XCTAssertEqual(pace.expectedPercent, 50, accuracy: 0.5)
        XCTAssertEqual(pace.deltaPercent, 0, accuracy: 0.5)
        XCTAssertFalse(pace.isNotable)
        XCTAssertFalse(pace.willExhaustBeforeReset)
    }

    func testBurningFasterThanTheWindowRefills() throws {
        // A quarter elapsed, three quarters spent.
        let pace = try XCTUnwrap(window(used: 75, hoursLeft: 126).pace(now: now))

        XCTAssertEqual(pace.expectedPercent, 25, accuracy: 0.5)
        XCTAssertGreaterThan(pace.deltaPercent, 45)
        XCTAssertTrue(pace.isNotable)
        XCTAssertTrue(pace.willExhaustBeforeReset, "at this rate it runs out first")
    }

    func testExhaustionIsEquivalentToBeingAheadOfPace() throws {
        // Under a linear projection the two reduce to the same predicate:
        //   (100-used)·elapsed/used < L-elapsed  ⟺  used > 100·elapsed/L
        // Pinned so nobody later treats "will exhaust" as a stricter signal.
        for used in stride(from: 5.0, through: 95.0, by: 5.0) {
            let pace = try XCTUnwrap(window(used: used, hoursLeft: 84).pace(now: now))
            XCTAssertEqual(
                pace.willExhaustBeforeReset, pace.deltaPercent > 0,
                "at \(used)% the two signals disagree")
        }
    }

    func testBehindPaceDoesNotProjectExhaustion() throws {
        // Half the window gone, a quarter spent.
        let pace = try XCTUnwrap(window(used: 25, hoursLeft: 84).pace(now: now))

        XCTAssertLessThan(pace.deltaPercent, 0)
        XCTAssertFalse(pace.willExhaustBeforeReset)
    }

    func testProjectsTheExhaustionMoment() throws {
        // 50% used with half the window left: the other 50% takes as long again.
        let pace = try XCTUnwrap(window(used: 50, hoursLeft: 84).pace(now: now))
        let hours = try XCTUnwrap(pace.secondsToExhaustion) / 3600

        XCTAssertEqual(hours, 84, accuracy: 2)
    }

    func testNothingUsedYieldsNoProjection() throws {
        let pace = try XCTUnwrap(window(used: 0, hoursLeft: 84).pace(now: now))
        XCTAssertNil(pace.secondsToExhaustion)
        XCTAssertFalse(pace.willExhaustBeforeReset)
    }

    func testNoPaceWithoutTheInputsItNeeds() {
        // No length reported (a billing cycle).
        XCTAssertNil(UsageWindow(title: "w", usedPercent: 50,
                                 resetsAt: now.addingTimeInterval(3600)).pace(now: now))
        // No reset time.
        XCTAssertNil(UsageWindow(title: "w", usedPercent: 50,
                                 windowSeconds: 604_800).pace(now: now))
        // No figure.
        XCTAssertNil(UsageWindow(title: "w", resetsAt: now.addingTimeInterval(3600),
                                 windowSeconds: 604_800).pace(now: now))
    }

    func testTooEarlyInTheWindowToJudge() {
        // Thirty seconds in, any rate extrapolates to nonsense.
        XCTAssertNil(window(used: 1, hoursLeft: 7 * 24 - 0.008).pace(now: now))
    }

    func testAResetFurtherOutThanTheWindowIsIgnored() {
        // Provider reported something inconsistent; do not invent a pace.
        XCTAssertNil(window(used: 50, hoursLeft: 200).pace(now: now))
    }

    func testAnAlreadyResetWindowHasNoPace() {
        XCTAssertNil(window(used: 50, hoursLeft: -1).pace(now: now))
    }
}

final class UpdateCheckTests: XCTestCase {
    func testComparesNumerically() {
        XCTAssertTrue(UpdateCheck.compare("0.2.5", isNewerThan: "0.2.4"))
        XCTAssertTrue(UpdateCheck.compare("0.3.0", isNewerThan: "0.2.9"))
        XCTAssertTrue(UpdateCheck.compare("1.0.0", isNewerThan: "0.9.9"))
    }

    func testDoubleDigitComponentsSortAbove() {
        // A string comparison puts "0.2.10" below "0.2.9"; this must not.
        XCTAssertTrue(UpdateCheck.compare("0.2.10", isNewerThan: "0.2.9"))
        XCTAssertFalse(UpdateCheck.compare("0.2.9", isNewerThan: "0.2.10"))
    }

    func testSameVersionIsNotNewer() {
        XCTAssertFalse(UpdateCheck.compare("0.2.4", isNewerThan: "0.2.4"))
    }

    func testOlderIsNotNewer() {
        XCTAssertFalse(UpdateCheck.compare("0.2.3", isNewerThan: "0.2.4"))
    }

    func testMissingComponentsCountAsZero() {
        XCTAssertTrue(UpdateCheck.compare("0.3", isNewerThan: "0.2.9"))
        XCTAssertFalse(UpdateCheck.compare("0.2", isNewerThan: "0.2.0"))
    }

    func testToleratesATagPrefixAndJunk() {
        XCTAssertTrue(UpdateCheck.compare("v0.2.5", isNewerThan: "0.2.4"))
        XCTAssertFalse(UpdateCheck.compare("", isNewerThan: "0.2.4"))
    }
}


final class NotchStripFormattingTests: XCTestCase {
    override func setUp() { L10n.override = .en }
    override func tearDown() { L10n.override = .system }

    /// `countdown` is a localised phrase; the strip needs the compact form in
    /// both languages or the Chinese one truncates mid-number.
    func testTickIsCompactAndLanguageNeutral() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for language in [L10n.Language.en, .zhHans] {
            L10n.override = language
            XCTAssertEqual(QuotaFormat.tick(to: now.addingTimeInterval(2_340), from: now), "39m")
            XCTAssertEqual(QuotaFormat.tick(to: now.addingTimeInterval(8_040), from: now), "2h 14m")
            XCTAssertEqual(QuotaFormat.tick(to: now.addingTimeInterval(493_200), from: now), "5d 17h")
            XCTAssertEqual(QuotaFormat.tick(to: now.addingTimeInterval(45), from: now), "45s")
            XCTAssertEqual(QuotaFormat.tick(to: now.addingTimeInterval(-10), from: now), "0m")
        }
    }

    /// The strip shows one reset time, and it has to be the one belonging to
    /// the figure beside it.
    func testHeadlineWindowIsTheOneBehindTheHeadlinePercent() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = UsageSnapshot(
            windows: [
                UsageWindow(title: "5h", usedPercent: 18, resetsAt: now.addingTimeInterval(600)),
                UsageWindow(title: "7d", usedPercent: 88, resetsAt: now.addingTimeInterval(493_200)),
                UsageWindow(title: "cycle", usedPercent: nil, resetsAt: now),
            ],
            fetchedAt: now)
        XCTAssertEqual(snapshot.headlinePercent, 88)
        XCTAssertEqual(snapshot.headlineWindow?.title, "7d")
    }

    /// The owner's pick stands while the provider reports it; a pick that
    /// is gone, or was never made, means the fullest window.
    func testHeadlineFollowsThePickedWindowWhileItIsReported() {
        let snapshot = UsageSnapshot(windows: [
            UsageWindow(title: "5h", usedPercent: 17),
            UsageWindow(title: "week", usedPercent: 37),
            UsageWindow(title: "Fable · week", usedPercent: 68, scope: "Fable"),
            UsageWindow(title: "credits", detail: "no figure"),
        ])
        XCTAssertEqual(snapshot.headlinePercent(preferring: nil), 68)
        XCTAssertEqual(snapshot.headlinePercent(preferring: "5h"), 17)
        XCTAssertEqual(snapshot.headlineWindow(preferring: "week")?.title, "week")
        XCTAssertEqual(snapshot.headlinePercent(preferring: "gone"), 68)
        XCTAssertEqual(snapshot.headlinePercent(preferring: "credits"), 68, "a window without a figure cannot be the figure")
    }

    func testAPreferredReadingOverridesTheHeadlineOnly() {
        var reading = MeterReading(short: 17, long: 68)
        XCTAssertEqual(reading.headline, 68)
        reading.preferred = 17
        XCTAssertEqual(reading.headline, 17)
        XCTAssertEqual(reading.long, 68, "the two-arc styles keep both horizons")
    }

    func testHeadlineWindowIsNilWithoutAFigure() {
        let snapshot = UsageSnapshot(
            windows: [UsageWindow(title: "cycle", usedPercent: nil)],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(snapshot.headlineWindow)
    }
}
