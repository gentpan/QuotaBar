import SwiftUI
import QuotaCore

// MARK: - The island, opened

/// Fixed metrics for the expanded island, so the coordinator can size the
/// panel before SwiftUI has laid anything out. After codex-island: 24pt
/// insets, a header the height of the notch, 96pt tiles, a 44pt footer.
enum IslandPanelLayout {
    static let horizontalInset: CGFloat = 24
    static let columnWidth: CGFloat = 300
    /// Between the columns on a screen with no notch to keep them apart.
    static let columnGap: CGFloat = 24
    static let rowHeight: CGFloat = 128
    static let rowGap: CGFloat = 12
    static let bodyPadding: CGFloat = 12
    static let footerHeight: CGFloat = 44
    static let tileHeight: CGFloat = 96

    static func headerHeight(notch: CGFloat) -> CGFloat { max(32, notch) }

    static func width(notchWidth: CGFloat?) -> CGFloat {
        columnWidth * 2 + (notchWidth ?? columnGap) + horizontalInset * 2
    }

    static func height(rows: Int, notch: CGFloat) -> CGFloat {
        let rows = max(1, rows)
        return headerHeight(notch: notch)
            + bodyPadding * 2 + CGFloat(rows) * rowHeight + CGFloat(rows - 1) * rowGap
            + footerHeight
    }
}

/// Two columns either side of the notch, one provider per row: its name and
/// plan, then a tile per horizon — label, the figure in the alert colour, a
/// stepped bar in the brand colour, the reset under it. The header carries
/// the wordmark and the sync state; the footer the settings gear, the
/// bar-style chip and the same sync state, as in the reference.
struct IslandPanel: View {
    @ObservedObject var store: UsageStore
    let notch: IslandCoordinator.NotchMetrics?
    /// 额度 shows the quota tiles; 用量 shows what each provider consumed,
    /// from the local logs where there are any — the footer chip flips it.
    @State private var page: Page = .quota

    enum Page {
        case quota
        case usage

        var label: String {
            switch self {
            case .quota: L10n.t("Quota", "额度")
            case .usage: L10n.t("Usage", "用量")
            }
        }
    }

    /// Left takes the first `slots` enabled providers, right the next.
    private var left: [ProviderID] { Array(store.islandProviders.prefix(store.islandSlots)) }
    private var right: [ProviderID] {
        Array(store.islandProviders.dropFirst(store.islandSlots).prefix(store.islandSlots))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: IslandPanelLayout.headerHeight(notch: notch?.height ?? 0))
            HStack(alignment: .top, spacing: 0) {
                column(left)
                    .frame(width: IslandPanelLayout.columnWidth, alignment: .topLeading)
                Color.clear.frame(width: notch?.notchWidth ?? IslandPanelLayout.columnGap)
                column(right)
                    .frame(width: IslandPanelLayout.columnWidth, alignment: .topLeading)
            }
            .padding(.vertical, IslandPanelLayout.bodyPadding)
            footer
                .frame(height: IslandPanelLayout.footerHeight)
        }
        .padding(.horizontal, IslandPanelLayout.horizontalInset)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 0) {
            Text("QuotaBar")
                .font(Design.wordmark(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: IslandPanelLayout.columnWidth, alignment: .leading)
            Color.clear.frame(width: notch?.notchWidth ?? IslandPanelLayout.columnGap)
            IslandSyncStatus(store: store)
                .frame(width: IslandPanelLayout.columnWidth, alignment: .trailing)
        }
    }

    // MARK: Columns

    @ViewBuilder
    private func column(_ ids: [ProviderID]) -> some View {
        VStack(alignment: .leading, spacing: IslandPanelLayout.rowGap) {
            if ids.isEmpty {
                Text(L10n.t("Enable more providers in Settings.", "在设置里启用更多服务商。"))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(height: IslandPanelLayout.rowHeight, alignment: .center)
                    .frame(maxWidth: .infinity)
            }
            ForEach(ids) { id in
                IslandProviderBlock(store: store, id: id, page: page)
                    .frame(height: IslandPanelLayout.rowHeight, alignment: .top)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [.clear, .white.opacity(0.06), .white.opacity(0.06), .clear],
                startPoint: .leading, endPoint: .trailing)
                .frame(height: 1)
            HStack(spacing: 10) {
                CalloutButton(symbol: "gearshape", help: L10n.t("Settings", "设置")) {
                    SettingsWindow.open()
                }
                // Three quick switches, each a chip that names its current
                // state: bar style, used-or-remaining, quota-or-usage.
                chip(store.meterStyle.displayName, help: L10n.t("Switch bar style", "切换进度条样式")) {
                    store.setMeterStyle(store.meterStyle == .stepped ? .continuous : .stepped)
                }
                chip(store.meterMode.displayName, help: L10n.t("Show used or remaining", "显示已用还是剩余")) {
                    store.setMeterMode(store.meterMode == .used ? .remaining : .used)
                }
                chip(page.label, help: L10n.t("Quota or consumption", "额度还是用量")) {
                    if page == .quota { store.wantLedger() }
                    withAnimation(.easeOut(duration: 0.2)) { page = page == .quota ? .usage : .quota }
                }
                Spacer(minLength: 0)
                IslandSyncStatus(store: store)
            }
            .frame(maxHeight: .infinity)
        }
    }
}

