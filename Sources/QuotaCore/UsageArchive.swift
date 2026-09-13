import Foundation

// MARK: - QuotaBar's own record of local token usage

/// One model's traffic on one day under one CLI.
public struct ArchiveEntry: Codable, Equatable, Sendable {
    public var usd: Double = 0
    public var input: Int = 0
    public var output: Int = 0
    public var cacheRead: Int = 0
    public var cacheWrite: Int = 0

    public init(usd: Double = 0, input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.usd = usd
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public var allTokens: Int { input + output + cacheRead + cacheWrite }
    public var billableTokens: Int { input + output }

    public func tokens(_ counting: TokenCounting) -> Int {
        counting == .all ? allTokens : billableTokens
    }

    mutating func add(_ other: ArchiveEntry) {
        usd += other.usd
        input += other.input
        output += other.output
        cacheRead += other.cacheRead
        cacheWrite += other.cacheWrite
    }
}

/// Day key ("2026-09-12", local) → CLI raw value → model id → entry.
public typealias ArchiveDays = [String: [String: [String: ArchiveEntry]]]

/// What a stretch of the archive adds up to.
public struct ArchiveSummary: Sendable, Equatable {
    public struct Day: Sendable, Equatable, Identifiable {
        public var day: Date
        public var usd: Double
        public var tokens: Int
        public var id: TimeInterval { day.timeIntervalSince1970 }
    }

    public struct Source: Sendable, Equatable, Identifiable {
        public var source: CostSource
        public var usd: Double
        public var tokens: Int
        public var id: String { source.rawValue }
    }

    public var start: Date
    public var end: Date
    public var usd: Double = 0
    public var tokens: Int = 0
    /// Every day in the range, oldest first, empty days included.
    public var days: [Day] = []
    public var sources: [Source] = []
    public var models: [ModelSpend] = []
    public var activeDays: Int = 0

    public var hasData: Bool { usd > 0 || tokens > 0 }

    /// Running total per day, for the share card's curve.
    public func cumulative(_ metric: KeyPath<Day, Double>) -> [Double] {
        var total = 0.0
        return days.map { total += $0[keyPath: metric]; return total }
    }
}

/// QuotaBar's own record of the tokens the local CLIs logged, after
/// codex-island's usage history: kept in Application Support, merged on every
/// scan, never shrunk. Claude Code prunes old session files; a count taken
/// from the logs alone would quietly fall when it does. Only counts, models,
/// days and dollars are kept — no conversations, no credentials.
public struct UsageArchive: Codable, Equatable, Sendable {
    public var version = 1
    public var days: ArchiveDays = [:]
    /// When the logs were last read, and whether a full read has happened.
    public var lastScan: Date?
    public var fullScanDone = false

    public init() {}

    // MARK: Keys

    private static let keyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    public static func dayKey(_ date: Date) -> String {
        keyFormatter.string(from: date)
    }

    public static func date(forKey key: String) -> Date? {
        keyFormatter.date(from: key)
    }

    // MARK: Merge

    /// Folds a fresh scan in. Per day, CLI and model the larger of the two
    /// readings wins: a later scan of the same logs only ever grows a count,
    /// so a smaller one means the logs lost something, and the archive keeps
    /// what it had.
    public mutating func merge(_ fresh: ArchiveDays, scannedAt: Date, full: Bool) {
        for (day, sources) in fresh {
            for (source, models) in sources {
                for (model, entry) in models {
                    let kept = days[day]?[source]?[model]
                    if kept == nil || entry.allTokens >= kept!.allTokens {
                        days[day, default: [:]][source, default: [:]][model] = entry
                    }
                }
            }
        }
        lastScan = scannedAt
        if full { fullScanDone = true }
    }

    public var firstDay: Date? {
        days.keys.filter { key in
            days[key]?.values.contains { $0.values.contains { $0.allTokens > 0 || $0.usd > 0 } } ?? false
        }.min().flatMap(Self.date(forKey:))
    }

