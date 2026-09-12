import SwiftUI
import QuotaCore

/// One provider as a ring with its mark in the middle and, where the surface
/// asks for it, the figure below or a selection dot.
///
/// The ring carries the reading and the alert colour at once; the logo says
/// which provider without a label, which is what makes a narrow vertical strip
/// possible at all.
struct ProviderRing: View {
    let id: ProviderID
    let percent: Double?
    let alerts: AlertSettings
    static let defaultDiameter: CGFloat = 46
    var diameter: CGFloat = Self.defaultDiameter
    var showsLabel: Bool = true
    /// Marks the provider the menu-bar glyph is reporting. Picking one is a
    /// single click in the dock; opening the panel is a double click, so
    /// choosing what the icon means does not also throw a window at you.
    var selected: Bool = false
    /// The pointer is over this ring. Only the disc reacts, and only by
    /// scaling, so the strip's height — which the dock derives from
    /// `cellHeight` — is untouched.
    var hovered: Bool = false
    /// Reserve a row under the disc for the selection dot. The row is always
    /// there, so picking a provider never shifts its neighbours; only the
    /// selected ring's dot is drawn.
    var selectionDot: Bool = false

    /// The dot: 5pt, like the Dock's running-app mark, in the live green —
    /// under the ring rather than beside it, the owner's call once the
    /// figures went: the callout has the numbers, the strip needs only the
    /// pick.
    static let markSize: CGFloat = 5
    static let markSpacing: CGFloat = 5
    static let markColor = Color(hex: "3DD68C")

    /// Disc plus the dot row, when reserved.
    static func cellHeight(diameter: CGFloat = defaultDiameter, selectionDot: Bool) -> CGFloat {
        selectionDot ? diameter + markSpacing + markSize : diameter
    }

    private var level: AlertLevel {
        alerts.level(for: percent ?? 0)
    }

    /// Only hover lifts the disc. Selection is marked by the strip — a short
    /// bar against the docked edge — not by the ring itself; a halo round the
    /// disc was tried and read as a second, decorative ring.
    private var discScale: CGFloat {
        hovered ? 1.14 : 1
    }

    private static let lift = Animation.spring(response: 0.26, dampingFraction: 0.72)

    /// Green until the warning band, then the alert colour. A provider with no
    /// reading yet gets the neutral track only.
    private var tint: Color {
        // No reading is not 0% used — 0 is the brightest green on the ramp.
        guard let percent else { return .secondary }
        return Color(hex: UsageRamp.hex(used: percent))
    }

    var body: some View {
        VStack(spacing: Self.markSpacing) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(selected ? 0.14 : 0.08))
                Circle()
                    .stroke(Color.white.opacity(0.14), lineWidth: 3)
                if let percent {
                    Circle()
                        .trim(from: 0, to: max(0.012, min(percent, 100) / 100))
                        .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                // Always-dark surface: force the mark light rather than
                // leaving it to resolve against the system appearance.
                // Half the disc: at 0.42 the owner found the marks small, and Kimi's,
                // on its own black tile, smaller still.
                ProviderGlyph(id: id, size: diameter * 0.5, tint: .white)
            }
            .frame(width: diameter, height: diameter)
            .scaleEffect(discScale)
            .animation(Self.lift, value: hovered)

            if selectionDot {
                Circle()
                    .fill(selected ? Self.markColor : Color.clear)
                    .frame(width: Self.markSize, height: Self.markSize)
                    .animation(.easeOut(duration: 0.18), value: selected)
            }

            if showsLabel {
                // Small and grey: the figure is a caption to the ring, not
                // a second reading of it. At 12pt bold white it competed
                // with the marks; selection lifts it a step, not to white.
                Text(percent.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.system(size: 10, weight: selected ? .semibold : .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(selected ? 0.85 : 0.55))
            }
        }
        .accessibilityLabel(percent.map {
            "\(id.displayName) \(QuotaFormat.percent($0))"
        } ?? id.displayName)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The bubble that appears beside a ring, with one row per quota window.
struct ProviderCallout: View {
    @ObservedObject var store: UsageStore
    let id: ProviderID
    /// The full card: wider, with the trend, the reset credits, when it was
    /// fetched, and the pin row. The summary is what hover shows.
    var detail: Bool = false

