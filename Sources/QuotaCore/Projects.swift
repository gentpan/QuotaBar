import Foundation

// MARK: - Projects: which repository the tokens went to, and how the CLI was driven

/// How a coding agent was driven: its own terminal UI, a desktop app, an
/// editor extension, an SDK, or a cloud task. Read from the session logs —
/// Claude Code writes an `entrypoint` on every line, Codex an `originator`
/// in each session's first record.
public enum CodingMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case cli
    case desktop
    case ide
    case sdk
    case cloud
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .cli: L10n.t("Terminal", "命令行")
        case .desktop: L10n.t("Desktop app", "桌面版")
        case .ide: L10n.t("Editor", "编辑器插件")
        case .sdk: "SDK"
        case .cloud: L10n.t("Cloud", "云端")
        case .other: L10n.t("Other", "其他")
        }
    }

    /// Claude Code's `entrypoint`: `cli`, `claude-desktop`, `claude-vscode`,
    /// `sdk-ts`, `sdk-py`, … Older logs have none, and they all came from the
    /// terminal.
    public static func claude(entrypoint: String?) -> CodingMode {
        guard let raw = entrypoint?.lowercased(), !raw.isEmpty else { return .cli }
        if raw == "cli" { return .cli }
        if raw.contains("desktop") { return .desktop }
        if raw.contains("vscode") || raw.contains("jetbrains") || raw.contains("ide") || raw.contains("cursor") { return .ide }
        if raw.hasPrefix("sdk") || raw.contains("action") { return .sdk }
        if raw.contains("web") || raw.contains("remote") || raw.contains("cloud") { return .cloud }
        return .other
    }

    /// Codex's `originator` (`codex_cli_rs`, `Codex Desktop`, `codex_vscode`,
    /// `codex_exec`, …) decides; `source` only when the originator says nothing.
    /// The desktop app reports `source: vscode`, so the originator comes first.
    public static func codex(originator: String?, source: String?) -> CodingMode {
        let raw = originator?.lowercased() ?? ""
        if raw.contains("desktop") { return .desktop }
        if raw.contains("vscode") || raw.contains("jetbrains") || raw.contains("ide") { return .ide }
        if raw.contains("exec") || raw.contains("sdk") { return .sdk }
        if raw.contains("cloud") || raw.contains("web") { return .cloud }
        if raw.contains("cli") || raw == "codex_tui" { return .cli }
        switch source?.lowercased() {
        case "vscode": return .ide
        case "exec", "mcp": return .sdk
        case "cli", nil, "": return .cli
        default: return .other
        }
    }
}

/// One project as the logs know it: a Git repository by its remote, or a
/// folder when it has none.
public struct ProjectRef: Sendable, Hashable {
    /// `github.com/owner/repo` in lower case for a repository with a remote;
    /// `local:<name>:<hash>` for one without; `dir:<name>:<hash>` for a plain
    /// folder; `unknown` when the log names no directory at all.
    public var key: String
    public var name: String
    /// `github.com/owner/Repo` as the remote spells it.
    public var repo: String?
    /// The main working tree on this Mac. Local only: never uploaded.
    public var root: String?

    public init(key: String, name: String, repo: String? = nil, root: String? = nil) {
        self.key = key
        self.name = name
        self.repo = repo
        self.root = root
    }

    public static let unknown = ProjectRef(key: "unknown", name: "")
    public var isUnknown: Bool { key == "unknown" }
}

/// Working directory → project. Every lookup walks up to the repository and
/// reads its config straight from disk (no `git` process); answers are
/// memoised per directory, since a log tree names the same few directories
/// millions of times.
public enum ProjectResolver {
    private static var memo: [String: ProjectRef] = [:]
    private static let lock = NSLock()

