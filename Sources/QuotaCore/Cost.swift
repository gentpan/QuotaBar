import Foundation

// MARK: - Local cost estimation (no network, reads the CLIs' own session logs)

/// Where a locally-logged token event came from.
public enum CostSource: String, Sendable, CaseIterable, Codable {
    case claudeCode
    case codexCLI
    case openCode

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codexCLI: "Codex CLI"
        case .openCode: "OpenCode"
        }
    }

    /// Whether the figure is our own estimate from token counts, or a cost the
    /// tool itself recorded. Worth distinguishing in the UI: the estimates
    /// price tokens at list rates and cannot see plan-included usage.
    public var isEstimated: Bool {
        switch self {
        case .claudeCode, .codexCLI: true
        case .openCode: false
        }
    }

    /// Chart colour.
    ///
    /// Chosen for mutual separation rather than taken from `ProviderID`:
    /// brand accents are picked to work on their own, and Codex (#0A84FF) and
    /// OpenCode (#5B8DEF) differ by 0.11 in luminance — indistinguishable as
    /// neighbouring slices of one ring.
    public var accentHex: String {
        switch self {
        case .claudeCode: "D97757"  // terracotta, matching Claude's accent
        case .codexCLI: "2563EB"    // deep blue
        case .openCode: "0D9488"    // teal, well clear of the blue
        }
    }
}

/// One calendar day's spend. Days with no activity are still present with
/// zeroes so a chart can render a continuous axis instead of collapsing gaps.
public struct DailyCost: Sendable, Equatable, Identifiable {
    public var day: Date
    public var usd: Double
    public var tokens: Int
    /// Fresh input plus output, without cache reads and writes.
    public var billableTokens: Int

    public var id: TimeInterval { day.timeIntervalSince1970 }

    public init(day: Date, usd: Double = 0, tokens: Int = 0, billableTokens: Int = 0) {
        self.day = day
        self.usd = usd
        self.tokens = tokens
        self.billableTokens = billableTokens
    }

    public func tokens(_ counting: TokenCounting) -> Int {
        counting == .all ? tokens : billableTokens
    }
}

/// Spend over one period, and where it went.
public struct SpendBreakdown: Sendable, Equatable {
    public var usd: Double = 0
    public var tokens: Int = 0
    public var bySource: [CostSource: Double] = [:]
    public var billableTokens: Int = 0
    public var tokensBySource: [CostSource: Int] = [:]
    public var billableBySource: [CostSource: Int] = [:]
    /// Dollars and tokens per model id, for the hover breakdown.
    public var byModel: [String: ModelSpend] = [:]

    public func tokens(_ counting: TokenCounting) -> Int {
        counting == .all ? tokens : billableTokens
    }

    public func tokens(from source: CostSource, _ counting: TokenCounting) -> Int {
        (counting == .all ? tokensBySource : billableBySource)[source] ?? 0
    }

    public init(usd: Double = 0, tokens: Int = 0, bySource: [CostSource: Double] = [:]) {
        self.usd = usd
        self.tokens = tokens
        self.bySource = bySource
    }

    public var hasData: Bool { usd > 0 || tokens > 0 }

    /// Sources that actually contributed, largest first — what a chart and its
    /// legend iterate over.
    public var contributions: [(source: CostSource, usd: Double)] {
        bySource
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .map { (source: $0.key, usd: $0.value) }
    }

    /// True when any contributing source is a token estimate rather than a
    /// figure the tool recorded itself.
    public var containsEstimates: Bool {
        contributions.contains { $0.source.isEstimated }
    }

    mutating func add(_ usd: Double, tokens: Int, billable: Int = 0, model: String? = nil, from source: CostSource) {
        self.usd += usd
        self.tokens += tokens
        bySource[source, default: 0] += usd
        billableTokens += billable
        tokensBySource[source, default: 0] += tokens
        billableBySource[source, default: 0] += billable
        if let model {
            var entry = byModel[model] ?? ModelSpend(model: model, source: source)
            entry.usd += usd
            entry.tokens += tokens
            entry.billableTokens += billable
            byModel[model] = entry
        }
    }

    /// Models by dollars, largest first.
    public var models: [ModelSpend] {
        byModel.values.filter { $0.usd > 0 || $0.tokens > 0 }.sorted { $0.usd == $1.usd ? $0.tokens > $1.tokens : $0.usd > $1.usd }
    }
}

/// One model's share of a period.
public struct ModelSpend: Sendable, Equatable, Identifiable {
    public var model: String
    public var source: CostSource
    public var usd: Double = 0
    public var tokens: Int = 0
    public var billableTokens: Int = 0

    public var id: String { model }

    public init(model: String, source: CostSource, usd: Double = 0, tokens: Int = 0, billableTokens: Int = 0) {
        self.model = model
        self.source = source
        self.usd = usd
        self.tokens = tokens
        self.billableTokens = billableTokens
    }

    public func tokens(_ counting: TokenCounting) -> Int {
        counting == .all ? tokens : billableTokens
    }
}

