import Foundation

// MARK: - Showing dollars in the owner's currency

/// Daily reference rates against the dollar, after codex-island: prices and
/// sums stay in dollars, only the figure on screen is converted. Cached for a
/// day in Application Support; offline, the last good table is used, and with
/// none at all the figure stays in dollars.
public final class CurrencyRates: @unchecked Sendable {
    public static let shared = CurrencyRates()

    /// The currencies Settings offers, dollars first.
    public static let supported = ["USD", "CNY", "HKD", "TWD", "JPY", "KRW", "SGD", "EUR", "GBP", "CAD", "AUD"]

    private struct Table: Codable {
        var rates: [String: Double]
        var fetchedAt: Date
    }

    private let lock = NSLock()
    private var table: Table?
    private let fileURL: URL
    private var inFlight = false

    public init(fileURL: URL? = nil) {
        let url = fileURL ?? AppSupport.directory.appendingPathComponent("rates.json")
        self.fileURL = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        table = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Table.self, from: $0) }
    }

    /// Units of `code` per dollar; nil when there is no table yet.
    public func rate(for code: String) -> Double? {
        if code == "USD" { return 1 }
        lock.lock(); defer { lock.unlock() }
        return table?.rates[code]
    }

    public var fetchedAt: Date? {
        lock.lock(); defer { lock.unlock() }
        return table?.fetchedAt
    }

    /// Fetches when the table is a day old or missing. `force` for a manual refresh.
    public func refreshIfNeeded(force: Bool = false) async {
        let go: Bool = lock.withLock {
            let stale = table.map { Date().timeIntervalSince($0.fetchedAt) > 86_400 } ?? true
            guard (force || stale), !inFlight else { return false }
            inFlight = true
            return true
        }
        guard go else { return }
        defer { lock.withLock { inFlight = false } }

        guard let url = URL(string: "https://open.er-api.com/v6/latest/USD"),
              let response = try? await HTTP.get(url, headers: ["Accept": "application/json"]),
              response.status == 200,
              let rates = Self.parse(response.data)
        else { return }
        let fresh = Table(rates: rates, fetchedAt: Date())
        lock.withLock { table = fresh }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(fresh) { AppSupport.write(data, to: fileURL) }
    }

    /// `{"result":"success","rates":{"CNY":7.1,…}}`; exposed for the tests.
    public static func parse(_ data: Data) -> [String: Double]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["result"] as? String) != "error",
              let rates = root["rates"] as? [String: Double], !rates.isEmpty
        else { return nil }
        return rates
    }

    public static func symbol(for code: String) -> String {
        switch code {
        case "USD": "$"
        case "CNY": "¥"
        case "JPY": "JP¥"
        case "HKD": "HK$"
        case "TWD": "NT$"
        case "KRW": "₩"
        case "SGD": "S$"
        case "EUR": "€"
        case "GBP": "£"
        case "CAD": "CA$"
        case "AUD": "A$"
        default: code + " "
        }
    }

    public static func displayName(for code: String) -> String {
        switch code {
        case "USD": L10n.t("US dollar", "美元")
        case "CNY": L10n.t("Chinese yuan", "人民币")
        case "HKD": L10n.t("Hong Kong dollar", "港币")
        case "TWD": L10n.t("New Taiwan dollar", "新台币")
        case "JPY": L10n.t("Japanese yen", "日元")
        case "KRW": L10n.t("Korean won", "韩元")
        case "SGD": L10n.t("Singapore dollar", "新加坡元")
        case "EUR": L10n.t("Euro", "欧元")
        case "GBP": L10n.t("Pound sterling", "英镑")
        case "CAD": L10n.t("Canadian dollar", "加元")
        case "AUD": L10n.t("Australian dollar", "澳元")
        default: code
        }
    }

    /// Currencies whose minor unit is not shown.
    static func wholeUnits(_ code: String) -> Bool { code == "JPY" || code == "KRW" || code == "TWD" }
}

extension QuotaFormat {
    /// A dollar amount in the owner's currency: "$4,557.33", "¥32,473.21".
    /// Dollars when the currency is dollars or no rate is known yet.
    public static func money(_ usd: Double, code: String? = nil) -> String {
        let code = code ?? ConfigStore.shared.experience.currency
        guard code != "USD", let rate = CurrencyRates.shared.rate(for: code) else { return self.usd(usd) }
        return converted(usd * rate, code: code)
    }

