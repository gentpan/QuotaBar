import Foundation

// MARK: - The run ledger: every reading, kept on this Mac

/// Every reading QuotaBar has taken, for 60 days, plus the personal bests
/// worked out from them — which outlive the readings.
///
/// Personal records need no account: this file is written whether or not the
/// owner ever joins Quota Run, and nothing reads it for upload until they do.
///
/// Unchanged readings are thinned rather than all kept. At a five-minute
/// cadence a handful of windows over 60 days is a quarter of a million rows,
/// nearly all of them "still 36%". A reading identical to the last one kept
/// for its window is dropped unless ten minutes have passed since, which
/// keeps the gap between kept readings well under the 20 minutes rule 4 of
/// the tiers allows. A change is always kept, so a threshold crossing is
/// recorded at the reading that crossed it.
public struct RunLedger: Sendable, Equatable {
    public static let retention = 60 * 86_400
    /// Longest an unchanged reading is left out for.
    public static let heartbeat = 600

    public private(set) var readings: [RunReading] = []
    public private(set) var nextSeq = 1
    public var bests: [PersonalBest] = []
    /// Index into `readings` of the last reading kept per `provider|windowKey`.
    private var lastBySeries: [String: Int] = [:]

    public init() {}

    public static func == (lhs: RunLedger, rhs: RunLedger) -> Bool {
        lhs.readings == rhs.readings && lhs.nextSeq == rhs.nextSeq && lhs.bests == rhs.bests
    }

    public var lastSeq: Int { nextSeq - 1 }

    /// Appends a reading unless it repeats one already kept. Returns the
    /// reading as stored, with its sequence number, or nil when dropped.
    @discardableResult
    public mutating func append(_ candidate: RunReading) -> RunReading? {
        let series = "\(candidate.provider)|\(candidate.windowKey)"
        var reading = candidate
        if let index = lastBySeries[series] {
            let last = readings[index]
            // Same instant for the same window is the same reading — what the
            // server dedupes on too. Older than what is kept is a cached
            // snapshot applied late.
            if candidate.observedAt <= last.observedAt { return nil }
            // A refresh that did not name the account, inside a period that
            // did, is the same account: one run carries one digest. A
            // different account arrives with a digest of its own.
            if reading.accountDigest == nil, last.accountDigest != nil,
               reading.resetsAt.map(RunMath.roundedReset) == last.resetsAt.map(RunMath.roundedReset)
            {
                reading.accountDigest = last.accountDigest
            }
            if Self.isUnchanged(reading, from: last), reading.observedAt - last.observedAt < Self.heartbeat {
                return nil
            }
        }
        reading.seq = nextSeq
        nextSeq += 1
        readings.append(reading)
        lastBySeries[series] = readings.count - 1
        return reading
    }

    static func isUnchanged(_ reading: RunReading, from last: RunReading) -> Bool {
        reading.usedPercent == last.usedPercent
            && reading.plan == last.plan
            && reading.accountDigest == last.accountDigest
            && reading.source == last.source
            && reading.resetsAt.map(RunMath.roundedReset) == last.resetsAt.map(RunMath.roundedReset)
    }

    /// Drops readings past the retention. Bests stay.
    public mutating func prune(now: Int) {
        let cutoff = now - Self.retention
        guard readings.contains(where: { $0.observedAt < cutoff }) else { return }
        readings.removeAll { $0.observedAt < cutoff }
        reindex()
    }

    /// Readings after a sequence number, oldest first.
    public func readings(after seq: Int) -> [RunReading] {
        // Sequence numbers only grow, so the tail is found by bisection.
        var low = 0, high = readings.count
        while low < high {
            let mid = (low + high) / 2
            if readings[mid].seq <= seq { low = mid + 1 } else { high = mid }
        }
        return Array(readings[low...])
    }

    private mutating func reindex() {
        lastBySeries = [:]
        for (index, reading) in readings.enumerated() {
            lastBySeries["\(reading.provider)|\(reading.windowKey)"] = index
        }
    }
}

// MARK: File format

/// Compact on purpose: the window's description is written once in `series`
/// and each reading is a five-element row
/// `[series, seq, observedAt, usedPercent, resetsAt|null]`.
extension RunLedger: Codable {
    private struct Series: Codable, Hashable {
        var provider: String
        var plan: String?
        var accountDigest: String?
        var windowKey: String
        var windowTitle: String
        var windowSeconds: Int
        var scope: String?
        var source: String
    }

