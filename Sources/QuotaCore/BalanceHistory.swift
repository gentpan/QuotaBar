import Foundation

// MARK: - Charts

/// Lays usage out into the hours, days or months a chart draws.
public enum UsageBuckets {
    /// One usage event: when, how much, in what, and what it counted.
    public struct Entry: Sendable {
        public var date: Date
        public var currency: String
        public var cost: Double
        public var requests: Int?
        public var tokens: Int?

        public init(date: Date, currency: String, cost: Double, requests: Int? = nil, tokens: Int? = nil) {
            self.date = date
            self.currency = currency
            self.cost = cost
            self.requests = requests
            self.tokens = tokens
        }
    }

    /// The bucket starts a period's chart has, oldest first: today's
    /// twenty-four hours, the last seven or thirty days, or every month from
    /// `first` to now.
    public static func starts(for period: KeyUsagePeriod, now: Date, first: Date?, calendar: Calendar) -> [Date] {
        let today = calendar.startOfDay(for: now)
        switch period {
        case .today:
            return (0..<24).compactMap { calendar.date(byAdding: .hour, value: $0, to: today) }
        case .last7:
            return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0 - 6, to: today) }
        case .last30:
            return (0..<30).compactMap { calendar.date(byAdding: .day, value: $0 - 29, to: today) }
        case .all:
            guard let first, let thisMonth = calendar.dateInterval(of: .month, for: now)?.start,
                  var month = calendar.dateInterval(of: .month, for: min(first, now))?.start
            else { return [] }
            var months: [Date] = []
            while month <= thisMonth, months.count < 120 {
                months.append(month)
                guard let next = calendar.date(byAdding: .month, value: 1, to: month) else { break }
                month = next
            }
            return months
        }
    }

    /// Where `date` falls for a span: the start of its hour, day or month.
    public static func start(of date: Date, span: UsageBucket.Span, calendar: Calendar) -> Date {
        switch span {
        case .hour: calendar.dateInterval(of: .hour, for: date)?.start ?? date
        case .day: calendar.startOfDay(for: date)
        case .month: calendar.dateInterval(of: .month, for: date)?.start ?? date
        }
    }

    /// Every start in `starts` gets a bucket, empty or not, so a quiet day is
    /// a gap in the chart rather than a missing column.
    public static func fill(_ starts: [Date], span: UsageBucket.Span, entries: [Entry], calendar: Calendar) -> [UsageBucket] {
        var money: [Date: MoneyTally] = [:]
        var requests: [Date: Int] = [:]
        var tokens: [Date: Int] = [:]
        var counted = false
        let wanted = Set(starts)
        for entry in entries {
            let key = start(of: entry.date, span: span, calendar: calendar)
            guard wanted.contains(key) else { continue }
            if entry.cost > 0 { money[key, default: MoneyTally()].add(entry.currency, entry.cost) }
            if let asked = entry.requests { requests[key, default: 0] += asked; counted = true }
            if let used = entry.tokens { tokens[key, default: 0] += used; counted = true }
        }
        return starts.map { start in
            UsageBucket(
                start: start,
                costs: money[start]?.money ?? [],
                requests: counted ? requests[start] ?? 0 : nil,
                tokens: counted ? tokens[start] ?? 0 : nil)
        }
    }

    /// The total of `entries` from `since` on.
    public static func figures(_ entries: [Entry], since: Date?, models: [ModelCost] = []) -> KeyUsageFigures {
        var money = MoneyTally()
        var requests = 0, tokens = 0, counted = false
        for entry in entries where since.map({ entry.date >= $0 }) ?? true {
            if entry.cost > 0 { money.add(entry.currency, entry.cost) }
            if let asked = entry.requests { requests += asked; counted = true }
            if let used = entry.tokens { tokens += used; counted = true }
        }
        return KeyUsageFigures(costs: money.money, requests: counted ? requests : nil, tokens: counted ? tokens : nil, models: models)
    }

    /// Where each period begins, ending today.
    public static func periodStart(_ period: KeyUsagePeriod, now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch period {
        case .today: return today
        case .last7: return calendar.date(byAdding: .day, value: -6, to: today)
        case .last30: return calendar.date(byAdding: .day, value: -29, to: today)
        case .all: return nil
        }
    }
}

