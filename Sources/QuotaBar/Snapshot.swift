import AppKit
import SwiftUI
import QuotaCore

/// Renders the panel off-screen to a PNG: `QuotaBar --snapshot <dir>`.
///
/// Exists so the layout can be inspected without a Mac in front of you — the
/// app is a menu-bar agent, so there is no window to screenshot in CI, and a
/// broken panel would otherwise only show up when a user clicks the icon.
///
/// Two renderer limitations to keep in mind when reading the output, neither of
/// which reflects how the app behaves on screen:
///
/// - `ScrollView` contents are not laid out, so panels render with
///   `scrollable: false`.
/// - AppKit-backed controls (`.borderless` buttons, `ProgressView`) come out as
///   yellow placeholder glyphs.
///
/// `SettingsView` renders too, via `--settings-preview`. Every `@State` in it
/// is seeded from `init` rather than `onAppear` precisely so that it can:
/// `ImageRenderer` runs outside a SwiftUI update transaction and traps on a
/// change queued from `onAppear`.
@MainActor
enum Snapshot {
    /// Representative data: a healthy provider, one in the alert band, one
    /// serving stale numbers, and one that failed outright.
    private static func sampleStates() -> [ProviderID: ProviderPhase] {
        let now = referenceDate
        return [
            .codex: .loaded(UsageSnapshot(
                planName: "Pro",
                account: "dev@example.com",
                windows: [
                    UsageWindow(
                        title: WindowTitle.forSeconds(604_800),
                        usedPercent: 36,
                        resetsAt: now.addingTimeInterval(524_721),
                        isActive: true,
                        windowSeconds: 604_800),
                    UsageWindow(
                        title: "GPT-5.3-Codex-Spark · \(WindowTitle.forSeconds(18_000))",
                        usedPercent: 4,
                        resetsAt: now.addingTimeInterval(18_000),
                        windowSeconds: 18_000,
                        scope: "GPT-5.3-Codex-Spark"),
                ],
                fetchedAt: now,
                // Deadlines from the real clock: the card lists only those
                // still ahead, and the reference date is long past.
                resetCredits: ResetCredits(available: 3, applicable: 0, totalEarned: 5, credits: [
                    ResetCredit(title: "Full reset (Weekly + 5 hr)", expiresAt: Date().addingTimeInterval(5 * 86_400 + 18 * 3600 + 60)),
                    ResetCredit(title: "Full reset (Weekly + 5 hr)", expiresAt: Date().addingTimeInterval(18 * 86_400 + 23 * 3600 + 60)),
                    ResetCredit(title: "Full reset (Weekly + 5 hr)", expiresAt: Date().addingTimeInterval(19 * 86_400 + 22 * 3600 + 60)),
                ]))),
            .claude: .loaded(UsageSnapshot(
                windows: [
                    UsageWindow(
                        title: WindowTitle.forSeconds(18_000),
                        usedPercent: 18,
                        resetsAt: now.addingTimeInterval(9_000),
                        isActive: true,
                        windowSeconds: 18_000),
                    UsageWindow(
                        title: WindowTitle.forSeconds(604_800),
                        usedPercent: 88,
                        // Well ahead of pace with most of the window left —
                        // the case the pace line exists for.
                        resetsAt: now.addingTimeInterval(400_000),
                        windowSeconds: 604_800),
                    UsageWindow(
                        title: "\(WindowTitle.forSeconds(604_800)) · Fable",
                        usedPercent: 10,
                        resetsAt: now.addingTimeInterval(320_000),
                        windowSeconds: 604_800,
                        scope: "Fable"),
                ],
                fetchedAt: now)),
            .cursor: .stale(UsageSnapshot(
                planName: "Pro",
                windows: [
                    UsageWindow(
                        title: L10n.t("Monthly plan", "月度套餐"),
                        usedPercent: 61,
                        detail: "$12.30 / $20.00",
                        resetsAt: now.addingTimeInterval(900_000)),
                ],
                fetchedAt: now.addingTimeInterval(-4_200)),
                error: ProviderError.unauthorized.errorDescription ?? ""),
            .zai: .failed(ProviderError.notConfigured(hint: ProviderID.zai.setupHint)
                .errorDescription ?? ""),
        ]
    }

