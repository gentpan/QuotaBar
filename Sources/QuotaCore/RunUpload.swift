import Foundation

// MARK: - Joining and uploading, the parts that are not UI

/// What this Mac knows about its Quota Run membership. Absent until the owner
/// joins; deleted, with the key, when they leave. Holds nothing secret — the
/// key lives in the keychain.
public struct RunAccountState: Codable, Equatable, Sendable {
    public var username: String
    public var displayName: String
    public var region: RunRegion
    public var deviceId: String
    public var joinedAt: Date
    /// Whether this Mac's readings count, as `/me` or registration last said.
    public var ranked: Bool
    public var me: RunMe?
    public var meFetchedAt: Date?

    public init(username: String, displayName: String, region: RunRegion, deviceId: String, joinedAt: Date, ranked: Bool, me: RunMe? = nil, meFetchedAt: Date? = nil) {
        self.username = username
        self.displayName = displayName
        self.region = region
        self.deviceId = deviceId
        self.joinedAt = joinedAt
        self.ranked = ranked
        self.me = me
        self.meFetchedAt = meFetchedAt
    }

    private enum CodingKeys: String, CodingKey { case username, displayName, region, deviceId, joinedAt, ranked, me, meFetchedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        username = try c.decode(String.self, forKey: .username)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        displayName = (try? c.decodeIfPresent(String.self, forKey: .displayName)) ?? username
        region = (try? c.decodeIfPresent(String.self, forKey: .region)).flatMap(RunRegion.init(rawValue:)) ?? .global
        joinedAt = c.lenientDate(.joinedAt) ?? Date()
        ranked = (try? c.decodeIfPresent(Bool.self, forKey: .ranked)) ?? false
        me = try? c.decodeIfPresent(RunMe.self, forKey: .me)
        meFetchedAt = c.lenientDate(.meFetchedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(username, forKey: .username)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(region, forKey: .region)
        try c.encode(deviceId, forKey: .deviceId)
        try c.encode(Int(joinedAt.timeIntervalSince1970), forKey: .joinedAt)
        try c.encode(ranked, forKey: .ranked)
        try c.encodeIfPresent(me, forKey: .me)
        try c.encodeIfPresent(meFetchedAt.map { Int($0.timeIntervalSince1970) }, forKey: .meFetchedAt)
    }

    /// `https://quota.run/@username`.
    public var profileURL: URL {
        URL(string: "https://quota.run/@\(username)") ?? URL(string: "https://quota.run/")!
    }
}

/// Where the upload has got to. The cursors are what make a queue: a reading
/// is "not yet sent" while its sequence number is past `sentSeq`, so readings
/// taken offline simply wait in the ledger.
public struct RunUploadState: Codable, Equatable, Sendable {
    /// The last ledger sequence number sent (or skipped as too old).
    public var sentSeq: Int = 0
    /// The last activity minute sent.
    public var activityMinute: Int = 0
    public var lastUploadAt: Date?
    public var lastAttemptAt: Date?
    public var lastError: String?
    /// Consecutive failures, for the backoff.
    public var failures: Int = 0
    public var retryAt: Date?
    /// Set on 401/403: the key is not accepted, and sending again will not
    /// change that.
    public var stopped: Bool = false
    public var lastAccepted: Int = 0
    public var lastRejected: Int = 0

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case sentSeq, activityMinute, lastUploadAt, lastAttemptAt, lastError, failures, retryAt, stopped, lastAccepted, lastRejected
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sentSeq = (try? c.decodeIfPresent(Int.self, forKey: .sentSeq)) ?? 0
        activityMinute = (try? c.decodeIfPresent(Int.self, forKey: .activityMinute)) ?? 0
        lastUploadAt = c.lenientDate(.lastUploadAt)
        lastAttemptAt = c.lenientDate(.lastAttemptAt)
        lastError = try? c.decodeIfPresent(String.self, forKey: .lastError)
        failures = (try? c.decodeIfPresent(Int.self, forKey: .failures)) ?? 0
        retryAt = c.lenientDate(.retryAt)
        stopped = (try? c.decodeIfPresent(Bool.self, forKey: .stopped)) ?? false
        lastAccepted = (try? c.decodeIfPresent(Int.self, forKey: .lastAccepted)) ?? 0
        lastRejected = (try? c.decodeIfPresent(Int.self, forKey: .lastRejected)) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        func seconds(_ date: Date?) -> Int? { date.map { Int($0.timeIntervalSince1970) } }
        try c.encode(sentSeq, forKey: .sentSeq)
        try c.encode(activityMinute, forKey: .activityMinute)
        try c.encodeIfPresent(seconds(lastUploadAt), forKey: .lastUploadAt)
        try c.encodeIfPresent(seconds(lastAttemptAt), forKey: .lastAttemptAt)
        try c.encodeIfPresent(lastError, forKey: .lastError)
        try c.encode(failures, forKey: .failures)
        try c.encodeIfPresent(seconds(retryAt), forKey: .retryAt)
        try c.encode(stopped, forKey: .stopped)
        try c.encode(lastAccepted, forKey: .lastAccepted)
        try c.encode(lastRejected, forKey: .lastRejected)
    }
}