private extension IslandPanel {
    /// A tap gesture rather than a `Button`, for the reason CalloutButton
    /// gives: this panel is never key, and buttons do not fire in it.
    func chip(_ label: String, help: String, action: @escaping () -> Void) -> some View {
        Text(label.uppercased())
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.06)))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .help(help)
            .accessibilityAddTraits(.isButton)
    }
}

/// "● 已同步 3 分钟前", or an amber note that something is not updating.
private struct IslandSyncStatus: View {
    @ObservedObject var store: UsageStore

    private var latest: Date? {
        store.enabled.compactMap { store.states[$0]?.snapshot?.fetchedAt }.max()
    }

    var body: some View {
        let failing = store.failingProviders.count
        HStack(spacing: 5) {
            Circle()
                .fill(failing > 0 ? Color(hex: "F5A524") : Color(hex: "3DD68C"))
                .frame(width: 6, height: 6)
                .shadow(color: (failing > 0 ? Color(hex: "F5A524") : Color(hex: "3DD68C")).opacity(0.55), radius: 3)
            Text(label(failing: failing))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
        }
    }

    private func label(failing: Int) -> String {
        if failing > 0 {
            return L10n.t("\(failing) not updating", "\(failing) 个未能更新")
        }
        guard let latest else { return L10n.t("Syncing…", "同步中…") }
        return L10n.t("Synced \(QuotaFormat.age(of: latest))", "已同步 \(QuotaFormat.age(of: latest))")
    }
}

/// One provider: title row, then a tile per horizon.
private struct IslandProviderBlock: View {
    @ObservedObject var store: UsageStore
    let id: ProviderID
    var page: IslandPanel.Page = .quota

    /// The CLI whose local logs this provider's traffic lands in, if any.
    private var costSource: CostSource? {
        switch id {
        case .claude: .claudeCode
        case .codex: .codexCLI
        case .opencodeGo: .openCode
        default: nil
        }
    }

    private var snapshot: UsageSnapshot? { store.states[id]?.snapshot }