/// Which stretch of time a spend figure covers.
public enum SpendPeriod: String, Sendable, CaseIterable, Identifiable {
    case today
    case yesterday
    case window

    public var id: String { rawValue }

    public func displayName(windowDays: Int) -> String {
        switch self {
        case .today: L10n.t("Today", "今日")
        case .yesterday: L10n.t("Yesterday", "昨日")
        case .window: L10n.t("\(windowDays) days", "\(windowDays) 天")
        }
    }
}

public struct CostSummary: Sendable, Equatable {
    public var todayUSD: Double = 0
    public var todayTokens: Int = 0
    /// Spend split by CLI over the same rolling window as `windowUSD` — a
    /// calendar-month split underneath a 30-day headline would not add up.
    public var windowBySource: [CostSource: Double] = [:]
    /// Rolling-window totals. A trailing 30 days says more about current
    /// burn rate than a calendar month, which reads as near-zero on the 1st.
    public var windowUSD: Double = 0
    public var windowTokens: Int = 0
    /// Per-day spend across the lookback window, oldest first, gaps filled.
    public var daily: [DailyCost] = []
    /// Spend and its per-source split, for each selectable period.
    public var periods: [SpendPeriod: SpendBreakdown] = [:]
    /// How many days `window` covers, for labelling.
    public var windowDays: Int = 30
    /// Model id the most money went to over the window.
    public var topModel: String?
    /// Billable events that were dropped as duplicates — the same assistant
    /// turn is written to several session files when a conversation is
    /// resumed or branched into a sidechain.
    public var deduplicated: Int = 0

    public static let empty = CostSummary()

    public init(
        todayUSD: Double = 0,
        todayTokens: Int = 0,
        windowBySource: [CostSource: Double] = [:],
        windowUSD: Double = 0,
        windowTokens: Int = 0,
        daily: [DailyCost] = [],
        topModel: String? = nil,
        deduplicated: Int = 0)
    {
        self.todayUSD = todayUSD
        self.todayTokens = todayTokens
        self.windowBySource = windowBySource
        self.windowUSD = windowUSD
        self.windowTokens = windowTokens
        self.daily = daily
        self.topModel = topModel
        self.deduplicated = deduplicated
    }

    public var hasData: Bool { windowUSD > 0 || windowTokens > 0 }

    public func spend(_ period: SpendPeriod) -> SpendBreakdown {
        periods[period] ?? SpendBreakdown()
    }

    /// The busiest day in the window — used to label the chart's peak.
    public var peakDay: DailyCost? {
        daily.max { $0.usd < $1.usd }
    }

    /// Trailing `count` days, for a chart that shows less than the full window.
    public func recentDays(_ count: Int) -> [DailyCost] {
        Array(daily.suffix(count))
    }
}

/// One pass over the logs: the archive's days, the recent minutes, and the
/// same tokens per project.
public struct ArchiveScan: Sendable {
    public var days: ArchiveDays
    public var activity: ActivityMinutes
    public var projects: ProjectDays = [:]
    public var projectRefs: [String: ProjectRef] = [:]
}

/// Tokens per minute per CLI over the last 48 hours, from the local session
/// logs. Quota Run's rule 5 asks for these as evidence that a run was real
/// work; they are counts only — no model, prompt or path.
public struct ActivityMinutes: Sendable, Equatable {
    public static let horizon: TimeInterval = 48 * 3_600

    /// When the logs behind these minutes were read. The minute this falls in,
    /// and anything later, may still be growing.
    public var scannedAt: Date?
    /// Minute (Unix seconds, floored) → run source (`claude`, `codex`,
    /// `opencode`) → tokens.
    public var minutes: [Int: [String: Int]] = [:]

    public init(scannedAt: Date? = nil, minutes: [Int: [String: Int]] = [:]) {
        self.scannedAt = scannedAt
        self.minutes = minutes
    }

    public static func floor(_ date: Date) -> Int {
        let seconds = Int(date.timeIntervalSince1970.rounded(.down))
        return seconds - ((seconds % 60) + 60) % 60
    }

    public mutating func add(tokens: Int, at date: Date, source: CostSource) {
        guard tokens > 0 else { return }
        minutes[Self.floor(date), default: [:]][source.runSource, default: 0] += tokens
    }

    /// Whole minutes after `minute` and before the one the scan happened in,
    /// oldest first, as the upload sends them.
    public func completeEntries(after minute: Int) -> [RunActivityPayload] {
        guard let scannedAt else { return [] }
        let open = Self.floor(scannedAt)
        return minutes.keys.filter { $0 > minute && $0 < open }.sorted().flatMap { key in
            (minutes[key] ?? [:]).filter { $0.value > 0 }.sorted { $0.key < $1.key }
                .map { RunActivityPayload(minute: key, source: $0.key, tokens: $0.value) }
        }
    }

    /// Whether `source` logged any tokens in a minute touching `from...to`.
    public func hasTokens(source: String, from: Int, to: Int) -> Bool {
        let first = from - ((from % 60) + 60) % 60
        return minutes.contains { key, sources in
            key >= first && key <= to && (sources[source] ?? 0) > 0
        }
    }
}

