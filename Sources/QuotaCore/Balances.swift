import Foundation

// MARK: - Prepaid accounts

/// A pay-as-you-go account, as opposed to a plan with windows: money put in,
/// what is left of it, what it went on, and — where the provider answers for
/// it — each API key's share.
///
/// A balance has no ceiling to be a percentage of, so it is not a window. It
/// was one, and every surface drew it as a meter that never filled. The
/// provider still reports a figure-only window alongside this sheet, so the
/// local API and the surfaces that only know windows keep reading something;
/// the card draws the sheet and leaves those windows out.
public struct BalanceSheet: Sendable, Equatable, Codable {
    /// One entry per currency the account holds, as the provider lists them.
    public var balances: [AccountBalance]
    /// The whole account's cost, requests, tokens and models per period.
    /// A period the provider cannot tell is absent.
    public var usage: [KeyUsagePeriod: KeyUsageFigures]
    /// What the chart draws per period, oldest first: hours for today, days
    /// for seven and thirty days, months for all of it.
    public var chart: [KeyUsagePeriod: [UsageBucket]]
    /// Each key's usage. Nil when the credential cannot see keys at all — say
    /// why in `keysNote` — and empty when it can and there are none.
    public var keys: [APIKeyUsage]?
    /// Why there are no keys to list, in a sentence the card can show.
    public var keysNote: String?
    /// False when the provider says the balance cannot pay for a call.
    public var canCallAPI: Bool?
    /// The usage was worked out on this Mac from how the balance fell between
    /// readings, because the credential cannot ask for usage.
    public var estimated: Bool
    /// When the estimate's readings start, for saying so.
    public var estimatedSince: Date?
    /// The windows this sheet stands in for; the card does not draw them.
    public var representedWindowIDs: [String]

    public init(
        balances: [AccountBalance],
        usage: [KeyUsagePeriod: KeyUsageFigures] = [:],
        chart: [KeyUsagePeriod: [UsageBucket]] = [:],
        keys: [APIKeyUsage]? = nil,
        keysNote: String? = nil,
        canCallAPI: Bool? = nil,
        estimated: Bool = false,
        estimatedSince: Date? = nil,
        representedWindowIDs: [String] = [])
    {
        self.balances = balances
        self.usage = usage
        self.chart = chart
        self.keys = keys
        self.keysNote = keysNote
        self.canCallAPI = canCallAPI
        self.estimated = estimated
        self.estimatedSince = estimatedSince
        self.representedWindowIDs = representedWindowIDs
    }

    private enum CodingKeys: String, CodingKey {
        case balances, usage, chart, keys, keysNote, canCallAPI, estimated, estimatedSince, representedWindowIDs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            balances: (try? c.decodeIfPresent([AccountBalance].self, forKey: .balances)) ?? [],
            usage: (try? c.decodeIfPresent([KeyUsagePeriod: KeyUsageFigures].self, forKey: .usage)) ?? [:],
            chart: (try? c.decodeIfPresent([KeyUsagePeriod: [UsageBucket]].self, forKey: .chart)) ?? [:],
            keys: try? c.decodeIfPresent([APIKeyUsage].self, forKey: .keys),
            keysNote: try? c.decodeIfPresent(String.self, forKey: .keysNote),
            canCallAPI: try? c.decodeIfPresent(Bool.self, forKey: .canCallAPI),
            estimated: (try? c.decodeIfPresent(Bool.self, forKey: .estimated)) ?? false,
            estimatedSince: try? c.decodeIfPresent(Date.self, forKey: .estimatedSince),
            representedWindowIDs: (try? c.decodeIfPresent([String].self, forKey: .representedWindowIDs)) ?? [])
    }

    /// Whether there is any usage to show at all.
    public var hasUsage: Bool { !usage.isEmpty || keys != nil }

    /// Keys with anything spent or asked in `period`, busiest first. Cost
    /// orders them — a request is not a unit of money — and requests break
    /// ties between keys that cost nothing.
    public func activeKeys(in period: KeyUsagePeriod) -> [APIKeyUsage] {
        (keys ?? [])
            .filter { $0.usage[period]?.isEmpty == false }
            .sorted { a, b in
                let ca = a.usage[period]?.costTotal ?? 0, cb = b.usage[period]?.costTotal ?? 0
                if ca != cb { return ca > cb }
                return (a.usage[period]?.requests ?? 0) > (b.usage[period]?.requests ?? 0)
            }
    }

    /// "¥107.39 · $12.33" — every balance, for places with room for one line.
    public var balanceLine: String {
        balances.map { QuotaFormat.amount($0.total, code: $0.currency) }.joined(separator: " · ")
    }

    /// "¥107", "$12" — the first balance without its cents, for a ring's
    /// middle or the notch strip.
    public var compactBalance: String? {
        guard let first = balances.first else { return nil }
        return QuotaFormat.amountCompact(first.total, code: first.currency)
    }
}