    /// One window per horizon, two at most — the 5-hour and the 7-day when
    /// both exist, the one there is otherwise.
    private var horizons: [UsageWindow] {
        var seen = Set<String>()
        var out: [UsageWindow] = []
        for window in snapshot?.windows ?? [] where window.usedPercent != nil {
            guard seen.insert(window.shortLabel ?? window.title).inserted else { continue }
            out.append(window)
            if out.count == 2 { break }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProviderGlyph(id: id, size: 14, tint: .white)
                Text(id.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let plan = snapshot?.planName?.trimmingCharacters(in: .whitespacesAndNewlines), !plan.isEmpty {
                    Text(plan.replacingOccurrences(of: "_", with: " ").uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.06)))
                }
                if let status = store.serviceStatus[id] {
                    ServiceStatusBadge(status: status, size: 10, ink: .white.opacity(0.5))
                }
                Spacer(minLength: 0)
            }
            switch page {
            case .quota:
                if horizons.isEmpty {
                    emptyTile
                } else {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(horizons) { window in
                            IslandTile(window: window, accent: Color(hex: id.accentHex), store: store)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(maxWidth: horizons.count == 1 ? 240 : .infinity, alignment: .leading)
                }
            case .usage:
                usageTiles
            }
        }
    }

    /// Today and this month from the local logs: tokens large, the estimate
    /// under them. Providers without logs say so.
    @ViewBuilder
    private var usageTiles: some View {
        if let source = costSource {
            if store.ledger.isEmpty {
                Text(store.isComputingLedger
                    ? L10n.t("Reading local session logs…", "正在读取本地会话日志…")
                    : L10n.t("Nothing logged locally yet.", "本地还没有记录。"))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, minHeight: IslandPanelLayout.tileHeight, alignment: .topLeading)
            } else {
                HStack(alignment: .top, spacing: 18) {
                    ForEach([LedgerPeriod.today, .month]) { period in
                        let sum = store.ledger.sum(period, source: source)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(period.displayName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                            IslandTokenFigure(count: sum.tokens, color: Color(hex: id.accentHex))
                            Text(L10n.t("≈ \(QuotaFormat.usd(sum.usd))", "≈ \(QuotaFormat.usd(sum.usd))"))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: IslandPanelLayout.tileHeight, alignment: .top)
                    }
                }
            }
        } else {
            Text(L10n.t(
                "No local logs for this provider — only the quota readings.",
                "这个服务商没有本地日志，只有额度读数。"))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: IslandPanelLayout.tileHeight, alignment: .topLeading)
        }
    }

    private var emptyTile: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.states[id]?.errorMessage ?? L10n.t("No reading yet.", "还没有读数。"))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: IslandPanelLayout.tileHeight, alignment: .topLeading)
    }
}

/// "243.2" and "M": the figure in the brand colour, the unit dimmer.
private struct IslandTokenFigure: View {
    let count: Int
    let color: Color

    var body: some View {
        let compact = QuotaFormat.compact(count)
        let unit = compact.last.map { $0.isLetter ? String($0).uppercased() : "" } ?? ""
        let value = unit.isEmpty ? compact : String(compact.dropLast())
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
            Text(unit)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(color.opacity(0.6))
        }
        .lineLimit(1)
    }
}

/// Label and figure on top, the bar, the reset under it. Figure and bar
/// follow the used-or-remaining switch, like the menu-bar glyph.
private struct IslandTile: View {
    let window: UsageWindow
    let accent: Color
    @ObservedObject var store: UsageStore

    private var used: Double { window.usedPercent ?? 0 }
    private var percent: Double { store.meterMode.shownPercent(fromUsed: used) }

    /// The alert colour for the figure — white until the warning band —
    /// so the number, not the bar, says how close this is. Judged on what
    /// is used, whichever way the figure is shown.
    private var figureColor: Color {
        guard let hex = store.alertSettings.level(for: used).hex else { return .white }
        return Color(hex: hex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.scope ?? window.shortLabel.map(horizonName) ?? window.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                Spacer(minLength: 4)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(percent.rounded()))")
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                        .foregroundStyle(figureColor)
                        .contentTransition(.numericText())
                    Text("%")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            Meter(percent: percent, tint: accent, style: store.meterStyle, height: 13, track: .white.opacity(0.10))
            Text(window.resetsAt.map { QuotaFormat.resetLabel(to: $0) } ?? (window.detail ?? " "))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
        }
        .frame(height: IslandPanelLayout.tileHeight, alignment: .top)
    }

    /// "5h" → "5 小时", "7d" → "周": the reference names the horizon, not
    /// the number.
    private func horizonName(_ short: String) -> String {
        switch short {
        case "5h": L10n.t("5 hours", "5 小时")
        case "7d": L10n.t("week", "周")
        case "1d", "24h": L10n.t("day", "天")
        case "30d": L10n.t("month", "月")
        default: short
        }
    }
}
