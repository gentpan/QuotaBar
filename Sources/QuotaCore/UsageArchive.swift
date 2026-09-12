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

    /// Reads the logs — everything the first time, the last few days after —
    /// and folds them in. Slow on a large log tree; call it off the main actor.
    @discardableResult
    public func update(paths: CostPaths = .default, now: Date = Date()) -> UsageArchive {
        let snapshot = current
        let cutoff = snapshot.incrementalCutoff() ?? .distantPast
        let fresh = CostEstimator.archiveRecords(paths: paths, since: cutoff)
        lock.lock()
        archive.merge(fresh, scannedAt: now, full: cutoff == .distantPast)
        let copy = archive
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(copy) { AppSupport.write(data, to: fileURL) }
        return copy
    }
}
