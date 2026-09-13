import CryptoKit
import Foundation

// MARK: - Which projects go to quota.run, and the usage upload

/// A project the owner has decided about. Nothing is public until its switch
/// is turned on; turning it off takes it off quota.run on the next upload.
public struct SharedProject: Codable, Equatable, Sendable {
    /// The id quota.run knows the project by. For a repository it is derived
    /// from the remote, so every Mac with that checkout sends the same one;
    /// for a folder it is random.
    public var id: String
    public var name: String
    public var isPublic: Bool

    public init(id: String, name: String, isPublic: Bool) {
        self.id = id
        self.name = name
        self.isPublic = isPublic
    }
}

public struct ProjectSharingPrefs: Codable, Equatable, Sendable {
    public var projects: [String: SharedProject] = [:]
    /// Bumped whenever a switch or a name changes: the upload then sends every
    /// day again, so a project taken private leaves no public day behind.
    public var revision = 0
    /// Slugs quota.run answered with, by project id, for "View on quota.run".
    public var slugs: [String: String] = [:]

    public init() {}

    public func isPublic(_ key: String) -> Bool {
        projects[key]?.isPublic ?? false
    }

    public func name(for info: ProjectInfo) -> String {
        projects[info.key]?.name.nilIfEmpty ?? info.displayName
    }

    public func slug(for key: String) -> String? {
        projects[key].flatMap { slugs[$0.id] }
    }

    public mutating func setPublic(_ on: Bool, info: ProjectInfo) {
        guard !info.isUnknown else { return }
        var entry = projects[info.key] ?? SharedProject(id: Self.publicID(for: info.key), name: info.displayName, isPublic: false)
        guard entry.isPublic != on else { return }
        entry.isPublic = on
        projects[info.key] = entry
        revision += 1
    }

    public mutating func rename(_ key: String, to name: String, info: ProjectInfo) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        var entry = projects[key] ?? SharedProject(id: Self.publicID(for: key), name: info.displayName, isPublic: false)
        guard entry.name != trimmed else { return }
        entry.name = trimmed
        projects[key] = entry
        if entry.isPublic { revision += 1 }
    }

    /// `r` and 20 hex characters of the remote's SHA-256 for a repository;
    /// `l` and 20 random ones otherwise.
    public static func publicID(for key: String) -> String {
        if key.hasPrefix("local:") || key.hasPrefix("dir:") || key == "unknown" {
            let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
            return "l" + String((0..<20).map { _ in alphabet.randomElement()! })
        }
        let digest = SHA256.hash(data: Data("quota-run-project-v1\n\(key)".utf8))
        return "r" + digest.map { String(format: "%02x", $0) }.joined().prefix(20)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// `project-sharing.json`.
public final class ProjectSharingStore: @unchecked Sendable {
    public static let shared = ProjectSharingStore()

    private let lock = NSLock()
    private let fileURL: URL?
    private var prefs: ProjectSharingPrefs

    public init(fileURL: URL? = AppSupport.directory.appendingPathComponent("project-sharing.json")) {
        self.fileURL = fileURL
        prefs = fileURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(ProjectSharingPrefs.self, from: $0) }
            ?? ProjectSharingPrefs()
    }

    public var current: ProjectSharingPrefs {
        lock.lock(); defer { lock.unlock() }
        return prefs
    }

    @discardableResult
    public func update(_ change: (inout ProjectSharingPrefs) -> Void) -> ProjectSharingPrefs {
        lock.lock()
        change(&prefs)
        let copy = prefs
        lock.unlock()
        if let fileURL, let data = try? JSONEncoder().encode(copy) { AppSupport.write(data, to: fileURL) }
        return copy
    }
}

// MARK: Payloads

public struct RunUsageRow: Codable, Equatable, Sendable {
    public var date: String
    public var tool: String
    public var mode: String
    public var model: String
    public var project: String?
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var sessions: Int
    public var activeMinutes: Int
    /// Only for OpenCode, which records its own cost; quota.run prices the rest.
    public var costUSD: Double?
}

public struct RunUsageProject: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var repo: String?
}

