import Foundation

// MARK: - Display and behaviour preferences added in 0.5

/// Reset labels as a countdown ("3 小时 25 分后重置") or a clock time
/// ("今天 18:38 重置"). Clicking a reset label flips it everywhere.
public enum ResetTimeFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case countdown
    case exact

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .countdown: L10n.t("Countdown", "倒计时")
        case .exact: L10n.t("Exact time", "具体时间")
        }
    }
}

/// 12- or 24-hour clock for exact reset times; automatic follows the system.
public enum ClockStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case twelveHour
    case twentyFourHour

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: L10n.t("Automatic", "自动")
        case .twelveHour: L10n.t("12-hour", "12 小时制")
        case .twentyFourHour: L10n.t("24-hour", "24 小时制")
        }
    }
}

/// How a bar warns. The whole bar takes the usage colour, or — after
/// codex-island — the bar keeps the brand colour and only the figure turns
/// amber past 70% and red past 90%.
public enum UrgencyStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case bar
    case figure
    /// After openusage: the bar's colour is a verdict on the pace — green on
    /// course, amber cutting it close, red running out before the reset.
    case pace

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bar: L10n.t("By usage", "按用量变色")
        case .figure: L10n.t("Figure only", "只让数字变色")
        case .pace: L10n.t("By pace", "按节奏变色")
        }
    }
}

/// Which tokens a token count counts. All includes cache reads and writes —
/// what the CLIs report and what ccusage counts; billable is fresh input plus
/// output, closer to what claude.ai's own usage page shows.
public enum TokenCounting: String, Codable, CaseIterable, Identifiable, Sendable {
    case all
    case billable

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: L10n.t("All tokens", "全部 token")
        case .billable: L10n.t("Input + output", "仅输入和输出")
        }
    }
}

/// Row spacing in the menu panel.
public enum PanelDensity: String, Codable, CaseIterable, Identifiable, Sendable {
    case regular
    case compact

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .regular: L10n.t("Regular", "标准")
        case .compact: L10n.t("Compact", "紧凑")
        }
    }
}

/// What the spend card's ring measures.
public enum SpendMetric: String, Codable, CaseIterable, Identifiable, Sendable {
    case cost
    case tokens
    case costPerMillion

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .cost: L10n.t("Cost", "花费")
        case .tokens: L10n.t("Tokens", "Token")
        case .costPerMillion: L10n.t("Cost / MTok", "每百万 token 花费")
        }
    }
}

/// How the island's panel draws a quota window, after codex-island's five.
public enum IslandChartStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case bar
    case ring
    case stepped
    case numeric
    case spark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bar: L10n.t("Bar", "条形")
        case .ring: L10n.t("Ring", "圆环")
        case .stepped: L10n.t("Stepped", "阶梯")
        case .numeric: L10n.t("Numeric", "数字")
        case .spark: L10n.t("Sparkline", "趋势线")
        }
    }

    public var next: IslandChartStyle {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }
}

/// The three pace notifications, after openusage. All off by default.
public struct PaceAlertPrefs: Codable, Equatable, Sendable {
    /// Under 10% left, windows without a reset included.
    public var almostOut: Bool
    /// Projected to finish the window with less than 10% left.
    public var cuttingClose: Bool
    /// Projected to run out before the window resets.
    public var willRunOut: Bool

    public init(almostOut: Bool = false, cuttingClose: Bool = false, willRunOut: Bool = false) {
        self.almostOut = almostOut
        self.cuttingClose = cuttingClose
        self.willRunOut = willRunOut
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        almostOut = (try? container.decodeIfPresent(Bool.self, forKey: .almostOut)) ?? false
        cuttingClose = (try? container.decodeIfPresent(Bool.self, forKey: .cuttingClose)) ?? false
        willRunOut = (try? container.decodeIfPresent(Bool.self, forKey: .willRunOut)) ?? false
    }
}

