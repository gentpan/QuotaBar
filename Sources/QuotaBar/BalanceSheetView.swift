import SwiftUI
import QuotaCore

// MARK: - A prepaid account on its card

/// What a pay-as-you-go provider's card shows in place of meters: the
/// balance in each currency, what was spent in the chosen period, and where
/// it went — by API key or by model.
///
/// No bar anywhere. A balance has no ceiling, so a meter of it only ever sat
/// empty; the figures are the reading.
struct BalanceSheetView: View {
    @ObservedObject var store: UsageStore
    let id: ProviderID
    let sheet: BalanceSheet
    var compact = false
    /// The card's own disclosure: every key and model instead of the top few.
    var expanded = false
    /// The copied image: this month, by model — key names stay on this Mac.
    var forExport = false

    @State private var period: KeyUsagePeriod = .month
    @State private var breakdown: Breakdown = .keys
    /// The key opened from the list, by the provider's id for it.
    @State private var focusedKey: String?

    init(
        store: UsageStore, id: ProviderID, sheet: BalanceSheet,
        compact: Bool = false, expanded: Bool = false, forExport: Bool = false, focusedKey: String? = nil)
    {
        self.store = store
        self.id = id
        self.sheet = sheet
        self.compact = compact
        self.expanded = expanded
        self.forExport = forExport
        _focusedKey = State(initialValue: focusedKey)
    }

    enum Breakdown: Hashable {
        case keys
        case models
    }

    /// Rows shown before the card is expanded.
    static let upFront = 3

    /// Whether the card's disclosure has anything of this sheet's to reveal.
    static func hasMore(_ sheet: BalanceSheet) -> Bool {
        KeyUsagePeriod.allCases.contains { period in
            sheet.activeKeys(in: period).count > upFront || (sheet.models[period]?.count ?? 0) > upFront
        }
    }

