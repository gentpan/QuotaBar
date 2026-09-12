import AppKit
import SwiftUI
import QuotaCore

struct MenuContentView: View {
    @ObservedObject var store: UsageStore
    /// Retained for the snapshot tool, which cannot lay out a `ScrollView`.
    /// The panel itself no longer scrolls.
    var scrollable: Bool = false

    var body: some View {
        MenuContentBody(store: store, scrollable: scrollable)
            .padding(Design.space3)
            .frame(width: 380)
            // Refuse vertical compression. Two things depend on it: the VStack
            // stops overlapping its own children when the window is too short —
            // which is how the footer came to be drawn on top of the last quota
            // row — and the measurement below becomes the height the content
            // *wants* rather than the height it was squeezed into. Without it
            // the two are circular: the window constrains the content, the
            // content reports the constrained size, and the resize is a no-op.
            .fixedSize(horizontal: false, vertical: true)
            .tint(Design.accent)
            // Always dark, like the dock, the island and the widget. The
            // environment covers what SwiftUI draws; `PanelAppearance` covers
            // the window AppKit draws around it.
            .environment(\.colorScheme, .dark)
            // An opaque backing, resolved in the same appearance as the text
            // on top of it. Without one the panel sits directly on the menu
            // bar window's vibrancy material, whose appearance does not always
            // match the one the content resolves in — light material under
            // dark-mode content renders the whole panel washed-out grey.
            .background(Design.panelSurface)
            .background(PanelAppearance())
    }
}

/// Shared panel content, reused by the menu-bar popover and the notch island.
struct MenuContentBody: View {
    @ObservedObject var store: UsageStore
    /// The menu-bar panel sizes itself to its content. Only the notch island,
    /// which lives in a fixed-size floating panel, scrolls.
    var scrollable: Bool = false

    /// As many columns as keeps the rows even: the overview plus four
    /// providers is one row of five; six tiles are 3 + 3; all eleven are
    /// 4 + 4 + 4. A fixed four columns left one tile alone on a second row
    /// as soon as a fourth provider was enabled.
    private var columns: [GridItem] {
        let count = GridLayout.balancedColumns(count: store.enabled.count + 1)
        return Array(repeating: GridItem(.flexible(), spacing: Design.space2), count: count)
    }

    var body: some View {
        // space4 between sections: the panel sizes itself to its content, so
        // room here costs nothing but height, and the tighter setting read as
        // cramped.
        VStack(spacing: Design.space4) {
            providerGrid
            Divider()
            if scrollable {
                ScrollView {
                    detailSection
                }
            } else {
                // No cap — a clipped panel with a scrollbar hides the numbers
                // the app exists to show — but a floor, so switching between a
                // provider with two windows and one with four does not resize
                // the whole panel out from under the pointer.
                detailSection
                    .frame(maxWidth: .infinity, minHeight: 210, alignment: .top)
            }
            updateBanner
            Divider()
            footer
        }
    }

    // MARK: Grid switcher

    private var providerGrid: some View {
        LazyVGrid(columns: columns, spacing: Design.space3) {
            gridCell(
                title: L10n.t("Overview", "总览"),
                logoID: nil,
                accent: .secondary,
                percent: nil,
                warn: !store.failingProviders.isEmpty,
                isSelected: store.selected == nil)
            {
                store.selected = nil
            }
            ForEach(store.enabled) { id in
                gridCell(
                    title: id.displayName,
                    logoID: id,
                    accent: Color(hex: id.accentHex),
                    percent: store.headlinePercent(for: id),
                    warn: store.states[id]?.errorMessage != nil,
                    isSelected: store.selected == id)
                {
                    store.selected = id
                }
            }
        }
    }