extension CostSource {
    /// The name Quota Run's activity uses for this CLI.
    public var runSource: String {
        switch self {
        case .claudeCode: "claude"
        case .codexCLI: "codex"
        case .openCode: "opencode"
        }
    }
}

private struct TokenEvent {
    let timestamp: Date
    let source: CostSource
    let model: String
    /// Fresh (uncached) input only.
    let input: Int
    let output: Int
    let cacheWrite5m: Int
    let cacheWrite1h: Int
    let cacheRead: Int
    /// Stable identity of the billable API call; nil when the log gives us
    /// nothing to key on and the event has to be trusted as unique.
    let dedupeKey: String?
    /// Cost the tool recorded itself. When set, it is used verbatim instead of
    /// pricing the token counts — the tool knows its own rates better than a
    /// list-price table does.
    var presetCost: Double?
    /// The directory the turn ran in, and the remote when the log names one
    /// (Codex does); resolved to a project after the scan.
    var cwd: String? = nil
    var repositoryURL: String? = nil
    var mode: CodingMode = .cli
    /// Session the turn belongs to, for counting sessions per project.
    var session: String? = nil
}

/// USD per million tokens; `marker` is substring-matched against the logged
/// model id, most specific first.
private struct Rates {
    let input: Double
    let output: Double
    /// 5-minute ephemeral cache write (1.25x input on Anthropic models).
    let cacheWrite5m: Double
    /// 1-hour ephemeral cache write (2x input on Anthropic models).
    let cacheWrite1h: Double
    let cacheRead: Double
}

/// Anthropic list prices; OpenAI models charge nothing to write a cache entry.
/// Order matters — "sonnet-5" must be tested before the generic "sonnet".
private let pricingTable: [(marker: String, rates: Rates)] = [
    ("fable", Rates(input: 10, output: 50, cacheWrite5m: 12.5, cacheWrite1h: 20, cacheRead: 1.0)),
    ("mythos", Rates(input: 10, output: 50, cacheWrite5m: 12.5, cacheWrite1h: 20, cacheRead: 1.0)),
    ("opus", Rates(input: 5, output: 25, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.50)),
    ("sonnet-5", Rates(input: 2, output: 10, cacheWrite5m: 2.5, cacheWrite1h: 4, cacheRead: 0.20)),
    ("sonnet", Rates(input: 3, output: 15, cacheWrite5m: 3.75, cacheWrite1h: 6, cacheRead: 0.30)),
    ("haiku", Rates(input: 1, output: 5, cacheWrite5m: 1.25, cacheWrite1h: 2, cacheRead: 0.10)),
    ("gpt-5", Rates(input: 1.25, output: 10, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0.125)),
    ("codex", Rates(input: 1.25, output: 10, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0.125)),
    ("o3", Rates(input: 2, output: 8, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0.5)),
    ("o4", Rates(input: 1.1, output: 4.4, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0.275)),
]

/// Exposed for the test suite so the price table stays pinned to real numbers.
public enum Pricing {
    /// (input, output, cacheWrite5m, cacheWrite1h, cacheRead) USD per million
    /// tokens. `catalog` is injectable so tests can pin the built-in fallback
    /// without depending on whatever prices this machine has fetched.
    public static func perMillion(
        for model: String,
        catalog: PricingCatalog = .shared) -> (Double, Double, Double, Double, Double)
    {
        let r = rates(for: model, catalog: catalog)
        return (r.input, r.output, r.cacheWrite5m, r.cacheWrite1h, r.cacheRead)
    }
}

/// Exact rates from the catalog when it knows the model, otherwise the
/// built-in prefix table.
///
/// Prefix matching is the fallback, not the primary path, because it is
/// actively wrong for models it has never seen: `gpt-5.6-sol` matched the
/// `gpt-5` prefix at $1.25/$10 against a real $4/$20.
private func rates(for model: String, catalog: PricingCatalog = .shared) -> Rates {
    if let published = catalog.rates(for: model) {
        return Rates(
            input: published.input,
            output: published.output,
            cacheWrite5m: published.cacheWrite,
            cacheWrite1h: published.cacheWriteLong,
            cacheRead: published.cacheRead)
    }
    let lowered = model.lowercased()
    for entry in pricingTable where lowered.contains(entry.marker) {
        return entry.rates
    }
    // Unknown model: price it as mid-tier Sonnet rather than as free.
    return Rates(input: 3, output: 15, cacheWrite5m: 3.75, cacheWrite1h: 6, cacheRead: 0.30)
}

private func cost(of event: TokenEvent) -> Double {
    if let preset = event.presetCost { return preset }
    let r = rates(for: event.model)
    return (Double(event.input) * r.input
        + Double(event.output) * r.output
        + Double(event.cacheWrite5m) * r.cacheWrite5m
        + Double(event.cacheWrite1h) * r.cacheWrite1h
        + Double(event.cacheRead) * r.cacheRead) / 1_000_000
}

private func tokens(of event: TokenEvent) -> Int {
    event.input + event.output + event.cacheWrite5m + event.cacheWrite1h + event.cacheRead
}