    public static func resolve(cwd: String?, repositoryURL: String? = nil) -> ProjectRef {
        let memoKey = "\(cwd ?? "")\u{1F}\(repositoryURL ?? "")"
        lock.lock()
        if let hit = memo[memoKey] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let ref = compute(cwd: cwd, repositoryURL: repositoryURL)
        lock.lock()
        if memo.count > 4_096 { memo.removeAll() }
        memo[memoKey] = ref
        lock.unlock()
        return ref
    }

    public static func resetCache() {
        lock.lock()
        memo.removeAll()
        lock.unlock()
    }

    private static func compute(cwd: String?, repositoryURL: String?) -> ProjectRef {
        let given = repositoryURL.flatMap(normalizeRemote)
        guard let cwd, !cwd.isEmpty, cwd.hasPrefix("/") else {
            if let given { return ref(remote: given, root: nil) }
            return .unknown
        }
        let path = (cwd as NSString).standardizingPath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if let repository = findRepository(from: path) {
            if let remote = given ?? repository.remote {
                return ref(remote: remote, root: repository.root)
            }
            let name = (repository.root as NSString).lastPathComponent
            return ProjectRef(key: "local:\(name.lowercased()):\(stableHash(repository.root))", name: name, root: repository.root)
        }
        if let given { return ref(remote: given, root: nil) }
        // Work started from the home folder or the disk root is not a project.
        if path == home || path == "/" || path == "/tmp" || path.hasPrefix("/private/var/folders") { return .unknown }
        let name = (path as NSString).lastPathComponent
        return ProjectRef(key: "dir:\(name.lowercased()):\(stableHash(path))", name: name, root: path)
    }

    private static func ref(remote: String, root: String?) -> ProjectRef {
        let name = remote.split(separator: "/").last.map(String.init) ?? remote
        return ProjectRef(key: remote.lowercased(), name: name, repo: remote, root: root)
    }

    /// The working tree containing `path` and its remote. A linked worktree
    /// (`.git` is a file naming the real git dir) resolves to the repository
    /// it belongs to, so a branch checked out elsewhere is the same project.
    static func findRepository(from path: String) -> (root: String, remote: String?)? {
        let fm = FileManager.default
        var current = path
        for _ in 0..<48 {
            let dotGit = (current as NSString).appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
                var gitDir = dotGit
                var root = current
                if !isDirectory.boolValue {
                    guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
                          let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
                    else { return nil }
                    let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    gitDir = target.hasPrefix("/") ? target : ((current as NSString).appendingPathComponent(target) as NSString).standardizingPath
                }
                var common = gitDir
                if let commonText = try? String(contentsOfFile: (gitDir as NSString).appendingPathComponent("commondir"), encoding: .utf8) {
                    let target = commonText.trimmingCharacters(in: .whitespacesAndNewlines)
                    common = target.hasPrefix("/") ? target : ((gitDir as NSString).appendingPathComponent(target) as NSString).standardizingPath
                    if (common as NSString).lastPathComponent == ".git" {
                        root = (common as NSString).deletingLastPathComponent
                    }
                }
                let config = try? String(contentsOfFile: (common as NSString).appendingPathComponent("config"), encoding: .utf8)
                return (root, config.flatMap(remoteURL(inConfig:)).flatMap(normalizeRemote))
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { break }
            current = parent
        }
        return nil
    }

