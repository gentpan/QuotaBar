import SwiftUI
import QuotaCore

// MARK: - A prepaid account on its card

/// What a pay-as-you-go provider's card shows in place of meters: the
/// balance in each currency, then usage over today, seven days, thirty days
/// or all of it — a figure, a chart of bars or a line, and where it went, by
/// API key or by model, when the provider says.
///
/// No meter anywhere. A balance has no ceiling, so a meter of it only ever
/// sat empty; the figures and the chart are the reading.
struct BalanceSheetView: View {
    @ObservedObject var store: UsageStore
    let id: ProviderID
    let sheet: BalanceSheet
    var compact = false
    /// The card's own disclosure: every key and model instead of the top few.
    var expanded = false
    /// The copied image: thirty days, the chart and the models — key names
    /// stay on this Mac.
    var forExport = false

    /// A style for off-screen renders, which must not write the owner's
    /// preference to show both.
    var chartStyle: BalanceChartStyle?

    @State private var period: KeyUsagePeriod
    @State private var breakdown: Breakdown = .keys
    /// The key opened from the list, by the provider's id for it.
    @State private var focusedKey: String?

    enum Breakdown: Hashable {
        case keys
        case models
    }

    init(
        store: UsageStore, id: ProviderID, sheet: BalanceSheet,
        compact: Bool = false, expanded: Bool = false, forExport: Bool = false,
        period: KeyUsagePeriod = .last7, focusedKey: String? = nil, chartStyle: BalanceChartStyle? = nil)
    {
        self.chartStyle = chartStyle
        self.store = store
        self.id = id
        self.sheet = sheet
        self.compact = compact
        self.expanded = expanded
        self.forExport = forExport
        _period = State(initialValue: period)
        _focusedKey = State(initialValue: focusedKey)
    }

    /// Rows shown before the card is expanded.
    static let upFront = 3

    /// Whether the card's disclosure has anything of this sheet's to reveal.
    static func hasMore(_ sheet: BalanceSheet) -> Bool {
        KeyUsagePeriod.allCases.contains { period in
            sheet.activeKeys(in: period).count > upFront || (sheet.usage[period]?.models.count ?? 0) > upFront
        }
    }