    private static func sampleCost() -> CostSummary {
        // A believable 30 days: quiet weekends, a ramp, one spike.
        let shape: [Double] = [
            12, 18, 4, 2, 22, 31, 27, 19, 6, 3,
            24, 38, 44, 29, 15, 5, 2, 33, 41, 52,
            47, 22, 8, 4, 36, 58, 214, 61, 33, 27,
        ]
        let today = Calendar.current.startOfDay(for: referenceDate)
        let daily = shape.enumerated().compactMap { index, usd -> DailyCost? in
            guard let day = Calendar.current.date(
                byAdding: .day, value: index - (shape.count - 1), to: today) else { return nil }
            return DailyCost(day: day, usd: usd, tokens: Int(usd * 260_000))
        }
        let total = shape.reduce(0, +)
        let todayUSD = shape.last ?? 0
        let yesterdayUSD = shape.dropLast().last ?? 0
        func split(_ amount: Double) -> [CostSource: Double] {
            [.claudeCode: amount * 0.63, .codexCLI: amount * 0.35, .openCode: amount * 0.02]
        }
        var summary = CostSummary(
            todayUSD: todayUSD,
            todayTokens: Int(todayUSD * 260_000),
            windowBySource: split(total),
            windowUSD: total,
            windowTokens: Int(total * 260_000),
            daily: daily,
            topModel: "claude-opus-5")
        summary.windowDays = shape.count
        summary.periods = [
            .today: SpendBreakdown(
                usd: todayUSD, tokens: Int(todayUSD * 260_000), bySource: split(todayUSD)),
            .yesterday: SpendBreakdown(
                usd: yesterdayUSD, tokens: Int(yesterdayUSD * 260_000),
                bySource: split(yesterdayUSD)),
            .window: SpendBreakdown(
                usd: total, tokens: Int(total * 260_000), bySource: split(total)),
        ]
        return summary
    }

    /// Snapshots must not shift with the wall clock, so every sample date is
    /// derived from one fixed instant.
    private static let referenceDate = Date(timeIntervalSince1970: 1_787_760_000)

    /// A fresh store per image: `ImageRenderer` runs outside a SwiftUI update
    /// transaction, so mutating a `@Published` between renders traps with
    /// "no current update to enqueue action to".
    private static func makeStore(selected: ProviderID?) -> UsageStore {
        let store = UsageStore.preview(
            enabled: [.codex, .claude, .cursor, .zai],
            states: sampleStates(),
            cost: sampleCost(),
            history: [
                .codex: [8, 11, 14, 14, 19, 23, 22, 27, 31, 36],
                .claude: [4, 9, 9, 13, 12, 15, 17, 16, 18, 18],
            ])
        store.selected = selected
        return store
    }

