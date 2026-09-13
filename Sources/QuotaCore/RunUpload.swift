import Foundation

// MARK: - Signing in and uploading, the parts that are not UI

/// What this Mac knows about its Quota Run account. Absent until the owner
/// signs in and quota.run approves this Mac; deleted, with the key, when the
/// Mac disconnects or the account is deleted. Holds nothing secret — the key
/// lives in the keychain.
public struct RunAccountState: Codable, Equatable, Sendable {
    public var username: String
    public var displayName: String
    public var region: RunRegion
    public var deviceId: String
    public var joinedAt: Date
    /// Whether this Mac's readings count, as `/me` or the approval last said.
    public var ranked: Bool
    public var me: RunMe?
    public var meFetchedAt: Date?
    /// Provider account digests the owner unbound on this Mac: their readings
    /// are not uploaded until bound again. Goes with the account.
    public var excludedDigests: Set<String>
    /// What `accounts/lookup` last said, by digest; a digest it did not know
    /// is absent. Only digests and quota.run's own ids — never an email.
    public var accountLookups: [String: RunProviderAccount]
    public var accountsCheckedAt: Date?

    public init(
        username: String, displayName: String, region: RunRegion, deviceId: String, joinedAt: Date, ranked: Bool,
        me: RunMe? = nil, meFetchedAt: Date? = nil, excludedDigests: Set<String> = [],
        accountLookups: [String: RunProviderAccount] = [:], accountsCheckedAt: Date? = nil)
    {
        self.username = username
        self.displayName = displayName
        self.region = region
        self.deviceId = deviceId
        self.joinedAt = joinedAt
        self.ranked = ranked
        self.me = me
        self.meFetchedAt = meFetchedAt
        self.excludedDigests = excludedDigests
        self.accountLookups = accountLookups
        self.accountsCheckedAt = accountsCheckedAt
    }

    private enum CodingKeys: String, CodingKey {
        case username, displayName, region, deviceId, joinedAt, ranked, me, meFetchedAt, excludedDigests, accountLookups, accountsCheckedAt
    }

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
        excludedDigests = Set(((try? c.decodeIfPresent([String].self, forKey: .excludedDigests)) ?? []).map { $0.lowercased() })
        accountLookups = (try? c.decodeIfPresent([String: RunProviderAccount].self, forKey: .accountLookups)) ?? [:]
        accountsCheckedAt = c.lenientDate(.accountsCheckedAt)
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
        try c.encode(excludedDigests.sorted(), forKey: .excludedDigests)
        try c.encode(accountLookups, forKey: .accountLookups)
        try c.encodeIfPresent(accountsCheckedAt.map { Int($0.timeIntervalSince1970) }, forKey: .accountsCheckedAt)
    }

    /// Where one of this Mac's provider accounts stands.
    public func standing(of digest: String) -> RunAccountStanding {
        RunAccountStanding.of(digest: digest, lookups: accountLookups, excluded: excludedDigests)
    }

    /// Folds a lookup in: known accounts are kept, and a digest quota.run
    /// answered null for is dropped.
    public mutating func apply(_ lookups: [RunAccountLookup], at date: Date) {
        for entry in lookups {
            accountLookups[entry.digest] = entry.account
        }
        accountsCheckedAt = date
    }

    /// `https://quota.run/@username`.
    public var profileURL: URL {
        URL(string: "https://quota.run/@\(username)") ?? URL(string: "https://quota.run/")!
    }

    /// The account page on quota.run — sign-in methods, Macs, deletion — in
    /// the interface's language.
    public static func accountURL(chinese: Bool = L10n.isChinese) -> URL {
        URL(string: chinese ? "https://quota.run/zh/account" : "https://quota.run/account")!
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
    /// Usage by project: when recent days last went, which sharing revision
    /// every day has been sent under (-1: never), and the days still to send.
    public var usageSentAt: Date?
    public var usageRevision: Int = -1
    public var usagePending: [String] = []
    public var usageError: String?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case sentSeq, activityMinute, lastUploadAt, lastAttemptAt, lastError, failures, retryAt, stopped, lastAccepted, lastRejected
        case usageSentAt, usageRevision, usagePending, usageError
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
        usageSentAt = c.lenientDate(.usageSentAt)
        usageRevision = (try? c.decodeIfPresent(Int.self, forKey: .usageRevision)) ?? -1
        usagePending = (try? c.decodeIfPresent([String].self, forKey: .usagePending)) ?? []
        usageError = try? c.decodeIfPresent(String.self, forKey: .usageError)
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
        try c.encodeIfPresent(seconds(usageSentAt), forKey: .usageSentAt)
        try c.encode(usageRevision, forKey: .usageRevision)
        try c.encode(usagePending, forKey: .usagePending)
        try c.encodeIfPresent(usageError, forKey: .usageError)
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
    /// skipped: too old for the server, without an account digest, or unbound.
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

    /// Whether a reading goes up at all: it names a provider account the owner
    /// has not unbound, and the server would still take it. Anything else is
    /// stepped over for good — it will never become acceptable.
    public static func isUploadable(_ reading: RunReading, excluded: Set<String>, clock: Int) -> Bool {
        guard let digest = reading.accountDigest, !excluded.contains(digest) else { return false }
        return reading.observedAt >= clock - maximumAge && reading.observedAt <= clock + maximumAhead
            && RunMath.isInsideWindow(reading)
    }

    public static func batch(readings: [RunReading], activity: ActivityMinutes, state: RunUploadState, excluded: Set<String> = [], now: Date) -> RunUploadBatch {
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
            // No account digest (it could never rank), an unbound account,
            // too old or from the future: step past it.
            guard isUploadable(reading, excluded: excluded, clock: clock) else { continue }
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