    private var shownPeriod: KeyUsagePeriod { forExport ? .month : period }
    private var shownBreakdown: Breakdown {
        if forExport || sheet.keys == nil { return .models }
        if sheet.models.isEmpty { return .keys }
        return breakdown
    }
    private var hasUsage: Bool { sheet.keys != nil || !sheet.models.isEmpty || !sheet.spend.isEmpty }

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
            if hasUsage {
                usage
            }
            if let note = sheet.keysNote, !forExport, sheet.keys == nil || expanded {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
                Text(spendLine)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if !forExport {
                    chips(KeyUsagePeriod.allCases.map { ($0, $0.displayName) }, selection: period) { period = $0 }
                }
            }
            if !forExport, sheet.keys != nil, !sheet.models.isEmpty {
                chips([(Breakdown.keys, "API Key"), (.models, L10n.t("Models", "模型"))], selection: breakdown) { breakdown = $0 }
            }
            switch shownBreakdown {
            case .keys:
                if let focused = focusedKey, let key = sheet.keys?.first(where: { $0.id == focused }) {
                    KeyDetailView(key: key, period: shownPeriod, accent: Color(hex: id.accentHex)) {
                        withAnimation(Motion.animation(Motion.spring)) { focusedKey = nil }
                    }
                    .transition(.opacity)
                } else {
                    keyRows
                }
            case .models: modelRows
            }
        }
    }

    private var spendLine: String {
        let name = shownPeriod.displayName
        guard let spent = sheet.spend[shownPeriod]?.filter({ $0.amount > 0 }), !spent.isEmpty else {
            return L10n.t("\(name): nothing spent", "\(name)没有消费")
        }
        let amounts = spent.map { QuotaFormat.amount($0.amount, code: $0.currency) }.joined(separator: " · ")
        return L10n.t("\(name) \(amounts)", "\(name)消费 \(amounts)")
    }

    @ViewBuilder
    private var keyRows: some View {
        let keys = sheet.activeKeys(in: shownPeriod)
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
                        guard !forExport else { return }
                        withAnimation(Motion.animation(Motion.spring)) { focusedKey = key.id }
                    }
                    .hoverDetail {
                        ModelCostList(title: "\(key.name) · \(shownPeriod.displayName)", models: figures.models)
                    }
                    .help(L10n.t("Click for this key's days and models", "点击查看这个 Key 每天的用量和模型"))
            }
        }
        more(keys.count - shown.count, idle: (sheet.keys?.count ?? 0) - keys.count)
    }

    @ViewBuilder
    private var modelRows: some View {
        let models = sheet.models[shownPeriod] ?? []
        let shown = expanded ? models : Array(models.prefix(Self.upFront))
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

    /// "23 requests · 208.7K tokens", or nil when the provider counts neither.
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

/// One key opened from the list: its three periods side by side, what it
/// spent each day, and its models in the chosen period.
private struct KeyDetailView: View {
    let key: APIKeyUsage
    let period: KeyUsagePeriod
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
                ForEach(KeyUsagePeriod.allCases) { period in
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
            if key.daily.contains(where: { $0.costTotal > 0 || ($0.requests ?? 0) > 0 }) {
                days
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

    /// A bar per day, to scale with the busiest; today in full colour.
    private var days: some View {
        let peak = max(0.000_001, key.daily.map(\.costTotal).max() ?? 0)
        let calendar = Calendar.current
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(key.daily) { day in
                    let today = calendar.isDateInToday(day.day)
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(day.costTotal > 0 ? accent.opacity(today ? 1 : 0.6) : Color.white.opacity(0.08))
                        .frame(height: max(2, 34 * day.costTotal / peak))
                        .frame(maxWidth: .infinity)
                        .help(dayHelp(day))
                }
            }
            .frame(height: 34, alignment: .bottom)
            if let first = key.daily.first?.day, let last = key.daily.last?.day {
                HStack {
                    Text(first.formatted(.dateTime.month(.defaultDigits).day()))
                    Spacer()
                    Text(last.formatted(.dateTime.month(.defaultDigits).day()))
                }
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    private func dayHelp(_ day: DailyUsage) -> String {
        let date = day.day.formatted(.dateTime.month(.abbreviated).day())
        var parts = [KeyUsageFigures(costs: day.costs).costLine]
        if let counts = BalanceSheetView.counts(requests: day.requests, tokens: day.tokens) { parts.append(counts) }
        return "\(date) · " + parts.joined(separator: " · ")
    }
}

/// One key's models, in the hover popover.
private struct ModelCostList: View {
    let title: String
    let models: [ModelCost]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            if models.isEmpty {
                Text(L10n.t("No data", "暂无数据"))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
            }
            ForEach(models) { model in
                HStack(alignment: .firstTextBaseline) {
                    Text(model.model)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(KeyUsageFigures(costs: model.costs).costLine)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                        if let counts = BalanceSheetView.counts(requests: model.requests, tokens: model.tokens) {
                            Text(counts)
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
    }
}

extension UsageStore {
    /// "¥107" — a prepaid provider's largest balance, for the places that show
    /// a percentage for everything else and would otherwise show a dash.
    func balanceFigure(for id: ProviderID) -> String? {
        states[id]?.snapshot?.balance?.compactBalance
    }
}

// MARK: - On the desktop

/// A prepaid provider on a single-provider desktop card, in place of a big
/// percentage it does not have: the balance, the spend by period, and on the
/// large card the keys that spent most this month.
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
                    ForEach(KeyUsagePeriod.allCases) { period in
                        if period != .today { divider }
                        DeskStat(value: spent(period), label: period.displayName)
                    }
                }
                if size == .large, let keys = Optional(sheet.activeKeys(in: .month)), !keys.isEmpty {
                    Spacer(minLength: 12)
                    VStack(spacing: 8) {
                        ForEach(keys.prefix(3)) { key in
                            HStack {
                                Text(key.name).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                                Spacer()
                                Text(key.usage[.month]?.costLine ?? "—").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
                            }
                        }
                    }
                }
                Spacer(minLength: 10)
                DeskFooter(symbol: "creditcard", text: L10n.t("Pay as you go", "按量付费"), time: store.deskUpdated([id]))
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
        guard let first = sheet.spend[period]?.first(where: { $0.amount > 0 }) else { return "—" }
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
