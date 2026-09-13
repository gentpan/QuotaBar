import SwiftUI
import ServiceManagement
import QuotaCore

// MARK: - Service status

/// Every provider on one page: the band, the page's own sentence about
/// what is going on, and when it was last asked. The rows in 服务商 carry
/// the band alone; this is where the sentence fits.
struct StatusPane: View {
    @ObservedObject var store: UsageStore
    /// The row that has been opened to show the page's own sentence.
    @State private var expanded: ProviderID?

    var body: some View {
        // Only the providers with a page. A row saying "none" for the rest
        // was five rows of nothing; the footnote names them once.
        let listed = ProviderID.allCases.filter { StatusPages.page(for: $0) != nil }
        SettingsCard {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(listed) { id in
                    row(id)
                    if id != listed.last {
                        Divider().opacity(0.3)
                    }
                }
            }
        }
        SettingFootnote(L10n.t(
            "Read from each provider's public status page every five minutes, without signing in. Click a row for the page's own account of what is going on. Providers without a page anyone can read are not listed.",
            "每五分钟读取各服务商的公开状态页，无需登录。点击一行可看状态页对当前情况的说明。没有可公开读取状态页的服务商不在此列出。"))
    }

    /// One line per provider — name, band, when it was asked — and the
    /// page's sentence only once the row is opened. A band is enough to
    /// scan the list; the sentence is for the row you stopped at.
    private func row(_ id: ProviderID) -> some View {
        let status = store.serviceStatus[id]
        let isOpen = expanded == id
        return VStack(alignment: .leading, spacing: Design.space2) {
            HStack(spacing: Design.space2 + 2) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(status == nil ? Color.clear : Color.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 10)
                ProviderGlyph(id: id, size: 18)
                    .frame(width: 20)
                Text(id.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .frame(width: 130, alignment: .leading)
                if let status {
                    ServiceStatusBadge(status: status, size: 12, ink: .primary)
                        .frame(width: 96, alignment: .leading)
                    // The provider's own service — claude.ai, the Codex CLI —
                    // over the last 30 days, without opening the row. The
                    // rest of what the page lists waits inside.
                    if let primary = StatusPages.primaryComponent(for: id, in: status.components),
                       let days = store.uptime[primary.id], !days.isEmpty
                    {
                        let recent = Array(days.suffix(30))
                        Text(String(format: "%.2f%%", UptimeDay.uptimePercent(recent)))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                        UptimeStrip(days: recent)
                    } else {
                        Spacer(minLength: Design.space2)
                    }
                    Text(L10n.t(
                        "checked \(QuotaFormat.age(of: status.checkedAt))",
                        "\(QuotaFormat.age(of: status.checkedAt))检查"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .frame(width: 92, alignment: .trailing)
                } else {
                    Text(L10n.t("Not read yet", "尚未读取"))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: Design.space2)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard status != nil else { return }
                withAnimation(.snappy(duration: 0.2)) { expanded = isOpen ? nil : id }
                if !isOpen { store.loadUptime(for: id) }
            }

            if isOpen, let status {
                VStack(alignment: .leading, spacing: Design.space2 + 2) {
                    // "Claude Code 服务正常" would only repeat the line under
                    // it; the sentence is worth a line when something is wrong.
                    if status.focus.isEmpty || !status.level.isHealthy {
                        Text(status.description)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if !status.focus.isEmpty {
                        // The badge above follows the coding services; say
                        // which, and what the rest of the page is reporting.
                        Text(L10n.t(
                            "Status follows \(status.focus.joined(separator: ", "))",
                            "状态按 \(status.focus.joined(separator: "、")) 判断"))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        ForEach(status.elsewhere, id: \.self) { incident in
                            Text(L10n.t("Elsewhere on the page: \(incident)", "其他组件：\(incident)"))
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    // Every part the page reports on, each with its band and
                    // — where the page answers for it — its last 90 days.
                    ForEach(status.components) { component in
                        ComponentRow(component: component, days: store.uptime[component.id])
                    }
                    Button {
                        NSWorkspace.shared.open(status.pageURL)
                    } label: {
                        Label(L10n.t("Open the status page", "打开状态页"), systemImage: "arrow.up.right")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(status.pageURL.absoluteString)
                }
                .padding(.leading, 10 + Design.space2 + 2 + 20 + Design.space2 + 2)
                .padding(.bottom, Design.space1)
            }
        }
        .padding(.vertical, Design.space2 + 2)
    }
}

/// One component: name, band, and its 90 days as a strip of ticks with
/// the uptime figure the days add up to.
private struct ComponentRow: View {
    let component: ServiceComponent
    let days: [UptimeDay]?

    var body: some View {
        HStack(spacing: Design.space3) {
            Text(component.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 190, alignment: .leading)
            ServiceStatusBadge(status: ServiceStatus(
                level: component.level, description: component.level.displayName,
                pageURL: URL(string: "https://example.invalid")!, checkedAt: .distantPast), size: 11)
                .frame(width: 80, alignment: .leading)
            // The page keeps 90 days; the owner found that a wall of ticks.
            // The last 30 are shown and the figure covers the same 30 — the
            // figure first, the strip running out to the row's end.
            if let days, !days.isEmpty {
                let recent = Array(days.suffix(30))
                Text(uptimeFigure(recent))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
                UptimeStrip(days: recent)
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    private func uptimeFigure(_ days: [UptimeDay]) -> String {
        String(format: "%.2f%%", UptimeDay.uptimePercent(days))
    }
}

/// 90 ticks, one per day, oldest on the left, in the day's band colour.
private struct UptimeStrip: View {
    let days: [UptimeDay]
    private let gap: CGFloat = 1.5

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, (proxy.size.width - gap * CGFloat(days.count - 1)) / CGFloat(days.count))
            HStack(spacing: gap) {
                ForEach(days.indices, id: \.self) { index in
                    // A clean day in the same green the quota bars start
                    // from, at full strength; the paler tint read as washed out.
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(days[index].level == .operational
                            ? Color(hex: UsageRamp.hex(used: 0))
                            : Color(hex: days[index].level.colorHex))
                        .frame(width: width)
                        .help(help(days[index]))
                }
            }
        }
        .frame(height: 14)
    }

    private func help(_ day: UptimeDay) -> String {
        let date = DateFormatter.localizedString(from: day.date, dateStyle: .medium, timeStyle: .none)
        let events = day.events.isEmpty ? day.level.displayName : day.events.joined(separator: "；")
        return "\(date)：\(events)"
    }
}