    /// Where the next scan should start: two days before the last one, so a
    /// session still being written at the last scan is read in full.
    public func incrementalCutoff(calendar: Calendar = .current) -> Date? {
        guard fullScanDone, let lastScan else { return nil }
        let start = calendar.startOfDay(for: lastScan)
        return calendar.date(byAdding: .day, value: -2, to: start)
    }

    // MARK: Queries

    /// Totals over `start...end` (local days, inclusive).
    public func summary(
        from start: Date,
        to end: Date,
        counting: TokenCounting = .all,
        calendar: Calendar = .current) -> ArchiveSummary
    {
        let first = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        var out = ArchiveSummary(start: first, end: last)
        var perSource: [CostSource: (Double, Int)] = [:]
        var perModel: [String: ModelSpend] = [:]
        var cursor = first
        while cursor <= last {
            let key = Self.dayKey(cursor)
            var usd = 0.0
            var tokens = 0
            var all = ArchiveEntry()
            for (raw, models) in days[key] ?? [:] {
                guard let source = CostSource(rawValue: raw) else { continue }
                for (model, entry) in models {
                    usd += entry.usd
                    tokens += entry.tokens(counting)
                    all.add(entry)
                    let current = perSource[source] ?? (0, 0)
                    perSource[source] = (current.0 + entry.usd, current.1 + entry.tokens(counting))
                    var spend = perModel[model] ?? ModelSpend(model: model, source: source)
                    spend.usd += entry.usd
                    spend.tokens += entry.allTokens
                    spend.billableTokens += entry.billableTokens
                    perModel[model] = spend
                }
            }
            out.days.append(.init(day: cursor, usd: usd, tokens: tokens))
            out.usd += usd
            out.tokens += tokens
            if tokens > 0 || usd > 0 { out.activeDays += 1 }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        out.sources = perSource.map { .init(source: $0.key, usd: $0.value.0, tokens: $0.value.1) }
            .filter { $0.usd > 0 || $0.tokens > 0 }
            .sorted { $0.usd == $1.usd ? $0.tokens > $1.tokens : $0.usd > $1.usd }
        out.models = perModel.values.filter { $0.usd > 0 || $0.tokens > 0 }
            .sorted { $0.usd == $1.usd ? $0.tokens > $1.tokens : $0.usd > $1.usd }
        return out
    }

    /// The last `count` days per CLI, oldest first, for a provider's trend.
    public func trend(for source: CostSource, days count: Int, counting: TokenCounting = .all, now: Date = Date(), calendar: Calendar = .current) -> [ArchiveSummary.Day] {
        let end = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -(count - 1), to: end) else { return [] }
        var out: [ArchiveSummary.Day] = []
        var cursor = start
        while cursor <= end {
            let models = days[Self.dayKey(cursor)]?[source.rawValue] ?? [:]
            out.append(.init(
                day: cursor,
                usd: models.values.reduce(0) { $0 + $1.usd },
                tokens: models.values.reduce(0) { $0 + $1.tokens(counting) }))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return out
    }
}

/// The archive on disk. Reads and writes happen off the main actor; the
/// store hands out value copies.
public final class UsageArchiveStore: @unchecked Sendable {
    public static let shared = UsageArchiveStore()

    private let lock = NSLock()
    private let fileURL: URL
    private var archive: UsageArchive

    public init(fileURL: URL? = nil) {
        let url = fileURL ?? AppSupport.directory.appendingPathComponent("usage-archive.json")
        self.fileURL = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        self.archive = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(UsageArchive.self, from: $0) }
            ?? UsageArchive()
    }

    public var current: UsageArchive {
        lock.lock(); defer { lock.unlock() }
        return archive
    }

    /// Tokens per minute over the last two days, from the latest scan. Kept in
    /// memory only: every launch scans at least that far back again.
    public var recentActivity: ActivityMinutes {
        lock.lock(); defer { lock.unlock() }
        return activity
    }

    private var activity = ActivityMinutes()