    /// `origin`'s URL, else the first remote's.
    static func remoteURL(inConfig text: String) -> String? {
        var section: String?
        var first: String?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                section = line
                continue
            }
            guard let section, section.hasPrefix("[remote "), line.hasPrefix("url") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "url" else { continue }
            let url = parts[1].trimmingCharacters(in: .whitespaces)
            if section == "[remote \"origin\"]" { return url }
            if first == nil { first = url }
        }
        return first
    }

    /// Any spelling of a remote → `host/owner/repo`: `git@github.com:o/r.git`,
    /// `https://user:token@github.com/o/r`, `ssh://git@host:22/o/r.git`.
    /// Credentials and ports are dropped; `nil` for local paths.
    public static func normalizeRemote(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("git+") { text.removeFirst(4) }
        var host: String
        var path: String
        if let schemeRange = text.range(of: "://") {
            let scheme = text[..<schemeRange.lowerBound].lowercased()
            guard ["https", "http", "ssh", "git"].contains(scheme) else { return nil }
            let rest = text[schemeRange.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            var authority = String(rest[..<slash])
            if let at = authority.lastIndex(of: "@") { authority = String(authority[authority.index(after: at)...]) }
            if let colon = authority.firstIndex(of: ":") { authority = String(authority[..<colon]) }
            host = authority
            path = String(rest[rest.index(after: slash)...])
        } else if let colon = text.firstIndex(of: ":"), !text.hasPrefix("/") {
            var authority = String(text[..<colon])
            if let at = authority.lastIndex(of: "@") { authority = String(authority[authority.index(after: at)...]) }
            host = authority
            path = String(text[text.index(after: colon)...])
        } else {
            return nil
        }
        host = host.lowercased()
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") { path.removeLast(4) }
        let segments = path.split(separator: "/").filter { !$0.isEmpty }
        guard host.contains("."), !host.contains(" "), segments.count >= 2,
              segments.allSatisfy({ $0.allSatisfy { $0.isLetter || $0.isNumber || "-_.~".contains($0) } })
        else { return nil }
        return ([host] + segments.map(String.init)).joined(separator: "/")
    }

    /// FNV-1a, so a folder's key is the same on every launch.
    static func stableHash(_ text: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return String(format: "%08x", hash)
    }
}

// MARK: - The project archive

/// One project's traffic under one CLI and one way of driving it, on one day.
public struct ProjectDay: Codable, Equatable, Sendable {
    /// Sessions with at least one billable turn that day.
    public var sessions: Int = 0
    /// Minutes with at least one billable turn.
    public var activeMinutes: Int = 0
    /// Tokens per local hour, 24 slots; empty when nothing was logged.
    public var hours: [Int] = []
    public var models: [String: ArchiveEntry] = [:]

    public init(sessions: Int = 0, activeMinutes: Int = 0, hours: [Int] = [], models: [String: ArchiveEntry] = [:]) {
        self.sessions = sessions
        self.activeMinutes = activeMinutes
        self.hours = hours
        self.models = models
    }

    public var allTokens: Int { models.values.reduce(0) { $0 + $1.allTokens } }
    public var billableTokens: Int { models.values.reduce(0) { $0 + $1.billableTokens } }
    public var usd: Double { models.values.reduce(0) { $0 + $1.usd } }
}

/// Day key → project key → CLI raw value → mode raw value → day.
public typealias ProjectDays = [String: [String: [String: [String: ProjectDay]]]]

/// What the app knows about a project besides its numbers.
public struct ProjectInfo: Codable, Equatable, Sendable, Identifiable {
    public var key: String
    public var name: String
    public var repo: String?
    public var root: String?
    public var firstDay: String
    public var lastDay: String

    public var id: String { key }

    public init(key: String, name: String, repo: String? = nil, root: String? = nil, firstDay: String, lastDay: String) {
        self.key = key
        self.name = name
        self.repo = repo
        self.root = root
        self.firstDay = firstDay
        self.lastDay = lastDay
    }

    public var isUnknown: Bool { key == "unknown" }

    /// What to call it: the repository or folder name, or "Other" for work
    /// started outside any project.
    public var displayName: String {
        isUnknown || name.isEmpty ? L10n.t("Outside a project", "项目之外") : name
    }

    /// `github.com/owner/repo` when the remote is on GitHub.
    public var githubRepo: String? {
        guard let repo, repo.lowercased().hasPrefix("github.com/") else { return nil }
        let parts = repo.split(separator: "/")
        return parts.count >= 3 ? "\(parts[1])/\(parts[2])" : nil
    }
}