/// The places a provider's figures are shown. Hiding a provider from one keeps
/// it enabled — read, alerted on and counted — just not drawn there.
public enum DisplaySurface: String, Codable, CaseIterable, Sendable, Identifiable {
    case panel
    case dock
    case island
    case desktop

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .panel: L10n.t("Panel", "下拉面板")
        case .dock: L10n.t("Dock", "停靠条")
        case .island: L10n.t("Island", "刘海岛")
        case .desktop: L10n.t("Desktop", "桌面卡片")
        }
    }
}

/// A global shortcut: a Carbon virtual key code and Carbon modifier mask.
public struct Hotkey: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    /// What the recorder showed, e.g. "⌃⌥Q", so the field can say it back
    /// without a keyboard-layout lookup.
    public var display: String

    public init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }
}

/// Everything 0.5 added to the preferences, kept in one object so the config
/// file gains a single key and an older build ignores it wholesale. Every
/// field decodes on its own, like the rest of the file: one value this build
/// does not recognise must not reset the others.
public struct ExperiencePrefs: Codable, Equatable, Sendable {
    // Figures
    public var resetTimeFormat: ResetTimeFormat = .countdown
    public var clockStyle: ClockStyle = .automatic
    /// Pace tick and "~35% left at reset" on every bar, not only the ones
    /// that are close to or over their limit.
    public var alwaysShowPace: Bool = false
    public var urgencyStyle: UrgencyStyle = .bar
    public var tokenCounting: TokenCounting = .all
    /// ISO 4217 code costs are shown in. Prices stay in dollars underneath.
    public var currency: String = "USD"

    // Menu panel
    public var panelDensity: PanelDensity = .regular
    public var showSpendCard: Bool = true
    /// openusage's Increase Transparency: the panel lets the desktop through.
    public var panelTranslucent: Bool = false
    public var spendMetric: SpendMetric = .cost
    /// Provider cards whose "more" section is open, by provider id.
    public var expandedCards: [String] = []
    public var welcomeDismissed: Bool = false
    /// Set once the first launch has matched providers to installed tools.
    public var providersDetected: Bool = false

    // Motion and glow
    public var reduceMotion: Bool = false
    public var islandGlow: Bool = true
    /// Glow and sweep only while refreshing, hovered or alerting.
    public var lowPowerGlow: Bool = false
    /// The island opens for a few seconds when a window crosses its warning.
    public var islandAutoPeek: Bool = true
    public var islandChart: IslandChartStyle = .stepped
    /// The desktop card lists the provider closest to its limit first.
    public var widgetSortsByUrgency: Bool = false
    /// The cards on the desktop. Empty until the first 0.5 launch fills it.
    public var deskCards: [DeskCard] = []
    public var deskCardsMigrated: Bool = false

    // Privacy and system
    public var hideWhenSharing: Bool = false
    public var hotkey: Hotkey?
    public var paceAlerts: PaceAlertPrefs = PaceAlertPrefs()
    /// The reset moment: the island's banner, the menu-bar glyph refilling,
    /// "just reset" on the rows.
    public var resetEffects: Bool = true
    /// Whether a reset also raises a system notification.
    public var resetNotify: ResetNotifyMode = .afterHeavyUse
    /// A notification when a provider gives the account an early reset, and
    /// a day before one runs out unspent.
    public var resetCreditNotify: Bool = true
    /// The run-out reminders already sent, by `ResetCreditNotice.key`.
    public var resetCreditNotified: [String] = []
    /// Providers hidden per surface, by raw value: still enabled, still read,
    /// only not shown there.
    public var hiddenProviders: [String: [String]] = [:]
    /// Provider raw value → the ids of the windows its card shows before it
    /// is expanded, where the owner chose them from the card's menu. Absent
    /// means the card's own choice (`UsageSnapshot.upFrontWindows`).
    public var cardWindows: [String: [String]] = [:]
    /// Provider raw value → the ids of the windows the owner hid from the
    /// card's menu: not on the card, not under its arrow, not followed by the
    /// ring anywhere. Still read, cached and served by the local API.
    public var hiddenWindows: [String: [String]] = [:]
    /// Spend limits per day and per month, and the crossings already notified.
    public var spendBudget: SpendBudget = SpendBudget()
    public var budgetNotified: [String] = []
    /// A notification each Monday morning with last week's spend.
    public var weeklyDigest: Bool = true
    /// The week (`2026-W37`) whose digest was last sent.
    public var weeklyDigestSent: String = ""
    /// Serve 127.0.0.1:6736/v1/limits for other local tools.
    public var localAPI: Bool = false
    /// "http://host:port" or "socks5://host:port"; empty = direct.
    public var proxy: String = ""
    public var betaUpdates: Bool = false

