import AppKit
import SwiftUI
import QuotaCore

// MARK: - The provider card, shared by the menu panel and the share image

/// One provider as the menu panel shows it, after openusage's card: name,
/// plan and status on top; the one or two windows that matter always
/// visible; everything else — other windows, early resets, the 30-day trend,
/// spend with its model breakdown, links — behind a caret that remembers
/// whether it was open.
struct ProviderCardView: View {
    @ObservedObject var store: UsageStore
    let id: ProviderID
    /// The static version rendered into a PNG: no hover, no caret, no buttons.
    var forExport = false

    @State private var refreshing = false

    private var phase: ProviderPhase? { store.states[id] }
    private var snapshot: UsageSnapshot? { phase?.snapshot }
    private var expanded: Bool { !forExport && store.isCardExpanded(id) }
    private var compact: Bool { store.experience.panelDensity == .compact }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            header
            content
        }
        .padding(compact ? 10 : 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(forExport ? 0.06 : 0.05)))
        .contextMenu { if !forExport { contextItems } }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                ProviderGlyph(id: id, size: 16, tint: .white)
                Text(id.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                if let plan = planChip {
                    Text(plan)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(.white.opacity(0.78))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                Spacer(minLength: 6)
                if let status = store.serviceStatus[id] {
                    if status.level.isHealthy {
                        Circle()
                            .fill(Color(hex: status.level.colorHex))
                            .frame(width: 6, height: 6)
                            .help(status.sourceNote)
                    } else {
                        ServiceStatusBadge(status: status, size: 10, ink: .white.opacity(0.65))
                    }
                }
                if !forExport {
                    if refreshing || store.isLoading(id) {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 22, height: 22)
                            .onChange(of: store.tick) { _, _ in refreshing = false }
                            .task {
                                try? await Task.sleep(for: .seconds(4))
                                refreshing = false
                            }
                    } else {
                        CalloutButton(symbol: "arrow.clockwise", help: L10n.t("Refresh \(id.displayName)", "刷新 \(id.displayName)")) {
                            refreshing = true
                            store.refresh(id)
                        }
                    }
                }
            }
            if let account = snapshot?.account, !account.isEmpty, !store.isPrivacyMasked {
                Text(account)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var planChip: String? {
        guard let raw = snapshot?.planName?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return nil }
        return raw.replacingOccurrences(of: "_", with: " ").uppercased()
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading, nil:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(L10n.t("Loading…", "加载中…"))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
        case let .failed(message):
            failure(message)
        case let .loaded(snapshot), let .stale(snapshot, _):
            VStack(alignment: .leading, spacing: compact ? 8 : 11) {
                if let error = phase?.errorMessage {
                    staleNote(error, age: snapshot.fetchedAt)
                }
                if snapshot.windows.isEmpty {
                    Text(L10n.t("No quota windows reported.", "服务商未返回额度窗口。"))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
                ForEach(primary(snapshot)) { window in
                    QuotaRowView(store: store, id: id, window: window, compact: compact, allowsPick: !forExport)
                }
                if hasMore(snapshot) && !forExport {
                    caret
                }
                if expanded {
                    more(snapshot)
                        .transition(.detailReveal)
                }
            }
        }
    }

    /// The window the ring follows, then the first window of the other
    /// horizon — the 5-hour and the week for most plans — in the order the
    /// provider reports them.
    private func primary(_ snapshot: UsageSnapshot) -> [UsageWindow] {
        let withFigures = snapshot.windows.filter { $0.usedPercent != nil }
        guard let lead = store.headlineWindow(for: id) ?? withFigures.first else {
            return Array(snapshot.windows.prefix(2))
        }
        var picked = [lead]
        if let other = withFigures.first(where: { $0.id != lead.id && $0.horizon != lead.horizon && $0.scope == nil })
            ?? withFigures.first(where: { $0.id != lead.id })
        {
            picked.append(other)
        }
        let order = snapshot.windows.map(\.id)
        return picked.sorted { (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0) }
    }

    private func rest(_ snapshot: UsageSnapshot) -> [UsageWindow] {
        let shown = Set(primary(snapshot).map(\.id))
        return snapshot.windows.filter { !shown.contains($0.id) }
    }

    private func hasMore(_ snapshot: UsageSnapshot) -> Bool {
        !rest(snapshot).isEmpty || snapshot.resetCredits != nil || id.costSource != nil
            || StatusPages.page(for: id) != nil || id.dashboardURL != nil
    }

    private var caret: some View {
        HStack {
            Spacer()
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .rotationEffect(.degrees(expanded ? 180 : 0))
                .frame(width: 44, height: 14)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(Motion.animation(Motion.spring)) { store.toggleCardExpanded(id) }
                }
                .help(expanded ? L10n.t("Show less", "收起") : L10n.t("Show more", "展开更多"))
            Spacer()
        }
    }

    // MARK: More

    @ViewBuilder
    private func more(_ snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 11) {
            ForEach(rest(snapshot)) { window in
                QuotaRowView(store: store, id: id, window: window, compact: compact)
            }
            if let credits = snapshot.resetCredits {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(hex: id.accentHex))
                    Text(L10n.t("Early resets", "限额重置次数"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(L10n.t("\(credits.available) available", "\(credits.available) 次可用"))
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color(hex: id.accentHex))
                }
            }
            if let source = id.costSource {
                trend(source)
                spendRows(source)
            }
            links(snapshot)
        }
    }

    private func trend(_ source: CostSource) -> some View {
        let days = store.archive.trend(for: source, days: 30, counting: store.experience.tokenCounting)
        return HStack(alignment: .bottom) {
            Text(L10n.t("Usage trend", "用量趋势"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
            Spacer(minLength: 12)
            if days.contains(where: { $0.tokens > 0 }) {
                TrendBars(days: days, accent: Color(hex: id.accentHex))
                    .frame(width: 170)
            } else {
                Text(!store.logsReady ? L10n.t("Reading logs…", "正在读取日志…") : L10n.t("No data", "暂无数据"))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    private func spendRows(_ source: CostSource) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SpendPeriod.allCases) { period in
                let spend = store.cost.spend(period)
                let usd = spend.bySource[source] ?? 0
                let tokens = spend.tokens(from: source, store.experience.tokenCounting)
                HStack {
                    Text(period.displayName(windowDays: store.cost.windowDays))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(usd > 0 || tokens > 0
                        ? "\(QuotaFormat.money(usd)) · \(QuotaFormat.compact(tokens)) tokens"
                        : L10n.t("No data", "暂无数据"))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(usd > 0 || tokens > 0 ? 0.8 : 0.4))
                }
                .contentShape(Rectangle())
                .hoverDetail {
                    ModelBreakdownList(
                        title: "\(id.displayName) · \(period.displayName(windowDays: store.cost.windowDays))",
                        models: spend.models.filter { $0.source == source },
                        counting: store.experience.tokenCounting)
                }
            }
        }
    }

    private func links(_ snapshot: UsageSnapshot) -> some View {
        HStack(spacing: 8) {
            if let page = StatusPages.page(for: id) {
                linkButton(L10n.t("Status", "状态页"), "waveform.path.ecg", page)
            }
            if let console = id.dashboardURL {
                linkButton(L10n.t("Console", "控制台"), "arrow.up.right", console)
            }
            Spacer()
            Text(L10n.t("Updated \(QuotaFormat.age(of: snapshot.fetchedAt))", "更新于 \(QuotaFormat.age(of: snapshot.fetchedAt))"))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    private func linkButton(_ title: String, _ symbol: String, _ url: URL) -> some View {
        Pressable(action: { NSWorkspace.shared.open(url) }) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.08)))
        }
        .help(url.absoluteString)
    }

    // MARK: States

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Palette.amber)
                .fixedSize(horizontal: false, vertical: true)
            if id == .claude, store.claudeNeedsAuthorization, !forExport {
                Pressable(action: { store.authorizeClaude() }) {
                    Text(L10n.t("Allow keychain access", "授权钥匙串访问"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white))
                }
            }
        }
    }

    private func staleNote(_ error: String, age: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(Palette.amber)
            Text(L10n.t("Showing numbers from \(QuotaFormat.age(of: age))", "显示的是 \(QuotaFormat.age(of: age))的数据"))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.55))
        }
        .help(error)
    }

    // MARK: Context menu

    @ViewBuilder
    private var contextItems: some View {
        Button(L10n.t("Refresh \(id.displayName)", "刷新 \(id.displayName)")) { store.refresh(id) }
        Button(L10n.t("Copy as Image", "复制为图片")) { copyImage() }
        if store.pickedHeadlineWindow(for: id) != nil {
            Button(L10n.t("Ring follows the fullest window", "圆环改回按最满的窗口显示")) {
                store.setHeadlineWindow(nil, for: id)
            }
        }
        Divider()
        if store.enabled.first != id {
            Button(L10n.t("Move Up", "上移")) { withAnimation(Motion.animation(Motion.spring)) { store.moveProvider(id, by: -1) } }
        }
        if store.enabled.last != id {
            Button(L10n.t("Move Down", "下移")) { withAnimation(Motion.animation(Motion.spring)) { store.moveProvider(id, by: 1) } }
        }
        Button(L10n.t("Hide from Panel", "在下拉面板中隐藏")) {
            withAnimation(Motion.animation(Motion.spring)) { store.setHidden(true, id, on: .panel) }
        }
        Button(L10n.t("Turn off \(id.displayName)", "停用 \(id.displayName)")) { store.setEnabled(id, false) }
        Button(L10n.t("Settings…", "设置…")) { SettingsWindow.open() }
    }

    private func copyImage() {
        let card = ShareableCard(store: store) {
            ProviderCardView(store: store, id: id, forExport: true)
        }
        if CardImageExporter.copy(card, text: "\(id.displayName) · QuotaBar") {
            store.flashNotice(L10n.t("Copied to clipboard", "已复制到剪贴板"))
        }
    }
}

/// The frame around anything copied as an image: black, padded, and a
/// footer that signs it — the app icon on its green tile with the name on
/// the left, the address on the right, each said once.
struct ShareableCard<Content: View>: View {
    @ObservedObject var store: UsageStore
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 14) {
            content()
            HStack(spacing: 8) {
                if let url = ProviderGlyph.markURL(named: "quotabar-icon"), let image = NSImage(contentsOfFile: url.path) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
                }
                Text("QuotaBar")
                    .font(Design.wordmark(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 8)
                Text("quota.bar")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 4)
        }
        .padding(16)
        .frame(width: 380)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }
}

extension UsageStore {
    /// Shows the transient pill for a moment.
    func flashNotice(_ text: String) {
        copiedNotice = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            if self?.copiedNotice == text { self?.copiedNotice = nil }
        }
    }
}