/// What is left in one currency, and where it came from.
public struct AccountBalance: Sendable, Equatable, Codable {
    public var currency: String
    public var total: Double
    /// Money put in, when the provider separates it from gifts.
    public var paid: Double?
    /// Vouchers and bonus credit.
    public var granted: Double?

    public init(currency: String, total: Double, paid: Double? = nil, granted: Double? = nil) {
        self.currency = currency
        self.total = total
        self.paid = paid
        self.granted = granted
    }
}

public struct Money: Sendable, Equatable, Codable {
    public var currency: String
    public var amount: Double

    public init(currency: String, amount: Double) {
        self.currency = currency
        self.amount = amount
    }
}

/// The periods usage is told over, ending today: today, the last seven and
/// thirty days, and everything the provider or this Mac has.
///
/// `CodingKeyRepresentable` so a dictionary keyed by it encodes as an object
/// ("last30": …) rather than a flat array of alternating keys and values.
public enum KeyUsagePeriod: String, Sendable, CaseIterable, Codable, CodingKeyRepresentable, Identifiable {
    case today
    case last7
    case last30
    case all

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .today: L10n.t("Today", "今日")
        case .last7: L10n.t("7 days", "7 天")
        case .last30: L10n.t("30 days", "30 天")
        case .all: L10n.t("All", "全部")
        }
    }

    /// What one bar or point of the chart covers.
    public var bucket: UsageBucket.Span {
        switch self {
        case .today: .hour
        case .last7, .last30: .day
        case .all: .month
        }
    }
}

/// One bar of a chart: an hour, a day or a month.
public struct UsageBucket: Sendable, Equatable, Codable, Identifiable {
    public enum Span: String, Sendable, Codable {
        case hour, day, month
    }

    /// Where the hour, day or month starts, in the time zone it was told in.
    public var start: Date
    public var costs: [Money]
    public var requests: Int?
    public var tokens: Int?

    public var id: Date { start }

    public init(start: Date, costs: [Money] = [], requests: Int? = nil, tokens: Int? = nil) {
        self.start = start
        self.costs = costs
        self.requests = requests
        self.tokens = tokens
    }

    /// For bar heights only; currencies are never added where they are read.
    public var costTotal: Double { costs.reduce(0) { $0 + $1.amount } }
}

/// One API key and what it did.
public struct APIKeyUsage: Sendable, Equatable, Codable, Identifiable {
    /// The provider's own id for the key — never the secret.
    public var id: String
    public var name: String
    /// The key as the provider masks it: "sk-b8e3****f7b".
    public var maskedKey: String?
    /// Deleted or disabled keys keep their history.
    public var isDisabled: Bool
    public var lastUsed: Date?
    public var usage: [KeyUsagePeriod: KeyUsageFigures]
    /// Day by day over the last thirty days, oldest first, days without use
    /// included; empty when the provider only reports totals.
    public var daily: [UsageBucket]

    public init(
        id: String, name: String, maskedKey: String? = nil, isDisabled: Bool = false,
        lastUsed: Date? = nil, usage: [KeyUsagePeriod: KeyUsageFigures] = [:], daily: [UsageBucket] = [])
    {
        self.id = id
        self.name = name
        self.maskedKey = maskedKey
        self.isDisabled = isDisabled
        self.lastUsed = lastUsed
        self.usage = usage
        self.daily = daily
    }

    private enum CodingKeys: String, CodingKey { case id, name, maskedKey, isDisabled, lastUsed, usage, daily }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            maskedKey: try c.decodeIfPresent(String.self, forKey: .maskedKey),
            isDisabled: (try? c.decodeIfPresent(Bool.self, forKey: .isDisabled)) ?? false,
            lastUsed: try c.decodeIfPresent(Date.self, forKey: .lastUsed),
            usage: (try? c.decodeIfPresent([KeyUsagePeriod: KeyUsageFigures].self, forKey: .usage)) ?? [:],
            daily: (try? c.decodeIfPresent([UsageBucket].self, forKey: .daily)) ?? [])
    }
}

/// The chart style for a balance card's usage.
public enum BalanceChartStyle: String, Sendable, Codable, CaseIterable, Identifiable {
    case bars
    case line

    public var id: String { rawValue }
}

public struct KeyUsageFigures: Sendable, Equatable, Codable {
    public var costs: [Money]
    public var requests: Int?
    /// Input, output and cache tokens together.
    public var tokens: Int?
    /// Cost per model, largest first.
    public var models: [ModelCost]

    public init(costs: [Money] = [], requests: Int? = nil, tokens: Int? = nil, models: [ModelCost] = []) {
        self.costs = costs
        self.requests = requests
        self.tokens = tokens
        self.models = models
    }