/// QuotaBar's record of tokens per project, kept next to the usage archive
/// and merged the same way: per day, project, CLI and mode, the larger of
/// two readings wins, so logs Claude Code prunes do not shrink it.
/// Holds counts, model ids, remotes and folder paths — no conversations.
public struct ProjectArchive: Codable, Equatable, Sendable {
    public var version = 1
    public var days: ProjectDays = [:]
    public var projects: [String: ProjectInfo] = [:]
    public var lastScan: Date?
    public var fullScanDone = false

    public init() {}

    public mutating func merge(_ fresh: ProjectDays, infos: [String: ProjectRef], scannedAt: Date, full: Bool) {
        for (day, projectsOnDay) in fresh {
            for (project, sources) in projectsOnDay {
                for (source, modes) in sources {
                    for (mode, entry) in modes {
                        let kept = days[day]?[project]?[source]?[mode]
                        if kept == nil || entry.allTokens >= kept!.allTokens {
                            days[day, default: [:]][project, default: [:]][source, default: [:]][mode] = entry
                        }
                    }
                }
                let ref = infos[project]
                if var info = projects[project] {
                    info.firstDay = min(info.firstDay, day)
                    info.lastDay = max(info.lastDay, day)
                    if let ref {
                        info.name = ref.name
                        info.repo = ref.repo ?? info.repo
                        info.root = ref.root ?? info.root
                    }
                    projects[project] = info
                } else {
                    projects[project] = ProjectInfo(
                        key: project, name: ref?.name ?? "", repo: ref?.repo, root: ref?.root, firstDay: day, lastDay: day)
                }
            }
        }
        lastScan = scannedAt
        if full { fullScanDone = true }
    }