/// Where the CLIs keep their session logs. Injectable so the estimator can be
/// tested against fixtures instead of the developer's real history.
public struct CostPaths: Sendable {
    public var claudeProjects: URL
    public var codexSessions: URL
    /// opencode's own SQLite store, which records a cost per session.
    public var openCodeDatabase: URL

    /// `openCodeDatabase` defaults to a path that does not exist, so callers
    /// that only care about the log-based sources need not name it.
    public init(
        claudeProjects: URL,
        codexSessions: URL,
        openCodeDatabase: URL = URL(fileURLWithPath: "/nonexistent/opencode.db"))
    {
        self.claudeProjects = claudeProjects
        self.codexSessions = codexSessions
        self.openCodeDatabase = openCodeDatabase
    }

    public static var `default`: CostPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return CostPaths(
            claudeProjects: home.appendingPathComponent(".claude/projects"),
            codexSessions: home.appendingPathComponent(".codex/sessions"),
            openCodeDatabase: home.appendingPathComponent(".local/share/opencode/opencode.db"))
    }
}

public enum CostEstimator {
    /// In-memory memo keyed by (path, mtime, size) so steady-state refreshes
    /// only re-parse files that actually changed.
    /// One entry per file path, stamped with the mtime and size it was parsed
    /// at. Keyed by path, not by path+stamp: a session log that is still being
    /// written changes stamp on every refresh, and keying by stamp kept every
    /// earlier parse of it alive for as long as the app ran.
    private static var cache: [String: (stamp: String, events: [TokenEvent])] = [:]
    private static let lock = NSLock()
    /// Lines bigger than this are base64/tool-output blobs — never usage rows.
    private static let maxLineBytes = 200_000
    /// Read granularity. Larger blocks mean far fewer syscalls across tens of
    /// gigabytes of logs.
    private static let chunkSize = 4 << 20

    public static func summary(
        paths: CostPaths = .default,
        lookbackDays: Int = 31,
        now: Date = Date()) -> CostSummary
    {
        let cutoff = now.addingTimeInterval(-Double(lookbackDays) * 86400)
        var events = scanClaude(root: paths.claudeProjects, cutoff: cutoff)
        events.append(contentsOf: scanCodex(root: paths.codexSessions, cutoff: cutoff))
        events.append(contentsOf: scanOpenCode(database: paths.openCodeDatabase, cutoff: cutoff))

        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)