    public var isEmpty: Bool {
        costs.allSatisfy { $0.amount <= 0 } && (requests ?? 0) == 0 && (tokens ?? 0) == 0
    }

    /// For ordering only: amounts in different currencies are not added up
    /// anywhere a person reads them.
    var costTotal: Double { costs.reduce(0) { $0 + $1.amount } }

    /// "¥312.40 · $1.20"
    public var costLine: String {
        let shown = costs.filter { $0.amount > 0 }
        guard !shown.isEmpty else { return QuotaFormat.amount(0, code: costs.first?.currency ?? "USD") }
        return shown.map { QuotaFormat.amount($0.amount, code: $0.currency) }.joined(separator: " · ")
    }
}

public struct ModelCost: Sendable, Equatable, Codable, Identifiable {
    public var model: String
    public var costs: [Money]
    public var requests: Int?
    public var tokens: Int?

    public var id: String { model }

    public init(model: String, costs: [Money], requests: Int? = nil, tokens: Int? = nil) {
        self.model = model
        self.costs = costs
        self.requests = requests
        self.tokens = tokens
    }

    var costTotal: Double { costs.reduce(0) { $0 + $1.amount } }

    /// Most spent first; requests order the ones that cost nothing.
    static func busiestFirst(_ a: ModelCost, _ b: ModelCost) -> Bool {
        if a.costTotal != b.costTotal { return a.costTotal > b.costTotal }
        return (a.requests ?? 0) > (b.requests ?? 0)
    }
}

extension QuotaFormat {
    /// "¥107", "$12", "¥1.2K" — an amount already in `code`, shortened.
    public static func amountCompact(_ value: Double, code: String) -> String {
        let symbol = CurrencyRates.symbol(for: code)
        switch abs(value) {
        case 1_000_000...: return symbol + String(format: "%.1fM", value / 1_000_000)
        case 10_000...: return symbol + String(format: "%.1fK", value / 1_000)
        default: return symbol + String(Int(value.rounded(.down)))
        }
    }
}

/// Adds amounts per currency, keeping the order currencies first appear in.
struct MoneyTally {
    private var order: [String] = []
    private var sums: [String: Double] = [:]

    mutating func add(_ currency: String, _ amount: Double) {
        if sums[currency] == nil { order.append(currency) }
        sums[currency, default: 0] += amount
    }

    var money: [Money] { order.map { Money(currency: $0, amount: sums[$0] ?? 0) } }
}

// MARK: - A floor under the balance

/// The amount a prepaid balance should not fall below, in the currency it
/// was set in. No amount means no alert.
public struct BalanceFloor: Codable, Equatable, Sendable {
    public var amount: Double?
    public var currency: String

    public init(amount: Double? = nil, currency: String = "USD") {
        self.amount = amount
        self.currency = currency
    }

    public var isSet: Bool { (amount ?? 0) > 0 }
}

/// A prepaid account newly below its floor, or unable to pay for a call.
public struct LowBalanceAlert: Equatable, Sendable {
    public var provider: ProviderID
    /// The account's balances added up in the floor's currency.
    public var left: Double?
    public var floor: Double
    public var currency: String
    public var cannotPay: Bool
}

public enum LowBalanceCheck {
    /// The accounts to notify about, and every account low right now.
    ///
    /// Each account speaks once per dip: `notified` is the set that was low
    /// last time, and an account that recovers — topped up — drops out of it,
    /// so the next dip speaks again. Balances in several currencies are added
    /// up in the floor's currency at `rate` (units per dollar); a currency
    /// with no rate yet is left out rather than guessed at.
    public static func evaluate(
        sheets: [ProviderID: BalanceSheet],
        floor: BalanceFloor,
        rate: (String) -> Double?,
        notified: [String]) -> (alerts: [LowBalanceAlert], low: [String])
    {
        guard floor.isSet, let limit = floor.amount else { return ([], []) }
        var alerts: [LowBalanceAlert] = []
        var low: [String] = []
        for (id, sheet) in sheets.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            var left: Double?
            for balance in sheet.balances {
                let value: Double?
                if balance.currency == floor.currency {
                    value = balance.total
                } else if let from = rate(balance.currency), from > 0, let to = rate(floor.currency) {
                    value = balance.total / from * to
                } else {
                    value = nil
                }
                if let value { left = (left ?? 0) + value }
            }
            let cannotPay = sheet.canCallAPI == false
            guard cannotPay || (left.map { $0 < limit } ?? false) else { continue }
            low.append(id.rawValue)
            guard !notified.contains(id.rawValue) else { continue }
            alerts.append(LowBalanceAlert(provider: id, left: left, floor: limit, currency: floor.currency, cannotPay: cannotPay))
        }
        return (alerts, low)
    }
}