    /// Front: the quota windows. Back: what this provider actually consumed,
    /// from the local session logs where there are any. Flipped by the
    /// header button, with the card turning over on its vertical axis.
    @State private var flipped = false
    /// The refresh button becomes a spinner until the store's next tick —
    /// the sign the owner asked for that the press did something — or for
    /// four seconds, whichever comes first.
    @State private var refreshing = false
    /// How many days the back face covers: 7, 14 or 30, picked at its foot.
    @State private var range = 14

    private var phase: ProviderPhase? { store.states[id] }
    private var status: ServiceStatus? { store.serviceStatus[id] }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.space3) {
            header
            // Both faces are laid out, so the card is as tall as the taller
            // one and the turn never resizes the panel under the pointer.
            ZStack(alignment: .topLeading) {
                content
                    .opacity(flipped ? 0 : 1)
                    .rotation3DEffect(.degrees(flipped ? 180 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                usageFace
                    .opacity(flipped ? 1 : 0)
                    .rotation3DEffect(.degrees(flipped ? 0 : -180), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            }
        }
        .padding(Design.space3)
        .frame(width: detail ? EdgeDockCoordinator.detailWidth : EdgeDockCoordinator.calloutWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Design.radiusCard + 2, style: .continuous)
                .fill(Color.black))
        .environment(\.colorScheme, .dark)
    }

    // MARK: Header

    /// Name and plan, the way codex-island heads its panel — "Codex PRO" —
    /// with the account and the status page's reading under it, and two
    /// small buttons: refresh this one provider, and turn the card over.
    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Design.space2) {
                ProviderGlyph(id: id, size: 15, tint: .white)
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
                Spacer(minLength: Design.space2)
                if refreshing {
                    ProgressView()
                        .controlSize(.small)
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
                // Only where there is something behind: a provider without
                // local logs has nothing to show but its readings, and a
                // chart of twenty-four identical bars said so at length.
                if costSource != nil {
                    CalloutButton(
                        symbol: flipped ? "list.bullet" : "chart.bar.xaxis",
                        help: flipped ? L10n.t("Show quota", "显示额度") : L10n.t("Show usage", "显示用量"))
                    {
                        if !flipped { store.wantLedger() }
                        withAnimation(.easeInOut(duration: 0.45)) { flipped.toggle() }
                    }
                }
            }
            let account = phase?.snapshot?.account.flatMap { $0.isEmpty ? nil : $0 }
            if account != nil || status != nil {
                HStack(spacing: Design.space2) {
                    if let account {
                        Text(account)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.40))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    if let status {
                        ServiceStatusBadge(status: status, size: 10, ink: .white.opacity(0.55))
                    }
                }
            }
        }
    }

    // MARK: Front: quota

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading, nil:
            Text(L10n.t("Loading…", "加载中…"))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        case let .failed(message):
            Text(message)
                .font(.caption)
                .foregroundStyle(Color(hex: "FF9F0A"))
                .fixedSize(horizontal: false, vertical: true)
        case let .loaded(snapshot), let .stale(snapshot, _):
            VStack(alignment: .leading, spacing: Design.space3) {
                if snapshot.windows.isEmpty {
                    Text(L10n.t("No quota windows reported.", "服务商未返回额度窗口。"))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                } else {
                    ForEach(snapshot.windows) { window in
                        row(window)
                    }
                }
                if detail {
                    detailExtras(snapshot)
                }
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private func detailExtras(_ snapshot: UsageSnapshot) -> some View {
        let history = store.history[id] ?? []
        if history.count > 1 {
            SparklineView(values: history, accent: Color(hex: id.accentHex))
        }
        if let credits = snapshot.resetCredits {
            ResetCreditsRow(credits: credits, accent: Color(hex: id.accentHex))
        }
        Text(L10n.t(
            "Updated \(QuotaFormat.age(of: snapshot.fetchedAt))",
            "更新于 \(QuotaFormat.age(of: snapshot.fetchedAt))"))
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.4))
        pinRow
    }

    /// Where this provider is shown on its own. Each chip is a toggle; the
    /// menu-bar one is the glyph's selection, the others are the surface's
    /// pin, and a pinned surface shows this provider and nothing else.
    private var pinRow: some View {
        VStack(alignment: .leading, spacing: Design.space1 + 2) {
            Text(L10n.t("PIN TO", "钉到"))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.55))
            HStack(spacing: Design.space1 + 2) {
                pinChip(L10n.t("Menu bar", "菜单栏"), on: store.selected == id) {
                    store.selected = store.selected == id ? nil : id
                }
                pinChip(L10n.t("Island", "刘海岛"), on: store.islandPin == id) {
                    store.setIslandPin(store.islandPin == id ? nil : id)
                }
                pinChip(L10n.t("Dock", "停靠条"), on: store.dockPin == id) {
                    store.setDockPin(store.dockPin == id ? nil : id)
                }
                pinChip(L10n.t("Desktop card", "桌面卡片"), on: store.widgetPin == id && store.widgetScope == .pinned) {
                    store.setWidgetPin(store.widgetPin == id && store.widgetScope == .pinned ? nil : id)
                }
            }
        }
    }

    private func pinChip(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Text(label)
            .font(.system(size: 10, weight: on ? .semibold : .medium))
            .foregroundStyle(on ? Color.black : Color.white.opacity(0.7))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(on ? Color.white.opacity(0.92) : Color.white.opacity(0.08)))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .animation(.easeOut(duration: 0.15), value: on)
    }

    private func row(_ window: UsageWindow) -> some View {
        QuotaRowView(store: store, id: id, window: window)
    }

    /// "Pro_plus" → "PRO PLUS", "pro" → "PRO". Providers spell their tiers
    /// every way; the chip spells them one way.
    private var planChip: String? {
        guard let raw = phase?.snapshot?.planName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        return raw.replacingOccurrences(of: "_", with: " ").uppercased()
    }

    // MARK: Back: usage

    private func usageFigure(_ label: String, _ value: String, _ cost: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.55))
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            Text(cost)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The CLI whose local logs this provider's traffic lands in, if any.
    private var costSource: CostSource? {
        switch id {
        case .claude: .claudeCode
        case .codex: .codexCLI
        case .opencodeGo: .openCode
        default: nil
        }
    }

    @ViewBuilder
    private var usageFace: some View {
        if let source = costSource {
            if !store.logsReady || store.ledger.isEmpty {
                Text(!store.logsReady
                    ? L10n.t("Reading local session logs…", "正在读取本地会话日志…")
                    : L10n.t("Nothing logged locally yet.", "本地还没有记录。"))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                // Today, then the chosen span: its tokens and its estimate.
                // The span is the foot's 7/14/30 switch, and the bars are
                // the same days, so the figures and the chart agree.
                let recent = Array(store.ledger.days(in: .year).suffix(range))
                let today = store.ledger.sum(.today, source: source)
                let span = recent.reduce(into: (tokens: 0, usd: 0.0)) { acc, day in
                    let tokens = day.bySource[source] ?? 0
                    acc.tokens += tokens
                    acc.usd += day.usd * Double(tokens) / Double(max(1, day.tokens))
                }
                VStack(alignment: .leading, spacing: Design.space3) {
                    HStack(alignment: .top, spacing: Design.space3) {
                        usageFigure(L10n.t("Today", "今天"), QuotaFormat.compact(today.tokens), QuotaFormat.usd(today.usd))
                        usageFigure(L10n.t("\(range) days", "\(range) 天"), QuotaFormat.compact(span.tokens), QuotaFormat.usd(span.usd))
                        usageFigure(L10n.t("Per day", "日均"), QuotaFormat.compact(span.tokens / max(1, recent.count)), QuotaFormat.usd(span.usd / Double(max(1, recent.count))))
                    }
                    Spacer(minLength: Design.space2)
                    DailyBars(days: recent, source: source, accent: Color(hex: source.accentHex)) {
                        HStack(spacing: 2) {
                            ForEach([7, 14, 30], id: \.self) { days in
                                let on = days == range
                                Text("\(days)d")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white.opacity(on ? 0.95 : 0.45))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 3).fill(.white.opacity(on ? 0.14 : 0)))
                                    .contentShape(Rectangle())
                                    .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { range = days } }
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        } else {
            EmptyView()
        }
    }
}

