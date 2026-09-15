import AppKit
import SwiftUI
import QuotaCore

// MARK: - Desktop card views

/// One desktop card, in its style and size. Dark rounded card, a name with a
/// status pill, one large figure, a row of facts, a strip along the foot —
/// the language of the owner's reference.
struct DeskCardView: View {
    @ObservedObject var store: UsageStore
    let card: DeskCard

    var body: some View {
        Group {
            switch card.style {
            case .focus: DeskFocus(store: store, card: card)
            case .gauge: DeskGauge(store: store, card: card)
            case .trend: DeskTrend(store: store, card: card)
            case .daily: DeskDaily(store: store, card: card)
            case .grid: DeskGrid(store: store, card: card)
            case .ranking: DeskRanking(store: store, card: card)
            case .classic: DeskClassic(store: store, card: card)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Chrome

enum Desk {
    static let card = Color(hex: "1C1D21")
    static let tile = Color.white.opacity(0.05)
    static let green = Color(hex: "3DD68C")

    static func figureColor(_ used: Double) -> Color {
        used >= 90 ? Palette.figureRed : used >= 70 ? Palette.figureAmber : .white
    }

    static func clock(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

struct DeskFrame<Content: View>: View {
    let size: DeskCardSize
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(size == .small ? 13 : 16)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: size == .small ? 22 : 24, style: .continuous).fill(Desk.card))
            .overlay(RoundedRectangle(cornerRadius: size == .small ? 22 : 24, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
    }
}

struct DeskHeader: View {
    let title: String
    var id: ProviderID?
    var symbol = "chart.bar.fill"
    var plan: String?
    var pill: (text: String, color: Color)?
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            if let id {
                ProviderGlyph(id: id, size: compact ? 15 : 18, tint: .white)
            } else {
                Image(systemName: symbol).font(.system(size: compact ? 11 : 14, weight: .semibold)).foregroundStyle(.white)
            }
            Text(title)
                .font(.system(size: compact ? 13 : 16, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if let plan, !compact {
                Text(plan.replacingOccurrences(of: "_", with: " ").uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.1)))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let pill {
                if compact {
                    Circle().fill(pill.color).frame(width: 7, height: 7).help(pill.text)
                } else {
                    HStack(spacing: 5) {
                        Circle().fill(pill.color).frame(width: 7, height: 7)
                        Text(pill.text).font(.system(size: 11, weight: .medium)).foregroundStyle(pill.color).lineLimit(1)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .overlay(Capsule().strokeBorder(pill.color.opacity(0.6), lineWidth: 1))
                }
            }
        }
    }
}

struct DeskFooter: View {
    let symbol: String
    let text: String
    let time: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            Text(time).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 12).frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Desk.tile))
    }
}

struct DeskStat: View {
    let value: String
    let label: String
    var color: Color = .white

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct StatDivider: View {
    var body: some View { Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 30) }
}

// MARK: - Data

@MainActor
extension UsageStore {
    /// The provider a single-provider card shows: its own, else the one the
    /// menu bar follows, else the one closest to its limit.
    func deskProvider(_ card: DeskCard) -> ProviderID? {
        if let provider = card.provider, enabled.contains(provider) { return provider }
        let shown = experience.visible(enabled, on: .desktop)
        if let selected, shown.contains(selected) { return selected }
        return shown.max { (headlinePercent(for: $0) ?? -1) < (headlinePercent(for: $1) ?? -1) }
    }

    /// The providers a multi-provider card shows.
    func deskProviders(_ card: DeskCard) -> [ProviderID] {
        if let provider = card.provider, enabled.contains(provider) { return [provider] }
        return experience.visible(enabled, on: .desktop)
    }

    func deskWindows(_ id: ProviderID) -> (lead: UsageWindow?, other: UsageWindow?, all: [UsageWindow]) {
        let windows = states[id]?.snapshot?.windows.filter { $0.usedPercent != nil } ?? []
        let lead = headlineWindow(for: id) ?? windows.first
        let other = windows.first { $0.id != lead?.id && $0.horizon != lead?.horizon && $0.scope == nil }
            ?? windows.first { $0.id != lead?.id }
        return (lead, other, windows)
    }