        // The same assistant turn is logged into every session file that
        // replays it (resume, sidechain, branch). Without this the month total
        // roughly doubles.
        // Oldest day the chart will show; also the rolling-window boundary.
        let windowStart = calendar.date(byAdding: .day, value: -(lookbackDays - 1), to: dayStart)
            ?? dayStart

        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: dayStart) ?? dayStart

        var seen = Set<String>()
        var summary = CostSummary()
        summary.windowDays = lookbackDays
        var periods: [SpendPeriod: SpendBreakdown] = [
            .today: SpendBreakdown(), .yesterday: SpendBreakdown(), .window: SpendBreakdown(),
        ]
        var perDay: [Date: DailyCost] = [:]
        var perModel: [String: Double] = [:]

        for event in events {
            if let key = event.dedupeKey {
                guard seen.insert(key).inserted else {
                    summary.deduplicated += 1
                    continue
                }
            }
            let cost = cost(of: event)
            let count = tokens(of: event)
            let billable = event.input + event.output

            guard event.timestamp >= windowStart else { continue }
            summary.windowUSD += cost
            summary.windowTokens += count
            summary.windowBySource[event.source, default: 0] += cost
            perModel[event.model, default: 0] += cost

            let day = calendar.startOfDay(for: event.timestamp)
            var bucket = perDay[day] ?? DailyCost(day: day)
            bucket.usd += cost
            bucket.tokens += count
            bucket.billableTokens += billable
            perDay[day] = bucket

            periods[.window]?.add(cost, tokens: count, billable: billable, model: event.model, from: event.source)
            if event.timestamp >= dayStart {
                summary.todayUSD += cost
                summary.todayTokens += count
                periods[.today]?.add(cost, tokens: count, billable: billable, model: event.model, from: event.source)
            } else if event.timestamp >= yesterdayStart {
                periods[.yesterday]?.add(cost, tokens: count, billable: billable, model: event.model, from: event.source)
            }
        }
        summary.periods = periods

        // Fill the gaps: a day with no activity must still occupy a slot, or
        // the chart silently compresses idle stretches and misreads as busy.
        summary.daily = (0..<lookbackDays).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: windowStart)
            else { return nil }
            return perDay[day] ?? DailyCost(day: day)
        }
        summary.topModel = perModel.max { $0.value < $1.value }?.key
        return summary
    }

    // MARK: Year ledger

    /// The calendar year to date, one bucket per local day, split by CLI and
    /// by model. Shares the parsed-file memo with `summary`, so once either
    /// has read a file the other gets it for free.
    public static func ledger(paths: CostPaths = .default, now: Date = Date()) -> UsageLedger {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: now)
        guard let yearStart = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let yearEnd = calendar.date(byAdding: .year, value: 1, to: yearStart)
        else { return .empty }
        // Logs are stamped in UTC and files are keyed by mtime; a file last
        // touched the day before the local year began can still hold its
        // first hours.
        let cutoff = yearStart.addingTimeInterval(-2 * 86_400)
        var events = scanClaude(root: paths.claudeProjects, cutoff: cutoff)
        events.append(contentsOf: scanCodex(root: paths.codexSessions, cutoff: cutoff))
        events.append(contentsOf: scanOpenCode(database: paths.openCodeDatabase, cutoff: cutoff))

        var seen = Set<String>()
        var perDay: [Date: UsageDay] = [:]
        var modelSources: [String: CostSource] = [:]
        var duplicates = 0
        for event in events {
            if let key = event.dedupeKey {
                guard seen.insert(key).inserted else { duplicates += 1; continue }
            }
            guard event.timestamp >= yearStart, event.timestamp < yearEnd else { continue }
            let day = calendar.startOfDay(for: event.timestamp)
            var bucket = perDay[day] ?? UsageDay(day: day)
            let count = tokens(of: event)
            bucket.bySource[event.source, default: 0] += count
            bucket.byModel[event.model, default: 0] += count
            bucket.usd += cost(of: event)
            bucket.input += event.input
            bucket.output += event.output
            bucket.cacheRead += event.cacheRead
            bucket.cacheWrite += event.cacheWrite5m + event.cacheWrite1h
            perDay[day] = bucket
            modelSources[event.model] = event.source
        }

        var days: [UsageDay] = []
        var cursor = yearStart
        while cursor < yearEnd {
            days.append(perDay[cursor] ?? UsageDay(day: cursor))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return UsageLedger(
            year: year,
            days: days,
            today: calendar.startOfDay(for: now),
            modelSources: modelSources,
            scannedAt: now,
            deduplicated: duplicates)
    }

    // MARK: Archive records

    /// Every token event since `cutoff`, folded per local day, CLI and model,
    /// for the archive. Shares the parsed-file memo with the other scans.
    public static func archiveRecords(paths: CostPaths = .default, since cutoff: Date) -> ArchiveDays {
        archiveScan(paths: paths, since: cutoff).days
    }

    /// The archive's days, plus tokens per minute for the last two days —
    /// Quota Run's evidence of real work — from the same pass. The events are
    /// already in hand, deduplicated and timestamped, so the minutes cost one
    /// comparison per event and a dictionary write for the recent ones; no
    /// file is read twice. An incremental scan starts two days before the
    /// last one, so it always covers the whole horizon.
    public static func archiveScan(paths: CostPaths = .default, since cutoff: Date, now: Date = Date()) -> ArchiveScan {
        var events = scanClaude(root: paths.claudeProjects, cutoff: cutoff)
        events.append(contentsOf: scanCodex(root: paths.codexSessions, cutoff: cutoff))
        events.append(contentsOf: scanOpenCode(database: paths.openCodeDatabase, cutoff: cutoff))
        var seen = Set<String>()
        var out: ArchiveDays = [:]
        var activity = ActivityMinutes(scannedAt: now)
        let recent = now.addingTimeInterval(-ActivityMinutes.horizon)
        // Per day, project, CLI and mode: the day itself, plus the sessions and
        // minutes seen, which only become counts at the end.
        struct ProjectBucket {
            var day = ProjectDay()
            var sessions = Set<String>()
            var minutes = Set<Int>()
        }
        var buckets: [String: [String: [String: [String: ProjectBucket]]]] = [:]
        var refs: [String: ProjectRef] = [:]
        let calendar = Calendar.current
        for event in events {
            if let key = event.dedupeKey {
                guard seen.insert(key).inserted else { continue }
            }
            guard event.timestamp >= cutoff else { continue }
            let day = UsageArchive.dayKey(event.timestamp)
            var fresh = ArchiveEntry()
            fresh.usd = cost(of: event)
            fresh.input = event.input
            fresh.output = event.output
            fresh.cacheRead = event.cacheRead
            fresh.cacheWrite = event.cacheWrite5m + event.cacheWrite1h
            var entry = out[day]?[event.source.rawValue]?[event.model] ?? ArchiveEntry()
            entry.add(fresh)
            out[day, default: [:]][event.source.rawValue, default: [:]][event.model] = entry
            let count = tokens(of: event)
            if event.timestamp >= recent, event.timestamp <= now {
                activity.add(tokens: count, at: event.timestamp, source: event.source)
            }

            let project = ProjectResolver.resolve(cwd: event.cwd, repositoryURL: event.repositoryURL)
            refs[project.key] = project
            var bucket = buckets[day]?[project.key]?[event.source.rawValue]?[event.mode.rawValue] ?? ProjectBucket()
            var model = bucket.day.models[event.model] ?? ArchiveEntry()
            model.add(fresh)
            bucket.day.models[event.model] = model
            if bucket.day.hours.isEmpty { bucket.day.hours = Array(repeating: 0, count: 24) }
            bucket.day.hours[calendar.component(.hour, from: event.timestamp)] += count
            if let session = event.session { bucket.sessions.insert(session) }
            bucket.minutes.insert(ActivityMinutes.floor(event.timestamp))
            buckets[day, default: [:]][project.key, default: [:]][event.source.rawValue, default: [:]][event.mode.rawValue] = bucket
        }
        var projects: ProjectDays = [:]
        for (day, perProject) in buckets {
            for (project, sources) in perProject {
                for (source, modes) in sources {
                    for (mode, bucket) in modes {
                        var entry = bucket.day
                        entry.sessions = bucket.sessions.count
                        entry.activeMinutes = bucket.minutes.count
                        projects[day, default: [:]][project, default: [:]][source, default: [:]][mode] = entry
                    }
                }
            }
        }
        return ArchiveScan(days: out, activity: activity, projects: projects, projectRefs: refs)
    }

    /// How many files the parse memo holds; for the tests.
    static var cachedFileCount: Int {
        lock.lock(); defer { lock.unlock() }
        return cache.count
    }

    /// Drops the parsed-file memo; used by tests and after a manual rescan.
    public static func resetCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    // MARK: Claude Code (~/.claude/projects/**/*.jsonl)

    private static func scanClaude(root: URL, cutoff: Date) -> [TokenEvent] {
        return walk(root, cutoff: cutoff, filter: { $0.pathExtension == "jsonl" }) { url, formatter in
            var out: [TokenEvent] = []
            // Every line repeats the directory and the entrypoint; one copy of
            // each string per file is kept however many turns name it.
            var strings: [String: String] = [:]
            func intern(_ value: String?) -> String? {
                guard let value else { return nil }
                if let kept = strings[value] { return kept }
                strings[value] = value
                return value
            }
            let fileSession = url.deletingPathExtension().lastPathComponent
            streamLines(url) { line in
                // Claude puts `usage` after the message content, so the whole
                // line has to be searched.
                contains(line, Markers.assistant) && contains(line, Markers.usage)
            } handle: { line in
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      obj["type"] as? String == "assistant",
                      let message = obj["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any]
                else { return }

                // Anthropic bills 5-minute and 1-hour cache writes at different
                // multiples of the input rate; fall back to the flat total when
                // the breakdown is absent (older log format).
                let totalWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
                let breakdown = usage["cache_creation"] as? [String: Any]
                let write1h = breakdown?["ephemeral_1h_input_tokens"] as? Int ?? 0
                let write5m = breakdown.map { $0["ephemeral_5m_input_tokens"] as? Int ?? 0 }
                    ?? totalWrite

                let messageID = message["id"] as? String
                let requestID = obj["requestId"] as? String
                let dedupeKey = (messageID ?? requestID).map { _ in
                    "claude|\(messageID ?? "")|\(requestID ?? "")"
                }

                out.append(TokenEvent(
                    timestamp: parseTimestamp(obj["timestamp"], formatter),
                    source: .claudeCode,
                    model: message["model"] as? String ?? "claude-sonnet",
                    input: usage["input_tokens"] as? Int ?? 0,
                    output: usage["output_tokens"] as? Int ?? 0,
                    cacheWrite5m: write5m,
                    cacheWrite1h: write1h,
                    cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
                    dedupeKey: dedupeKey,
                    presetCost: nil,
                    cwd: intern(obj["cwd"] as? String),
                    mode: CodingMode.claude(entrypoint: obj["entrypoint"] as? String),
                    session: intern(obj["sessionId"] as? String ?? fileSession)))
            }
            return out
        }
    }

    // MARK: Codex CLI (~/.codex/sessions/**/rollout-*.jsonl)

    private static func scanCodex(root: URL, cutoff: Date) -> [TokenEvent] {
        return walk(root, cutoff: cutoff, filter: { $0.lastPathComponent.hasPrefix("rollout-") }) { url, formatter in
            var out: [TokenEvent] = []
            var currentModel = "gpt-5-codex"
            // The session's first record says where it ran and from what; each
            // turn's context repeats the directory in case it moved.
            var cwd: String?
            var repository: String?
            var mode = CodingMode.cli
            var session = url.deletingPathExtension().lastPathComponent
            streamLines(url) { line in
                let head = line.count > Markers.codexHeadBytes
                    ? UnsafeRawBufferPointer(rebasing: line[0..<Markers.codexHeadBytes])
                    : line
                return contains(head, Markers.turnContext) || contains(head, Markers.tokenCount)
                    || contains(head, Markers.sessionMeta)
            } handle: { line in
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                else { return }
                let type = obj["type"] as? String ?? ""
                let payload = obj["payload"] as? [String: Any] ?? [:]
                if type == "session_meta" {
                    cwd = payload["cwd"] as? String ?? cwd
                    repository = (payload["git"] as? [String: Any])?["repository_url"] as? String ?? repository
                    mode = CodingMode.codex(originator: payload["originator"] as? String, source: payload["source"] as? String)
                    if let id = payload["id"] as? String { session = id }
                    return
                }
                if type == "turn_context" {
                    if let directory = payload["cwd"] as? String { cwd = directory }
                    if let model = payload["model"] as? String { currentModel = model }
                    return
                }
                guard type == "event_msg", payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let last = info["last_token_usage"] as? [String: Any]
                else { return }

                // Codex reports `input_tokens` inclusive of `cached_input_tokens`;
                // billing the full figure *and* the cached figure double-charges
                // every cache hit.
                let rawInput = last["input_tokens"] as? Int ?? 0
                let cached = last["cached_input_tokens"] as? Int ?? 0
                let timestamp = parseTimestamp(obj["timestamp"], formatter)
                let output = last["output_tokens"] as? Int ?? 0

                out.append(TokenEvent(
                    timestamp: timestamp,
                    source: .codexCLI,
                    model: currentModel,
                    input: max(0, rawInput - cached),
                    output: output,
                    cacheWrite5m: last["cache_write_input_tokens"] as? Int ?? 0,
                    cacheWrite1h: 0,
                    cacheRead: cached,
                    dedupeKey: "codex|\(obj["timestamp"] as? String ?? "")|\(rawInput)|\(output)",
                    presetCost: nil,
                    cwd: cwd,
                    repositoryURL: repository,
                    mode: mode,
                    session: session))
            }
            return out
        }
    }

    // MARK: OpenCode (~/.local/share/opencode/opencode.db)

    /// opencode records a cost per session in its own database, so there is
    /// nothing to price here — the figure is taken as reported rather than
    /// re-derived from token counts.
    ///
    /// Cost is attributed to the session's last-updated time. A session spanning
    /// midnight therefore lands entirely on the later day; splitting it would
    /// need per-message costs, which the table does not carry.
    private static func scanOpenCode(database: URL, cutoff: Date) -> [TokenEvent] {
        let cutoffMillis = Int(cutoff.timeIntervalSince1970 * 1000)
        func read(_ directory: String) -> [[String?]] {
            SQLiteRead.rows(
                inFile: database.path,
                query: """
                SELECT time_updated, cost, tokens_input, tokens_output,
                       tokens_cache_read, tokens_cache_write, id\(directory)
                FROM session
                WHERE cost > 0 AND time_updated >= \(cutoffMillis)
                """)
        }
        // Older opencode databases have no `directory` column; the query then
        // fails as a whole, so it is asked again without it.
        var rows = read(", directory")
        if rows.isEmpty { rows = read("") }
        return rows.compactMap { row in
            guard row.count >= 7,
                  let millis = row[0].flatMap(Double.init),
                  let cost = row[1].flatMap(Double.init)
            else { return nil }
            func count(_ index: Int) -> Int {
                row[index].flatMap(Int.init) ?? 0
            }
            return TokenEvent(
                timestamp: Date(timeIntervalSince1970: millis / 1000),
                source: .openCode,
                model: "opencode",
                input: count(2),
                output: count(3),
                cacheWrite5m: count(5),
                cacheWrite1h: 0,
                cacheRead: count(4),
                dedupeKey: row[6].map { "opencode|\($0)" },
                presetCost: cost,
                cwd: row.count > 7 ? row[7] : nil,
                session: row[6])
        }
    }

    // MARK: Shared plumbing

    private static func walk(
        _ root: URL,
        cutoff: Date,
        filter: @escaping (URL) -> Bool,
        parse: @escaping @Sendable (URL, ISO8601DateFormatter) -> [TokenEvent]) -> [TokenEvent]
    {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Enumerate and stat first (cheap), then parse the misses in parallel:
        // this is IO- and CPU-bound over gigabytes, and doing it on one thread
        // left most of the machine idle.
        var out: [TokenEvent] = []
        var pending: [(url: URL, key: String, size: Int)] = []
        var visited = Set<String>()
        for case let url as URL in enumerator {
            guard filter(url) else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let mtime = values?.contentModificationDate, mtime >= cutoff else { continue }
            // Size is part of the stamp: an append within the same mtime
            // second would otherwise serve a stale parse.
            let size = values?.fileSize ?? -1
            let stamp = "\(mtime.timeIntervalSince1970)|\(size)"
            visited.insert(url.path)
            lock.lock()
            let cached = cache[url.path]
            lock.unlock()
            if let cached, cached.stamp == stamp {
                out.append(contentsOf: cached.events)
            } else {
                pending.append((url, stamp, size))
            }
        }
        // Files under this root the scan no longer reaches — older than the
        // cutoff, or deleted — have nothing more to give; let them go.
        // The enumerator may hand back /private/var for /var, and
        // resolvingSymlinksInPath goes the other way, so both sides are
        // compared without the /private.
        func plain(_ path: String) -> String {
            path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
        }
        let prefix = plain(root.path.hasSuffix("/") ? root.path : root.path + "/")
        lock.lock()
        for path in cache.keys where plain(path).hasPrefix(prefix) && !visited.contains(path) {
            cache[path] = nil
        }
        lock.unlock()
        guard !pending.isEmpty else { return out }

        // Longest-processing-time-first: session logs are wildly uneven (a real
        // tree has 3GB files next to 40KB ones). In enumeration order a giant
        // file picked up last leaves every other core idle waiting for it.
        pending.sort { $0.size > $1.size }

        var parsed = [[TokenEvent]](repeating: [], count: pending.count)
        parsed.withUnsafeMutableBufferPointer { buffer in
            let box = UncheckedBox(buffer)
            DispatchQueue.concurrentPerform(iterations: pending.count) { index in
                let localFormatter = ISO8601DateFormatter()
                localFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                box.value[index] = parse(pending[index].url, localFormatter)
            }
        }
        for (index, item) in pending.enumerated() {
            lock.lock()
            cache[item.url.path] = (item.key, parsed[index])
            lock.unlock()
            out.append(contentsOf: parsed[index])
        }
        return out
    }

    /// `concurrentPerform` writes disjoint indices, which the compiler cannot
    /// prove; each worker touches only its own slot.
    private final class UncheckedBox<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    /// Byte patterns matched before any JSON parsing. Held as `Data` so the
    /// hot path never builds a `String`: the Codex log tree alone is tens of
    /// gigabytes, and converting every line to `String` just to test for a
    /// substring dominated the scan.
    private enum Markers {
        static let assistant = Array("\"assistant\"".utf8)
        static let usage = Array("\"usage\"".utf8)
        static let turnContext = Array("turn_context".utf8)
        static let tokenCount = Array("token_count".utf8)
        static let sessionMeta = Array("session_meta".utf8)

        /// Codex writes `"type"` near the start of every record, while the bulk
        /// of the file is enormous tool-output lines. Measured over a real
        /// tree: rows we care about are 0.2% of the bytes and the marker never
        /// appeared past ~2.7KB, so scanning only the head of each line skips
        /// almost all of the work. Claude puts `usage` *after* the message
        /// content, so its lines must still be searched in full.
        static let codexHeadBytes = 8192
    }

    /// Substring search straight over the mapped bytes. `Data.range(of:)` had
    /// to materialise a slice per line first, and at hundreds of millions of
    /// lines that allocation dominated the scan.
    private static func contains(_ haystack: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        // An empty needle has no base address to hand to memmem.
        guard !needle.isEmpty, let base = haystack.baseAddress, haystack.count >= needle.count
        else { return false }
        return needle.withUnsafeBytes { pattern in
            memmem(base, haystack.count, pattern.baseAddress!, needle.count) != nil
        }
    }

    /// Splits the file into lines without allocating for the ones we discard.
    ///
    /// `matches` is offered the raw bytes; only lines it accepts are turned
    /// into `Data` and handed to `handle`. On a real log tree that is under
    /// 0.3% of the bytes read.
    private static func streamLines(
        _ url: URL,
        matches: (UnsafeRawBufferPointer) -> Bool,
        handle: (Data) -> Void)
    {
        guard let file = FileHandle(forReadingAtPath: url.path) else { return }
        defer { try? file.close() }

        // Carries the trailing partial line across a chunk boundary.
        var remainder = Data()
        // Set while discarding an oversized line so its tail isn't mistaken
        // for the start of the next one.
        var skipping = false

        func emit(_ line: Data) {
            guard line.count <= maxLineBytes else { return }
            let accepted = line.withUnsafeBytes { matches($0) }
            if accepted { handle(line) }
        }

        while true {
            let chunk = file.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                var cursor = 0
                while cursor < raw.count {
                    guard let newline = memchr(base + cursor, 0x0A, raw.count - cursor) else { break }
                    let newlineOffset = UnsafeRawPointer(newline) - base
                    let length = newlineOffset - cursor

                    if skipping {
                        skipping = false
                    } else if remainder.isEmpty {
                        let line = UnsafeRawBufferPointer(start: base + cursor, count: length)
                        if length <= maxLineBytes, matches(line) {
                            handle(Data(line))
                        }
                    } else {
                        remainder.append(
                            contentsOf: UnsafeRawBufferPointer(start: base + cursor, count: length))
                        emit(remainder)
                        remainder = Data()
                    }
                    cursor = newlineOffset + 1
                }
                if cursor < raw.count {
                    let tail = UnsafeRawBufferPointer(start: base + cursor, count: raw.count - cursor)
                    if skipping {
                        // still inside the oversized line
                    } else if remainder.isEmpty {
                        remainder = Data(tail)
                    } else {
                        remainder.append(contentsOf: tail)
                    }
                }
            }
            if remainder.count > maxLineBytes {
                remainder = Data()
                skipping = true
            }
        }
        if !skipping, !remainder.isEmpty {
            emit(remainder)
        }
    }

    private static func parseTimestamp(_ raw: Any?, _ formatter: ISO8601DateFormatter) -> Date {
        if let string = raw as? String {
            if let date = formatter.date(from: string) { return date }
            let plain = ISO8601DateFormatter()
            if let date = plain.date(from: string) { return date }
        }
        return .distantPast
    }
}

extension ProviderID {
    /// The CLI whose local session logs this provider's traffic lands in.
    public var costSource: CostSource? {
        switch self {
        case .claude: .claudeCode
        case .codex: .codexCLI
        case .opencodeGo: .openCode
        default: nil
        }
    }
}