    private enum CodingKeys: String, CodingKey { case version, nextSeq, series, rows, bests }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        var table: [Series] = []
        var index: [Series: Int] = [:]
        var rows: [[Double?]] = []
        rows.reserveCapacity(readings.count)
        for reading in readings {
            let series = Series(
                provider: reading.provider, plan: reading.plan, accountDigest: reading.accountDigest,
                windowKey: reading.windowKey, windowTitle: reading.windowTitle,
                windowSeconds: reading.windowSeconds, scope: reading.scope, source: reading.source)
            let slot: Int
            if let existing = index[series] {
                slot = existing
            } else {
                slot = table.count
                index[series] = slot
                table.append(series)
            }
            rows.append([
                Double(slot), Double(reading.seq), Double(reading.observedAt),
                reading.usedPercent, reading.resetsAt.map(Double.init),
            ])
        }
        try c.encode(1, forKey: .version)
        try c.encode(nextSeq, forKey: .nextSeq)
        try c.encode(table, forKey: .series)
        try c.encode(rows, forKey: .rows)
        try c.encode(bests, forKey: .bests)
    }

    /// A number, or nil for `null` and for anything else. Decoding one never
    /// fails, so one stray value cannot take its whole row down — or, since a
    /// failed element would fail the array, every row.
    private struct Cell: Decodable {
        let value: Double?

        init(from decoder: Decoder) throws {
            value = try? decoder.singleValueContainer().decode(Double.self)
        }
    }

    /// Lenient row by row: a malformed row is skipped, not the file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let table = (try? c.decodeIfPresent([Series].self, forKey: .series)) ?? []
        let rows = ((try? c.decodeIfPresent([[Cell]].self, forKey: .rows)) ?? []).map { $0.map(\.value) }
        var readings: [RunReading] = []
        readings.reserveCapacity(rows.count)
        for row in rows {
            guard row.count >= 4,
                  let slot = row[0].map(Int.init), table.indices.contains(slot),
                  let seq = row[1].map(Int.init),
                  let observed = row[2].map(Int.init),
                  let used = row[3], used.isFinite
            else { continue }
            let series = table[slot]
            readings.append(RunReading(
                seq: seq, provider: series.provider, plan: series.plan, accountDigest: series.accountDigest,
                windowKey: series.windowKey, windowTitle: series.windowTitle, windowSeconds: series.windowSeconds,
                scope: series.scope, usedPercent: used, resetsAt: row.count > 4 ? row[4].map(Int.init) : nil,
                observedAt: observed, source: series.source))
        }
        readings.sort { $0.seq < $1.seq }
        self.readings = readings
        let storedNext = (try? c.decodeIfPresent(Int.self, forKey: .nextSeq)) ?? 1
        // Never hand out a number already in the file, whatever it claims.
        self.nextSeq = max(storedNext, (readings.last?.seq ?? 0) + 1)
        self.bests = (try? c.decodeIfPresent([PersonalBest].self, forKey: .bests)) ?? []
        reindex()
    }
}

// MARK: - On disk

/// The ledger in Application Support (`runs.json`). Recording happens on
/// every refresh, so writes are coalesced: a change schedules one write a few
/// seconds out, and further changes before it ride along.
public final class RunLedgerStore: @unchecked Sendable {
    public static let shared = RunLedgerStore()

    private let lock = NSLock()
    private let fileURL: URL?
    private let saveDelay: TimeInterval
    private let queue = DispatchQueue(label: "bar.quota.run-ledger", qos: .utility)
    private var ledger: RunLedger
    private var saveScheduled = false

    /// `fileURL: nil` keeps the ledger in memory only — previews and tests.
    public init(fileURL: URL? = AppSupport.directory.appendingPathComponent("runs.json"), saveDelay: TimeInterval = 5, now: Date = Date()) {
        self.fileURL = fileURL
        self.saveDelay = saveDelay
        var loaded = fileURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(RunLedger.self, from: $0) } ?? RunLedger()
        loaded.prune(now: Int(now.timeIntervalSince1970))
        self.ledger = loaded
    }

    public var current: RunLedger {
        lock.lock(); defer { lock.unlock() }
        return ledger
    }

    public var lastSeq: Int {
        lock.lock(); defer { lock.unlock() }
        return ledger.lastSeq
    }

    public func readings(after seq: Int) -> [RunReading] {
        lock.lock(); defer { lock.unlock() }
        return ledger.readings(after: seq)
    }

    /// Records one provider's refresh. Returns how many readings were kept.
    @discardableResult
    public func record(provider: ProviderID, snapshot: UsageSnapshot) -> Int {
        record(RunReading.from(provider: provider, snapshot: snapshot))
    }

    @discardableResult
    public func record(_ readings: [RunReading]) -> Int {
        guard !readings.isEmpty else { return 0 }
        lock.lock()
        let kept = readings.reduce(0) { $0 + (ledger.append($1) == nil ? 0 : 1) }
        lock.unlock()
        if kept > 0 { scheduleSave() }
        return kept
    }

    public func setBests(_ bests: [PersonalBest]) {
        lock.lock()
        let changed = ledger.bests != bests
        ledger.bests = bests
        lock.unlock()
        if changed { scheduleSave() }
    }

    /// Writes now, for termination and tests.
    public func flush() {
        lock.lock()
        saveScheduled = false
        let snapshot = ledger
        lock.unlock()
        write(snapshot)
    }

    private func scheduleSave() {
        guard fileURL != nil else { return }
        lock.lock()
        let already = saveScheduled
        saveScheduled = true
        lock.unlock()
        guard !already else { return }
        queue.asyncAfter(deadline: .now() + saveDelay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.saveScheduled else { self.lock.unlock(); return }
            self.saveScheduled = false
            // The app runs for weeks; retention applies to memory too.
            self.ledger.prune(now: Int(Date().timeIntervalSince1970))
            let snapshot = self.ledger
            self.lock.unlock()
            self.write(snapshot)
        }
    }

    private func write(_ ledger: RunLedger) {
        guard let fileURL, let data = try? JSONEncoder().encode(ledger) else { return }
        AppSupport.write(data, to: fileURL)
    }
}