    /// The last `count` days of local traffic, for every CLI or one.
    func deskDays(_ count: Int, source: CostSource?) -> [ArchiveSummary.Day] {
        if let source { return archive.trend(for: source, days: count, counting: experience.tokenCounting) }
        let today = Calendar.current.startOfDay(for: Date())
        let start = Calendar.current.date(byAdding: .day, value: -(count - 1), to: today) ?? today
        return archive.summary(from: start, to: today, counting: experience.tokenCounting).days
    }

    func deskPill(_ id: ProviderID) -> (text: String, color: Color)? {
        // A window that just reset says so in place of the status for a while.
        if let windows = states[id]?.snapshot?.windows, windows.contains(where: { justReset(id, window: $0.id) }) {
            return (L10n.t("Just reset", "刚刚重置"), id.accent)
        }
        guard let status = serviceStatus[id] else { return nil }
        return (status.level.displayName, Color(hex: status.level.colorHex))
    }

    func deskUpdated(_ ids: [ProviderID]) -> String {
        Desk.clock(ids.compactMap { states[$0]?.snapshot?.fetchedAt }.max())
    }

    /// Percent shown on a card, in the used-or-left mode.
    func deskShown(_ used: Double) -> Double { meterMode.shownPercent(fromUsed: used) }

    /// How full a bar or ring is drawn. No reading yet draws it empty, not
    /// full: in the remaining mode 0% used would read as all of it left.
    func deskFill(_ used: Double?) -> Double { used.map(deskShown) ?? 0 }

    var deskShownLabel: String { meterMode == .used ? L10n.t("used", "已用") : L10n.t("left", "剩余") }
}

private struct DeskEmpty: View {
    let size: DeskCardSize
    let text: String

    var body: some View {
        DeskFrame(size: size) {
            DeskHeader(title: "QuotaBar", compact: size == .small)
            Spacer()
            Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }
}

// MARK: - Big figure

private struct DeskFocus: View {
    @ObservedObject var store: UsageStore
    let card: DeskCard

    var body: some View {
        if let id = store.deskProvider(card), let sheet = store.deskBalance(id) {
            DeskBalanceCard(store: store, id: id, sheet: sheet, size: card.size)
        } else if let id = store.deskProvider(card) {
            content(id)
        } else {
            DeskEmpty(size: card.size, text: L10n.t("Turn on a provider in Settings.", "请先在设置里开启服务商。"))
        }
    }

