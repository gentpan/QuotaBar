import SwiftUI
import QuotaCore

// MARK: - Usage pane: a year of tokens, as a grid and as figures

/// Two tabs over one ledger, on the window's own light cards. A black card
/// was tried first, after codex-island, and sat in the pane like a hole; the
/// grid reads just as well on the light surface, GitHub-style, and belongs
/// to the window it is in. What is kept from codex-island: SF Mono figures,
/// hue from the CLI that logged the day, intensity by rank among active days.
struct UsagePane: View {
    @ObservedObject var store: UsageStore
    @State private var tab: Tab = .heatmap

    enum Tab: Hashable, CaseIterable {
        case heatmap
        case volume

        var label: String {
            switch self {
            case .heatmap: L10n.t("Heatmap", "热力图")
            case .volume: L10n.t("Volume", "数据量")
            }
        }
    }

    var body: some View {
        HStack {
            GlassSegmented(
                options: Tab.allCases.map { (value: $0, label: $0.label) },
                selection: tab,
                onSelect: { tab = $0 })
            .frame(width: 200)
            Spacer(minLength: 0)
            if store.isComputingLedger {
                HStack(spacing: Design.space1 + 2) {
                    ProgressView().controlSize(.mini)
                    Text(L10n.t("Scanning session logs…", "正在扫描会话日志…"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }

        if store.ledger.isEmpty {
            placeholder
        } else {
            switch tab {
            case .heatmap: HeatmapCards(ledger: store.ledger)
            case .volume: VolumeCards(ledger: store.ledger)
            }
            SettingFootnote(footnote)
        }
        Color.clear.frame(height: 0).onAppear { store.wantLedger() }
    }

    private var placeholder: some View {
        Text(store.isComputingLedger
            ? L10n.t("Reading this year's session logs. The first pass over a large tree takes a while.",
                     "正在读取今年的会话日志。日志很多时，第一次要等一会儿。")
            : L10n.t("Nothing logged yet.", "还没有记录。"))
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
            .background(RoundedRectangle(cornerRadius: Design.radiusPanel, style: .continuous).fill(Design.surface))
    }

    private var footnote: String {
        let sources = store.ledger.sources.map(\.source.displayName).joined(separator: " / ")
        let scanned = QuotaFormat.age(of: store.ledger.scannedAt)
        return L10n.t(
            "From this Mac's \(sources) session logs. Tokens include cache reads and writes; cost is an estimate at list prices and cannot see what a plan includes. \(store.ledger.deduplicated) replayed turns dropped. Scanned \(scanned).",
            "来自本机的 \(sources) 会话日志。token 含缓存读写；费用按公开价目估算，看不到套餐内含的部分。已去重 \(store.ledger.deduplicated) 条回放记录。扫描于\(scanned)。")
    }
}

// MARK: - Shared pieces

/// "37.9" and "B" as two runs, so the unit can sit smaller and dimmer.
private struct TokenFigure {
    let value: String
    let unit: String

    init(_ count: Int) {
        let compact = QuotaFormat.compact(count)
        if let last = compact.last, last.isLetter {
            value = String(compact.dropLast())
            unit = String(last).uppercased()
        } else {
            value = compact
            unit = ""
        }
    }
}

private struct BigFigure: View {
    let count: Int
    var size: CGFloat = 30
    var color: Color = .primary

    var body: some View {
        let figure = TokenFigure(count)
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(figure.value)
                .font(.system(size: size, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
            if !figure.unit.isEmpty {
                Text(figure.unit)
                    .font(.system(size: size * 0.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color.opacity(0.6))
            }
        }
        .lineLimit(1)
        .monospacedDigit()
    }
}

private struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

private struct Rule: View {
    var body: some View { Divider().opacity(0.4) }
}

private func share(_ part: Int, of total: Int) -> String {
    guard total > 0 else { return "0%" }
    return "\(Int((Double(part) / Double(total) * 100).rounded()))%"
}

private extension CostSource {
    var color: Color { Color(hex: accentHex) }
}

// MARK: - Heatmap

/// A year of days, one cell each, seven to a column. Hue is the CLI that
/// logged most of the day; intensity is the day's rank among active days,
/// so a quiet month is not washed out by one enormous week. Click a chip to
/// narrow the grid to one CLI, a model row to narrow it to one model, a
/// cell to read that day.
private struct HeatmapCards: View {
    let ledger: UsageLedger
    @State private var scope: LedgerScope = .all
    @State private var selectedDay: Date?

    private var selected: UsageDay? {
        guard let selectedDay else { return nil }
        return ledger.days.first { $0.day == selectedDay }
    }

    var body: some View {
        SettingsCard(L10n.t("\(ledger.year) heatmap", "\(ledger.year) 年热力图")) {
            header
            HeatmapGrid(ledger: ledger, scope: scope, selectedDay: $selectedDay)
            if let selected {
                DayDetail(day: selected, ledger: ledger, scope: scope)
            }
        }
        SettingsCard(L10n.t("By model", "按模型")) {
            ModelList(ledger: ledger, scope: $scope)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: Design.space4) {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(text: headerLabel)
                BigFigure(count: selected?.tokens(in: scope) ?? ledger.total(scope))
            }
            Text(subline)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            Spacer(minLength: 0)
            chips
                .padding(.bottom, 6)
        }
    }

    private var headerLabel: String {
        if let selected {
            return DateFormatter.localizedString(from: selected.day, dateStyle: .medium, timeStyle: .none)
        }
        let year = "\(ledger.year) TOKEN"
        switch scope {
        case .all: return year
        case let .source(source): return "\(source.displayName) · \(year)"
        case let .model(model): return "\(model) · \(year)"
        }
    }

    private var subline: String {
        if let selected {
            guard selected.tokens > 0 else { return L10n.t("No activity", "没有活动") }
            let leader = selected.contributions.first
            if let leader, Double(leader.tokens) / Double(selected.tokens) >= 0.6 {
                return L10n.t("Mostly \(leader.source.displayName)", "主要是 \(leader.source.displayName)")
            }
            return L10n.t("Mixed use", "混合使用")
        }
        let count = ledger.activeDays(scope)
        return L10n.t("\(count) active days", "\(count) 个活跃日")
    }

    /// One chip per CLI with its share of the year; the selected one is lit.
    private var chips: some View {
        let total = ledger.total()
        return HStack(spacing: Design.space2) {
            ForEach(ledger.sources, id: \.source) { item in
                let on = scope == .source(item.source)
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        scope = on ? .all : .source(item.source)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(item.source.color).frame(width: 6, height: 6)
                        Text("\(item.source.displayName) \(share(item.tokens, of: total))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(on ? Color.primary : Color.secondary)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(on ? item.source.color.opacity(0.16) : Design.surface))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(on
                    ? L10n.t("Show every CLI", "显示全部")
                    : L10n.t("Only \(item.source.displayName)", "只看 \(item.source.displayName)"))
            }
        }
    }
}

/// Ranks active days into six bands by quantile, so intensity reads as
/// "how busy for you" rather than as a fraction of the single busiest day.
private struct IntensityScale {
    private let sorted: [Int]

    init(values: [Int]) {
        sorted = values.filter { $0 > 0 }.sorted()
    }

    func level(_ tokens: Int) -> Int {
        guard tokens > 0, !sorted.isEmpty else { return 0 }
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] <= tokens { low = mid + 1 } else { high = mid }
        }
        switch Double(low) / Double(sorted.count) {
        case ..<0.15: return 1
        case ..<0.35: return 2
        case ..<0.60: return 3
        case ..<0.80: return 4
        case ..<0.93: return 5
        default: return 6
        }
    }

    /// On the light surface the ladder starts higher than codex-island's
    /// does on black: a 16% tint of terracotta on white is nearly white.
    func opacity(_ tokens: Int) -> Double {
        switch level(tokens) {
        case 1: 0.22
        case 2: 0.36
        case 3: 0.5
        case 4: 0.66
        case 5: 0.83
        case 6: 1.0
        default: 0.07
        }
    }
}

private struct HeatmapGrid: View {
    let ledger: UsageLedger
    let scope: LedgerScope
    @Binding var selectedDay: Date?

    private var calendar: Calendar { .current }
    private let spacing: CGFloat = 2

    /// Sunday or Monday first, whichever the calendar says.
    private var gridStart: Date {
        guard let first = ledger.days.first?.day else { return .distantPast }
        let weekday = calendar.component(.weekday, from: first)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -offset, to: first) ?? first
    }

    private var weekCount: Int {
        guard let last = ledger.days.last?.day else { return 1 }
        let span = calendar.dateComponents([.day], from: gridStart, to: last).day ?? 0
        return span / 7 + 1
    }

    /// Days of the first week that belong to last year.
    private var leadingGap: Int {
        guard let first = ledger.days.first?.day else { return 0 }
        return calendar.dateComponents([.day], from: gridStart, to: first).day ?? 0
    }

    var body: some View {
        let scale = IntensityScale(values: ledger.days.map { $0.tokens(in: scope) })
        GeometryReader { proxy in
            let cell = max(6, min(14, ((proxy.size.width - CGFloat(weekCount - 1) * spacing) / CGFloat(weekCount)).rounded(.down)))
            VStack(alignment: .leading, spacing: 6) {
                monthRail(cell: cell)
                    .frame(height: 12)
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(0..<weekCount, id: \.self) { week in
                        VStack(spacing: spacing) {
                            ForEach(0..<7, id: \.self) { row in
                                let index = week * 7 + row - leadingGap
                                if index >= 0, index < ledger.days.count {
                                    HeatCell(
                                        day: ledger.days[index],
                                        scope: scope,
                                        scale: scale,
                                        size: cell,
                                        isFuture: ledger.days[index].day > ledger.today,
                                        isSelected: selectedDay == ledger.days[index].day)
                                    {
                                        let day = ledger.days[index].day
                                        withAnimation(.easeOut(duration: 0.2)) {
                                            selectedDay = selectedDay == day ? nil : day
                                        }
                                    }
                                } else {
                                    Color.clear.frame(width: cell, height: cell)
                                }
                            }
                        }
                    }
                }
            }
        }
        // GeometryReader takes whatever height it is offered, so the card
        // has to say: the rail, its gap, and seven of the largest cell.
        .frame(height: 12 + 6 + 7 * 14 + 6 * spacing)
    }

    private func monthRail(cell: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(1...12, id: \.self) { month in
                if let first = calendar.date(from: DateComponents(year: ledger.year, month: month, day: 1)) {
                    let offset = calendar.dateComponents([.day], from: gridStart, to: first).day ?? 0
                    Text(L10n.t(calendar.shortMonthSymbols[month - 1], "\(month)月"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .offset(x: CGFloat(offset / 7) * (cell + spacing))
                }
            }
        }
    }
}

private struct HeatCell: View {
    let day: UsageDay
    let scope: LedgerScope
    let scale: IntensityScale
    let size: CGFloat
    let isFuture: Bool
    let isSelected: Bool
    let onTap: () -> Void

    @State private var hovering = false

    private var tokens: Int { day.tokens(in: scope) }
    private var radius: CGFloat { min(3, size * 0.22) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if isFuture {
                shape.fill(Color.primary.opacity(0.03))
            } else {
                fill
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(stroke, lineWidth: isSelected ? 1.5 : 1))
                    .onTapGesture(perform: onTap)
                    .onHover { hovering = $0 }
                    .help(help)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var fill: some View {
        let opacity = tokens > 0 ? scale.opacity(tokens) : 0.07
        if let hue {
            hue.opacity(opacity)
                .overlay(alignment: .bottom) {
                    // A split day shows its mix as a stripe along the foot.
                    if case .all = scope, day.contributions.count > 1 {
                        HStack(spacing: 0) {
                            ForEach(day.contributions, id: \.source) { item in
                                item.source.color.opacity(max(0.45, opacity))
                                    .frame(width: size * CGFloat(Double(item.tokens) / Double(max(1, day.tokens))))
                            }
                        }
                        .frame(height: max(2, size * 0.2))
                    }
                }
        } else {
            Color.primary.opacity(opacity)
        }
    }

    private var hue: Color? {
        switch scope {
        case .all, .model: day.leadingSource?.color
        case let .source(source): source.color
        }
    }

    private var stroke: Color {
        if isSelected { return Color.primary.opacity(0.7) }
        if hovering { return Color.primary.opacity(0.35) }
        return .clear
    }

    private var help: String {
        let date = DateFormatter.localizedString(from: day.day, dateStyle: .medium, timeStyle: .none)
        guard tokens > 0 else { return L10n.t("\(date): nothing", "\(date)：没有活动") }
        let split = day.contributions
            .map { "\($0.source.displayName) \(share($0.tokens, of: day.tokens))" }
            .joined(separator: " · ")
        return "\(date): \(QuotaFormat.compact(tokens)) tokens · \(split)"
    }
}

/// The selected day, under the grid: total, each CLI's share, the cost.
private struct DayDetail: View {
    let day: UsageDay
    let ledger: UsageLedger
    let scope: LedgerScope

    var body: some View {
        VStack(spacing: Design.space2) {
            Rule()
            HStack(alignment: .center, spacing: Design.space4) {
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel(text: DateFormatter.localizedString(from: day.day, dateStyle: .long, timeStyle: .none))
                    Text(L10n.t("All tokens", "全部 token"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                metric(L10n.t("Total", "合计"), day.tokens, color: .primary)
                ForEach(day.contributions, id: \.source) { item in
                    metric(item.source.displayName, item.tokens, color: item.source.color)
                }
                VStack(alignment: .trailing, spacing: 2) {
                    SectionLabel(text: L10n.t("Est. cost", "估算费用"))
                    Text(QuotaFormat.usd(day.usd))
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                }
            }
        }
    }

    private func metric(_ label: String, _ count: Int, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            SectionLabel(text: label)
            BigFigure(count: count, size: 14, color: color)
        }
    }
}

/// Models, largest first, with their share of the current scope. A row is
/// a filter: click it and the grid shows that model alone.
private struct ModelList: View {
    let ledger: UsageLedger
    @Binding var scope: LedgerScope

    private var rows: [(model: String, source: CostSource, tokens: Int)] {
        Array(ledger.models(within: scope.source).prefix(8))
    }

    private var total: Int {
        ledger.total(scope.source.map { .source($0) } ?? .all)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.space1) {
            ForEach(rows, id: \.model) { row in
                let on = scope == .model(row.model)
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        scope = on ? (scope.source.map { .source($0) } ?? .all) : .model(row.model)
                    }
                } label: {
                    HStack(spacing: Design.space2) {
                        Circle().fill(row.source.color).frame(width: 6, height: 6)
                        Text(row.model)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                        Text(row.source.displayName)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: Design.space2)
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Design.track)
                                Capsule().fill(row.source.color.opacity(on ? 1 : 0.75))
                                    .frame(width: max(2, proxy.size.width * CGFloat(Double(row.tokens) / Double(max(1, total)))))
                            }
                        }
                        .frame(width: 120, height: 4)
                        Text(QuotaFormat.compact(row.tokens))
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 56, alignment: .trailing)
                        Text(share(row.tokens, of: total))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: Design.radiusTile - 2, style: .continuous)
                            .fill(on ? row.source.color.opacity(0.14) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Volume

/// The figures behind the grid: today, this week, this month, this year —
/// per CLI in its colour, with the estimate under each — then the in/out/
/// cache split and the models for one chosen period.
private struct VolumeCards: View {
    let ledger: UsageLedger
    @State private var period: LedgerPeriod = .month

    var body: some View {
        SettingsCard(L10n.t("By period", "各周期用量")) {
            block(nil)
            ForEach(ledger.sources, id: \.source) { item in
                Rule()
                block(item.source)
            }
        }
        SettingsCard(L10n.t("Breakdown", "构成")) {
            breakdown
        }
    }

    // MARK: Period figures

    private func block(_ source: CostSource?) -> some View {
        let color = source?.color ?? .primary
        return VStack(alignment: .leading, spacing: Design.space3) {
            HStack(spacing: Design.space2) {
                if let source {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(source.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(L10n.t(
                        "\(ledger.activeDays(.source(source))) active days",
                        "\(ledger.activeDays(.source(source))) 个活跃日"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text(L10n.t("All CLIs", "全部"))
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            HStack(alignment: .top, spacing: Design.space4) {
                ForEach(LedgerPeriod.allCases) { period in
                    let sum = ledger.sum(period, source: source)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: Design.space1) {
                            SectionLabel(text: period.displayName)
                            if let reset = resetLabel(period) {
                                Text(reset)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        BigFigure(count: sum.tokens, size: 26, color: color)
                        Text(QuotaFormat.usd(sum.usd))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// "↻ 19h": how long until the period rolls over.
    private func resetLabel(_ period: LedgerPeriod) -> String? {
        let calendar = Calendar.current
        let now = Date()
        let end: Date?
        switch period {
        case .today: end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        case .week: end = calendar.dateInterval(of: .weekOfYear, for: now)?.end
        case .month: end = calendar.dateInterval(of: .month, for: now)?.end
        case .year: end = calendar.dateInterval(of: .year, for: now)?.end
        }
        guard let end else { return nil }
        let hours = Int(end.timeIntervalSince(now) / 3600)
        return "↻ " + (hours < 48 ? "\(max(1, hours))h" : "\(hours / 24)d")
    }

    // MARK: Breakdown for one period

    private var breakdown: some View {
        let sum = ledger.sum(period)
        return VStack(alignment: .leading, spacing: Design.space3) {
            GlassSegmented(
                options: LedgerPeriod.allCases.map { (value: $0, label: $0.displayName) },
                selection: period,
                onSelect: { period = $0 })
            .frame(width: 300)
            HStack(alignment: .top, spacing: Design.space4) {
                kind(L10n.t("Input", "输入"), sum.input)
                kind(L10n.t("Output", "输出"), sum.output)
                kind(L10n.t("Cache read", "缓存读取"), sum.cacheRead)
                kind(L10n.t("Cache write", "缓存写入"), sum.cacheWrite)
                kind(L10n.t("Est. cost", "估算费用"), nil, text: QuotaFormat.usd(sum.usd))
            }
            let models = ledger.models(days: ledger.days(in: period)).prefix(6)
            if !models.isEmpty {
                Rule()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(models), id: \.model) { row in
                        HStack(spacing: Design.space2) {
                            Circle().fill(row.source.color).frame(width: 6, height: 6)
                            Text(row.model)
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1)
                            Spacer(minLength: Design.space2)
                            Text(QuotaFormat.compact(row.tokens))
                                .font(.system(size: 12, design: .monospaced))
                            Text(share(row.tokens, of: sum.tokens))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private func kind(_ label: String, _ count: Int?, text: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel(text: label)
            Text(text ?? QuotaFormat.compact(count ?? 0))
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
