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

    /// Left takes the first `slots` enabled providers, right the next.
    private var left: [ProviderID] { Array(store.enabled.prefix(store.islandSlots)) }
    private var right: [ProviderID] {
        Array(store.enabled.dropFirst(store.islandSlots).prefix(store.islandSlots))
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
                IslandProviderBlock(store: store, id: id)
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
                Button {
                    store.setMeterStyle(store.meterStyle == .stepped ? .continuous : .stepped)
                } label: {
                    Text(store.meterStyle.displayName.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.06)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.t("Switch bar style", "切换进度条样式"))
                Spacer(minLength: 0)
                IslandSyncStatus(store: store)
            }
            .frame(maxHeight: .infinity)
        }
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

/// Label and figure on top, the bar, the reset under it.
private struct IslandTile: View {
    let window: UsageWindow
    let accent: Color
    @ObservedObject var store: UsageStore

    private var percent: Double { window.usedPercent ?? 0 }

    /// The alert colour for the figure — white until the warning band —
    /// so the number, not the bar, says how close this is.
    private var figureColor: Color {
        guard let hex = store.alertSettings.level(for: percent).hex else { return .white }
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