    @ViewBuilder
    private func content(_ id: ProviderID) -> some View {
        let windows = store.deskWindows(id)
        let used = windows.lead?.usedPercent ?? 0
        let snapshot = store.states[id]?.snapshot
        let compact = card.size == .small
        DeskFrame(size: card.size) {
            DeskHeader(title: id.displayName, id: id, plan: snapshot?.planName, pill: store.deskPill(id), compact: compact)
            Spacer(minLength: compact ? 6 : 10)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(windows.lead == nil ? "—" : "\(Int(store.deskShown(used).rounded()))")
                    .font(.system(size: compact ? 44 : 52, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Desk.figureColor(used))
                    .contentTransition(.numericText(value: used))
                Text("%").font(.system(size: compact ? 18 : 22, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            }
            Text(caption(windows.lead, compact: compact))
                .font(.system(size: compact ? 11 : 12)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            if !compact {
                Spacer(minLength: 10)
                HStack(spacing: 0) {
                    DeskStat(value: windows.other?.usedPercent.map { "\(Int(store.deskShown($0).rounded()))%" } ?? "—",
                             label: windows.other?.scope ?? windows.other?.title ?? "—", color: Desk.green)
                    StatDivider()
                    DeskStat(value: id.costSource.map { QuotaFormat.moneyCompact(store.cost.spend(.today).bySource[$0] ?? 0) } ?? (windows.lead?.pace()?.verdict == .over ? L10n.t("Fast", "偏快") : "—"),
                             label: id.costSource != nil ? L10n.t("Today", "今日花费") : L10n.t("Pace", "节奏"))
                    StatDivider()
                    DeskStat(value: id.costSource.map { QuotaFormat.compact(store.cost.spend(.today).tokens(from: $0, store.experience.tokenCounting)) } ?? (windows.lead?.resetsAt.map { QuotaFormat.tick(to: $0) } ?? "—"),
                             label: id.costSource != nil ? L10n.t("Tokens today", "今日 token") : L10n.t("To reset", "后重置"))
                }
                if card.size == .large {
                    Spacer(minLength: 12)
                    VStack(spacing: 9) {
                        ForEach(windows.all.filter { $0.id != windows.lead?.id }.prefix(3)) { window in
                            DeskWindowLine(store: store, window: window)
                        }
                    }
                }
                Spacer(minLength: 10)
                DeskFooter(symbol: "person.crop.circle", text: store.isPrivacyMasked ? id.displayName : (snapshot?.account ?? id.displayName), time: store.deskUpdated([id]))
            } else {
                Spacer(minLength: 4)
            }
        }
    }

    private func caption(_ window: UsageWindow?, compact: Bool) -> String {
        guard let window else { return L10n.t("No reading yet", "还没有读数") }
        let name = window.scope ?? window.title
        if compact {
            return "\(name) · \(window.resetsAt.map { QuotaFormat.tick(to: $0) } ?? store.deskShownLabel)"
        }
        return L10n.t("\(name) \(store.deskShownLabel)", "\(name)\(store.deskShownLabel)") + (window.resetsAt.map { " · " + store.resetText($0) } ?? "")
    }
}

/// A window as one line: name, bar, figure, reset.
private struct DeskWindowLine: View {
    @ObservedObject var store: UsageStore
    let window: UsageWindow

    var body: some View {
        let used = window.usedPercent ?? 0
        VStack(spacing: 4) {
            HStack {
                Text(window.scope ?? window.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                Spacer()
                Text(window.resetsAt.map { QuotaFormat.tick(to: $0) } ?? "").font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
                Text("\(Int(store.deskShown(used).rounded()))%").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Desk.figureColor(used)).frame(width: 36, alignment: .trailing)
            }
            Meter(percent: store.deskShown(used), tint: Color(hex: UsageRamp.hex(used: used)), style: store.meterStyle, height: 4, track: .white.opacity(0.1))
                .paceTick(window, mode: store.meterMode, always: store.experience.alwaysShowPace)
        }
    }
}

// MARK: - Gauge

private struct DeskGauge: View {
    @ObservedObject var store: UsageStore
    let card: DeskCard

    var body: some View {
        if let id = store.deskProvider(card), let sheet = store.deskBalance(id) {
            DeskBalanceCard(store: store, id: id, sheet: sheet, size: card.size)
        } else if let id = store.deskProvider(card) {
            content(id)
        } else {
            DeskEmpty(size: card.size, text: L10n.t("Turn on a provider in Settings.", "请先在设置里开启服务商。"))
        }
    }

    @ViewBuilder
    private func content(_ id: ProviderID) -> some View {
        let windows = store.deskWindows(id)
        let used = windows.lead?.usedPercent ?? 0
        let pace = windows.lead?.pace()
        let snapshot = store.states[id]?.snapshot
        DeskFrame(size: card.size) {
            DeskHeader(title: id.displayName, id: id, plan: snapshot?.planName, pill: store.deskPill(id), compact: card.size == .small)
            if card.size == .small {
                Spacer(minLength: 4)
                HStack {
                    Spacer()
                    gauge(id: id, used: windows.lead?.usedPercent, diameter: 92, figure: true)
                    Spacer()
                }
                Spacer(minLength: 2)
                Text(windows.lead.map { ($0.scope ?? $0.title) + ($0.resetsAt.map { " · " + QuotaFormat.tick(to: $0) } ?? "") } ?? "—")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1).frame(maxWidth: .infinity)
            } else {
                // Medium is 224pt tall: at the large card's ring and gaps its
                // footer ran 23pt past the bottom edge.
                let medium = card.size == .medium
                Spacer(minLength: medium ? 6 : 8)
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(windows.lead?.scope ?? windows.lead?.title ?? "—").font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(windows.lead == nil ? "—" : "\(Int(store.deskShown(used).rounded()))")
                                .font(.system(size: 46, weight: .semibold, design: .monospaced)).foregroundStyle(Desk.figureColor(used))
                                .contentTransition(.numericText(value: used))
                            Text("% \(store.deskShownLabel)").font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    Spacer()
                    gauge(id: id, used: windows.lead?.usedPercent, diameter: medium ? 70 : 84, figure: false)
                }
                Spacer(minLength: medium ? 6 : 8)
                HStack(spacing: 6) {
                    tile("clock", windows.lead?.resetsAt.map { QuotaFormat.tick(to: $0) } ?? "—", L10n.t("to reset", "后重置"), padding: medium ? 6 : 8)
                    tile("flame", pace.map { $0.runOutSeconds.map { QuotaFormat.tick(to: Date().addingTimeInterval($0)) } ?? L10n.t("OK", "够用") } ?? "—",
                         L10n.t("runs out", "预计用完"), tint: pace?.verdict == .over || pace?.verdict == .spent ? Palette.red : Desk.green, padding: medium ? 6 : 8)
                    tile("calendar", windows.other?.usedPercent.map { "\(Int(store.deskShown($0).rounded()))%" } ?? "—", windows.other?.scope ?? windows.other?.title ?? "—", padding: medium ? 6 : 8)
                }
                if card.size == .large {
                    Spacer(minLength: 12)
                    VStack(spacing: 9) {
                        ForEach(windows.all.filter { $0.id != windows.lead?.id }.prefix(3)) { window in
                            DeskWindowLine(store: store, window: window)
                        }
                    }
                }
                Spacer(minLength: medium ? 6 : 8)
                DeskFooter(symbol: "person.crop.circle", text: store.isPrivacyMasked ? id.displayName : (snapshot?.account ?? id.displayName), time: store.deskUpdated([id]))
            }
        }
    }

    private func gauge(id: ProviderID, used: Double?, diameter: CGFloat, figure: Bool) -> some View {
        let shown = store.deskFill(used)
        return ZStack {
            Circle().trim(from: 0, to: 0.78).stroke(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 9, lineCap: .round)).rotationEffect(.degrees(129))
            Circle().trim(from: 0, to: used == nil ? 0 : max(0.01, 0.78 * shown / 100))
                .stroke(Color(hex: UsageRamp.hex(used: used ?? 0)), style: StrokeStyle(lineWidth: 9, lineCap: .round)).rotationEffect(.degrees(129))
                .animation(Motion.animation(.easeOut(duration: 0.4)), value: shown)
            if figure {
                VStack(spacing: 0) {
                    Text(used == nil ? "—" : "\(Int(shown.rounded()))%").font(.system(size: 20, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
                    ProviderGlyph(id: id, size: 12, tint: .white.opacity(0.7))
                }
            } else {
                ProviderGlyph(id: id, size: 26, tint: .white)
            }
        }
        .frame(width: diameter, height: diameter)
    }

    private func tile(_ symbol: String, _ value: String, _ label: String, tint: Color = Desk.green, padding: CGFloat = 8) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                Text(value).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
            }
            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
        }
        .frame(maxWidth: .infinity).padding(.vertical, padding)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Desk.tile))
    }
}