    public func incrementalCutoff(calendar: Calendar = .current) -> Date? {
        guard fullScanDone, let lastScan else { return nil }
        return calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: lastScan))
    }

    /// Folder and remote-less keys that are really a repository seen elsewhere:
    /// the same work before `git remote add`, or a copy of the checkout without
    /// its `.git`. A folder is folded into the repository with the same name
    /// when exactly one repository has that name.
    public func aliases() -> [String: String] {
        var repositories: [String: [String]] = [:]
        for info in projects.values where info.repo != nil {
            repositories[info.name.lowercased(), default: []].append(info.key)
        }
        var out: [String: String] = [:]
        for info in projects.values where info.repo == nil && !info.isUnknown {
            if let keys = repositories[info.name.lowercased()], keys.count == 1 {
                out[info.key] = keys[0]
            }
        }
        return out
    }

    /// The archive with every alias folded into its repository.
    public func canonical() -> ProjectArchive {
        let map = aliases()
        guard !map.isEmpty else { return self }
        var out = ProjectArchive()
        out.lastScan = lastScan
        out.fullScanDone = fullScanDone
        for (key, info) in projects where map[key] == nil {
            out.projects[key] = info
        }
        for (key, target) in map {
            guard let info = projects[key], var kept = out.projects[target] else { continue }
            kept.firstDay = min(kept.firstDay, info.firstDay)
            kept.lastDay = max(kept.lastDay, info.lastDay)
            out.projects[target] = kept
        }
        for (day, perProject) in days {
            for (key, sources) in perProject {
                let target = map[key] ?? key
                for (source, modes) in sources {
                    for (mode, entry) in modes {
                        var merged = out.days[day]?[target]?[source]?[mode] ?? ProjectDay()
                        merged.sessions += entry.sessions
                        merged.activeMinutes += entry.activeMinutes
                        if merged.hours.isEmpty { merged.hours = Array(repeating: 0, count: 24) }
                        for (hour, value) in entry.hours.enumerated() where hour < 24 { merged.hours[hour] += value }
                        for (model, modelEntry) in entry.models {
                            var kept = merged.models[model] ?? ArchiveEntry()
                            kept.add(modelEntry)
                            merged.models[model] = kept
                        }
                        out.days[day, default: [:]][target, default: [:]][source, default: [:]][mode] = merged
                    }
                }
            }
        }
        return out
    }

    /// Every project with activity in `start...end` (local days), most dollars
    /// first, with folder aliases folded into their repositories.
    public func overview(from start: Date, to end: Date, calendar: Calendar = .current) -> ProjectOverview {
        let archive = canonical()
        return archive.rawOverview(from: start, to: end, calendar: calendar)
    }

    private func rawOverview(from start: Date, to end: Date, calendar: Calendar) -> ProjectOverview {
        let first = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        var out = ProjectOverview(start: first, end: last)
        var builders: [String: ProjectSummary] = [:]
        var dayIndex = 0
        var cursor = first
        var dayCount = 0
        while cursor <= last {
            dayCount += 1
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        cursor = first
        while cursor <= last {
            let key = UsageArchive.dayKey(cursor)
            let weekday = (calendar.component(.weekday, from: cursor) + 5) % 7   // Monday 0
            for (project, sources) in days[key] ?? [:] {
                var summary = builders[project] ?? ProjectSummary(
                    info: projects[project] ?? ProjectInfo(key: project, name: "", firstDay: key, lastDay: key),
                    dayCount: dayCount)
                var dayUSD = 0.0
                var dayTokens = 0
                for (rawSource, modes) in sources {
                    let source = CostSource(rawValue: rawSource)
                    for (rawMode, entry) in modes {
                        let mode = CodingMode(rawValue: rawMode) ?? .other
                        let usd = entry.usd
                        let tokens = entry.allTokens
                        dayUSD += usd
                        dayTokens += tokens
                        summary.sessions += entry.sessions
                        summary.activeMinutes += entry.activeMinutes
                        summary.billableTokens += entry.billableTokens
                        summary.byMode[mode, default: 0] += tokens
                        if let source {
                            summary.bySource[source, default: SourceShare()].usd += usd
                            summary.bySource[source, default: SourceShare()].tokens += tokens
                            summary.modePairs.insert("\(source.rawValue)|\(mode.rawValue)")
                        }
                        for (model, modelEntry) in entry.models {
                            var spend = summary.modelSpend[model] ?? ModelSpend(model: model, source: source ?? .claudeCode)
                            spend.usd += modelEntry.usd
                            spend.tokens += modelEntry.allTokens
                            spend.billableTokens += modelEntry.billableTokens
                            summary.modelSpend[model] = spend
                        }
                        for (hour, value) in entry.hours.enumerated() where hour < 24 {
                            summary.weekHours[weekday][hour] += value
                        }
                    }
                }
                summary.usd += dayUSD
                summary.tokens += dayTokens
                summary.daily[dayIndex] = ArchiveSummary.Day(day: cursor, usd: dayUSD, tokens: dayTokens)
                if dayTokens > 0 || dayUSD > 0 {
                    summary.activeDays += 1
                    summary.lastActive = cursor
                }
                builders[project] = summary
            }
            dayIndex += 1
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        // Empty days get their dates too, so every project's series lines up.
        var dates: [Date] = []
        cursor = first
        while cursor <= last {
            dates.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        out.projects = builders.values.map { summary in
            var summary = summary
            for (index, date) in dates.enumerated() where summary.daily[index].day != date {
                summary.daily[index] = ArchiveSummary.Day(day: date, usd: 0, tokens: 0)
            }
            return summary
        }
        .filter { $0.usd > 0 || $0.tokens > 0 }
        .sorted { $0.usd == $1.usd ? $0.tokens > $1.tokens : $0.usd > $1.usd }
        for summary in out.projects {
            out.usd += summary.usd
            out.tokens += summary.tokens
            out.sessions += summary.sessions
            out.activeMinutes += summary.activeMinutes
            for (mode, tokens) in summary.byMode { out.byMode[mode, default: 0] += tokens }
            for (source, share) in summary.bySource {
                out.bySource[source, default: SourceShare()].usd += share.usd
                out.bySource[source, default: SourceShare()].tokens += share.tokens
            }
            out.modePairs.formUnion(summary.modePairs)
        }
        return out
    }
}

public struct SourceShare: Sendable, Equatable {
    public var usd: Double = 0
    public var tokens: Int = 0
    public init(usd: Double = 0, tokens: Int = 0) {
        self.usd = usd
        self.tokens = tokens
    }
}

/// One project over a stretch of days.
public struct ProjectSummary: Sendable, Equatable, Identifiable {
    public var info: ProjectInfo
    public var usd: Double = 0
    public var tokens: Int = 0
    public var billableTokens: Int = 0
    public var sessions: Int = 0
    public var activeMinutes: Int = 0
    public var activeDays: Int = 0
    public var lastActive: Date?
    public var bySource: [CostSource: SourceShare] = [:]
    public var byMode: [CodingMode: Int] = [:]
    /// `claudeCode|desktop`, one per way of working this project saw.
    public var modePairs: Set<String> = []
    public var modelSpend: [String: ModelSpend] = [:]
    /// One per day in the range, oldest first.
    public var daily: [ArchiveSummary.Day]
    /// Tokens by weekday (Monday first) and local hour.
    public var weekHours: [[Int]] = Array(repeating: Array(repeating: 0, count: 24), count: 7)

    public var id: String { info.key }

    init(info: ProjectInfo, dayCount: Int) {
        self.info = info
        self.daily = Array(repeating: ArchiveSummary.Day(day: .distantPast, usd: 0, tokens: 0), count: dayCount)
    }

    public var models: [ModelSpend] {
        modelSpend.values.filter { $0.usd > 0 || $0.tokens > 0 }
            .sorted { $0.usd == $1.usd ? $0.tokens > $1.tokens : $0.usd > $1.usd }
    }

    public var sources: [(source: CostSource, share: SourceShare)] {
        bySource.filter { $0.value.tokens > 0 || $0.value.usd > 0 }
            .sorted { $0.value.usd == $1.value.usd ? $0.value.tokens > $1.value.tokens : $0.value.usd > $1.value.usd }
            .map { (source: $0.key, share: $0.value) }
    }

    public var modes: [(mode: CodingMode, tokens: Int)] {
        byMode.filter { $0.value > 0 }.sorted { $0.value > $1.value }.map { (mode: $0.key, tokens: $0.value) }
    }
}

public struct ProjectOverview: Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var projects: [ProjectSummary] = []
    public var usd: Double = 0
    public var tokens: Int = 0
    public var sessions: Int = 0
    public var activeMinutes: Int = 0
    public var bySource: [CostSource: SourceShare] = [:]
    public var byMode: [CodingMode: Int] = [:]
    public var modePairs: Set<String> = []

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    /// Distinct CLI + mode combinations: "Claude Code desktop, Codex terminal, …".
    public var waysOfWorking: Int { modePairs.count }
}

/// The project archive on disk, next to the usage archive.
public final class ProjectArchiveStore: @unchecked Sendable {
    public static let shared = ProjectArchiveStore()

    private let lock = NSLock()
    private let fileURL: URL
    private var archive: ProjectArchive

    public init(fileURL: URL? = nil) {
        let url = fileURL ?? AppSupport.directory.appendingPathComponent("project-archive.json")
        self.fileURL = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        self.archive = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(ProjectArchive.self, from: $0) }
            ?? ProjectArchive()
    }

    public var current: ProjectArchive {
        lock.lock(); defer { lock.unlock() }
        return archive
    }

    func merge(_ days: ProjectDays, infos: [String: ProjectRef], scannedAt: Date, full: Bool) {
        lock.lock()
        archive.merge(days, infos: infos, scannedAt: scannedAt, full: full)
        let copy = archive
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(copy) { AppSupport.write(data, to: fileURL) }
    }
}