    // Sharing
    public var shareSignature: String = ""
    public var shareShowsSignature: Bool = false
    /// A card copied as an image shows the signed-in account as a mosaic
    /// rather than the address. On unless turned off: the image is made to
    /// be posted, and the address is the one thing on it nobody meant to.
    public var shareMasksAccount: Bool = true
    /// The app version the weekly card last opened itself for.
    public var shareCardShownForVersion: String = ""

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case resetTimeFormat, clockStyle, alwaysShowPace, urgencyStyle, tokenCounting, currency
        case panelDensity, showSpendCard, panelTranslucent, spendMetric, expandedCards, welcomeDismissed, providersDetected
        case reduceMotion, islandGlow, lowPowerGlow, islandAutoPeek, islandChart, widgetSortsByUrgency
        case deskCards, deskCardsMigrated
        case hideWhenSharing, hotkey, paceAlerts, localAPI, proxy, betaUpdates
        case resetEffects, resetNotify, resetCreditNotify, resetCreditNotified, hiddenProviders, cardWindows, hiddenWindows
        case spendBudget, budgetNotified, weeklyDigest, weeklyDigestSent
        case shareSignature, shareShowsSignature, shareMasksAccount, shareCardShownForVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ExperiencePrefs()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        func choice<T: RawRepresentable & Decodable>(_ key: CodingKeys, _ fallback: T) -> T where T.RawValue == String {
            guard let raw = try? c.decodeIfPresent(String.self, forKey: key), let parsed = T(rawValue: raw)
            else { return fallback }
            return parsed
        }
        resetTimeFormat = choice(.resetTimeFormat, d.resetTimeFormat)
        clockStyle = choice(.clockStyle, d.clockStyle)
        alwaysShowPace = value(.alwaysShowPace, d.alwaysShowPace)
        urgencyStyle = choice(.urgencyStyle, d.urgencyStyle)
        tokenCounting = choice(.tokenCounting, d.tokenCounting)
        let code = value(.currency, d.currency).uppercased()
        currency = code.count == 3 && code.allSatisfy(\.isLetter) ? code : d.currency
        panelDensity = choice(.panelDensity, d.panelDensity)
        showSpendCard = value(.showSpendCard, d.showSpendCard)
        panelTranslucent = value(.panelTranslucent, d.panelTranslucent)
        spendMetric = choice(.spendMetric, d.spendMetric)
        expandedCards = value(.expandedCards, d.expandedCards)
        welcomeDismissed = value(.welcomeDismissed, d.welcomeDismissed)
        providersDetected = value(.providersDetected, d.providersDetected)
        reduceMotion = value(.reduceMotion, d.reduceMotion)
        islandGlow = value(.islandGlow, d.islandGlow)
        lowPowerGlow = value(.lowPowerGlow, d.lowPowerGlow)
        islandAutoPeek = value(.islandAutoPeek, d.islandAutoPeek)
        islandChart = choice(.islandChart, d.islandChart)
        widgetSortsByUrgency = value(.widgetSortsByUrgency, d.widgetSortsByUrgency)
        deskCards = value(.deskCards, d.deskCards)
        deskCardsMigrated = value(.deskCardsMigrated, d.deskCardsMigrated)
        hideWhenSharing = value(.hideWhenSharing, d.hideWhenSharing)
        hotkey = try? c.decodeIfPresent(Hotkey.self, forKey: .hotkey)
        paceAlerts = value(.paceAlerts, d.paceAlerts)
        resetEffects = value(.resetEffects, d.resetEffects)
        resetNotify = choice(.resetNotify, d.resetNotify)
        resetCreditNotify = value(.resetCreditNotify, d.resetCreditNotify)
        resetCreditNotified = value(.resetCreditNotified, d.resetCreditNotified)
        hiddenProviders = value(.hiddenProviders, d.hiddenProviders)
        cardWindows = value(.cardWindows, d.cardWindows)
        hiddenWindows = value(.hiddenWindows, d.hiddenWindows)
        spendBudget = value(.spendBudget, d.spendBudget)
        budgetNotified = value(.budgetNotified, d.budgetNotified)
        weeklyDigest = value(.weeklyDigest, d.weeklyDigest)
        weeklyDigestSent = value(.weeklyDigestSent, d.weeklyDigestSent)
        localAPI = value(.localAPI, d.localAPI)
        proxy = value(.proxy, d.proxy)
        betaUpdates = value(.betaUpdates, d.betaUpdates)
        shareSignature = value(.shareSignature, d.shareSignature)
        shareShowsSignature = value(.shareShowsSignature, d.shareShowsSignature)
        shareMasksAccount = value(.shareMasksAccount, d.shareMasksAccount)
        shareCardShownForVersion = value(.shareCardShownForVersion, d.shareCardShownForVersion)
    }
}