// MARK: - Spend trend

private struct DeskTrend: View {
    @ObservedObject var store: UsageStore
    let card: DeskCard

    var body: some View {
        let span = card.size == .large ? 30 : 14
        let days = store.deskDays(span, source: card.source)
        let today = days.last?.usd ?? 0
        let yesterday = days.dropLast().last?.usd ?? 0
        let week = days.suffix(7).reduce(0) { $0 + $1.usd }
        let title = card.source?.displayName ?? L10n.t("AI spend", "AI 花费")
        DeskFrame(size: card.size) {
            DeskHeader(title: title, symbol: "dollarsign.circle.fill", pill: (L10n.t("Live", "实时"), Desk.green), compact: card.size == .small)
            if card.size == .small {
                Spacer(minLength: 6)
                Text(L10n.t("Today", "今日")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                CountUpMoney(usd: today, font: .system(size: 26, weight: .semibold, design: .monospaced))
                Spacer(minLength: 6)
                DeskLine(values: days.map(\.usd), color: Desk.green).frame(height: 30)
                Spacer(minLength: 4)
                Text(L10n.t("7 days \(QuotaFormat.moneyCompact(week))", "近 7 天 \(QuotaFormat.moneyCompact(week))"))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
            } else {
                Spacer(minLength: 8)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("Today", "今日")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                        CountUpMoney(usd: today, font: .system(size: 34, weight: .semibold, design: .monospaced))
                    }
                    Spacer(minLength: 8)
                    if card.size == .medium {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(L10n.t("\(span) days", "近 \(span) 天")).font(.system(size: 10, design: .monospaced)).foregroundStyle(Desk.green)
                            DeskLine(values: days.map(\.usd), color: Desk.green).frame(width: 140, height: 52)
                        }
                    }
                }
                if card.size == .large {
                    Spacer(minLength: 10)
                    HStack {
                        Text(L10n.t("\(span) days", "近 \(span) 天")).font(.system(size: 10, design: .monospaced)).foregroundStyle(Desk.green)
                        Spacer()
                    }
                    DeskLine(values: days.map(\.usd), color: Desk.green).frame(height: 70)
                }
                Spacer(minLength: 10)
                HStack(spacing: 0) {
                    DeskStat(value: QuotaFormat.moneyCompact(yesterday), label: L10n.t("Yesterday", "昨日"), color: Desk.green)
                    StatDivider()
                    DeskStat(value: QuotaFormat.moneyCompact(week), label: L10n.t("7 days", "近 7 天"))
                    StatDivider()
                    DeskStat(value: QuotaFormat.compact(days.last?.tokens ?? 0), label: L10n.t("Tokens today", "今日 token"))
                }
                .padding(.vertical, 8)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                Spacer(minLength: 10)
                DeskFooter(symbol: "cpu", text: store.cost.topModel ?? "—", time: Desk.clock(store.archive.lastScan))
            }
        }
    }
}