    private func gridCell(
        title: String,
        logoID: ProviderID?,
        accent: Color,
        percent: Double?,
        warn: Bool,
        isSelected: Bool,
        action: @escaping () -> Void) -> some View
    {
        Button(action: action) {
            VStack(spacing: Design.space1) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let logoID {
                            ProviderGlyph(id: logoID, size: 17, ink: isSelected)
                        } else {
                            Image(systemName: "square.grid.2x2")
                                .font(.system(size: 15, weight: .semibold))
                        }
                    }
                    .frame(height: 18)
                    if warn {
                        Circle()
                            .fill(Design.panelWarning)
                            .frame(width: 5, height: 5)
                            .offset(x: 5, y: -2)
                    }
                }
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                MiniMeter(percent: percent, accent: isSelected ? Design.ink : accent)
            }
            .padding(.vertical, Design.space2)
            .padding(.horizontal, Design.space1)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Design.radiusTile, style: .continuous)
                    .fill(isSelected ? Design.accent : Design.surfaceStrong))
            .foregroundStyle(isSelected ? Design.ink : Color.primary)
        }
        .buttonStyle(TileButtonStyle())
        .accessibilityLabel(percent.map { "\(title) \(QuotaFormat.percent($0))" } ?? title)
    }

    // MARK: Detail

    @ViewBuilder
    private var detailSection: some View {
        if let selected = store.selected {
            ProviderDetailView(store: store, id: selected)
        } else {
            overviewRows
        }
    }

    private var overviewRows: some View {
        VStack(spacing: Design.space3) {
            if store.cost.hasData {
                CostCard(cost: store.cost)
            } else if store.isComputingCost {
                HStack(spacing: Design.space2) {
                    ProgressView().controlSize(.small)
                    Text(L10n.t(
                        "Reading local session logs…",
                        "正在读取本地会话日志…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .quotaCard()
            }
            if store.enabled.isEmpty {
                VStack(spacing: Design.space2) {
                    Text(L10n.t("No providers enabled.", "尚未启用任何服务商。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button(L10n.t("Open Settings", "打开设置")) {
                        SettingsWindow.open()
                    }
                        .controlSize(.small)
                }
                .padding(.top, Design.space6)
            }
            ForEach(store.enabled) { id in
                OverviewRow(store: store, id: id)
            }
        }
        .padding(.horizontal, 2)
    }

    // MARK: Footer

    @ViewBuilder
    private var updateBanner: some View {
        switch store.updateStage {
        case .idle, .checking:
            EmptyView()
        case let .available(release):
            if store.updateIsManagedByHomebrew {
                // Replacing the bundle would desync Homebrew's metadata and
                // the next `brew upgrade` would fight us.
                banner(
                    icon: "arrow.down.circle",
                    text: L10n.t(
                        "Version \(release.version) is available — run brew upgrade",
                        "有新版本 \(release.version) —— 请运行 brew upgrade"),
                    action: { NSWorkspace.shared.open(release.pageURL) },
                    trailing: nil)
            } else {
                banner(
                    icon: "arrow.down.circle.fill",
                    text: L10n.t(
                        "Version \(release.version) is available",
                        "有新版本 \(release.version)"),
                    action: { store.downloadUpdate() },
                    trailing: L10n.t("Download", "下载"))
            }
        case .downloading:
            HStack(spacing: Design.space2) {
                ProgressView().controlSize(.small)
                Text(L10n.t("Downloading and verifying…", "正在下载并校验…"))
                    .font(.caption)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, Design.space2 + 2)
            .padding(.vertical, Design.space2)
            .background(
                RoundedRectangle(cornerRadius: Design.radiusTile, style: .continuous)
                    .fill(Design.surfaceStrong))
        case let .readyToInstall(release):
            banner(
                icon: "checkmark.circle.fill",
                text: L10n.t(
                    "\(release.version) verified — restart to install",
                    "\(release.version) 已校验 —— 重启以安装"),
                action: { store.installUpdate() },
                trailing: L10n.t("Restart", "重启"))
        case let .failed(message):
            HStack(alignment: .top, spacing: Design.space2) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .foregroundStyle(Design.panelWarning)
            .padding(.horizontal, Design.space2 + 2)
            .padding(.vertical, Design.space2)
            .background(
                RoundedRectangle(cornerRadius: Design.radiusTile, style: .continuous)
                    .fill(Design.panelWarning.opacity(0.12)))
        }
    }

    private func banner(
        icon: String,
        text: String,
        action: @escaping () -> Void,
        trailing: String?) -> some View
    {
        Button(action: action) {
            HStack(spacing: Design.space2) {
                Image(systemName: icon)
                Text(text)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: Design.space2)
                if let trailing {
                    Text(trailing)
                        .font(.caption.weight(.semibold))
                } else {
                    Image(systemName: "arrow.up.right").font(.caption2)
                }
            }
            .foregroundStyle(Design.accent)
            .padding(.horizontal, Design.space2 + 2)
            .padding(.vertical, Design.space2)
            .background(
                RoundedRectangle(cornerRadius: Design.radiusTile, style: .continuous)
                    .fill(Design.surfaceStrong))
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: Design.space3) {
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.t("Every \(store.refreshMinutes)m", "每 \(store.refreshMinutes) 分钟刷新"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !store.failingProviders.isEmpty {
                    let names = store.failingProviders.map(\.displayName).joined(separator: ", ")
                    Label(
                        L10n.t("\(names) not updating", "\(names) 未能更新"),
                        systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(Design.panelWarning)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                store.refreshAll()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(L10n.t("Refresh now", "立即刷新"))
            Button {
                SettingsWindow.open()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help(L10n.t("Settings", "设置"))
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help(L10n.t("Quit QuotaBar", "退出 QuotaBar"))
        }
    }
}

// MARK: - Overview row

struct OverviewRow: View {
    @ObservedObject var store: UsageStore
    let id: ProviderID

    var body: some View {
        HStack(spacing: Design.space2 + 2) {
            ProviderGlyph(id: id, size: 16)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Design.space1 + 2) {
                    Text(id.displayName)
                        .font(.callout.weight(.medium))
                    if store.states[id]?.errorMessage != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(Design.panelWarning)
                            .help(store.states[id]?.errorMessage ?? "")
                    }
                    Spacer()
                    trailing
                }
                if let percent = store.headlinePercent(for: id) {
                    MiniMeter(percent: percent, accent: Color(hex: id.accentHex))
                }
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch store.states[id] {
        case .loading, nil:
            ProgressView().controlSize(.small)
        case let .loaded(snapshot), let .stale(snapshot, _):
            if let percent = store.headlinePercent(for: id) ?? snapshot.headlinePercent {
                Text(QuotaFormat.percent(percent))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(
                        store.alertSettings.level(for: percent).hex.map { Color(hex: $0) }
                            ?? Color(hex: id.accentHex))
            } else if let first = snapshot.windows.first, let detail = first.detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        case let .failed(message):
            Text(message)
                .font(.caption)
                .foregroundStyle(Design.panelWarning)
                .lineLimit(1)
                .help(message)
        }
    }
}

// MARK: - Cost card

struct CostCard: View {
    let cost: CostSummary
    /// Which period the donut and legend describe. Local to the card — the
    /// panel is transient, and a remembered tab would be one more thing whose
    /// state the user has to notice.
    @State private var period: SpendPeriod = .window
    /// How many days the chart shows. 30 keeps each bar wide enough to read
    /// inside a 380pt panel.
    private let chartDays = 30

    private var spend: SpendBreakdown { cost.spend(period) }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.space3) {
            header
            periodPicker
            if spend.contributions.isEmpty {
                Text(L10n.t("Nothing recorded for this period.", "该时段没有记录。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Design.space2)
            } else {
                SpendDonut(spend: spend)
            }
            if period == .window, days.contains(where: { $0.usd > 0 }) {
                DailyBarChart(days: days, peak: cost.peakDay)
            }
            footnote
        }
        .quotaCard()
    }

    private var days: [DailyCost] {
        cost.recentDays(chartDays)
    }

    private var header: some View {
        HStack(spacing: Design.space2) {
            Text(L10n.t("Total spend", "总用量"))
                .font(.callout.weight(.semibold))
            Spacer()
            Text(L10n.t(
                "\(QuotaFormat.compact(spend.tokens)) tokens",
                "\(QuotaFormat.compact(spend.tokens)) tokens"))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var periodPicker: some View {
        Picker("", selection: $period) {
            ForEach(SpendPeriod.allCases) { option in
                Text(option.displayName(windowDays: cost.windowDays)).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: Footnote

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let model = cost.topModel {
                Text(L10n.t("Most spend on \(model)", "花费最多的模型：\(model)"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(disclaimer)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Says plainly which figures are ours and which the tool reported, since
    /// the donut mixes both.
    private var disclaimer: String {
        guard spend.containsEstimates else {
            return L10n.t("Reported by each tool", "由各工具自行记录")
        }
        return L10n.t(
            "Estimated from local logs at list prices — not a bill",
            "按官方标价从本地日志估算，非账单")
    }
}

/// Spend split by source, as a ring with the total in the middle.
///
/// A ring rather than a stacked bar: with three or four sources the parts are
/// easier to compare as angles than as segments of a thin bar, and the middle
/// is free space for the total.
struct SpendDonut: View {
    let spend: SpendBreakdown
    var size: CGFloat = 74

    private var slices: [(source: CostSource, usd: Double, start: Double, end: Double)] {
        let total = spend.usd
        guard total > 0 else { return [] }
        var cursor = 0.0
        return spend.contributions.map { item in
            let fraction = item.usd / total
            let slice = (item.source, item.usd, cursor, cursor + fraction)
            cursor += fraction
            return slice
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: Design.space3) {
            ring
            legend
            Spacer(minLength: 0)
        }
    }

    private var ring: some View {
        ZStack {
            ForEach(slices, id: \.source) { slice in
                Circle()
                    .trim(from: slice.start, to: slice.end)
                    .stroke(
                        Color(hex: slice.source.accentHex),
                        style: StrokeStyle(lineWidth: 10, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 0) {
                Text(QuotaFormat.usdCompact(spend.usd))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
        }
        .frame(width: size, height: size)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: Design.space1 + 2) {
            ForEach(spend.contributions, id: \.source) { item in
                HStack(spacing: Design.space2) {
                    Circle()
                        .fill(Color(hex: item.source.accentHex))
                        .frame(width: 8, height: 8)
                    Text(item.source.displayName)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: Design.space3)
                    Text(QuotaFormat.usd(item.usd))
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                }
            }
        }
    }
}

/// Per-day spend as bars on a shared scale, with the peak called out.
///
/// The scale is the window's own maximum rather than a fixed ceiling: unlike a
/// quota percentage, spend has no natural upper bound to normalise against.
struct DailyBarChart: View {
    let days: [DailyCost]
    var peak: DailyCost?
    var height: CGFloat = 44

    /// Chooses a ceiling that keeps ordinary days readable without lying about
    /// the peak.
    ///
    /// Scaling to the maximum lets one runaway session flatten the other days
    /// into 1pt stubs; scaling to the runner-up makes the spike and the
    /// second-busiest day render identically. So: use the true maximum while
    /// it is within 2x of the runner-up, and cap at 2x beyond that.
    private var scaleUSD: Double {
        let sorted = days.map(\.usd).sorted(by: >)
        guard let highest = sorted.first, highest > 0 else { return 0.0001 }
        guard sorted.count > 1, sorted[1] > 0 else { return highest }
        return min(highest, sorted[1] * 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.space1) {
            if let peak, peak.usd > 0 {
                HStack(spacing: Design.space1) {
                    Spacer(minLength: 0)
                    Text(L10n.t(
                        "peak \(QuotaFormat.usd(peak.usd)) on \(QuotaFormat.shortDay(peak.day))",
                        "峰值 \(QuotaFormat.usd(peak.usd)) · \(QuotaFormat.shortDay(peak.day))"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            GeometryReader { proxy in
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(days) { day in
                        bar(for: day, in: proxy.size.height)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: height)
            axis
        }
    }

    private func bar(for day: DailyCost, in available: CGFloat) -> some View {
        let ratio = day.usd / scaleUSD
        let isPeak = day.day == peak?.day && day.usd > 0
        return RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(isPeak ? Design.accent : Design.accent.opacity(0.45))
            // An idle day keeps a 1pt stub so the axis stays legible and the
            // gap is visibly a gap, not a missing bar.
            .frame(height: max(1, available * CGFloat(min(ratio, 1))))
            .frame(maxWidth: .infinity)
            .help("\(QuotaFormat.shortDay(day.day)) · \(QuotaFormat.usd(day.usd))")
    }

    @ViewBuilder
    private var axis: some View {
        if let first = days.first, let last = days.last {
            HStack {
                Text(QuotaFormat.shortDay(first.day))
                Spacer()
                Text(QuotaFormat.shortDay(last.day))
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
    }
}

// MARK: - Detail

struct ProviderDetailView: View {
    @ObservedObject var store: UsageStore
    let id: ProviderID

    var body: some View {
        VStack(alignment: .leading, spacing: Design.space3) {
            switch store.states[id] {
            case .loading, nil:
                HStack {
                    Spacer()
                    ProgressView(L10n.t("Fetching \(id.displayName)…", "正在获取 \(id.displayName)…"))
                        .padding(.top, Design.space6)
                    Spacer()
                }
            case let .loaded(snapshot):
                content(snapshot, error: nil)
            case let .stale(snapshot, error):
                content(snapshot, error: error)
            case let .failed(message):
                FailureView(store: store, id: id, message: message)
            }
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private func content(_ snapshot: UsageSnapshot, error: String?) -> some View {
        header(snapshot)
        if let error {
            StaleBanner(message: error, fetchedAt: snapshot.fetchedAt) { store.refresh(id) }
        }
        SparklineView(
            values: store.history[id] ?? [],
            accent: Color(hex: id.accentHex))
        if snapshot.windows.isEmpty {
            Text(L10n.t("No quota windows reported.", "服务商未返回任何额度窗口。"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        ForEach(snapshot.windows) { window in
            WindowRow(
                window: window,
                accent: Color(hex: id.accentHex),
                alerts: store.alertSettings)
        }
        if let credits = snapshot.resetCredits {
            Divider()
            ResetCreditsRow(credits: credits, accent: Color(hex: id.accentHex))
        }
        if error == nil {
            Text(L10n.t(
                "Updated \(QuotaFormat.age(of: snapshot.fetchedAt))",
                "更新于 \(QuotaFormat.age(of: snapshot.fetchedAt))"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func header(_ snapshot: UsageSnapshot) -> some View {
        HStack(spacing: Design.space2) {
            ProviderGlyph(id: id, size: 18)
            Text(id.displayName)
                .font(.title3.weight(.semibold))
            if let plan = snapshot.planName {
                Text(plan)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color(hex: id.accentHex).opacity(0.18)))
                    .foregroundStyle(Color(hex: id.accentHex))
            }
            if let status = store.serviceStatus[id] {
                ServiceStatusBadge(status: status)
            }
            Spacer()
            if let account = snapshot.account {
                Text(account)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(account)
            }
        }
    }
}

/// Shown when the newest numbers on screen came from an earlier, successful
/// refresh — the panel must never present stale data as current.
struct StaleBanner: View {
    let message: String
    let fetchedAt: Date
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Design.space2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Design.panelWarning)
            VStack(alignment: .leading, spacing: 2) {
                // No space before 的: the Chinese age string already ends in 前.
                Text(L10n.t(
                    "Showing data from \(QuotaFormat.age(of: fetchedAt))",
                    "当前显示 \(QuotaFormat.age(of: fetchedAt))的数据"))
                    .font(.caption.weight(.medium))
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(L10n.t("Retry", "重试"), action: retry)
                .glassAction(compact: true)
        }
        .padding(Design.space2 + 2)
        .background(
            RoundedRectangle(cornerRadius: Design.radiusTile, style: .continuous)
                .fill(Design.panelWarning.opacity(0.12)))
    }
}

struct FailureView: View {
    @ObservedObject var store: UsageStore
    let id: ProviderID
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: Design.space2 + 2) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(Design.panelWarning)
                .fixedSize(horizontal: false, vertical: true)
            // `notConfigured` already quotes the setup hint; repeating it here
            // printed the same sentence twice.
            if !message.contains(id.setupHint) {
                Text(id.setupHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Design.space2) {
                if id == .claude, store.claudeNeedsAuthorization {
                    // The one button that may raise the keychain dialog.
                    Button(L10n.t("Allow keychain access", "授权钥匙串访问")) { store.authorizeClaude() }
                        .glassAction(prominent: true, compact: true)
                }
                Button(L10n.t("Retry", "重试")) { store.refresh(id) }
                    .glassAction(compact: true)
                Button(L10n.t("Settings", "设置")) {
                    SettingsWindow.open()
                }
                    .glassAction(compact: true)
                if let url = id.dashboardURL {
                    Button(L10n.t("Console", "控制台")) { NSWorkspace.shared.open(url) }
                        .glassAction(compact: true)
                }
            }
        }
        .padding(.top, Design.space2)
    }
}

// MARK: - Small components

/// Snappy press feedback for grid tiles.
struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct MiniMeter: View {
    let percent: Double?
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Design.track)
                if let percent, percent > 0 {
                    // No minimum stub at zero: a 4pt dot next to "0%" reads as
                    // a stray mark, and the track alone already says "empty".
                    Capsule()
                        .fill(accent)
                        .frame(width: max(3, proxy.size.width * CGFloat(percent / 100)))
                }
            }
        }
        .frame(height: 3)
    }
}

/// Mini trend line of recorded headline readings (0–100% scale).
struct SparklineView: View {
    let values: [Double]
    let accent: Color
    var height: CGFloat = 26

    var body: some View {
        if values.count > 1 {
            VStack(alignment: .leading, spacing: 3) {
                GeometryReader { proxy in
                    // Fixed 0–100 scale: an auto-scaled axis would make 3% look
                    // as dramatic as 90%, which is the opposite of useful here.
                    // The plot area is drawn so the headroom above a low line
                    // reads as "plenty left", not as a layout gap.
                    // Line only, no area fill. A series pinned at 100% — which
                    // is exactly what an exhausted quota looks like — fills the
                    // whole plot and stops reading as a trend at all.
                    line(in: proxy.size).stroke(
                        accent.opacity(0.9),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
                .frame(height: height)
                .padding(.horizontal, 1)
                .background(
                    RoundedRectangle(cornerRadius: Design.radiusTile - 2, style: .continuous)
                        .fill(Design.track.opacity(0.35)))
                HStack(spacing: Design.space1) {
                    Text(L10n.t(
                        "trend · last \(values.count) refreshes",
                        "趋势 · 最近 \(values.count) 次刷新"))
                    if let last = values.last, let peak = values.max(), peak > last {
                        Text(L10n.t("· peak \(QuotaFormat.percent(peak))",
                                    "· 峰值 \(QuotaFormat.percent(peak))"))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func point(_ index: Int, in size: CGSize) -> CGPoint {
        let stepX = size.width / CGFloat(values.count - 1)
        let clamped = min(max(values[index], 0), 100)
        return CGPoint(x: CGFloat(index) * stepX, y: size.height * (1 - CGFloat(clamped / 100)))
    }

    private func line(in size: CGSize) -> Path {
        Path { path in
            for index in values.indices {
                let next = point(index, in: size)
                if index == 0 { path.move(to: next) } else { path.addLine(to: next) }
            }
        }
    }

}

/// One quota window: a length badge, a meter, the figure, and when it resets.
///
/// The badge carries the window length ("5h", "7d") so the row scans without
/// reading a sentence — several providers report two or three windows and the
/// difference between them is the only thing that distinguishes the rows.
struct WindowRow: View {
    let window: UsageWindow
    let accent: Color
    var alerts: AlertSettings = AlertSettings()

    /// Matches the colour the Overview list gives the same number — two
    /// different colours for one reading reads as a bug.
    private var tint: Color {
        guard let percent = window.usedPercent,
              let hex = alerts.level(for: percent).hex else { return accent }
        return Color(hex: hex)
    }

    var body: some View {
        HStack(alignment: .top, spacing: Design.space2) {
            badge
            VStack(alignment: .leading, spacing: 4) {
                headline
                if let percent = window.usedPercent {
                    ProgressView(value: min(max(percent, 0), 100), total: 100)
                        .progressViewStyle(.linear)
                        .tint(tint)
                }
                secondary
            }
        }
    }

    // MARK: Badge

    @ViewBuilder
    private var badge: some View {
        if let label = window.shortLabel {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(accent)
                .frame(minWidth: 30)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: Design.radiusTile - 2, style: .continuous)
                        .fill(accent.opacity(0.14)))
        } else {
            // Balance rows and billing cycles have no fixed length; keep the
            // meters aligned with the badged rows above them.
            Color.clear.frame(width: 30, height: 1)
        }
    }

    // MARK: Rows

    private var headline: some View {
        HStack(spacing: Design.space1 + 2) {
            // Only labelled when the window is scoped to something. An
            // account-wide window needs no caption — repeating "whole account"
            // on every row is filler, and the badge already says what it is.
            if let caption {
                Text(caption)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
            if window.isActive {
                Text(L10n.t("active", "生效中"))
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(accent.opacity(0.18)))
                    .foregroundStyle(accent)
            }
            Spacer(minLength: Design.space2)
            if let percent = window.usedPercent {
                Text(QuotaFormat.percent(percent))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
        }
    }

    /// The badge already carries the length, so the text beside it names what
    /// the window is scoped to and does not repeat "7-day window". nil when
    /// there is nothing to add.
    private var caption: String? {
        if let scope = window.scope, !scope.isEmpty { return scope }
        // No badge means no length was reported — fall back to the full title
        // so balance and billing-cycle rows still say what they are.
        return window.shortLabel == nil ? window.title : nil
    }

    @ViewBuilder
    private var secondary: some View {
        if window.detail != nil || window.resetsAt != nil {
            HStack {
                if let detail = window.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let resetsAt = window.resetsAt {
                    Text(QuotaFormat.resetLabel(to: resetsAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        // Only when the rate says something the percentage does not: a window
        // at 60% is fine three days in and alarming three hours in.
        if let pace = window.pace(), let label = QuotaFormat.paceLabel(pace) {
            HStack(spacing: Design.space1) {
                Image(systemName: pace.willExhaustBeforeReset
                    ? "exclamationmark.triangle.fill" : "checkmark.circle")
                Text(label)
            }
            .font(.caption2)
            .foregroundStyle(pace.willExhaustBeforeReset ? Design.panelWarning : .secondary)
        }
    }
}

/// Early-reset credits, when the plan grants them.
struct ResetCreditsRow: View {
    let credits: ResetCredits
    let accent: Color

    var body: some View {
        HStack(spacing: Design.space2) {
            Image(systemName: "arrow.clockwise.circle")
                .foregroundStyle(accent)
            Text(L10n.t("Early resets", "限额重置额度"))
                .font(.callout.weight(.medium))
            Spacer()
            Text(L10n.t(
                "\(credits.available) available",
                "\(credits.available) 次可用"))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(accent)
        }
        .help(L10n.t(
            "Credits that reset a rate-limit window early. \(credits.applicable ?? 0) apply to the window limiting you right now.",
            "可提前重置限额窗口的次数。当前正在限流的窗口可用 \(credits.applicable ?? 0) 次。"))
    }
}
