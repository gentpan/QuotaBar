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
    private enum CodingKeys: String, CodingKey { case available, applicable }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            available: try c.decode(Int.self, forKey: .available),
            applicable: try c.decodeIfPresent(Int.self, forKey: .applicable))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(available, forKey: .available)
        try c.encodeIfPresent(applicable, forKey: .applicable)
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
public final class SnapshotCache: @unchecked Sendable {
    public static let shared = SnapshotCache()

    private let lock = NSLock()
    private let fileURL: URL
    private var snapshots: [String: UsageSnapshot]

    public init(fileURL: URL? = nil) {
        let url = fileURL ?? AppSupport.directory.appendingPathComponent("snapshots.json")
        self.fileURL = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        self.snapshots = (try? Data(contentsOf: url))
            .flatMap { try? decoder.decode([String: UsageSnapshot].self, from: $0) } ?? [:]
    }

    public func snapshot(for id: ProviderID) -> UsageSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return snapshots[id.rawValue]
    }

    public func store(_ snapshot: UsageSnapshot, for id: ProviderID) {
        lock.lock()
        snapshots[id.rawValue] = snapshot
        let copy = snapshots
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(copy) { AppSupport.write(data, to: fileURL) }
    }

    public func remove(_ id: ProviderID) {
        lock.lock()
        snapshots[id.rawValue] = nil
        let copy = snapshots
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(copy) { AppSupport.write(data, to: fileURL) }
    }
}