// MARK: - Usage from the balance alone

/// A balance as read at one moment, per currency.
public struct BalanceReading: Codable, Equatable, Sendable {
    public var date: Date
    public var totals: [String: Double]

    public init(date: Date, totals: [String: Double]) {
        self.date = date
        self.totals = totals
    }
}

/// Every change in a prepaid account's balance this Mac has read, so a
/// credential that can only ask for the balance still yields recent usage.
///
/// A reading is kept only when a total moved: an account left alone for a
/// week is one line, not two thousand.
public final class BalanceHistoryStore: @unchecked Sendable {
    public static let shared = BalanceHistoryStore()

    private static let cap = 5_000
    private let lock = NSLock()
    private var data: [String: [BalanceReading]]
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        let url = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/quotabar/balance-history.json")
        self.fileURL = url
        self.data = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: [BalanceReading]].self, from: $0) } ?? [:]
    }

    public func readings(for id: ProviderID) -> [BalanceReading] {
        lock.lock(); defer { lock.unlock() }
        return data[id.rawValue] ?? []
    }

    public func record(_ id: ProviderID, balances: [AccountBalance], at date: Date = Date()) {
        let totals = Dictionary(balances.map { ($0.currency, $0.total) }, uniquingKeysWith: +)
        lock.lock()
        var readings = data[id.rawValue] ?? []
        if let last = readings.last, last.totals == totals {
            lock.unlock()
            return
        }
        readings.append(BalanceReading(date: date, totals: totals))
        if readings.count > Self.cap { readings.removeFirst(readings.count - Self.cap) }
        data[id.rawValue] = readings
        let snapshot = data
        lock.unlock()
        guard let encoded = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoded.write(to: fileURL, options: .atomic)
    }
}

public enum BalanceEstimate {
    /// Spend as the balance's falls between readings. A rise is a top-up and
    /// counts for nothing; spend in the same interval as a top-up is lost,
    /// which a refresh every few minutes keeps small.
    public static func entries(_ readings: [BalanceReading]) -> [UsageBuckets.Entry] {
        let sorted = readings.sorted { $0.date < $1.date }
        guard sorted.count > 1 else { return [] }
        var entries: [UsageBuckets.Entry] = []
        for (before, after) in zip(sorted, sorted.dropFirst()) {
            for (currency, was) in before.totals {
                guard let now = after.totals[currency], was - now > 0.000_001 else { continue }
                entries.append(UsageBuckets.Entry(date: after.date, currency: currency, cost: was - now))
            }
        }
        return entries
    }

    /// Fills a sheet that has a balance but no usage with an estimate.
    public static func apply(to sheet: inout BalanceSheet, readings: [BalanceReading], now: Date = .now, calendar: Calendar = .current) {
        guard !sheet.hasUsage, let first = readings.map(\.date).min() else { return }
        let entries = entries(readings)
        var usage: [KeyUsagePeriod: KeyUsageFigures] = [:]
        var chart: [KeyUsagePeriod: [UsageBucket]] = [:]
        for period in KeyUsagePeriod.allCases {
            usage[period] = UsageBuckets.figures(entries, since: UsageBuckets.periodStart(period, now: now, calendar: calendar))
            chart[period] = UsageBuckets.fill(
                UsageBuckets.starts(for: period, now: now, first: first, calendar: calendar),
                span: period.bucket, entries: entries, calendar: calendar)
        }
        sheet.usage = usage
        sheet.chart = chart
        sheet.estimated = true
        sheet.estimatedSince = first
    }
}