    /// "$13.4K", "¥95.2K" — the compact form for the middle of a ring.
    public static func moneyCompact(_ usd: Double, code: String? = nil) -> String {
        let code = code ?? ConfigStore.shared.experience.currency
        guard code != "USD", let rate = CurrencyRates.shared.rate(for: code) else { return usdCompact(usd) }
        let value = usd * rate
        let symbol = CurrencyRates.symbol(for: code)
        switch abs(value) {
        case 1_000_000...: return symbol + String(format: "%.1fM", value / 1_000_000)
        case 10_000...: return symbol + String(format: "%.1fK", value / 1_000)
        default: return converted(value, code: code)
        }
    }

    /// An amount already in `code`: "¥1,000.00", "$250.00".
    public static func amount(_ value: Double, code: String) -> String {
        converted(value, code: code)
    }

    static func converted(_ value: Double, code: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.decimalSeparator = "."
        let digits = CurrencyRates.wholeUnits(code) ? 0 : 2
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        let magnitude = formatter.string(from: NSNumber(value: abs(value))) ?? String(format: "%.2f", abs(value))
        return (value < 0 ? "-" : "") + CurrencyRates.symbol(for: code) + magnitude
    }

    /// The reset phrase in the chosen format: "3 小时 25 分后重置" or
    /// "今天 18:38 重置".
    public static func resetText(
        to date: Date,
        format: ResetTimeFormat,
        clock: ClockStyle = .automatic,
        now: Date = .now) -> String
    {
        switch format {
        case .countdown: return resetLabel(to: date, from: now)
        case .exact:
            guard date > now else { return L10n.t("reset due", "已到重置时间") }
            let when = exactTime(date, clock: clock, now: now)
            return L10n.t("resets \(when)", "\(when) 重置")
        }
    }

    /// Banked resets' deadlines in the reset rows' format, soonest first:
    /// "5d 18h · 18d 23h · 19d 22h" or "Sep 20 18:38 · Oct 3 09:00". Past
    /// three, the rest are counted.
    public static func expiryList(
        _ dates: [Date],
        format: ResetTimeFormat,
        clock: ClockStyle = .automatic,
        now: Date = .now) -> String
    {
        let upcoming = dates.filter { $0 > now }.sorted()
        var parts = upcoming.prefix(3).map { date in
            format == .countdown ? countdown(to: date, from: now) : exactTime(date, clock: clock, now: now)
        }
        if upcoming.count > 3 {
            parts.append(L10n.t("+\(upcoming.count - 3) more", "另 \(upcoming.count - 3) 次"))
        }
        return parts.joined(separator: " · ")
    }

    /// "today at 18:38" / "今天 18:38", "tomorrow 09:00", "Sep 14 18:38".
    public static func exactTime(_ date: Date, clock: ClockStyle = .automatic, now: Date = .now) -> String {
        let calendar = Calendar.current
        let time = DateFormatter()
        switch clock {
        case .automatic: time.timeStyle = .short
        case .twelveHour: time.dateFormat = "h:mm a"
        case .twentyFourHour: time.dateFormat = "HH:mm"
        }
        let clockText = time.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) {
            return L10n.t("today at \(clockText)", "今天 \(clockText)")
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return L10n.t("tomorrow at \(clockText)", "明天 \(clockText)")
        }
        let day = DateFormatter()
        day.locale = L10n.locale
        day.setLocalizedDateFormatFromTemplate("MMMd")
        return "\(day.string(from: date)) \(clockText)"
    }

    /// A run-out moment in the same format as the reset label.
    public static func runOutText(in seconds: Double, format: ResetTimeFormat, clock: ClockStyle = .automatic, now: Date = .now) -> String {
        let date = now.addingTimeInterval(seconds)
        switch format {
        case .countdown:
            return L10n.t("Limit in \(countdown(to: date, from: now))", "\(countdown(to: date, from: now))后用完")
        case .exact:
            return L10n.t("Limit \(exactTime(date, clock: clock, now: now))", "\(exactTime(date, clock: clock, now: now)) 用完")
        }
    }
}