    /// Reads the logs — everything the first time, the last few days after —
    /// and folds them in. Slow on a large log tree; call it off the main actor.
    @discardableResult
    public func update(paths: CostPaths = .default, now: Date = Date()) -> UsageArchive {
        let snapshot = current
        let cutoff = snapshot.incrementalCutoff() ?? .distantPast
        let scan = CostEstimator.archiveScan(paths: paths, since: cutoff, now: now)
        lock.lock()
        archive.merge(scan.days, scannedAt: now, full: cutoff == .distantPast)
        activity = scan.activity
        let copy = archive
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(copy) { AppSupport.write(data, to: fileURL) }
        return copy
    }
}

// MARK: - The figures the app shows, straight from the archive

extension UsageArchive {
    /// The year-to-date ledger behind the usage pane, the card's back and the
    /// island's usage page — built from the archive in memory, so it is there
    /// the moment any of them opens, instead of after a scan of the logs.
    public func ledger(now: Date = Date(), calendar: Calendar = .current) -> UsageLedger {
        let year = calendar.component(.year, from: now)
        guard let yearStart = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let yearEnd = calendar.date(byAdding: .year, value: 1, to: yearStart)
        else { return .empty }
        var modelSources: [String: CostSource] = [:]
        var result: [UsageDay] = []
        var cursor = yearStart
        while cursor < yearEnd {
            var day = UsageDay(day: cursor)
            for (raw, models) in days[Self.dayKey(cursor)] ?? [:] {
                guard let source = CostSource(rawValue: raw) else { continue }
                for (model, entry) in models {
                    day.bySource[source, default: 0] += entry.allTokens
                    day.byModel[model, default: 0] += entry.allTokens
                    day.usd += entry.usd
                    day.input += entry.input
                    day.output += entry.output
                    day.cacheRead += entry.cacheRead
                    day.cacheWrite += entry.cacheWrite
                    modelSources[model] = source
                }
            }
            result.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return UsageLedger(
            year: year,
            days: result,
            today: calendar.startOfDay(for: now),
            modelSources: modelSources,
            scannedAt: lastScan ?? now)
    }

    /// Today, yesterday and the trailing window, by CLI and by model — the
    /// spend card's figures — from the archive in memory.
    public func costSummary(lookbackDays: Int = 31, now: Date = Date(), calendar: Calendar = .current) -> CostSummary {
        let today = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(byAdding: .day, value: -(lookbackDays - 1), to: today),
              let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        else { return .empty }
        var summary = CostSummary()
        summary.windowDays = lookbackDays
        var periods: [SpendPeriod: SpendBreakdown] = [.today: SpendBreakdown(), .yesterday: SpendBreakdown(), .window: SpendBreakdown()]
        var perModel: [String: Double] = [:]
        var daily: [DailyCost] = []
        var cursor = windowStart
        while cursor <= today {
            var bucket = DailyCost(day: cursor)
            for (raw, models) in days[Self.dayKey(cursor)] ?? [:] {
                guard let source = CostSource(rawValue: raw) else { continue }
                for (model, entry) in models {
                    let tokens = entry.allTokens
                    let billable = entry.billableTokens
                    bucket.usd += entry.usd
                    bucket.tokens += tokens
                    bucket.billableTokens += billable
                    summary.windowUSD += entry.usd
                    summary.windowTokens += tokens
                    summary.windowBySource[source, default: 0] += entry.usd
                    perModel[model, default: 0] += entry.usd
                    periods[.window]?.add(entry.usd, tokens: tokens, billable: billable, model: model, from: source)
                    if cursor == today {
                        summary.todayUSD += entry.usd
                        summary.todayTokens += tokens
                        periods[.today]?.add(entry.usd, tokens: tokens, billable: billable, model: model, from: source)
                    } else if cursor == yesterday {
                        periods[.yesterday]?.add(entry.usd, tokens: tokens, billable: billable, model: model, from: source)
                    }
                }
            }
            daily.append(bucket)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        summary.periods = periods
        summary.daily = daily
        summary.topModel = perModel.max { $0.value < $1.value }?.key
        return summary
    }
}