    private var accent: Color { Color(hex: id.accentHex) }
    private var shownPeriod: KeyUsagePeriod { forExport ? .last30 : period }
    private var style: BalanceChartStyle { forExport ? .bars : chartStyle ?? store.experience.balanceChart }
    private var figures: KeyUsageFigures? { sheet.usage[shownPeriod] }
    private var models: [ModelCost] { figures?.models ?? [] }
    private var keysInPeriod: [APIKeyUsage] { sheet.activeKeys(in: shownPeriod) }
    private var shownBreakdown: Breakdown? {
        let hasKeys = sheet.keys != nil && !keysInPeriod.isEmpty
        if forExport { return models.isEmpty ? nil : .models }
        if hasKeys && !models.isEmpty { return breakdown }
        if hasKeys { return .keys }
        if !models.isEmpty { return .models }
        return sheet.keys != nil && shownPeriod != .all ? .keys : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            if !sheet.balances.isEmpty {
                balances
            }
            if sheet.canCallAPI == false {
                Label(L10n.t("Not enough to pay for API calls", "余额不足，无法调用 API"), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.red)
            }
            if sheet.hasUsage {
                usage
            }
            if !forExport, let note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Says an estimate is one and since when, then whatever the provider
    /// says about keys it cannot see.
    private var note: String? {
        var parts: [String] = []
        if sheet.estimated {
            let since = sheet.estimatedSince.map { $0.formatted(.dateTime.month(.abbreviated).day().hour().minute()) } ?? ""
            parts.append(L10n.t(
                "Usage estimated from the balance's falls since \(since); top-ups aren't counted.",
                "用量按余额的减少估算，自 \(since) 开始记录，充值不计入。"))
        }
        if let keysNote = sheet.keysNote, sheet.keys == nil || expanded || sheet.estimated {
            parts.append(keysNote)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: Balances

    private var balances: some View {
        HStack(alignment: .top, spacing: 18) {
            ForEach(sheet.balances, id: \.currency) { balance in
                VStack(alignment: .leading, spacing: 2) {
                    Text(QuotaFormat.amount(balance.total, code: balance.currency))
                        .font(.system(size: compact ? 17 : 20, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(balance.total > 0 ? Color.white : Palette.red)
                        .contentTransition(.numericText(value: balance.total))
                    Text(source(of: balance))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func source(of balance: AccountBalance) -> String {
        if let granted = balance.granted, granted > 0 {
            let paid = QuotaFormat.amount(balance.paid ?? balance.total - granted, code: balance.currency)
            let gift = QuotaFormat.amount(granted, code: balance.currency)
            return L10n.t("\(paid) paid + \(gift) granted", "充值 \(paid) + 赠送 \(gift)")
        }
        return sheet.balances.count > 1
            ? L10n.t("Balance · \(balance.currency)", "余额 · \(balance.currency)")
            : L10n.t("Balance", "余额")
    }

    // MARK: Usage

    private var usage: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            HStack(spacing: 8) {
                if forExport {
                    Text(shownPeriod.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                } else {
                    chips(KeyUsagePeriod.allCases.map { ($0, $0.displayName) }, selection: period) { period = $0 }
                }
                Spacer(minLength: 6)
                if !forExport, hasAnyChart {
                    styleToggle
                }
            }
            Text(summaryLine)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            // An opened key draws its own days; the account's would repeat them.
            if focusedKey == nil, let buckets = sheet.chart[shownPeriod], !buckets.isEmpty {
                UsageChart(buckets: buckets, span: shownPeriod.bucket, style: style, accent: accent, height: compact ? 44 : 54)
            }
            if let shown = shownBreakdown {
                if !forExport, sheet.keys != nil, !keysInPeriod.isEmpty, !models.isEmpty, focusedKey == nil {
                    chips([(Breakdown.keys, "API Key"), (.models, L10n.t("Models", "模型"))], selection: breakdown) { breakdown = $0 }
                }
                switch shown {
                case .keys:
                    if let focused = focusedKey, let key = sheet.keys?.first(where: { $0.id == focused }) {
                        KeyDetailView(key: key, period: shownPeriod, style: style, accent: accent) {
                            withAnimation(Motion.animation(Motion.spring)) { focusedKey = nil }
                        }
                        .transition(.opacity)
                    } else {
                        keyRows
                    }
                case .models:
                    modelRows
                }
            }
        }
    }

    private var hasAnyChart: Bool { sheet.chart.values.contains { !$0.isEmpty } }

    /// "Spent ¥36.79 · 4,210 requests · 61.0M tokens", "about" for an
    /// estimate, or that nothing was spent.
    private var summaryLine: String {
        guard let figures, !figures.isEmpty else {
            return L10n.t("Nothing spent \(shownPeriod.displayName.lowercased())", "\(shownPeriod.displayName)没有消费")
        }
        var parts = [figures.costLine]
        if let counts = Self.counts(requests: figures.requests, tokens: figures.tokens) { parts.append(counts) }
        let line = parts.joined(separator: " · ")
        return sheet.estimated
            ? L10n.t("Spent about \(line)", "约消费 \(line)")
            : L10n.t("Spent \(line)", "消费 \(line)")
    }

    private var styleToggle: some View {
        HStack(spacing: 2) {
            ForEach(BalanceChartStyle.allCases) { option in
                let selected = option == style
                Image(systemName: option == .bars ? "chart.bar.fill" : "chart.xyaxis.line")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(selected ? .white : .white.opacity(0.45))
                    .frame(width: 24, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(selected ? 0.13 : 0)))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(Motion.animation(Motion.spring)) {
                            store.updateExperience { $0.balanceChart = option }
                        }
                    }
                    .help(option == .bars ? L10n.t("Bars", "柱状图") : L10n.t("Line", "折线图"))
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    @ViewBuilder
    private var keyRows: some View {
        let keys = keysInPeriod
        let shown = expanded ? keys : Array(keys.prefix(Self.upFront))
        if keys.isEmpty {
            empty
        }
        ForEach(shown) { key in
            if let figures = key.usage[shownPeriod] {
                usageRow(
                    title: key.name,
                    subtitle: [key.maskedKey, key.isDisabled ? L10n.t("deleted", "已删除") : nil].compactMap { $0 }.joined(separator: " · "),
                    figures: figures.costs, requests: figures.requests, tokens: figures.tokens)
                    .onTapGesture {
                        guard !forExport, !key.daily.isEmpty || !figures.models.isEmpty else { return }
                        withAnimation(Motion.animation(Motion.spring)) { focusedKey = key.id }
                    }
                    .help(L10n.t("Click for this key's days and models", "点击查看这个 Key 每天的用量和模型"))
            }
        }
        more(keys.count - shown.count, idle: (sheet.keys?.count ?? 0) - keys.count)
    }

    @ViewBuilder
    private var modelRows: some View {
        let shown = expanded && !forExport ? models : Array(models.prefix(Self.upFront))
        if models.isEmpty {
            empty
        }
        ForEach(shown) { model in
            usageRow(title: model.model, subtitle: nil, figures: model.costs, requests: model.requests, tokens: model.tokens)
        }
        more(models.count - shown.count, idle: 0)
    }

    private var empty: some View {
        Text(L10n.t("No usage \(shownPeriod.displayName.lowercased())", "\(shownPeriod.displayName)没有用量"))
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.4))
    }

    @ViewBuilder
    private func more(_ hidden: Int, idle: Int) -> some View {
        if !forExport, hidden > 0 || (expanded && idle > 0) {
            HStack(spacing: 4) {
                if hidden > 0 {
                    Text(L10n.t("\(hidden) more", "还有 \(hidden) 个"))
                }
                if expanded, idle > 0 {
                    Text(L10n.t("\(idle) keys unused \(shownPeriod.displayName.lowercased())", "\(idle) 个 Key \(shownPeriod.displayName)未使用"))
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.4))
            .contentShape(Rectangle())
            .onTapGesture {
                guard hidden > 0 else { return }
                withAnimation(Motion.animation(Motion.spring)) { store.toggleCardExpanded(id) }
            }
        }
    }

    private func usageRow(title: String, subtitle: String?, figures: [Money], requests: Int?, tokens: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(KeyUsageFigures(costs: figures).costLine)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                if let counts = Self.counts(requests: requests, tokens: tokens) {
                    Text(counts)
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .contentShape(Rectangle())
    }

    /// "4,210 requests · 61.0M tokens", or nil when the provider counts neither.
    static func counts(requests: Int?, tokens: Int?) -> String? {
        var parts: [String] = []
        if let requests, requests > 0 {
            let count = requests.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
            parts.append(L10n.t("\(count) requests", "\(count) 次请求"))
        }
        if let tokens, tokens > 0 { parts.append("\(QuotaFormat.compact(tokens)) tokens") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Chips

    /// The spend card's period switch, smaller: a row of words, the chosen
    /// one lit.
    private func chips<Value: Hashable>(_ options: [(Value, String)], selection: Value, onSelect: @escaping (Value) -> Void) -> some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                Text(label)
                    .font(.system(size: 10, weight: value == selection ? .semibold : .medium))
                    .foregroundStyle(value == selection ? .white : .white.opacity(0.5))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(value == selection ? 0.13 : 0)))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(Motion.animation(Motion.spring)) { onSelect(value) }
                    }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}

// MARK: - The chart

/// Usage as bars or a line over hours, days or months; the current one in
/// full colour, and each one's figures on hover.
struct UsageChart: View {
    let buckets: [UsageBucket]
    let span: UsageBucket.Span
    let style: BalanceChartStyle
    let accent: Color
    var height: CGFloat = 54

    private var peak: Double { max(0.000_001, buckets.map(\.costTotal).max() ?? 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { proxy in
                if style == .line, buckets.count > 1 {
                    line(in: proxy.size)
                } else {
                    bars(in: proxy.size)
                }
            }
            .frame(height: height)
            if let first = buckets.first, let last = buckets.last {
                HStack {
                    Text(axis(first.start))
                    Spacer()
                    Text(axis(last.start))
                }
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    private func bars(in size: CGSize) -> some View {
        let gap: CGFloat = buckets.count > 20 ? 1.5 : 3
        return HStack(alignment: .bottom, spacing: gap) {
            ForEach(buckets) { bucket in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(bucket.costTotal > 0 ? accent.opacity(isCurrent(bucket) ? 1 : 0.62) : Color.white.opacity(0.07))
                    .frame(height: max(2, size.height * bucket.costTotal / peak))
                    .frame(maxWidth: .infinity)
                    .help(detail(bucket))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .bottom)
    }

    private func line(in size: CGSize) -> some View {
        let step = size.width / CGFloat(buckets.count - 1)
        let points = buckets.enumerated().map { index, bucket in
            CGPoint(x: CGFloat(index) * step, y: size.height - 2 - (size.height - 4) * bucket.costTotal / peak)
        }
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: size.height))
                for point in points { path.addLine(to: point) }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
            }
            .fill(accent.opacity(0.16))
            Path { path in
                path.addLines(points)
            }
            .stroke(accent, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            if let last = points.last {
                Circle().fill(accent).frame(width: 5, height: 5).position(last)
            }
            // Hover targets, one column per bucket.
            HStack(spacing: 0) {
                ForEach(buckets) { bucket in
                    Color.clear.contentShape(Rectangle()).frame(maxWidth: .infinity).help(detail(bucket))
                }
            }
            .frame(width: size.width + step, height: size.height)
            .offset(x: -step / 2)
        }
        .frame(width: size.width, height: size.height)
    }

    private func isCurrent(_ bucket: UsageBucket) -> Bool {
        let calendar = Calendar.current
        switch span {
        case .hour: return calendar.isDate(bucket.start, equalTo: Date(), toGranularity: .hour)
        case .day: return calendar.isDateInToday(bucket.start)
        case .month: return calendar.isDate(bucket.start, equalTo: Date(), toGranularity: .month)
        }
    }

    private func axis(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour], from: date)
        switch span {
        case .hour: return String(format: "%02d:00", parts.hour ?? 0)
        case .day: return "\(parts.month ?? 0)/\(parts.day ?? 0)"
        case .month: return "\(parts.year ?? 0)/\(parts.month ?? 0)"
        }
    }

    private func detail(_ bucket: UsageBucket) -> String {
        let when: String = switch span {
        case .hour: bucket.start.formatted(.dateTime.hour().minute())
        case .day: bucket.start.formatted(.dateTime.month(.abbreviated).day())
        case .month: bucket.start.formatted(.dateTime.year().month(.abbreviated))
        }
        var parts = [KeyUsageFigures(costs: bucket.costs).costLine]
        if let counts = BalanceSheetView.counts(requests: bucket.requests, tokens: bucket.tokens) { parts.append(counts) }
        return "\(when) · " + parts.joined(separator: " · ")
    }
}

// MARK: - One key

/// One key opened from the list: today, seven and thirty days side by side,
/// its last thirty days as a chart, and its models in the chosen period.
private struct KeyDetailView: View {
    let key: APIKeyUsage
    let period: KeyUsagePeriod
    let style: BalanceChartStyle
    let accent: Color
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Label(L10n.t("All keys", "全部 Key"), systemImage: "chevron.left")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onBack)
                Spacer(minLength: 6)
                if let lastUsed = key.lastUsed {
                    Text(L10n.t("Last used \(QuotaFormat.age(of: lastUsed))", "最近使用：\(QuotaFormat.age(of: lastUsed))"))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(key.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text([key.maskedKey, key.isDisabled ? L10n.t("deleted", "已删除") : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }
            HStack(alignment: .top, spacing: 8) {
                ForEach([KeyUsagePeriod.today, .last7, .last30]) { period in
                    let figures = key.usage[period]
                    VStack(alignment: .leading, spacing: 2) {
                        Text(period.displayName)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                        Text(figures?.costLine ?? "—")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(figures == nil ? 0.35 : 0.9))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        if let figures, let counts = BalanceSheetView.counts(requests: figures.requests, tokens: nil) {
                            Text(counts)
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if key.daily.contains(where: { $0.costTotal > 0 }) {
                UsageChart(
                    buckets: period == .last7 ? Array(key.daily.suffix(7)) : key.daily,
                    span: .day, style: style, accent: accent, height: 40)
            }
            let models = key.usage[period]?.models ?? []
            if !models.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.t("Models · \(period.displayName.lowercased())", "\(period.displayName)用到的模型"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                    ForEach(models) { model in
                        HStack(alignment: .firstTextBaseline) {
                            Text(model.model)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(KeyUsageFigures(costs: model.costs).costLine)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.8))
                            if let counts = BalanceSheetView.counts(requests: model.requests, tokens: model.tokens) {
                                Text(counts)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                        }
                    }
                }
            }
        }
    }
}

extension UsageStore {
    /// "¥107" — a prepaid provider's balance, for the places that show a
    /// percentage for everything else and would otherwise show a dash.
    func balanceFigure(for id: ProviderID) -> String? {
        states[id]?.snapshot?.balance?.compactBalance
    }
}

// MARK: - On the desktop

/// A prepaid provider on a single-provider desktop card, in place of a big
/// percentage it does not have: the balance, spend today, over seven and
/// over thirty days, and on the large card a chart of the thirty days.
struct DeskBalanceCard: View {
    @ObservedObject var store: UsageStore
    let id: ProviderID
    let sheet: BalanceSheet
    let size: DeskCardSize

    var body: some View {
        let compact = size == .small
        let first = sheet.balances.first
        DeskFrame(size: size) {
            DeskHeader(title: id.displayName, id: id, plan: store.states[id]?.snapshot?.planName, pill: store.deskPill(id), compact: compact)
            Spacer(minLength: compact ? 6 : 10)
            Text(first.map { QuotaFormat.amount($0.total, code: $0.currency) } ?? "—")
                .font(.system(size: compact ? 30 : 38, weight: .semibold, design: .monospaced))
                .foregroundStyle(sheet.canCallAPI == false || (first?.total ?? 1) <= 0 ? Palette.figureRed : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(caption)
                .font(.system(size: compact ? 11 : 12))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            if !compact {
                Spacer(minLength: 10)
                HStack(spacing: 0) {
                    ForEach([KeyUsagePeriod.today, .last7, .last30]) { period in
                        if period != .today { divider }
                        DeskStat(value: spent(period), label: period.displayName)
                    }
                }
                if size == .large, let days = sheet.chart[.last30], days.contains(where: { $0.costTotal > 0 }) {
                    Spacer(minLength: 12)
                    UsageChart(buckets: days, span: .day, style: store.experience.balanceChart, accent: Color(hex: id.accentHex), height: 64)
                }
                Spacer(minLength: 10)
                DeskFooter(
                    symbol: "creditcard",
                    text: sheet.estimated ? L10n.t("Estimated from the balance", "按余额变化估算") : L10n.t("Pay as you go", "按量付费"),
                    time: store.deskUpdated([id]))
            } else {
                Spacer(minLength: 4)
            }
        }
    }

    /// The other currencies, or where the money came from when there is one.
    private var caption: String {
        if sheet.balances.count > 1 {
            return L10n.t("Balance · also ", "余额 · 另有 ") + sheet.balances.dropFirst().map { QuotaFormat.amount($0.total, code: $0.currency) }.joined(separator: " · ")
        }
        if let first = sheet.balances.first, let granted = first.granted, granted > 0 {
            return L10n.t("incl. \(QuotaFormat.amount(granted, code: first.currency)) granted", "含赠送 \(QuotaFormat.amount(granted, code: first.currency))")
        }
        return L10n.t("Balance", "余额")
    }

    private func spent(_ period: KeyUsagePeriod) -> String {
        guard let first = sheet.usage[period]?.costs.first(where: { $0.amount > 0 }) else {
            return sheet.usage[period] == nil ? "—" : QuotaFormat.amount(0, code: sheet.balances.first?.currency ?? "USD")
        }
        // Cents fit up to three figures; past that they only crowd the tile.
        return first.amount >= 1_000
            ? QuotaFormat.amountCompact(first.amount, code: first.currency)
            : QuotaFormat.amount(first.amount, code: first.currency)
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1, height: 28)
    }
}

extension UsageStore {
    /// The sheet a single-provider desktop card should draw instead of a
    /// percentage: a prepaid provider with no window that has one.
    func deskBalance(_ id: ProviderID) -> BalanceSheet? {
        guard deskWindows(id).lead == nil else { return nil }
        return states[id]?.snapshot?.balance
    }
}
