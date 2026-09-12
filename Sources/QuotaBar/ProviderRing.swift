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

    /// Front: the quota windows. Back: what this provider actually consumed,
    /// from the local session logs where there are any. Flipped by the
    /// header button, with the card turning over on its vertical axis.
    @State private var flipped = false
    @State private var spin = 0.0

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
        .frame(width: 260, alignment: .leading)
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
                CalloutButton(symbol: "arrow.clockwise", help: L10n.t("Refresh \(id.displayName)", "刷新 \(id.displayName)")) {
                    withAnimation(.easeInOut(duration: 0.6)) { spin += 360 }
                    store.refresh(id)
                }
                .rotationEffect(.degrees(spin))
                CalloutButton(
                    symbol: flipped ? "list.bullet" : "chart.bar.xaxis",
                    help: flipped ? L10n.t("Show quota", "显示额度") : L10n.t("Show usage", "显示用量"))
                {
                    if !flipped { store.wantLedger() }
                    withAnimation(.easeInOut(duration: 0.45)) { flipped.toggle() }
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
            if snapshot.windows.isEmpty {
                Text(L10n.t("No quota windows reported.", "服务商未返回额度窗口。"))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                VStack(alignment: .leading, spacing: Design.space3) {
                    ForEach(snapshot.windows) { window in
                        row(window)
                    }
                }
            }
        }
    }

    /// Title and reset on one line, the meter under it, the figure below —
    /// the arrangement from the reference: nothing wraps, nothing competes.
    private func row(_ window: UsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(window.scope ?? window.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: Design.space2)
                if let resetsAt = window.resetsAt {
                    Text(QuotaFormat.resetLabel(to: resetsAt))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            Meter(
                percent: window.usedPercent,
                tint: window.usedPercent.map(meterTint) ?? .clear,
                style: store.meterStyle)
            Text(window.usedPercent.map {
                L10n.t("\(QuotaFormat.percent($0)) used", "已用 \(QuotaFormat.percent($0))")
            } ?? (window.detail ?? "—"))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private func meterTint(_ percent: Double) -> Color {
        Color(hex: UsageRamp.hex(used: percent))
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
            if store.ledger.isEmpty {
                Text(store.isComputingLedger
                    ? L10n.t("Reading local session logs…", "正在读取本地会话日志…")
                    : L10n.t("Nothing logged locally yet.", "本地还没有记录。"))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                VStack(alignment: .leading, spacing: Design.space3) {
                    HStack(alignment: .top, spacing: Design.space3) {
                        ForEach([LedgerPeriod.today, .week, .month]) { period in
                            let sum = store.ledger.sum(period, source: source)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(period.displayName.uppercased())
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .tracking(0.6)
                                    .foregroundStyle(.white.opacity(0.55))
                                Text(QuotaFormat.compact(sum.tokens))
                                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.white)
                                Text(QuotaFormat.usd(sum.usd))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    let recent = store.ledger.days(in: .year).suffix(14)
                    MiniBars(
                        values: recent.map { Double($0.bySource[source] ?? 0) },
                        accent: Color(hex: source.accentHex))
                    Text(L10n.t("Last 14 days · tokens incl. cache", "最近 14 天 · token 含缓存"))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        } else {
            let history = store.history[id] ?? []
            if history.count > 1 {
                VStack(alignment: .leading, spacing: Design.space2) {
                    MiniBars(values: Array(history.suffix(24)), accent: Color(hex: id.accentHex), ceiling: 100)
                    Text(L10n.t(
                        "Headline reading over the last \(min(history.count, 24)) refreshes",
                        "最近 \(min(history.count, 24)) 次刷新的用量读数"))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                }
            } else {
                Text(L10n.t(
                    "No local logs for this provider — only the quota readings.",
                    "这个服务商没有本地日志，只有额度读数。"))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A 22pt glyph button for the card header: dim until hovered, no chrome.
struct CalloutButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(hovering ? 0.92 : 0.5))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(hovering ? 0.10 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .animation(.easeOut(duration: 0.12), value: hovering)
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
