import Foundation

// MARK: - A year of local token traffic, by day, CLI and model

/// One local calendar day's token traffic across every CLI that logs it.
/// Every day of the year is present, so a grid can be drawn straight from
/// the array; the future ones simply hold zeros.
public struct UsageDay: Sendable, Equatable, Identifiable {
    public var day: Date
    /// Tokens including cache reads and writes — what the CLIs themselves
    /// count as "tokens", and what makes two providers comparable.
    public var bySource: [CostSource: Int]
    public var byModel: [String: Int]
    public var usd: Double
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int

    public var id: TimeInterval { day.timeIntervalSince1970 }

    public init(day: Date) {
        self.day = day
        bySource = [:]
        byModel = [:]
        usd = 0
        input = 0
        output = 0
        cacheRead = 0
        cacheWrite = 0
    }

    public var tokens: Int { bySource.values.reduce(0, +) }

    public func tokens(in scope: LedgerScope) -> Int {
        switch scope {
        case .all: tokens
        case let .source(source): bySource[source] ?? 0
        case let .model(model): byModel[model] ?? 0
        }
    }

    /// The CLI with the most tokens that day — the cell's hue.
    public var leadingSource: CostSource? {
        bySource.filter { $0.value > 0 }.max { $0.value < $1.value }?.key
    }

    /// Contributing CLIs, largest first, for the split stripe under a cell.
    public var contributions: [(source: CostSource, tokens: Int)] {
        bySource.filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .map { (source: $0.key, tokens: $0.value) }
    }

    mutating func add(_ other: UsageDay) {
        for (source, count) in other.bySource { bySource[source, default: 0] += count }
        for (model, count) in other.byModel { byModel[model, default: 0] += count }
        usd += other.usd
        input += other.input
        output += other.output
        cacheRead += other.cacheRead
        cacheWrite += other.cacheWrite
    }
}

/// What a figure or a grid is filtered to.
public enum LedgerScope: Hashable, Sendable {
    case all
    case source(CostSource)
    case model(String)

    public var source: CostSource? {
        if case let .source(source) = self { return source }
        return nil
    }
}

/// The spans the volume page sums over.
public enum LedgerPeriod: String, CaseIterable, Sendable, Identifiable {
    case today
    case week
    case month
    case year

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .today: L10n.t("Today", "今天")
        case .week: L10n.t("This week", "本周")
        case .month: L10n.t("This month", "本月")
        case .year: L10n.t("This year", "今年")
        }
    }
}

public struct UsageLedger: Sendable, Equatable {
    public var year: Int
    /// Every local day of `year`, first to last, gaps and future filled.
    public var days: [UsageDay]
    /// Start of the local day the ledger was built on; days after it are
    /// the future and drawn as such.
    public var today: Date
    /// Which CLI each model id was seen under, for grouping the model list.
    public var modelSources: [String: CostSource]
    public var scannedAt: Date
    public var deduplicated: Int

    public init(
        year: Int,
        days: [UsageDay],
        today: Date,
        modelSources: [String: CostSource] = [:],
        scannedAt: Date = Date(),
        deduplicated: Int = 0)
    {
        self.year = year
        self.days = days
        self.today = today
        self.modelSources = modelSources
        self.scannedAt = scannedAt
        self.deduplicated = deduplicated
    }

    public static let empty = UsageLedger(year: 0, days: [], today: .distantPast, scannedAt: .distantPast)

    public var isEmpty: Bool { days.isEmpty }
    public var hasData: Bool { days.contains { $0.tokens > 0 } }

    // MARK: Year figures

    public func total(_ scope: LedgerScope = .all) -> Int {
        days.reduce(0) { $0 + $1.tokens(in: scope) }
    }

    public func activeDays(_ scope: LedgerScope = .all) -> Int {
        days.filter { $0.tokens(in: scope) > 0 }.count
    }

    /// CLIs that logged anything this year, largest first.
    public var sources: [(source: CostSource, tokens: Int)] {
        var totals: [CostSource: Int] = [:]
        for day in days {
            for (source, count) in day.bySource { totals[source, default: 0] += count }
        }
        return totals.filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .map { (source: $0.key, tokens: $0.value) }
    }

    /// Models that logged anything, largest first; `within` narrows to one CLI.
    public func models(within source: CostSource? = nil, days subset: ArraySlice<UsageDay>? = nil) -> [(model: String, source: CostSource, tokens: Int)] {
        var totals: [String: Int] = [:]
        for day in subset ?? days[...] {
            for (model, count) in day.byModel { totals[model, default: 0] += count }
        }
        return totals.compactMap { model, count -> (String, CostSource, Int)? in
            guard count > 0, let owner = modelSources[model] else { return nil }
            if let source, owner != source { return nil }
            return (model, owner, count)
        }
        .sorted { $0.2 > $1.2 }
        .map { (model: $0.0, source: $0.1, tokens: $0.2) }
    }

    // MARK: Periods

    /// The days a period covers, up to and including today. The week starts
    /// on the calendar's first weekday, the month and year on the 1st.
    public func days(in period: LedgerPeriod, calendar: Calendar = .current) -> ArraySlice<UsageDay> {
        guard !days.isEmpty else { return [] }
        let start: Date
        switch period {
        case .today: start = today
        case .week:
            start = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        case .month:
            start = calendar.dateInterval(of: .month, for: today)?.start ?? today
        case .year:
            start = days[0].day
        }
        let lower = days.firstIndex { $0.day >= start } ?? days.endIndex
        let upper = days.firstIndex { $0.day > today } ?? days.endIndex
        return lower < upper ? days[lower..<upper] : []
    }

    /// Everything a period logged, folded into one bucket.
    public func sum(_ period: LedgerPeriod, source: CostSource? = nil, calendar: Calendar = .current) -> UsageDay {
        var out = UsageDay(day: today)
        for day in days(in: period, calendar: calendar) {
            if let source {
                guard let count = day.bySource[source], count > 0 else { continue }
                out.bySource[source, default: 0] += count
                for (model, tokens) in day.byModel where modelSources[model] == source {
                    out.byModel[model, default: 0] += tokens
                }
                // Cost and the in/out split are only kept per day; scale
                // them by the CLI's share, which is exact when one CLI logged
                // the day and a fair split otherwise.
                let share = Double(count) / Double(max(1, day.tokens))
                out.usd += day.usd * share
                out.input += Int(Double(day.input) * share)
                out.output += Int(Double(day.output) * share)
                out.cacheRead += Int(Double(day.cacheRead) * share)
                out.cacheWrite += Int(Double(day.cacheWrite) * share)
            } else {
                out.add(day)
            }
        }
        return out
    }
}