/// A 22pt glyph button for the card header: dim until hovered, no chrome.
///
/// A tap gesture, not a `Button`: the card and the strip are non-activating
/// panels that are never the key window, and SwiftUI's `Button` never
/// fired there — the pointer highlighted it and the click went nowhere —
/// while the strip's tap gestures always have.
struct CalloutButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(hovering ? 0.92 : 0.5))
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.10 : 0)))
            .scaleEffect(pressed ? 0.88 : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture {
                pressed = true
                action()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    pressed = false
                }
            }
            .help(help)
            .accessibilityLabel(help)
            .accessibilityAddTraits(.isButton)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.12), value: pressed)
    }
}

/// A fortnight of days as bars, sat on the card's floor, with the day
/// under the pointer read out where the caption is.
struct DailyBars<Trailing: View>: View {
    let days: [UsageDay]
    let source: CostSource
    let accent: Color
    /// Sits at the foot's right end: the span switch.
    @ViewBuilder var trailing: Trailing
    @State private var hovered: Int?

    private var peak: Double {
        max(days.map { Double($0.bySource[source] ?? 0) }.max() ?? 1, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.space2) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(days.indices, id: \.self) { index in
                    let tokens = Double(days[index].bySource[source] ?? 0)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(accent.opacity(tokens > 0 ? (hovered == nil || hovered == index ? 0.92 : 0.45) : 0.15))
                        .frame(height: max(3, 56 * CGFloat(tokens / peak)))
                        .frame(maxWidth: .infinity, alignment: .bottom)
                        .contentShape(Rectangle().size(width: 40, height: 60))
                        .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
                        .animation(.easeOut(duration: 0.12), value: hovered)
                }
            }
            .frame(height: 56, alignment: .bottom)
            HStack(spacing: Design.space2) {
                Text(caption)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(hovered == nil ? 0.4 : 0.7))
                    .lineLimit(1)
                Spacer(minLength: 0)
                trailing
            }
        }
    }

    private var caption: String {
        guard let hovered, days.indices.contains(hovered) else {
            return L10n.t("Last \(days.count) days · tokens incl. cache", "最近 \(days.count) 天 · token 含缓存")
        }
        let day = days[hovered]
        let tokens = day.bySource[source] ?? 0
        let share = Double(tokens) / Double(max(1, day.tokens))
        let date = DateFormatter.localizedString(from: day.day, dateStyle: .short, timeStyle: .none)
        return "\(date) · \(QuotaFormat.compact(tokens)) · \(QuotaFormat.usd(day.usd * share))"
    }
}

/// Bars for a short series — a fortnight of days, or the recent readings —
/// scaled to the series' own peak unless a ceiling is given.
struct MiniBars: View {
    let values: [Double]
    let accent: Color
    var ceiling: Double? = nil
    var height: CGFloat = 44

    var body: some View {
        let peak = max(ceiling ?? (values.max() ?? 1), 1)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(values.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(accent.opacity(values[index] > 0 ? 0.9 : 0.15))
                    .frame(height: max(2, height * CGFloat(values[index] / peak)))
                    .frame(maxWidth: .infinity, alignment: .bottom)
            }
        }
        .frame(height: height, alignment: .bottom)
    }
}
