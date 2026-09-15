import Foundation

// MARK: - Last readings on disk, so a launch shows numbers at once

/// Where QuotaBar keeps what is not a preference: the last readings, the
/// usage archive, exchange rates. Created 0700 on first use.
public enum AppSupport {
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let url = base.appendingPathComponent("QuotaBar", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    /// Writes atomically and owner-only: these files name accounts.
    public static func write(_ data: Data, to url: URL) {
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

extension ResetCredits: Codable {
    private enum CodingKeys: String, CodingKey { case available, applicable, expirations }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            available: try c.decode(Int.self, forKey: .available),
            applicable: try c.decodeIfPresent(Int.self, forKey: .applicable),
            expirations: (try? c.decodeIfPresent([Date].self, forKey: .expirations)) ?? [])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(available, forKey: .available)
        try c.encodeIfPresent(applicable, forKey: .applicable)
        if !expirations.isEmpty { try c.encode(expirations, forKey: .expirations) }
    }
}

extension UsageWindow: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, title, usedPercent, detail, resetsAt, isActive, windowSeconds, scope
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title: try c.decode(String.self, forKey: .title),
            usedPercent: try c.decodeIfPresent(Double.self, forKey: .usedPercent),
            detail: try c.decodeIfPresent(String.self, forKey: .detail),
            resetsAt: try c.decodeIfPresent(Date.self, forKey: .resetsAt),
            isActive: (try? c.decodeIfPresent(Bool.self, forKey: .isActive)) ?? false,
            windowSeconds: try c.decodeIfPresent(Int.self, forKey: .windowSeconds),
            scope: try c.decodeIfPresent(String.self, forKey: .scope))
        if let id = try c.decodeIfPresent(String.self, forKey: .id) { self.id = id }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(usedPercent, forKey: .usedPercent)
        try c.encodeIfPresent(detail, forKey: .detail)
        try c.encodeIfPresent(resetsAt, forKey: .resetsAt)
        try c.encode(isActive, forKey: .isActive)
        try c.encodeIfPresent(windowSeconds, forKey: .windowSeconds)
        try c.encodeIfPresent(scope, forKey: .scope)
    }
}

extension UsageSnapshot: Codable {
    private enum CodingKeys: String, CodingKey { case planName, account, windows, fetchedAt, resetCredits }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            planName: try c.decodeIfPresent(String.self, forKey: .planName),
            account: try c.decodeIfPresent(String.self, forKey: .account),
            windows: (try? c.decodeIfPresent([UsageWindow].self, forKey: .windows)) ?? [],
            fetchedAt: try c.decode(Date.self, forKey: .fetchedAt),
            resetCredits: try? c.decodeIfPresent(ResetCredits.self, forKey: .resetCredits))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(planName, forKey: .planName)
        try c.encodeIfPresent(account, forKey: .account)
        try c.encode(windows, forKey: .windows)
        try c.encode(fetchedAt, forKey: .fetchedAt)
        try c.encodeIfPresent(resetCredits, forKey: .resetCredits)
    }
}

/// The last good reading per provider. openusage's stale-while-revalidate:
/// the panel opens on these at launch and the first refresh replaces them,
/// so a cold start never shows a column of spinners.
///
/// A reading is worded when it is taken — window names, plan details — so the
/// file remembers the language it was written in, and a launch in the other
/// language starts without it rather than showing the old wording.
public final class SnapshotCache: @unchecked Sendable {
    public static let shared = SnapshotCache()

    private struct File: Codable {
        var language: String
        var snapshots: [String: UsageSnapshot]
    }

    private let lock = NSLock()
    private let fileURL: URL
    private var snapshots: [String: UsageSnapshot]
    private var language: String

    public init(fileURL: URL? = nil) {
        let url = fileURL ?? AppSupport.directory.appendingPathComponent("snapshots.json")
        self.fileURL = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let data = try? Data(contentsOf: url), let file = try? decoder.decode(File.self, from: data) {
            self.snapshots = file.snapshots
            self.language = file.language
        } else {
            // Nothing, or the earlier bare map with no language recorded:
            // which language that was is a guess, so it is not shown.
            self.snapshots = [:]
            self.language = Self.currentLanguage
        }
    }

    private static var currentLanguage: String { L10n.isChinese ? "zh" : "en" }

    public func snapshot(for id: ProviderID) -> UsageSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard language == Self.currentLanguage else { return nil }
        return snapshots[id.rawValue]
    }

    public func store(_ snapshot: UsageSnapshot, for id: ProviderID) {
        write { snapshots in snapshots[id.rawValue] = snapshot }
    }

    public func remove(_ id: ProviderID) {
        write { snapshots in snapshots[id.rawValue] = nil }
    }

    private func write(_ change: (inout [String: UsageSnapshot]) -> Void) {
        lock.lock()
        let current = Self.currentLanguage
        // Readings in the other language are no use to this one.
        if language != current {
            snapshots = [:]
            language = current
        }
        change(&snapshots)
        let file = File(language: language, snapshots: snapshots)
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(file) { AppSupport.write(data, to: fileURL) }
    }
}