public struct RunUsageBody: Codable, Equatable, Sendable {
    public var timezone: String
    public var days: [String]
    public var rows: [RunUsageRow]
    public var projects: [RunUsageProject]
    /// The project list is every public project: anything else is taken private.
    public var projectsComplete = true
}

public struct RunUsageReceipt: Decodable, Equatable, Sendable {
    public struct Project: Decodable, Equatable, Sendable {
        public var id: String
        public var slug: String
        public var repoVerified: Bool
    }

    public var accepted: Int
    public var days: Int
    public var projects: [Project]
}

public enum RunUsagePlan {
    /// Days quota.run takes, and how many go in one request.
    public static let historyDays = 395
    public static let batchDays = 30
    /// Recent days are sent again this often; today and yesterday still grow.
    public static let interval: TimeInterval = 600
    public static let recentDays = 3

    /// One day's rows: public projects under their id, everything else folded
    /// together without one. Sessions and minutes ride on the first model row
    /// of each project, CLI and mode, so they are not counted once per model.
    public static func rows(day: String, archive: ProjectArchive, sharing: ProjectSharingPrefs) -> [RunUsageRow] {
        var out: [String: RunUsageRow] = [:]
        for (projectKey, sources) in archive.days[day] ?? [:] {
            let project = sharing.isPublic(projectKey) ? sharing.projects[projectKey]?.id : nil
            for (rawSource, modes) in sources {
                guard let source = CostSource(rawValue: rawSource) else { continue }
                for (mode, entry) in modes {
                    var first = true
                    for (model, counts) in entry.models.sorted(by: { $0.key < $1.key }) where counts.allTokens > 0 || counts.usd > 0 {
                        let key = [source.runSource, mode, model, project ?? ""].joined(separator: "\u{1F}")
                        var row = out[key] ?? RunUsageRow(
                            date: day, tool: source.runSource, mode: mode, model: String(model.prefix(100)), project: project,
                            input: 0, output: 0, cacheRead: 0, cacheWrite: 0, sessions: 0, activeMinutes: 0,
                            costUSD: source == .openCode ? 0 : nil)
                        row.input += counts.input
                        row.output += counts.output
                        row.cacheRead += counts.cacheRead
                        row.cacheWrite += counts.cacheWrite
                        if source == .openCode { row.costUSD = (row.costUSD ?? 0) + counts.usd }
                        if first {
                            row.sessions += entry.sessions
                            row.activeMinutes += min(entry.activeMinutes, 1_440)
                            first = false
                        }
                        out[key] = row
                    }
                }
            }
        }
        return out.values.sorted { ($0.tool, $0.mode, $0.model, $0.project ?? "") < ($1.tool, $1.mode, $1.model, $1.project ?? "") }
    }

    /// The request for `days`; the archive is the canonical one, folders
    /// folded into their repositories.
    public static func body(days: [String], archive: ProjectArchive, sharing: ProjectSharingPrefs, timezone: TimeZone = .current) -> RunUsageBody {
        let projects = sharing.projects
            .filter { $0.value.isPublic && archive.projects[$0.key] != nil }
            .map { key, entry in
                RunUsageProject(id: entry.id, name: entry.name.isEmpty ? (archive.projects[key]?.displayName ?? "") : entry.name,
                                repo: archive.projects[key]?.repo)
            }
            .sorted { $0.id < $1.id }
        let rows = days.flatMap { rows(day: $0, archive: archive, sharing: sharing) }
        return RunUsageBody(timezone: timezone.identifier, days: days, rows: rows, projects: projects)
    }

    /// Every day the archive holds that quota.run still takes, newest first.
    public static func allDays(in archive: ProjectArchive, now: Date = Date(), calendar: Calendar = .current) -> [String] {
        let oldest = UsageArchive.dayKey(calendar.date(byAdding: .day, value: -historyDays, to: now) ?? now)
        return archive.days.keys.filter { $0 >= oldest }.sorted(by: >)
    }

    /// Today and the days before it.
    public static func recent(now: Date = Date(), calendar: Calendar = .current) -> [String] {
        (0..<recentDays).compactMap { calendar.date(byAdding: .day, value: -$0, to: now).map(UsageArchive.dayKey) }
    }
}