extension ExperiencePrefs {
    public func isHidden(_ id: ProviderID, on surface: DisplaySurface) -> Bool {
        hiddenProviders[surface.rawValue]?.contains(id.rawValue) ?? false
    }

    public mutating func setHidden(_ hidden: Bool, _ id: ProviderID, on surface: DisplaySurface) {
        var list = hiddenProviders[surface.rawValue] ?? []
        list.removeAll { $0 == id.rawValue }
        if hidden { list.append(id.rawValue) }
        hiddenProviders[surface.rawValue] = list.isEmpty ? nil : list
    }

    /// `ids` in order, without the ones hidden from `surface`.
    public func visible(_ ids: [ProviderID], on surface: DisplaySurface) -> [ProviderID] {
        let hidden = Set(hiddenProviders[surface.rawValue] ?? [])
        return ids.filter { !hidden.contains($0.rawValue) }
    }
}

// MARK: - Pace verdict

/// openusage's reading of a window's pace: where the current burn rate lands
/// at reset, and what that means for the bar.
public enum PaceVerdict: String, Sendable, Equatable {
    /// On course to finish with at least 10% to spare.
    case ahead
    /// Projected to land inside the last 10%, with at least 1% to spare.
    case close
    /// Projected to run out before the reset, or to finish with nothing left.
    case over
    /// Nothing left now, whatever the rate.
    case spent
}

extension WindowPace {
    /// Where usage lands at reset if it keeps going at the current rate.
    public var projectedPercent: Double {
        guard expectedPercent > 0 else { return actualPercent }
        return actualPercent / (expectedPercent / 100)
    }

    /// How long the window has run, from how far through it is and how long
    /// is left.
    public var elapsedSeconds: Double {
        let fraction = expectedPercent / 100
        guard fraction < 1 else { return .infinity }
        return secondsToReset * fraction / (1 - fraction)
    }

    /// Enough of the window has passed for its average rate to mean
    /// something: at least 5% of it and at least a quarter of an hour. Three
    /// minutes into a 5-hour window, 3% used projects to 300% — true of the
    /// arithmetic, useless as a forecast.
    public var isSettled: Bool {
        expectedPercent >= 5 && elapsedSeconds >= 900
    }

    /// The pace verdict. Nothing used yet has no rate to project, and a
    /// window too young to have a rate is left alone.
    public var verdict: PaceVerdict? {
        if actualPercent >= 99.5 { return .spent }
        guard actualPercent > 0, isSettled else { return nil }
        let projected = projectedPercent
        if projected <= 90 { return .ahead }
        // "~0% spare" is not a cushion: a projection that lands on the limit
        // is over, so an amber bar always has at least 1% to offer.
        if projected <= 99 { return .close }
        return .over
    }

    /// The even-pace position as a fraction of the bar, for the tick.
    public var tickFraction: Double { min(max(expectedPercent / 100, 0), 1) }

    /// Seconds until the window runs out, only when that lands before reset.
    public var runOutSeconds: Double? {
        guard isSettled, let secondsToExhaustion, secondsToExhaustion < secondsToReset else { return nil }
        return secondsToExhaustion
    }
}