struct DeskLine: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let top = max(values.max() ?? 1, 0.000_1)
            let step = values.count > 1 ? proxy.size.width / CGFloat(values.count - 1) : 0
            let points = values.enumerated().map {
                CGPoint(x: CGFloat($0.offset) * step, y: 3 + (proxy.size.height - 6) * (1 - CGFloat($0.element / top)))
            }
            ZStack {
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for point in points.dropFirst() { path.addLine(to: point) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if let last = points.last {
                    Circle().fill(color).frame(width: 7, height: 7).position(last)
                }
            }
        }
    }
}

// MARK: - Day by day

private struct DeskDaily: View {
    @ObservedObject var store: UsageStore
    let card: DeskCard

    var body: some View {
        let count = card.size == .large ? 14 : 7
        let days = store.deskDays(count, source: card.source)
        let peak = max(days.map(\.tokens).max() ?? 1, 1)
        let today = days.last?.tokens ?? 0
        let earlier = days.dropLast()
        let average = earlier.isEmpty ? 0 : earlier.reduce(0) { $0 + $1.tokens } / earlier.count
        DeskFrame(size: card.size) {
            DeskHeader(title: card.source?.displayName ?? L10n.t("Daily tokens", "每日用量"), symbol: "chart.bar.xaxis",
                       pill: (L10n.t("\(count) days", "近 \(count) 天"), Desk.green), compact: card.size == .small)
            if card.size == .small {
                Spacer(minLength: 6)
                Text(QuotaFormat.compact(today)).font(.system(size: 26, weight: .semibold, design: .monospaced)).foregroundStyle(Desk.green)
                Text(L10n.t("tokens today", "今日 token")).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 6)
                bars(days, peak: peak, height: 46, labels: false)
            } else {
                Spacer(minLength: 10)
                bars(days, peak: peak, height: card.size == .large ? 150 : 74, labels: true)
                Spacer(minLength: 10)
                HStack(spacing: 6) {
                    DeskStat(value: QuotaFormat.compact(today), label: L10n.t("Today", "今日"), color: Desk.green)
                    DeskStat(value: QuotaFormat.compact(average), label: L10n.t("Daily average", "日均"))
                    DeskStat(value: average > 0 ? "\(Int((Double(today) / Double(average) * 100).rounded()))%" : "—", label: L10n.t("Of average", "达到日均"))
                }
                if card.size == .large {
                    Spacer(minLength: 10)
                    DeskFooter(symbol: "cpu", text: store.cost.topModel ?? "—", time: Desk.clock(store.archive.lastScan))
                }
            }
        }
    }

    private func bars(_ days: [ArchiveSummary.Day], peak: Int, height: CGFloat, labels: Bool) -> some View {
        HStack(alignment: .bottom, spacing: days.count > 7 ? 4 : 7) {
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                let isToday = index == days.count - 1
                VStack(spacing: 4) {
                    if labels && isToday {
                        Text(QuotaFormat.compact(day.tokens)).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(Desk.green).fixedSize()
                    }
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(isToday ? Desk.green : Color.white.opacity(0.22))
                        .frame(height: max(3, height * CGFloat(day.tokens) / CGFloat(peak)))
                        .help("\(QuotaFormat.shortDay(day.day))：\(QuotaFormat.compact(day.tokens)) tokens · \(QuotaFormat.money(day.usd))")
                    if labels {
                        Text(label(day.day, many: days.count > 7)).font(.system(size: 9)).foregroundStyle(.white.opacity(isToday ? 0.9 : 0.45)).fixedSize()
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height + (labels ? 30 : 0), alignment: .bottom)
    }

    private func label(_ date: Date, many: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        if many {
            formatter.dateFormat = "d"
        } else {
            formatter.setLocalizedDateFormatFromTemplate("EEEEE")
        }
        return formatter.string(from: date)
    }
}

// MARK: - Provider grid

private struct DeskGrid: View {
    @ObservedObject var store: UsageStore
    let card: DeskCard

    var body: some View {
        let ids = store.deskProviders(card)
        let limit = card.size == .large ? 4 : (card.size == .medium ? 4 : 2)
        let shown = Array(ids.prefix(limit))
        let failing = ids.filter { !(store.serviceStatus[$0]?.level.isHealthy ?? true) }.count
        DeskFrame(size: card.size) {
            DeskHeader(title: "QuotaBar", symbol: "square.grid.2x2.fill",
                       pill: failing == 0 ? (L10n.t("All up", "全部正常"), Desk.green) : (L10n.t("\(failing) degraded", "\(failing) 个故障"), Palette.amber),
                       compact: card.size == .small)
            Spacer(minLength: card.size == .small ? 6 : 10)
            switch card.size {
            case .small:
                VStack(spacing: 8) {
                    ForEach(shown) { id in compactRow(id) }
                }
            case .medium:
                HStack(spacing: 6) {
                    ForEach(shown) { id in tile(id, big: false) }
                }
            case .large:
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(shown) { id in tile(id, big: true) }
                }
            }
            if card.size == .small {
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 10)
                DeskFooter(symbol: "square.grid.2x2", text: L10n.t("\(ids.count) providers · % \(store.deskShownLabel)", "\(ids.count) 个服务商 · \(store.deskShownLabel)"), time: store.deskUpdated(ids))
            }
        }
    }

    private func tile(_ id: ProviderID, big: Bool) -> some View {
        let window = store.deskWindows(id).lead
        let used = window?.usedPercent ?? 0
        return VStack(alignment: .leading, spacing: big ? 7 : 6) {
            HStack(spacing: 5) {
                ProviderGlyph(id: id, size: big ? 14 : 12, tint: .white)
                if big {
                    Text(id.displayName).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if window == nil, let balance = store.balanceFigure(for: id) {
                // A balance has no percentage and no bar to fill; the figure
                // takes the percentage's size and the bar's row stays empty,
                // so the tile is as tall as its neighbours.
                Text(balance)
                    .font(.system(size: big ? 30 : 22, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Color.clear.frame(height: big ? 8 : 7)
                Text(L10n.t("Balance", "余额")).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(window == nil ? "—" : "\(Int(store.deskShown(used).rounded()))")
                        .font(.system(size: big ? 30 : 22, weight: .semibold, design: .monospaced)).foregroundStyle(Desk.figureColor(used))
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .contentTransition(.numericText(value: used))
                    Text("%").font(.system(size: big ? 13 : 10, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                }
                Meter(percent: store.deskFill(window?.usedPercent), tint: Color(hex: UsageRamp.hex(used: used)), style: .stepped, height: big ? 5 : 4, track: .white.opacity(0.1))
                Text(window?.resetsAt.map { QuotaFormat.tick(to: $0) } ?? " ").font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            }
        }
        .padding(big ? 11 : 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Desk.tile))
    }

    private func compactRow(_ id: ProviderID) -> some View {
        let reading = store.deskWindows(id).lead?.usedPercent
        let used = reading ?? 0
        return VStack(spacing: 4) {
            HStack(spacing: 6) {
                ProviderGlyph(id: id, size: 13, tint: .white)
                Text(id.displayName).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                Spacer(minLength: 2)
                Text(reading == nil ? store.balanceFigure(for: id) ?? "—" : "\(Int(store.deskShown(used).rounded()))%").font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Desk.figureColor(used))
            }
            if reading != nil || store.balanceFigure(for: id) == nil {
                Meter(percent: store.deskFill(reading), tint: Color(hex: UsageRamp.hex(used: used)), style: .stepped, height: 4, track: .white.opacity(0.1))
            }
        }
    }
}

// MARK: - Closest first

private struct DeskRanking: View {
    @ObservedObject var store: UsageStore
    let card: DeskCard

    var body: some View {
        let ranked = store.deskProviders(card).sorted {
            (store.deskWindows($0).lead?.usedPercent ?? -1) > (store.deskWindows($1).lead?.usedPercent ?? -1)
        }
        let limit = card.size == .large ? 5 : 3
        DeskFrame(size: card.size) {
            DeskHeader(title: card.size == .small ? L10n.t("Running out", "快用完") : L10n.t("Closest to the limit", "快用完的排前面"),
                       symbol: "flame.fill", pill: (L10n.t("Live", "实时"), Desk.green), compact: card.size == .small)
            // The list starts under the title, not centred in the card: with
            // fewer providers than rows a centred list left a band of empty
            // card over it.
            Color.clear.frame(height: card.size == .small ? 8 : 14)
            VStack(spacing: card.size == .small ? 9 : 13) {
                ForEach(Array(ranked.prefix(limit).enumerated()), id: \.element) { index, id in
                    row(index: index, id: id, compact: card.size == .small)
                }
            }
            Spacer(minLength: 8)
            if card.size == .large {
                DeskFooter(symbol: "flame", text: L10n.t("Sorted by what runs out first", "按剩余从少到多排序"), time: store.deskUpdated(ranked))
            }
        }
    }

    private func row(index: Int, id: ProviderID, compact: Bool) -> some View {
        let window = store.deskWindows(id).lead
        let used = window?.usedPercent ?? 0
        return HStack(spacing: compact ? 7 : 10) {
            if !compact {
                Text("\(index + 1)").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(.white.opacity(0.35)).frame(width: 12)
            }
            ProviderGlyph(id: id, size: compact ? 14 : 18, tint: .white)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(id.displayName).font(.system(size: compact ? 11 : 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Spacer(minLength: 2)
                    if !compact {
                        Text(window?.resetsAt.map { QuotaFormat.tick(to: $0) } ?? "").font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
                    }
                    Text(window == nil ? store.balanceFigure(for: id) ?? "—" : "\(Int(store.deskShown(used).rounded()))%")
                        .font(.system(size: compact ? 12 : 13, weight: .semibold, design: .monospaced)).foregroundStyle(Desk.figureColor(used))
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(width: compact ? 34 : 42, alignment: .trailing)
                }
                if window != nil || store.balanceFigure(for: id) == nil {
                    Meter(percent: store.deskFill(window?.usedPercent), tint: Color(hex: UsageRamp.hex(used: used)), style: .continuous, height: compact ? 4 : 5, track: .white.opacity(0.1))
                        .paceTick(window ?? UsageWindow(title: ""), mode: store.meterMode, always: false)
                }
            }
        }
    }
}

// MARK: - Classic

private struct DeskClassic: View {
    @ObservedObject var store: UsageStore
    let card: DeskCard

    var body: some View {
        DesktopWidgetView(
            store: store,
            density: card.size == .small ? .compact : (card.size == .medium ? .standard : .detailed),
            providers: store.deskProviders(card))
    }
}