/// `quota-run.json`: membership and upload progress in one small file.
public struct RunStateFile: Codable, Equatable, Sendable {
    public var account: RunAccountState?
    public var upload = RunUploadState()

    public init(account: RunAccountState? = nil, upload: RunUploadState = RunUploadState()) {
        self.account = account
        self.upload = upload
    }

    private enum CodingKeys: String, CodingKey { case account, upload }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        account = try? c.decodeIfPresent(RunAccountState.self, forKey: .account)
        upload = (try? c.decodeIfPresent(RunUploadState.self, forKey: .upload)) ?? RunUploadState()
    }

    public static func load(from url: URL) -> RunStateFile {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(RunStateFile.self, from: $0) } ?? RunStateFile()
    }

    public func save(to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(self) { AppSupport.write(data, to: url) }
    }
}

/// One upload's worth of what is waiting, and where the cursors land if it
/// goes through.
public struct RunUploadBatch: Equatable, Sendable {
    public var snapshots: [RunSnapshotPayload]
    public var activity: [RunActivityPayload]
    /// The cursors after this batch — past what it carries and past anything
    /// skipped as too old for the server to take.
    public var sentSeq: Int
    public var activityMinute: Int
    /// More is waiting beyond the batch limits.
    public var hasMore: Bool

    public var isEmpty: Bool { snapshots.isEmpty && activity.isEmpty }
}

public enum RunUploadPlan {
    public static let snapshotLimit = 500
    public static let activityLimit = 1_440
    /// The server takes readings from the last 7 days; ten minutes' margin so
    /// a batch that queues briefly is not refused at the edge.
    public static let maximumAge = 7 * 86_400 - 600
    public static let maximumAhead = 300
    public static let minimumInterval: TimeInterval = 60

    public static func batch(readings: [RunReading], activity: ActivityMinutes, state: RunUploadState, now: Date) -> RunUploadBatch {
        let clock = Int(now.timeIntervalSince1970)
        var cursor = state.sentSeq
        var snapshots: [RunSnapshotPayload] = []
        var hasMore = false
        for reading in readings.sorted(by: { $0.seq < $1.seq }) where reading.seq > state.sentSeq {
            if snapshots.count == snapshotLimit {
                hasMore = true
                break
            }
            cursor = reading.seq
            // Too old or from the future: the server would reject it, and
            // it will never become acceptable. Step past it.
            guard reading.observedAt >= clock - maximumAge, reading.observedAt <= clock + maximumAhead,
                  RunMath.isInsideWindow(reading) else { continue }
            snapshots.append(RunSnapshotPayload(reading))
        }

        var minute = state.activityMinute
        var entries: [RunActivityPayload] = []
        let oldest = clock - maximumAge
        let pending = activity.completeEntries(after: max(state.activityMinute, oldest - 60))
        var index = 0
        while index < pending.count {
            // A minute goes whole or waits, so the cursor never splits one.
            let key = pending[index].minute
            var end = index
            while end < pending.count, pending[end].minute == key { end += 1 }
            if entries.count + (end - index) > activityLimit {
                hasMore = true
                break
            }
            entries.append(contentsOf: pending[index..<end])
            minute = key
            index = end
        }
        return RunUploadBatch(snapshots: snapshots, activity: entries, sentSeq: cursor, activityMinute: minute, hasMore: hasMore)
    }

    /// Seconds to wait after `failures` failures in a row: a minute, doubling,
    /// capped at an hour.
    public static func backoff(failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return min(3_600, 60 * pow(2, Double(min(failures - 1, 10))))
    }
}