    /// The island, off-screen: the collapsed strip with its glow at rest and
    /// alerting, then the open panel on each page and in each chart style.
    /// Uses the sample providers and the real preferences otherwise.
    static func islandPreview(directory: String) {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let store = makeStore(selected: nil)
        store.experience.islandGlow = true
        let notch = IslandCoordinator.NotchMetrics(notchWidth: 200, height: 38)
        let shape = UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 14, bottomTrailingRadius: 14, topTrailingRadius: 0, style: .continuous)
        for (name, colour) in [("rest", Palette.cobalt), ("alert", Palette.red)] {
            let strip = ZStack(alignment: .top) {
                IslandGlow(shape: shape, color: colour, ambient: true, sweeping: false, expanded: false)
                shape.fill(Color.black)
                NotchStrip(store: store, metrics: notch, slots: 2)
            }
            .frame(width: notch.totalWidth(slots: 2), height: notch.height)
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
            .environment(\.colorScheme, .dark)
            render(strip, to: url, name: "island-strip-\(name)", backing: Color(hex: "D8D8D8"))
        }
        if let strip = MenuBarIcon.strip([(id: .claude, percent: 63), (id: .codex, percent: 100), (id: .cursor, percent: 7)]),
           let tiff = strip.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:])
        {
            try? png.write(to: url.appendingPathComponent("menubar-strip.png"))
        }
        // The reset moment: the strip with its banner, a row saying it just
        // reset, and the glyph in its refill green.
        let banner = ResetBanner(provider: .claude, name: L10n.t("5-hour", "5 小时"), others: 1, usedBefore: 96, usedNow: 0)
        let bannerWidth = max(notch.totalWidth(slots: 2), 400)
        let resetStrip = ZStack(alignment: .top) {
            IslandGlow(shape: shape, color: banner.provider.accent, ambient: true, sweeping: false, expanded: false)
            shape.fill(Color.black)
            VStack(spacing: 0) {
                NotchStrip(store: store, metrics: notch, slots: 2)
                ResetBannerRow(banner: banner, settled: true)
            }
        }
        .frame(width: bannerWidth, height: notch.height + ResetBannerRow.height)
        .padding(.horizontal, 22)
        .padding(.bottom, 22)
        .environment(\.colorScheme, .dark)
        render(resetStrip, to: url, name: "island-reset-banner", backing: Color(hex: "D8D8D8"))
        if let window = store.states[.claude]?.snapshot?.windows.first {
            store.recentResets["\(ProviderID.claude.rawValue)|\(window.id)"] = Date().addingTimeInterval(600)
            let row = QuotaRowView(store: store, id: .claude, window: window)
                .frame(width: 320)
                .padding(16)
                .background(Color.black)
                .environment(\.colorScheme, .dark)
            render(row, to: url, name: "row-just-reset", backing: .black)
            store.recentResets = [:]
        }
        let callout = ResetCallout(store: store, banner: banner, settled: true)
            .padding(20)
            .background(Color(hex: "1A1D24"))
        render(callout, to: url, name: "dock-reset-callout", backing: Color(hex: "1A1D24"))
        let sweep = ZStack {
            ProviderRing(id: .claude, percent: 0, alerts: store.alertSettings, showsLabel: false)
            ResetSweep(color: ProviderID.claude.accent, diameter: ProviderRing.defaultDiameter)
        }
        .frame(width: 74, height: 74)
        .background(Color.black)
        render(sweep, to: url, name: "dock-reset-ring", backing: .black)

        let bridge = IslandCoordinator.Bridge()
        for page in IslandPanel.Page.allCases {
            for chart in page == .quota ? IslandChartStyle.allCases : [IslandChartStyle.stepped] {
                store.experience.islandChart = chart
                bridge.page = page
                let size = NSSize(
                    width: IslandPanelLayout.width(notchWidth: notch.notchWidth),
                    height: IslandPanelLayout.height(rows: 2, notch: notch.height))
                let panel = ZStack(alignment: .top) {
                    IslandGlow(shape: shape, color: Palette.cobalt, ambient: true, sweeping: false, expanded: true)
                    shape.fill(Color.black)
                    IslandPanel(store: store, notch: notch, bridge: bridge)
                }
                .frame(width: size.width, height: size.height)
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
                .environment(\.colorScheme, .dark)
                render(panel, to: url, name: "island-\(page)-\(chart.rawValue)", backing: Color(hex: "D8D8D8"))
            }
        }
    }

    /// Renders every menu-bar style across a range of levels, so a style can
    /// be judged on whether its gradations are actually readable rather than
    /// on how it sounds.
    static func iconPreview(directory: String) {
        let base = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let levels: [Double] = [0, 12, 25, 40, 50, 63, 75, 88, 100]
        L10n.override = .zhHans

        let sheet = VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                Text("").frame(width: 74, alignment: .leading)
                ForEach(levels, id: \.self) { level in
                    Text("\(Int(level))%")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 40)
                }
            }
            ForEach(MenuBarStyle.allCases) { style in
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(style.displayName)
                            .font(.system(size: 11, weight: .semibold))
                        if let steps = style.steps {
                            Text("\(steps) 格")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("连续")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 74, alignment: .leading)
                    ForEach(levels, id: \.self) { level in
                        // `.used` so the fill matches the printed figure.
                        Image(nsImage: MenuBarIcon.render(
                            percent: level, style: style, mode: .used))
                            .frame(width: 40, height: 22)
                    }
                }
            }
        }
        .padding(16)

        render(sheet, to: base, name: "icon-styles", backing: Color(hex: "F5F5F5"))

        // Alert states across levels — this is where an empty meter and a full
        // one can end up looking the same.
        let alertSheet = VStack(alignment: .leading, spacing: 10) {
            ForEach([AlertLevel.none, .warning, .critical], id: \.rawValue) { level in
                HStack(spacing: 0) {
                    Text(level.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 60, alignment: .leading)
                    ForEach([0.0, 25.0, 50.0, 75.0, 100.0], id: \.self) { used in
                        VStack(spacing: 2) {
                            Image(nsImage: MenuBarIcon.render(
                                percent: used, style: .grid, level: level, mode: .remaining))
                                .frame(width: 44, height: 22)
                            Text("用\(Int(used))%")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text("mode=remaining：用 100% ⇒ 剩 0% ⇒ 应该 0 格亮")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        render(alertSheet, to: base, name: "icon-alerts", backing: Color(hex: "F5F5F5"))

        // Glanceability comparison: can you read the proportion without
        // consciously counting?
        let compareLevels: [Double] = [0, 20, 40, 60, 80, 100]
        let compare = VStack(alignment: .leading, spacing: 14) {
            Text("同一组「已用」百分比，两种样式对比")
                .font(.system(size: 11, weight: .semibold))
            ForEach([MenuBarStyle.grid, .segments, .ticks, .bar], id: \.rawValue) { style in
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(style.displayName)
                            .font(.system(size: 11, weight: .semibold))
                        Text(style.steps.map { "\($0) 格" } ?? "连续")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 70, alignment: .leading)
                    ForEach(compareLevels, id: \.self) { used in
                        VStack(spacing: 3) {
                            Image(nsImage: MenuBarIcon.render(
                                percent: used, style: style, mode: .used))
                                .frame(width: 46, height: 22)
                            Text("\(Int(used))%")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text("mode=used：填充越多＝用得越多")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        render(compare, to: base, name: "icon-compare", backing: Color(hex: "F5F5F5"))

        // Dual glyph: both horizons, and the single-horizon fallback.
        let cases: [(String, MeterReading)] = [
            ("短5 长39", MeterReading(short: 5, long: 39)),
            ("短25 长39", MeterReading(short: 25, long: 39)),
            ("短80 长20", MeterReading(short: 80, long: 20)),
            ("短10 长95", MeterReading(short: 10, long: 95)),
            ("短100 长100", MeterReading(short: 100, long: 100)),
            ("仅长39 (Pro)", MeterReading(long: 39)),
            ("仅长100", MeterReading(long: 100)),
            ("无数据", MeterReading()),
        ]
        let dualSheet = VStack(alignment: .leading, spacing: 12) {
            Text("双层：上＝短窗口(5h/滚动)　下＝长窗口(7d/30d/账单周期)")
                .font(.system(size: 11, weight: .semibold))
            ForEach([MenuBarStyle.dualBar, .dual], id: \.rawValue) { style in
                HStack(spacing: 0) {
                    Text(style.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 72, alignment: .leading)
                    ForEach(cases, id: \.0) { label, reading in
                        VStack(spacing: 3) {
                            Image(nsImage: MenuBarIcon.render(
                                reading: reading, style: style, mode: .used))
                                .frame(width: 52, height: 24)
                            Text(label)
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text("已用口径 · 只有一个窗口时收敛成单行居中，而不是画一行空的")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        render(dualSheet, to: base, name: "icon-dual", backing: Color(hex: "F5F5F5"))

        // The Settings picker itself. `SettingsView` as a whole cannot be
        // rendered (it assigns @State from onAppear), but this component can.
        let picker = MenuBarStylePicker(selection: .grid, mode: .remaining, onSelect: { _ in })
            .frame(width: 420)
            .padding(16)
        render(picker, to: base, name: "icon-picker", backing: Color(hex: "F5F5F5"))
        render(
            picker.environment(\.colorScheme, .dark),
            to: base,
            name: "icon-picker-dark",
            backing: Color(hex: "1E1E1E"))
        L10n.override = ConfigStore.shared.language
        FileHandle.standardOutput.write(Data("Wrote icon sheet to \(base.path)\n".utf8))
    }

    /// Renders the settings window section by section: `--settings-preview <dir>`.
    ///
    /// Glass and vibrancy do not survive `ImageRenderer` — the flat stand-in is
    /// what comes out. Read this for spacing, alignment and truncation; judge
    /// the material on screen.
    /// A release as the update card would show it, for previews.
    static var sampleRelease: UpdateRelease {
        let notes = """
        ### 2026-09-14

        #### Added

        - The menu bar icon's right-click menu is redone, with Show in Menu Bar, Check for Updates, Feedback and About.
        - Provider cards in the panel can be dragged into a new order.

        #### Style

        - Each Settings section's title and its explanation share one line.

        #### Fixed

        - With automatic update checks turned off, Check now did nothing.

        ---

        ### 2026-09-14

        #### 新增

        - 菜单栏图标的右键菜单重做：显示在菜单栏、检查更新、反馈、关于。
        - 下拉面板里的服务商卡片可以按住拖动排序。

        #### 样式

        - 设置窗口右侧每个分区的标题和说明文字改为同一行显示。

        #### 修复

        - 关闭自动检查更新后，「立即检查」点了没有反应。
        """
        return UpdateRelease(
            version: "0.5.4", downloadURL: URL(string: "https://quota.bar/download/QuotaBar-0.5.4.zip")!,
            pageURL: URL(string: "https://quota.bar/changelog.html")!, notes: notes, publishedAt: Date())
    }

    static func settingsPreview(directory: String) {
        let base = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let store = makeStore(selected: nil)
        for language in [L10n.Language.en, .zhHans] {
            L10n.override = language
            let suffix = language == .en ? "en" : "zh"
            for section in SettingsSection.allCases {
                for dark in [false, true] {
                    write(
                        SettingsView(store: store, scrollable: false, section: section),
                        to: base,
                        name: "settings-\(section.rawValue)-\(suffix)\(dark ? "-dark" : "")",
                        dark: dark)
                }
            }
        }

        // One provider expanded, which is the only state that shows the
        // credential field, the action row and the label column together.
        // One open provider row on its own — the whole pane clips at the
        // top — for the header's quick actions and the label column's
        // baselines. Codex has no action row; Cursor keeps one. Both get a
        // status reading, so the service-status row is drawn too.
        for id in [ProviderID.codex, .cursor] {
            store.serviceStatus[id] = ServiceStatus(
                level: .operational,
                description: "CLI, VS Code extension, Codex API, Codex Web",
                pageURL: URL(string: "https://status.openai.com")!,
                checkedAt: Date())
        }
        for language in [L10n.Language.zhHans, .en] {
            L10n.override = language
            let suffix = language == .en ? "en" : "zh"
            for id in [ProviderID.codex, .cursor] {
                write(
                    ProviderSettingsRow(store: store, id: id, isExpanded: true, onToggle: {})
                        .frame(width: 620)
                        .padding(Design.space4),
                    to: base,
                    name: "settings-row-expanded-\(id.rawValue)-\(suffix)",
                    dark: false)
            }
        }
        // The Alerts page in full — the window's height clips it — for the
        // spend card at its foot.
        for language in [L10n.Language.zhHans, .en] {
            L10n.override = language
            write(
                VStack(alignment: .leading, spacing: Design.space3) { AlertsPane(store: store) }
                    .environment(\.glassDisabled, true)
                    .frame(width: 620)
                    .padding(Design.space4),
                to: base,
                name: "settings-alerts-full-\(language == .en ? "en" : "zh")",
                dark: false)
        }

        // Quota Run, on sample data and with no key or network: the records
        // alone, the sign-in card over an empty ledger, the code waiting for
        // the browser, a signed-in page, one project open for editing, and a
        // best as the copied image.
        for language in [L10n.Language.zhHans, .en] {
            L10n.override = language
            let suffix = language == .en ? "en" : "zh"
            let records = RunCenter.preview(.records, now: referenceDate)
            let signIn = RunCenter.preview(.signIn, now: referenceDate)
            let signingIn = RunCenter.preview(.signingIn, now: referenceDate)
            let member = RunCenter.preview(.signedIn, now: referenceDate)
            write(runPane(RunRecordsCard(store: store, run: records, now: referenceDate)), to: base, name: "settings-run-records-\(suffix)")
            write(runPane(RunPane(store: store, run: signIn, now: referenceDate)), to: base, name: "settings-run-signin-\(suffix)")
            write(runPane(RunSignInCard(run: signingIn, now: referenceDate)), to: base, name: "settings-run-waiting-\(suffix)")
            write(runPane(RunPane(store: store, run: member, now: referenceDate)), to: base, name: "settings-run-signedin-\(suffix)")
            write(runPane(RunPane(store: store, run: member, now: referenceDate)), to: base, name: "settings-run-signedin-\(suffix)-dark", dark: true)
            if let account = member.account {
                write(runPane(RunProjectsCard(run: member, account: account, editing: 1)), to: base, name: "settings-run-project-editor-\(suffix)")
            }
            // Every provider account standing, including an account id
            // rather than an email and one unbound on this Mac.
            let standings = RunCenter.preview(.signedIn, now: referenceDate)
            standings.previewEveryStanding()
            if let account = standings.account {
                write(
                    runPane(RunProviderAccountsCard(run: standings, account: account, accounts: standings.localAccounts)),
                    to: base, name: "settings-run-provider-accounts-\(suffix)")
            }
            if let best = records.bests.first {
                render(RunShare.card(best, store: store), to: base, name: "run-share-card-\(suffix)", backing: .black)
            }
        }

        for language in [L10n.Language.zhHans, .en] {
            L10n.override = language
            write(
                ResetCalendarCard(store: store, now: referenceDate)
                    .environment(\.glassDisabled, true)
                    .frame(width: 620)
                    .padding(Design.space4),
                to: base,
                name: "usage-resets-\(language == .en ? "en" : "zh")",
                dark: false)
        }

        // The update card: found, and downloaded and verified.
        let sample = Self.sampleRelease
        for language in [L10n.Language.zhHans, .en] {
            L10n.override = language
            let suffix = language == .en ? "en" : "zh"
            for (name, stage) in [("available", Updater.Stage.available(sample)), ("ready", .readyToInstall(sample))] {
                store.updateStage = stage
                write(UpdateCard(store: store, scrollable: false), to: base, name: "update-\(name)-\(suffix)", dark: false)
            }
        }
        store.updateStage = .idle

        L10n.override = ConfigStore.shared.language
        FileHandle.standardOutput.write(Data("Wrote settings preview to \(base.path)\n".utf8))
    }

    /// A settings pane on its own, at the detail column's width.
    private static func runPane(_ content: some View) -> some View {
        VStack(alignment: .leading, spacing: Design.space3) { content }
            .environment(\.glassDisabled, true)
            .frame(width: 612)
            .padding(Design.space4)
    }

    static func run(directory: String) {
        let base = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        // The menu panel as it opens, in both languages. It is dark whatever
        // the system appearance, so there is no second pass for dark mode.
        for language in [L10n.Language.en, .zhHans] {
            L10n.override = language
            write(
                MenuPanelView(store: makeStore(selected: nil), scrollable: false),
                to: base,
                name: "panel-\(language == .en ? "en" : "zh")",
                dark: true)
        }
        L10n.override = ConfigStore.shared.language

        // The usage ramp itself. The handle sheet above samples 0/15/25/50/
        // 75/90/100, which steps straight over the slope — this walks it.
        L10n.override = .zhHans
        let rampSheet = VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                ForEach(Array(stride(from: 30.0, through: 100.0, by: 2.5)), id: \.self) { used in
                    Rectangle()
                        .fill(Color(hex: UsageRamp.hex(used: used)))
                        .frame(width: 16, height: 46)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            HStack(spacing: 0) {
                ForEach([30, 40, 50, 60, 70, 80, 90, 100], id: \.self) { used in
                    VStack(spacing: 3) {
                        Circle()
                            .fill(Color(hex: UsageRamp.hex(used: Double(used))))
                            .frame(width: 26, height: 26)
                        Text("\(used)%")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.7))
                        Text(UsageRamp.hex(used: Double(used)))
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .frame(width: 71)
                }
            }
            Text("用量色标 · 50% 以下与 90% 以上是平的 · 亮度全程递减")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(16)
        render(rampSheet, to: base, name: "usage-ramp", backing: Color(hex: "000000"))

        // Notch strip: the collapsed island on a notched Mac. Rendered against
        // a fake notch, since the CI runner has no display at all.
        L10n.override = .zhHans
        let notchStore = makeStore(selected: nil)
        let notch = IslandCoordinator.NotchMetrics(notchWidth: 190, height: 38)
        let stripSheet = VStack(alignment: .leading, spacing: 10) {
            NotchStrip(store: notchStore, metrics: notch)
            Text("刘海条 · 数字在外侧、logo 贴着刘海，两边镜像")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(16)
        render(stripSheet, to: base, name: "island-notch", backing: Color(hex: "3A3A3C"))

        // Edge dock: the strip and one callout, on a dark ground since both
        // are always dark regardless of appearance.
        L10n.override = .zhHans
        let store = makeStore(selected: nil)
        let dockSheet = HStack(alignment: .top, spacing: 12) {
            ProviderCallout(store: store, id: .claude)
            VStack(spacing: Design.space3) {
                ForEach(store.enabled) { id in
                    ProviderRing(
                        id: id,
                        percent: store.headlinePercent(for: id),
                        alerts: store.alertSettings,
                        // Claude marked: a single click in the dock picks which
                        // provider the menu-bar glyph reports, and the mark is
                        // the only thing that says which one that is.
                        selected: id == .claude)
                }
            }
            .padding(.vertical, Design.space4)
            .frame(width: 74)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: Design.radiusPanel + 6,
                    bottomLeadingRadius: Design.radiusPanel + 6,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0,
                    style: .continuous)
                    .fill(Color.black))
        }
        .padding(20)
        .environment(\.colorScheme, .dark)
        render(dockSheet, to: base, name: "edge-dock", backing: Color(hex: "3A4A5A"))

        // The collapsed handle across levels — this is what sits at the screen
        // edge most of the time, so its scale has to be readable on its own.
        let handleSheet = HStack(spacing: 22) {
            ForEach([0.0, 15.0, 25.0, 50.0, 75.0, 90.0, 100.0], id: \.self) { used in
                VStack(spacing: 6) {
                    DockHandle(
                        fraction: CGFloat(MeterMode.remaining.shownPercent(fromUsed: used) / 100),
                        tint: Color(hex: UsageRamp.hex(used: used)),
                        onLeft: false)
                        // The dock draws this black itself; the handle no
                        // longer carries its own, so the sheet supplies it.
                        .background(EdgeDockView.dockShape(onLeft: false).fill(Color.black))
                    Text("用\(Int(used))%")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        render(handleSheet, to: base, name: "dock-handle", backing: Color(hex: "3A4A5A"))

        // Desktop widget at each density.
        for density in WidgetDensity.allCases {
            let sample = makeStore(selected: nil)
            let card = DesktopWidgetView(store: sample, density: density, providers: sample.enabled)
                .padding(24)
            render(card, to: base, name: "widget-\(density.rawValue)",
                   backing: Color(hex: "2E3B4E"))
        }
        L10n.override = ConfigStore.shared.language

        writeMenuBarIcons(to: base)
        FileHandle.standardOutput.write(Data("Wrote snapshots to \(base.path)\n".utf8))
    }

    /// `QuotaBar --projects-preview [dir]`: the Projects pane over this Mac's
    /// real logs of the last 90 days, off-screen, in both languages. Reads the
    /// logs; writes only the PNGs.
    static func projectsPreview(directory: String) {
        let base = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let now = Date()
        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: now) ?? now
        let scan = CostEstimator.archiveScan(since: cutoff, now: now)
        var archive = ProjectArchive()
        archive.merge(scan.projects, infos: scan.projectRefs, scannedAt: now, full: true)
        let store = makeStore(selected: nil)
        store.projectArchive = archive
        for language in [L10n.Language.zhHans, .en] {
            L10n.override = language
            let suffix = language == .en ? "en" : "zh"
            write(SettingsView(store: store, scrollable: false, section: .projects), to: base, name: "settings-projects-\(suffix)")
        }
        L10n.override = ConfigStore.shared.language
        FileHandle.standardOutput.write(Data("Wrote the projects pane to \(base.path)\n".utf8))
    }

    private static func write(
        _ view: some View,
        to directory: URL,
        name: String,
        dark: Bool = false)
    {
        guard !dark else {
            // Adaptive colours resolve against the drawing appearance, which
            // ImageRenderer does not inherit from the SwiftUI environment.
            NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
                render(
                    view.environment(\.colorScheme, .dark),
                    to: directory,
                    name: name,
                    backing: Color(hex: "1E1E1E"))
            }
            return
        }
        render(view, to: directory, name: name, backing: Color(hex: "ECECEC"))
    }

    private static func render(
        _ view: some View,
        to directory: URL,
        name: String,
        backing: Color)
    {
        // The panel normally sits on the menu-bar window's material. The
        // backing is passed in rather than read from `.windowBackgroundColor`,
        // which resolves outside the dark drawing scope and comes out light.
        let framed = view
            .frame(alignment: .top)
            .background(backing)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("Failed to render \(name)\n".utf8))
            return
        }
        try? png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private static func writeMenuBarIcons(to directory: URL) {
        // 34% used — so "remaining" reads 66% and the two modes are obviously
        // different at a glance.
        for style in MenuBarStyle.allCases {
            for mode in MeterMode.allCases {
                let image = MenuBarIcon.render(percent: 34, style: style, mode: mode)
                guard let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:])
                else { continue }
                try? png.write(to: directory
                    .appendingPathComponent("menubar-\(style.rawValue)-\(mode.rawValue).png"))
            }
            // At 3x for the website's menu-bar replica, with the same readings
            // its island shows (Claude: 5-hour 18%, week 58%). Drawn from the
            // glyph's own vector closure, so it is sharp rather than upscaled.
            let glyph = MenuBarIcon.render(reading: MeterReading(short: 18, long: 58), style: style, mode: .remaining)
            let scale: CGFloat = 3
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(glyph.size.width * scale), pixelsHigh: Int(glyph.size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { continue }
            rep.size = glyph.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            glyph.draw(in: NSRect(origin: .zero, size: glyph.size))
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("glyph-\(style.rawValue)@3x.png"))
        }
    }
}
